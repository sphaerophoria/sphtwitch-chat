const std = @import("std");

const GlobalPackedInfo = packed struct {
    ct_size: u3,
    sort: bool,
    color_res: u3,
    ct_present: bool,
};

const RGB = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub fn readColorTable(alloc: std.mem.Allocator, r: *std.Io.Reader, size_flag: u8) ![]RGB {
    const ct_size_bytes = 3 * @as(usize, 1) << @intCast(@as(u8, size_flag) + 1);

    const ret = try alloc.alloc(RGB, ct_size_bytes);

    const color_table = try r.take(ct_size_bytes);
    var i: usize = 0;
    while (i < color_table.len) {
        defer i += 3;
        const red = color_table[i + 0];
        const g = color_table[i + 1];
        const b = color_table[i + 2];

        ret[i / 3] = .{ .r = red, .g = g , .b = b };
        std.debug.print("{d}: {any}\n", .{i, color_table[i..][0..3]});
    }

    return ret;
}

pub fn main() !void {
    var alloc = std.heap.FixedBufferAllocator.init(try std.heap.page_allocator.alloc(u8, 50 * 1024 * 1024));

    var gif_data_buf: [4 * 1024 * 1024]u8 = undefined;
    const gif_data = try std.fs.cwd().readFile("/home/streamer/test3.gif", &gif_data_buf);

    var r = std.Io.Reader.fixed(gif_data);

    const sig = try r.take(3);
    const version = try r.take(3);

    if (!std.mem.eql(u8, sig, "GIF")) {
        return error.InvalidSig;
    }

    if (!std.mem.eql(u8, version, "89a")) {
        return error.InvalidVersion;
    }

    const width = try r.takeInt(u16, .little);
    const height = try r.takeInt(u16, .little);
    std.debug.print("{d}x{d}\n", .{width, height});

    const global_packed = try r.takeStruct(GlobalPackedInfo, .little);
    const background_color = try r.takeByte();
    const pixel_aspect = try r.takeByte();

    std.debug.print("{any}\n", .{global_packed});
    std.debug.print("color {any}\n", .{background_color});
    std.debug.print("aspect {any}\n", .{pixel_aspect});

    var global_ct: []const RGB = &.{};
    if (global_packed.ct_present) {
        global_ct = try readColorTable(alloc.allocator(), &r, global_packed.ct_size);
    }

    while (true) {
        const block_type = try r.takeByte();
        switch (block_type) {
            '!' => {
                const label = try r.takeByte();

                std.debug.print("label: {x}\n", .{label});
                const block_size = try r.takeByte();

                const extension_header = try r.take(block_size);
                std.debug.print("{s}\n", .{extension_header});

                while (true) {
                    const sub_size = try r.takeByte();
                    if (sub_size == 0) break;
                    try r.discardAll(sub_size);
                }
            },
            ',' => {
                const left = try r.takeInt(u16, .little);
                const top = try r.takeInt(u16, .little);
                const image_width = try r.takeInt(u16, .little);
                const image_height = try r.takeInt(u16, .little);

                const ImageDescriptorOptions = packed struct {
                    lct_size: u3,
                    reserved: u2,
                    sort: bool,
                    interlace: bool,
                    lct_present: bool,
                };

                const options = try r.takeStruct(ImageDescriptorOptions, .little);

                std.debug.print("image block: {d} {d} {d}x{d}\n", .{left, top, image_width, image_height});

                var color_table = global_ct;
                if (options.lct_present) {
                    std.debug.print("local ct\n", .{});
                    color_table = try readColorTable(alloc.allocator(), &r, options.lct_size);
                }
                std.debug.assert(global_packed.ct_present or options.lct_present);


                var ppmf = try std.fs.cwd().createFile("test.ppm", .{});
                var ppmw_buf: [4096]u8 = undefined;
                var ppmw = ppmf.writer(&ppmw_buf);
                try ppmw.interface.print(
                    \\P6
                    \\{d} {d}
                    \\255
                    \\
                    , .{image_width, image_height});


                const lzw_min_code_size = try r.takeByte();
                var sdr_buf: [4096]u8 = undefined;
                var sdr = SubDataReader.init(&r, &sdr_buf);

                // FIXME: Lol
                var scratch = std.heap.FixedBufferAllocator.init(try std.heap.page_allocator.alloc(u8, 50 * 1024 * 1024));

                std.debug.print("code len: {d}\n", .{lzw_min_code_size});
                var lzwd = try LzwDecompressor.init(alloc.allocator(), lzw_min_code_size, &sdr.interface);
                var written_bytes: usize = 0;
                while (try lzwd.step()) |seq| {
                    scratch.end_index = 0;
                    written_bytes += seq.len;
                    std.debug.print("seq: {any}\n", .{seq});
                    for (seq) |elem| {
                        std.debug.print("elem: {d}\n", .{elem});
                        const color = global_ct[elem];
                        try ppmw.interface.writeByte(color.r);
                        try ppmw.interface.writeByte(color.g);
                        try ppmw.interface.writeByte(color.b);
                    }
                }
                try ppmw.interface.flush();

                const image_data_len = try sdr.interface.discardRemaining();
                std.debug.print("parsed bytes: {d}, remaining data {d}\n", .{written_bytes, image_data_len});
                if (true) return;
            },
            ';' => break,
            else => {
                std.debug.print("invalid block: {c}\n", .{block_type});
                return error.InvalidBlockType;
            },
        }
    }
}

const SubDataReader = struct {
    input: *std.Io.Reader,
    interface: std.Io.Reader,
    block_remaining_len: u8,

    pub fn init(r: *std.Io.Reader, buffer: []u8) SubDataReader {
        return .{
            .input = r,
            .interface = .{
                .seek = 0,
                .end = 0,
                .buffer = buffer,
                .vtable = &.{
                    .stream = stream,
                },
            },
            .block_remaining_len = 0,
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *SubDataReader = @fieldParentPtr("interface", r);

        if (self.block_remaining_len == 0) {
            self.block_remaining_len = try self.input.takeByte();
            if (self.block_remaining_len == 0) return error.EndOfStream;
        }

        const merged_limit = limit.min(.limited(self.block_remaining_len));
        const out_slice = merged_limit.slice(try w.writableSliceGreedy(1));
        const read_bytes = try self.input.readSliceShort(out_slice);

        self.block_remaining_len -= @intCast(read_bytes);
        w.advance(read_bytes);

        return read_bytes;
    }
};

const LzwDecompressor = struct {
    input: *std.Io.Reader,

    initial_code_size: u8,
    code_size_bits: u8,

    next_byte: u8,
    bits_remaining: u4,

    alloc: std.mem.Allocator,

    dict2: Dict,

    last_code: ?Code = null,

    buffered_seq_2: std.ArrayList(Code),

    const Code = u12;
    const Sequence = []u12;


    pub fn init(alloc: std.mem.Allocator, initial_code_len: u8, r: *std.Io.Reader) !LzwDecompressor {
        return .{
            .input = r,
            .initial_code_size = initial_code_len,
            .code_size_bits = initial_code_len + 1,
            .next_byte = 0,
            .bits_remaining = 0,
            .buffered_seq_2 = .initBuffer(try alloc.alloc(Code, 128)),
            .alloc = alloc,
            .last_code = null,
            .dict2 = .{
                .alloc = alloc,
                .initial_len = initial_code_len,
                .inner = .{},
            },
        };

    }

    pub fn step(self: *LzwDecompressor) !?u12 {
        if (self.buffered_seq_2.pop()) |val| {
            return val;
        }

        //std.debug.print("next code\n", .{});
        const next_code = try self.readCode();

        std.debug.print("got code: {d} ({d})\n", .{next_code, self.code_size_bits});

        if (next_code == @as(u12, 1) << @intCast(self.initial_code_size)) {
            std.debug.print("Rebuilding dictionary: {d}\n", .{self.initial_code_size});
            self.code_size_bits = self.initial_code_size;
            self.dict2.reset();
            self.last_code = null;
            self.code_size_bits = self.initial_code_size + 1;
            // FIXME: recursion
            return self.step();
        }

        if (next_code == (@as(u12, 1) << @intCast(self.initial_code_size)) + 1) {
            std.debug.print("Donezo\n", .{});
            return null;
        }

        defer self.last_code = next_code;


        if (!self.dict2.inRagne(next_code)) {

            var last_seq_start: Code = undefined;
            {
                var it = self.dict2.parentIter(self.last_code.?);
                while (it.next()) |val| last_seq_start = val;
            }

            std.debug.print("path 1\n", .{});

            const new_code =try self.dict2.append(last_seq_start, self.last_code.?);
            self.updateCodeSize(new_code);
            var it = self.dict2.parentIter(new_code);
            self.buffered_seq_2.clearRetainingCapacity();

            while (it.next()) |code| {
                std.debug.print("got elem {d}\n", .{code});
                try self.buffered_seq_2.appendBounded(code);
            }

            return self.buffered_seq_2.pop().?;
        }

        var it = self.dict2.parentIter(next_code);
        self.buffered_seq_2.clearRetainingCapacity();


        while (it.next()) |code| {
            std.debug.print("got elem {d}\n", .{code});
            try self.buffered_seq_2.appendBounded(code);
        }

        const ret = self.buffered_seq_2.pop().?;

        // FIXME: Actually error instead of crash
        if (self.last_code) |lc| {
            std.debug.print("last code: {d}\n", .{lc});
            std.debug.print("path 2\n", .{});

            self.updateCodeSize(try self.dict2.append(ret, lc));

        }
        return ret;

    }

    fn updateCodeSize(self: *LzwDecompressor, new_code: Code) void {
        if (new_code + 1 >= (@as(Code, 1) << @intCast(self.code_size_bits))) {
            self.code_size_bits += 1;
        }
    }

    fn appendSequence(self: *LzwDecompressor, seq: []u12) !void {
        try self.dictionary.append(self.alloc, seq);
        std.debug.print("Inserted {any} at {d}\n", .{seq, self.dictionary.items.len - 1});
    }

    fn rebuildDict(alloc: std.mem.Allocator, initial_code_len: u8, dict: *std.ArrayListUnmanaged(Sequence)) !void {
        dict.clearRetainingCapacity();

        // FIXME: dict doesn't need 0..initial_code_len idiot
        for (0..(@as(usize, 1) << @intCast(initial_code_len))) |i| {
            const sequence = try alloc.alloc(Code, 1);
            sequence[0] = @intCast(i);
            try dict.append(alloc, sequence);
        }

        try dict.append(alloc, &.{});
        try dict.append(alloc, &.{});
    }

    fn readCode(self: *LzwDecompressor) !u12 {
        // self.code_size_bits: 5
        // self.bits_remaining:  3
        var code_remaining_bits: u8 = self.code_size_bits;

        var out: u12 = 0;
        var out_shift: u4 = 0;

        //std.debug.print("code time\n", .{});
        while (code_remaining_bits > 0) {
            //std.debug.print("remaining_bits: {d}, out: {d}, out_shift: {d}\n", .{code_remaining_bits, out, out_shift});
            if (self.bits_remaining == 0) {
                self.next_byte = try self.input.takeByte();
                //std.debug.print("pulling next byte: {x}\n", .{self.next_byte});
                self.bits_remaining = 8;
            }

            const bits_pulled = @min(code_remaining_bits, self.bits_remaining);

            self.bits_remaining -= bits_pulled;
            code_remaining_bits -= bits_pulled;

            //std.debug.print("{d} {d}\n", .{bits_pulled, out_shift});
            //std.debug.print("next byte: {x}\n", .{self.next_byte});
            const mask: u8 = @intCast((@as(u16, 1) << bits_pulled) - 1);
            out |= @as(Code, (self.next_byte & mask)) << @intCast(out_shift);
            out_shift += bits_pulled;

            if (bits_pulled < 8) {
                self.next_byte >>= @intCast(bits_pulled);
            }
        }

        return out;
    }

    const Dict = struct {
        alloc: std.mem.Allocator,
        inner: std.ArrayList(DictItem),
        initial_len: u8,

        // Index (where in inner we live)
        // Code (value coming from decoder)
        // Sequence item (element to be exposed to caller)

        const Idx = struct {
            inner: usize,
        };

        const SequenceItem = struct {
            inner: Code,
        };

        const DictItem = struct {
            parent: Code,
            item: SequenceItem,
        };

        const QueryRes = struct {
            parent: ?Code,
            item: SequenceItem,
        };


        fn query(self: *Dict, code: Code) QueryRes {
            const offs = self.calcOffs();
            if (code < offs) {
                return .{
                    .parent = null,
                    .item = .{ .inner = code },
                };
            }

            const item = self.inner.items[code - offs];
            return .{
                .parent = item.parent,
                .item = item.item,
            };
        }

        fn inRagne(self: *Dict, item: Code) bool {
            const offs = self.calcOffs();
            if (item < offs) return true;
            return item - offs < self.inner.items.len;
        }

        fn append(self: *Dict, item: Code, parent: Code) !Code {
            std.debug.assert(item < self.calcOffs());
            const idx = self.inner.items.len;
            std.debug.print("Appending: {d} at {d}\n", .{item, self.calcOffs() + idx});
            try self.inner.append(self.alloc, .{
                .item = .{ .inner = item },
                .parent = parent,
            });
            return @intCast(self.calcOffs() + idx);
        }

        fn getIdx(self: *Dict, idx: Idx) DictItem {
            return self.inner.items[idx.inner];
        }

        fn codeToIdx(self: *Dict, code: Code) ?Idx {
            const offs = self.calcOffs();
            if (code < offs) {
                return null;
            }
            return .{ .inner = code - offs };
        }

        const ParentIter = struct {
            current: ?Code,
            dict: *Dict,

            pub fn next(self: *ParentIter) ?Code {
                const current = self.current orelse return null;

                const query_res = self.dict.query(current);
                self.current = query_res.parent;
                return query_res.item.inner;
            }
        };

        fn parentIter(self: *Dict, item: Code) ParentIter {
            return .{
                .current = item,
                .dict = self,
            };
        }

        fn calcOffs(self: *Dict) u12 {
            return (@as(u12, 1) << @as(u4, @intCast(self.initial_len))) + 2;
        }

        fn codeAsSeqItem(self: *Dict, item: Code) ?SequenceItem {
            const offs = self.calcOffs();
            if (item < offs) {
                return .{ .inner = item };
            }

            const idx = item - offs;
            return self.inner.items[idx].item;
        }

        fn getParent(self: *Dict, item: Code) ?Code {
            const offs = self.calcOffs();
            if (item < offs) {
                return null;
            }

            const idx = item - offs;
            return self.inner.items[idx].parent;
        }

        fn reset(self: *Dict) void {
            self.inner.clearRetainingCapacity();
        }
    };

};

//test "LzwDecompressor readCode" {
//    const input = &.{0b11110000, 0b00001111};
//
//    var r = std.Io.Reader.fixed(input);
//    var lzwd = LzwDecompressor {
//        .input = &r,
//        .code_size_bits = 5,
//        .next_byte = 0,
//        .bits_remaining = 0,
//    };
//
//    try std.testing.expectEqual(0b10000, try lzwd.readCode());
//    try std.testing.expectEqual(0b11111, try lzwd.readCode());
//    try std.testing.expectEqual(0b11, try lzwd.readCode());
//}


test "4 byte lzw decomrpession" {
    var alloc_buf: [1 * 1024 * 1024]u8 = undefined;
    var alloc = std.heap.FixedBufferAllocator.init(&alloc_buf);

    const input = &.{0x5c, 0x04, 0x05};
    var r = std.Io.Reader.fixed(input);
    var lzwd = try LzwDecompressor.init(alloc.allocator(), 2, &r);

    const expected: []const u12 = &.{3, 1, 2, 0};
    var i: usize = 0;
    while (try lzwd.step()) |elem| {
        try std.testing.expectEqual(expected[i], elem);
        i += 1;
    }
}

test "36 byte lzw decomrpession" {
    var alloc_buf: [1 * 1024 * 1024]u8 = undefined;
    var alloc = std.heap.FixedBufferAllocator.init(&alloc_buf);

    const input = &.{0x44, 0x6c, 0xa7, 0x80,  0xba, 0xd7, 0x52, 0x2c};
    var r = std.Io.Reader.fixed(input);
    var lzwd = try LzwDecompressor.init(alloc.allocator(), 2, &r);

    const expected: []const u12 = &.{
        0, 1, 0, 1, 0, 1,
        1, 0, 1, 0, 1, 0,
        0, 1, 0, 1, 0, 1,
        1, 0, 1, 0, 1, 0,
        0, 1, 0, 1, 0, 1,
        1, 0, 1, 0, 1, 0,
    };

    var i: usize = 0;
    while (try lzwd.step()) |elem| {
        try std.testing.expectEqual(expected[i], elem);
        i += 1;
    }
}
