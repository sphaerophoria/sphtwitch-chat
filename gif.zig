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
    const gif_data = try std.fs.cwd().readFile("some_emote.gif", &gif_data_buf);

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

                std.debug.print("code len: {d}\n", .{lzw_min_code_size});

                var lzwd: LzwDecompressor = undefined;
                try lzwd.initPinned(lzw_min_code_size, &sdr.interface);

                var written_bytes: usize = 0;
                while (try lzwd.step()) |elem| {
                    written_bytes += 1;
                    const color = global_ct[elem];
                    try ppmw.interface.writeByte(color.r);
                    try ppmw.interface.writeByte(color.g);
                    try ppmw.interface.writeByte(color.b);
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
    code_reader: CodeReader,

    initial_code_size_bits: u8,
    code_size_bits: u8,

    dict: Dict,
    last_code: ?Code = null,

    // Dictionary can be at max 2^12 entries, the maximum sequence
    // length would be each element referencing the previous element,
    // so something on the order of 2^12 seems like a sane size here
    buffered_seq_buf: [max_code]u8,
    buffered_seq: std.ArrayList(u8),

    const Code = u12;
    const max_code = 1 << 12;

    pub fn initPinned(self: *LzwDecompressor, initial_code_len: u8, r: *std.Io.Reader) !void {
        const initial_code_len_shift = std.math.cast(u6, initial_code_len) orelse return error.InvalidCodeLen;

        self.* = .{
            .code_reader = .{
                .input = r,
                .next_byte = 0,
                .bits_remaining = 0,
            },
            .initial_code_size_bits = initial_code_len,
            .code_size_bits = initial_code_len + 1,
            .buffered_seq_buf = undefined,
            .buffered_seq = .initBuffer(&self.buffered_seq_buf),
            .last_code = null,
            .dict = .{
                .item_buf = undefined,
                .inner = .initBuffer(&self.dict.item_buf),
                .offs = (@as(usize, 1) << initial_code_len_shift)  + 2,
            },
        };
    }

    pub fn step(self: *LzwDecompressor) !?u8 {
        while (true) {
            if (self.buffered_seq.pop()) |val| {
                return val;
            }

            const next_code = try self.readCode();

            if (next_code == resetCode(self.initial_code_size_bits)) {
                self.reset();
                continue;
            }

            if (next_code == endCode(self.initial_code_size_bits)) {
                return null;
            }

            defer self.last_code = next_code;

            std.debug.assert(self.buffered_seq.items.len == 0);

            if (self.dict.containsCode(next_code)) {
                // Use existing sequence, but add prev + sequence to the dictionary

                try self.fillBuffer(next_code);

                if (self.last_code) |lc| {
                    const last = self.buffered_seq.getLast();
                    self.updateCodeSize(try self.dict.append(last, lc));
                }
            } else {
                // Use previous sequence with the first value repeated at the
                // end

                const last_code = self.last_code orelse return error.InvalidStream;

                try self.buffered_seq.appendBounded(0);
                try self.fillBuffer(last_code);

                self.buffered_seq.items[0] = self.buffered_seq.getLast();

                const new_code = try self.dict.append(self.buffered_seq.items[0], last_code);
                self.updateCodeSize(new_code);
            }
        }
    }

    fn resetCode(initial_code_len: u8) Code {
        return @as(u12, 1) << @intCast(initial_code_len);
    }

    fn endCode(initial_code_len: u8) Code {
        return resetCode(initial_code_len) + 1;
    }

    fn fillBuffer(self: *LzwDecompressor, start_code: Code) !void {
        var it = self.dict.parentIter(start_code);
        while (try it.next()) |val| {
            try self.buffered_seq.appendBounded(val);
        }
    }

    fn updateCodeSize(self: *LzwDecompressor, new_code: Code) void {
        if (new_code + 1 >= (@as(Code, 1) << @intCast(self.code_size_bits))) {
            self.code_size_bits += 1;
        }
    }

    fn reset(self: *LzwDecompressor) void {
        self.code_size_bits = self.initial_code_size_bits;
        self.dict.reset();
        self.last_code = null;
        self.code_size_bits = self.initial_code_size_bits + 1;
    }

    fn readCode(self: *LzwDecompressor) !u12 {
        return self.code_reader.readCode(self.code_size_bits);
    }

    const Dict = struct {
        item_buf: [max_code]DictItem,
        inner: std.ArrayList(DictItem),
        offs: usize,

        const DictItem = struct {
            parent: Code,
            item: u8,
        };

        const QueryRes = struct {
            parent: ?Code,
            item: u8,
        };


        fn query(self: *Dict, code: Code) !QueryRes {
            if (code < self.offs) {
                return .{
                    .parent = null,
                    .item = std.math.cast(u8, code) orelse return error.InvalidItem,
                };
            }

            const item = self.inner.items[code - self.offs];
            return .{
                .parent = item.parent,
                .item = item.item,
            };
        }

        fn containsCode(self: *Dict, item: Code) bool {
            if (item < self.offs) return true;
            return item - self.offs < self.inner.items.len;
        }

        fn append(self: *Dict, item: u8, parent: Code) !Code {
            std.debug.assert(item < self.offs);
            const idx = self.inner.items.len;
            try self.inner.appendBounded(.{
                .item = item,
                .parent = parent,
            });
            return @intCast(self.offs + idx);
        }

        const ParentIter = struct {
            current: ?Code,
            dict: *Dict,

            pub fn next(self: *ParentIter) !?u8 {
                const current = self.current orelse return null;

                const query_res = try self.dict.query(current);

                self.current = query_res.parent;
                return query_res.item;
            }
        };

        fn parentIter(self: *Dict, item: Code) ParentIter {
            return .{
                .current = item,
                .dict = self,
            };
        }

        fn getParent(self: *Dict, item: Code) ?Code {
            if (item < self.offs) {
                return null;
            }

            const idx = item - self.offs;
            return self.inner.items[idx].parent;
        }

        fn reset(self: *Dict) void {
            self.inner.clearRetainingCapacity();
        }
    };

    const CodeReader = struct {
        input: *std.Io.Reader,
        next_byte: u8,
        bits_remaining: u4,

        fn readCode(self: *CodeReader, code_size_bits: u8) !u12 {
            var code_remaining_bits: u8 = code_size_bits;

            var out: u12 = 0;
            var out_shift: u4 = 0;

            while (code_remaining_bits > 0) {
                if (self.bits_remaining == 0) {
                    self.next_byte = try self.input.takeByte();
                    self.bits_remaining = 8;
                }

                const bits_pulled = @min(code_remaining_bits, self.bits_remaining);

                self.bits_remaining -= bits_pulled;
                code_remaining_bits -= bits_pulled;

                const mask: u8 = @intCast((@as(u16, 1) << bits_pulled) - 1);
                out |= @as(Code, (self.next_byte & mask)) << @intCast(out_shift);
                out_shift += bits_pulled;

                if (bits_pulled < 8) {
                    self.next_byte >>= @intCast(bits_pulled);
                }
            }

            return out;
        }

    };
};


// FIXME: This can test the code reader directly
test "LzwDecompressor readCode" {
    const input = &.{0b11110000, 0b00001111};

    var r = std.Io.Reader.fixed(input);
    var lzwd: LzwDecompressor = undefined;
    try lzwd.initPinned(4, &r);

    try std.testing.expectEqual(0b10000, try lzwd.readCode());
    try std.testing.expectEqual(0b11111, try lzwd.readCode());
    try std.testing.expectEqual(0b11, try lzwd.readCode());
}


test "4 byte lzw decomrpession" {
    const input = &.{0x5c, 0x04, 0x05};
    var r = std.Io.Reader.fixed(input);
    var lzwd: LzwDecompressor = undefined;
    try lzwd.initPinned(2, &r);

    const expected: []const u12 = &.{3, 1, 2, 0};
    var i: usize = 0;
    while (try lzwd.step()) |elem| {
        try std.testing.expectEqual(expected[i], elem);
        i += 1;
    }
}

test "36 byte lzw decomrpession" {
    const input = &.{0x44, 0x6c, 0xa7, 0x80,  0xba, 0xd7, 0x52, 0x2c};
    var r = std.Io.Reader.fixed(input);
    var lzwd: LzwDecompressor = undefined;
    try lzwd.initPinned(2, &r);

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
