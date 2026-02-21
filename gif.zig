const std = @import("std");
const sphtud = @import("sphtud");
const img_mod = sphtud.img;
const sphrender = sphtud.render;
const gl = sphrender.gl;
const sphwindow = sphtud.window;
const gui = sphtud.ui;
const sphmath = sphtud.math;

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

pub fn readColorTable(buf: []u8, r: *std.Io.Reader, size_flag: u8) !img_mod.PackedData(img_mod.Rgb888Pixel) {
    const ct_size_bytes = 3 * @as(usize, 1) << @intCast(@as(u8, size_flag) + 1);

    try r.readSliceAll(buf[0..ct_size_bytes]);

    return .{
        .data = buf[0..ct_size_bytes],
    };
}

const GifAtlas = struct {
    atlas: img_mod.PackedData(img_mod.Rgba8888Pixel),

    frame_width_px: u32,
    frame_height_px: u32,

    loop_count: u16,

    timesteps: []u32,

    fn numImages(self: *const GifAtlas) usize {
        return self.timesteps.len;
    }

    fn load(alloc: std.mem.Allocator, r: *std.Io.Reader) !GifAtlas {
        var gr: GifReader = undefined;
        try gr.initPinned(r);


        var loop_count: u16 = 0;
        var next_time_held_ms: u32 = 0;
        var transparent_color_idx: ?u8 = null;

        var atlas_builder = std.ArrayList(u8){};

        var timesteps = std.ArrayList(u32){};
        var timestep_ms: u32 = 0;

        var data_buf: [4096]u8 = undefined;
        while (try gr.next(&data_buf)) |item| {
            switch (item) {
                .nab_loop_count => |count| loop_count = count,
                .graphic_control => |ctrl| {
                    next_time_held_ms = ctrl.delay_time_ms;
                    transparent_color_idx = ctrl.transparent_color_idx;
                },
                .image => |image| {
                    try timesteps.append(alloc, timestep_ms);
                    timestep_ms += next_time_held_ms;

                    while (try image.data.step()) |pallete_idx| {
                        const rgb = image.palette.get(pallete_idx);

                        try atlas_builder.append(alloc, rgb.r);
                        try atlas_builder.append(alloc, rgb.b);
                        try atlas_builder.append(alloc, rgb.g);

                        const alpha: u8 = if (pallete_idx == transparent_color_idx) 0 else 255;
                        try atlas_builder.append(alloc, alpha);
                    }
                },
                .extension => {},
            }
        }

        return .{
            .atlas = .{ .data = atlas_builder.items },
            .loop_count = loop_count,
            .timesteps = timesteps.items,
            .frame_width_px = gr.width,
            .frame_height_px = gr.height,
        };
    }
};

// FIXME: ImageSequenceWidget
pub const GifWidget = struct {
    atlas: sphrender.Texture,
    prog: sphtud.render.xyuvt_program.Program(Uniform),
    render_source: sphrender.xyuvt_program.RenderSource,
    timestep_idx: usize,
    frame_time_ms: usize,
    timesteps: []FrameData,
    frame_width_norm: f32,
    frame_height_norm: f32,

    const FrameData = struct {
        timestep_ms: u32,
        offs_x_norm: f32,
        offs_y_norm: f32,
    };

    const Uniform = struct {
        transform: sphmath.Mat3x3,
        input_image: sphtud.render.Texture,
        offs_x: f32,
        offs_y: f32,
        width: f32,
        height: f32,
    };

    pub const fragment_shader =
        \\#version 330
        \\in vec2 uv;
        \\out vec4 fragment;
        \\uniform sampler2D input_image;
        \\uniform float offs_x;
        \\uniform float offs_y;
        \\uniform float width;
        \\uniform float height;
        \\void main()
        \\{
        \\    fragment = texture(input_image, vec2(uv.x * width + offs_x, ((1.0 - uv.y) * height + offs_y)));
        \\}
    ;

    pub fn init(alloc: sphtud.render.RenderAlloc, atlas: GifAtlas) !GifWidget {

        const prog = try sphrender.xyuvt_program.Program(Uniform).init(alloc.gl, fragment_shader);
        var render_source = try sphrender.xyuvt_program.RenderSource.init(alloc.gl);
        render_source.bindData(prog.handle(), try sphrender.xyuvt_program.makeFullScreenPlane(alloc.gl));

        // FIXME: Polled from OpenGL
        const max_tex_height = 16384;
        const max_tex_width = 16384;

        // How many images can we fit in one column
        const images_per_col = @min(atlas.numImages(), max_tex_height / atlas.frame_height_px);
        const images_per_row = atlas.numImages() / images_per_col;

        const tex_height_px = images_per_col * atlas.frame_height_px;
        const tex_width_px = images_per_row * atlas.frame_width_px;

        if (tex_width_px >= max_tex_width) return error.Unimplemented;

        var framedata = std.ArrayList(FrameData){};

        const tex = try sphrender.makeTextureCommon(alloc.gl);
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, @intCast(tex_width_px), @intCast(tex_height_px), 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, null);

        // FIXME: last column will be smaller
        for (0..images_per_row) |x| {
            const col_first_image_idx = x * images_per_col;
            const px_idx = col_first_image_idx * atlas.frame_width_px * atlas.frame_height_px;

            const col_height_images = atlas.numImages() - col_first_image_idx;
            const col_height_px = col_height_images * atlas.frame_height_px;

            const data = atlas.atlas.getSlice(px_idx, col_height_px);

            const lod = 0;
            const x_offs = x * atlas.frame_width_px;
            const y_offs = 0;

            // FIXME: intcast is dangerouso
            gl.glTexSubImage2D(
                gl.GL_TEXTURE_2D,
                lod,
                @intCast(x_offs),
                y_offs,
                @intCast(atlas.frame_width_px),
                @intCast(col_height_px),
                gl.GL_RGBA,
                gl.GL_UNSIGNED_BYTE,
                // FIXME: This will probably crash on the last col??
                data.ptr,
            );

            const timestep_col_start = x * images_per_col;
            const timestep_col_end = timestep_col_start + col_height_images;
            for (atlas.timesteps[timestep_col_start..timestep_col_end], 0..) |ts, y| {
                try framedata.append(alloc.heap.arena(), .{
                    .timestep_ms = ts,
                    .offs_x_norm = asf32(x) / asf32(tex_width_px),
                    .offs_y_norm = asf32(y * atlas.frame_height_px) / asf32(tex_height_px),
                });
            }
        }

        return .{
            .atlas = tex,
            .prog = prog,
            .timesteps = framedata.items,
            .timestep_idx = 0,
            .render_source = render_source,
            .frame_height_norm = asf32(atlas.frame_height_px) / asf32(tex_height_px),
            .frame_width_norm = asf32(atlas.frame_width_px) / asf32(tex_width_px),
            .frame_time_ms = 0,
        };
    }

    pub fn render(self: GifWidget, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
        const transform = gui.util.widgetToClipTransform(widget_bounds, window_bounds);

        const timestep = self.timesteps[self.timestep_idx];
        self.prog.render(self.render_source, .{
            .transform = transform.inner,
            .input_image = self.atlas,
            .offs_x = timestep.offs_x_norm,
            .offs_y = timestep.offs_y_norm,
            .width = self.frame_width_norm,
            .height = self.frame_height_norm,
        });
    }

    pub fn getSize(_: GifWidget) gui.PixelSize {
        return .{ .width = 300, .height = 300 };
    }

    pub fn update(self: *GifWidget, _: gui.PixelSize, delta_s: f32) anyerror!void {
        const delta_ms = delta_s * 1000;
        self.frame_time_ms += @intFromFloat(delta_ms);

        while (self.frame_time_ms >= self.timesteps[self.timestep_idx].timestep_ms) {
            std.debug.print("advancing because frame time {d} > {d}\n", .{self.frame_time_ms, self.timesteps[self.timestep_idx].timestep_ms});
            self.timestep_idx = (self.timestep_idx + 1);
            if (self.timestep_idx >= self.timesteps.len) {
                self.timestep_idx = 0;
                self.frame_time_ms = 0;

            }
        }
    }
};

const GuiAction = struct {};

fn asf32(val: anytype) f32 {
    return @floatFromInt(val);
}

pub fn main() !void {
    var allocators: sphrender.AppAllocators = undefined;
    try allocators.initPinned(10 * 1024 * 1024);

    var window: sphwindow.Window = undefined;
    try window.initPinned("sphui demo", 800, 600);

    try sphrender.initGl(window.glLoader());

    gl.glEnable(gl.GL_SCISSOR_TEST);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);

    const gui_alloc = try allocators.root_render.makeSubAlloc("gui");

    const gui_state = try gui.widget_factory.widgetState(
        GuiAction,
        gui_alloc,
        &allocators.scratch,
        &allocators.scratch_gl,
        .{},
    );

    var gif_data_buf: [4 * 1024 * 1024]u8 = undefined;
    const gif_data = try std.fs.cwd().readFile("bopbop.gif", &gif_data_buf);

    var r = std.Io.Reader.fixed(gif_data);

    const atlas = try GifAtlas.load(allocators.root.arena(), &r);

    // atlas has rgba pixels
    var ppmf = try std.fs.cwd().createFile("test.ppm", .{});
    defer ppmf.close();

    var ppmw_buf: [4096]u8 = undefined;
    var ppmw = ppmf.writer(&ppmw_buf);
    try ppmw.interface.print(
        \\P6
        \\{d} {d}
        \\255
        \\
        , .{atlas.frame_width_px, atlas.frame_height_px});

    var i: usize = 0;
    while (i < atlas.atlas.len()) {
        defer i += 4;
        const px = atlas.atlas.get(i);
        try ppmw.interface.writeByte(px.r);
        try ppmw.interface.writeByte(px.g);
        try ppmw.interface.writeByte(px.b);
    }

    try ppmw.interface.flush();

    for (atlas.timesteps) |ts| {
        std.debug.print("{any}\n", .{ts});
    }

    const widget_factory = gui_state.factory(gui_alloc);

    var gif_widget = try GifWidget.init(gui_alloc, atlas);
    var runner = try widget_factory.makeRunner(
        gui.Widget(GuiAction).fromConcrete(&gif_widget, "gif viewer"),
    );

    var last_frame = try std.time.Instant.now();

    while (!window.closed()) {
        allocators.resetScratch();

        const now = try std.time.Instant.now();
        defer last_frame = now;

        const width, const height = window.getWindowSize();

        gl.glViewport(0, 0, @intCast(width), @intCast(height));
        gl.glScissor(0, 0, @intCast(width), @intCast(height));

        const background_color = gui.widget_factory.StyleColors.background_color;
        gl.glClearColor(background_color.r, background_color.g, background_color.b, background_color.a);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        const delta_ns =now.since(last_frame);
        _ = try runner.step(asf32(delta_ns) / 1e9, .{
            .width = @intCast(width),
            .height = @intCast(height),
        }, &window.queue);

        window.swapBuffers();
    }

    //var gr = try GifReader.init(alloc.allocator(), &r);

    //var first_image = false;
    //const cp = alloc.end_index;
    //var data_buf: [4096]u8 = undefined;
    //while (try gr.next(alloc.allocator(), &data_buf)) |item| {
    //    defer alloc.end_index = cp;

    //    switch (item) {
    //        .nab_loop_count => |count| {
    //            std.debug.print("loop count: {d}\n", .{count});
    //        },
    //        .graphic_control => |ctrl| {
    //            std.debug.print("ctrl: {any}\n", .{ctrl});
    //        },
    //        .extension => |data| {
    //            std.debug.print("extension label: {d} 0x{x}\n", .{data.label, data.label});

    //            while (true) {
    //                data.data.fillMore() catch |e| {
    //                    if (e == error.EndOfStream) break;
    //                    return e;
    //                };

    //                const buffered = data.data.buffered();
    //                std.debug.print("{any}\n", .{buffered});
    //                data.data.toss(buffered.len);
    //            }
    //        },
    //        .image => |data| {
    //            std.debug.print("{d}x{d} image\n", .{data.width, data.height});
    //            if (first_image) {
    //                first_image = false;

    //                var ppmf = try std.fs.cwd().createFile("test.ppm", .{});
    //                defer ppmf.close();

    //                var ppmw_buf: [4096]u8 = undefined;
    //                var ppmw = ppmf.writer(&ppmw_buf);
    //                try ppmw.interface.print(
    //                    \\P6
    //                    \\{d} {d}
    //                    \\255
    //                    \\
    //                    , .{data.width, data.height});

    //                while (try data.data.step()) |elem| {
    //                    const px = data.palette[elem];
    //                    try ppmw.interface.writeByte(px.r);
    //                    try ppmw.interface.writeByte(px.g);
    //                    try ppmw.interface.writeByte(px.b);
    //                }


    //                try ppmw.interface.flush();
    //            }
    //        },
    //    }
    //}
}

const GifReader = struct {
    input: *std.Io.Reader,
    width: u16,
    height: u16,
    global_packed: GlobalPackedInfo,
    background_color: u8,
    pixel_aspect: u8,
    global_ct_buf: [256 * 3]u8,
    local_ct_buf: [256 * 3]u8,
    global_ct: img_mod.PackedData(img_mod.Rgb888Pixel),

    sub_reader: ?SubDataReader = null,
    lzw_reader: ?LzwDecompressor = null,

    const Item = union(enum) {
        nab_loop_count: u16,
        graphic_control: struct {
            user_input: bool,
            disposal_method: enum (u3) {
                none = 0,
                do_not_dispose = 1,
                restore_background = 2,
                restore_previous = 3,
                _,
            },
            delay_time_ms: u32,
            transparent_color_idx: ?u8,
        },
        // FIXME: rename unhandled ext
        extension: struct {
            label: u8,
            data: *std.Io.Reader,
        },
        image: struct {
            left: u16,
            top: u16,
            width: u16,
            height: u16,
            interlace: bool,
            palette: img_mod.PackedData(img_mod.Rgb888Pixel),
            // FIXME: This should probably be a std.Io.Reader
            data: *LzwDecompressor,
        },
    };

    pub fn initPinned(self: *GifReader, r: *std.Io.Reader) !void {
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

        const global_packed = try r.takeStruct(GlobalPackedInfo, .little);
        const background_color = try r.takeByte();
        const pixel_aspect = try r.takeByte();

        self.* = .{
            .input = r,
            .width = width,
            .height = height,
            .global_packed = global_packed,
            .background_color = background_color,
            .pixel_aspect = pixel_aspect,
            .global_ct_buf = undefined,
            .local_ct_buf = undefined,
            .global_ct = .{ .data = &.{} },
        };

        if (global_packed.ct_present) {
            self.global_ct = try readColorTable(&self.global_ct_buf, r, global_packed.ct_size);
        }
    }

    pub fn next(self: *GifReader, data_buf: []u8) !?Item {
        if (self.sub_reader) |*s| {
            _ = try s.interface.discardRemaining();
            self.sub_reader = null;
        }
        self.lzw_reader = null;

        const r = self.input;
        const block_type = try r.takeByte();

        switch (block_type) {
            '!' => {
                const label = try r.takeByte();

                self.sub_reader = SubDataReader.init(self.input, data_buf);

                if (label == 0xff) {
                    const extension_header = try self.sub_reader.?.interface.peek(11);

                    if (std.mem.eql(u8, extension_header, "NETSCAPE2.0")) {
                        self.sub_reader.?.interface.toss(11);
                        const sub_block_id = try self.sub_reader.?.interface.take(1);
                        _ = sub_block_id;
                        const loop_amount = try self.sub_reader.?.interface.takeInt(u16, .little);
                        return .{
                            .nab_loop_count = loop_amount,
                        };
                    }
                } else if (label == 0xf9) {
                    const GCPacked = packed struct {
                        transparent: bool,
                        user_input: bool,
                        disposal_method: u3,
                        reserved: u3,
                    };

                    const gc_packed = try self.sub_reader.?.interface.takeStruct(GCPacked, .little);
                    const delay_time_cs = try self.sub_reader.?.interface.takeInt(u16, .little);
                    const transparent_color_idx = try self.sub_reader.?.interface.takeByte();
                    return .{
                        .graphic_control = .{
                            .user_input = gc_packed.user_input,
                            .disposal_method = @enumFromInt(gc_packed.disposal_method),
                            .delay_time_ms = @as(u32, delay_time_cs) * 10,
                            .transparent_color_idx = if (gc_packed.transparent) transparent_color_idx else null,
                        },
                    };
                }

                return .{
                    .extension = .{
                        .label = label,
                        .data = &self.sub_reader.?.interface,
                    },
                };
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

                var color_table = self.global_ct;
                if (options.lct_present) {
                    color_table = try readColorTable(&self.local_ct_buf, r, options.lct_size);
                }
                std.debug.assert(self.global_packed.ct_present or options.lct_present);


                const lzw_min_code_size = try r.takeByte();
                self.sub_reader = SubDataReader.init(r, data_buf);

                const undef_lzw: LzwDecompressor = undefined;
                self.lzw_reader = comptime undef_lzw;
                try self.lzw_reader.?.initPinned(lzw_min_code_size, &self.sub_reader.?.interface);

                return .{
                    .image = .{
                        .left = left,
                        .top = top,
                        .width = image_width,
                        .height = image_height,
                        .interlace = options.interlace,
                        .palette = color_table,
                        .data = &self.lzw_reader.?,
                    },
                };
            },
            ';' => return null,
            else => {
                return error.InvalidBlockType;
            },
        }
    }

};

const SubDataReader = struct {
    input: *std.Io.Reader,
    interface: std.Io.Reader,
    block_remaining_len: u8,
    finished: bool,

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
            .finished = false,
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *SubDataReader = @fieldParentPtr("interface", r);

        if (self.finished) return error.EndOfStream;

        if (self.block_remaining_len == 0) {
            self.block_remaining_len = try self.input.takeByte();
            if (self.block_remaining_len == 0) {
                self.finished = true;
                return error.EndOfStream;
            }
        }

        const merged_limit = limit.min(.limited(self.block_remaining_len));
        const read_bytes = try self.input.stream(w, merged_limit);
        self.block_remaining_len -= @intCast(read_bytes);

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

        fn reset(self: *Dict) void {
            self.inner.clearRetainingCapacity();
        }
    };

    const CodeReader = struct {
        input: *std.Io.Reader,
        // Buffered byte from input
        next_byte: u8,
        // How many bits are left in the buffered byte
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


test "CodeReader readCode" {
    const input = &.{0b11110000, 0b00001111};

    var r = std.Io.Reader.fixed(input);
    var cr = LzwDecompressor.CodeReader {
        .input = &r,
        .bits_remaining = 0,
        .next_byte = 0,
    };

    try std.testing.expectEqual(0b10000, try cr.readCode(5));
    try std.testing.expectEqual(0b11111, try cr.readCode(5));
    try std.testing.expectEqual(0b11, try cr.readCode(5));
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
