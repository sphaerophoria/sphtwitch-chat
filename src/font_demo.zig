const std = @import("std");
const sphtud = @import("sphtud");
const gl = sphtud.render.gl;
const gui = sphtud.ui;


fn glDebugCallback(source: gl.GLenum, typ: gl.GLenum, id: gl.GLuint, severity: gl.GLenum, length: gl.GLsizei, msg: [*c]const gl.GLchar, ctx: ?*const anyopaque) callconv(.c) void {
    _ = source;
    _ = typ;
    _ = id;
    _ = ctx;
    _ = length;

    const enable_debug_logs = false;
    switch (severity) {
        gl.GL_DEBUG_SEVERITY_HIGH => std.log.err("{s}", .{msg}),
        gl.GL_DEBUG_SEVERITY_MEDIUM => std.log.warn("{s}", .{msg}),
        else => if (enable_debug_logs) std.log.debug("{s}", .{msg}),
    }
}

const GuiAction = union(enum) {
    select_layer: usize,

    fn makeSelectLayer(idx: usize) GuiAction {
        return .{ .select_layer = idx };
    }
};

const ImageRetriever = struct {
    tex: sphtud.render.Texture,
    width: u31,
    height: u31,

    pub fn getTexture(self: ImageRetriever) sphtud.render.Texture {
        return self.tex;
    }

    pub fn getSize(self: ImageRetriever) gui.PixelSize {
        return .{
            .width = self.width,
            .height = self.height,
        };
    }

};

const LayerSelect = struct {
    selected: usize,
    item_list: []sphtud.text.ttf.ColorTableV1.PaintItemWalker.Item,
    cpal: *const sphtud.text.ttf.CpalTableV0,
    text_buf: [256]u8,

    const Formatter = struct {
        item: sphtud.text.ttf.ColorTableV1.PaintItemWalker.Item,
        cpal: *const sphtud.text.ttf.CpalTableV0,

        fn init(item: sphtud.text.ttf.ColorTableV1.PaintItemWalker.Item, cpal: *const sphtud.text.ttf.CpalTableV0) Formatter {
            return .{ .item = item, .cpal = cpal};
        }

        pub fn format(self: Formatter, w: *std.Io.Writer) !void {
            for (0..self.item.depth) |_| {
                try w.writeAll("  ");
            }

            try w.print("{s}", .{@tagName(self.item.item)});

            switch (self.item.item) {
                .glyph => |glyph| {
                    try w.print(" {d}", .{glyph.glyph_id});
                },
                .solid => |solid| {
                    const val = self.cpal.colorRecord(solid.palette_idx) catch unreachable;
                    try w.print(" color: {any}, alpha: {d}", .{val, solid.alpha});
                },
                else => {},
            }
        }
    };

    pub fn numItems(self: LayerSelect) usize {
        return self.item_list.len;
    }

    pub fn getText(self: *LayerSelect, idx: usize) []const u8 {
        return std.fmt.bufPrint(&self.text_buf, "{f}", .{Formatter.init(self.item_list[idx], self.cpal)}) catch "";
    }

    pub fn selectedId(self: LayerSelect) usize {
        return self.selected;
    }
};

pub const ColorRenderer = struct {
    program: sphtud.render.xyuvt_program.Program(Uniforms),
    render_source: sphtud.render.xyuvt_program.RenderSource,
    ttf: *const sphtud.text.ttf.Ttf,

    pub const Uniforms = struct {
        transform: sphtud.math.Mat3x3,
        tex: sphtud.render.Texture,
        color_multiplier: sphtud.math.Vec4,
    };

    pub const frag =
        \\#version 330
        \\in vec2 uv;
        \\out vec4 fragment;
        \\uniform sampler2D tex;
        \\uniform vec4 color_multiplier;
        \\void main()
        \\{
        \\    fragment = texture(tex, vec2(uv.x, uv.y)) * color_multiplier;
        \\}
    ;

    pub fn init(alloc: *sphtud.render.GlAlloc, ttf: *const sphtud.text.ttf.Ttf) !ColorRenderer {
        const program = try sphtud.render.xyuvt_program.Program(Uniforms).init(alloc, frag);

        var render_source = try sphtud.render.xyuvt_program.RenderSource.init(alloc);
        render_source.bindData(program.handle(), try sphtud.render.xyuvt_program.makeFullScreenPlane(alloc));

        return .{
            .program = program,
            .render_source = render_source,
            .ttf = ttf,
        };
    }

    fn renderPaintOffset(self: ColorRenderer, scratch: std.mem.Allocator, scratch_gl: *sphtud.render.GlAlloc, offs: sphtud.text.ttf.ColorTableV1.PaintItemOffset, output: sphtud.render.Texture) !struct { u31, u31 } {
        var walker: sphtud.text.ttf.ColorTableV1.PaintItemWalker = undefined;
        walker.initPinned(&self.ttf.colr.?, offs);

        var width: u31 = 0;
        var height: u31 = 0;

        var uniforms = Uniforms {
            .transform = .{},
            .tex = .invalid,
            .color_multiplier = .{ 1.0, 1.0, 1.0, 1.0 },
        };

        while (try walker.next()) |item| {
            switch (item.item) {
                .paint_transform => |txfm| {
                    uniforms.transform.data = .{
                        txfm.txfm.xx.toF32(), txfm.txfm.xy.toF32(), 0,
                        txfm.txfm.yx.toF32(), txfm.txfm.yy.toF32(), 0,
                        0.0, 0.0, 1.0,
                    };
                    std.debug.print("{any}\n", .{uniforms.transform.data});
                },
                .glyph => |g| {
                    const start_offs, const end_offs = self.ttf.loca.glyphRange(g.glyph_id) orelse return error.NoGlpyh;
                    const gs  = try self.ttf.glyf.getGlyphSimple(scratch, start_offs, end_offs);
                    const canvas, _ = try sphtud.text.ttf.renderGlyphAt1PxPerFunit(scratch, gs);

                    const glyph_tex = try sphtud.render.makeTextureCommon(scratch_gl);
                    gl.glTexImage2D(
                        gl.GL_TEXTURE_2D,
                        0,
                        gl.GL_RED,
                        @intCast(canvas.width),
                        @intCast(canvas.calcHeight()),
                        0,
                        gl.GL_RED,
                        gl.GL_UNSIGNED_BYTE,
                        canvas.pixels.ptr,
                    );

                    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_SWIZZLE_G, gl.GL_RED);
                    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_SWIZZLE_B, gl.GL_RED);
                    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_SWIZZLE_A, gl.GL_RED);
                    gl.glBindTexture(gl.GL_TEXTURE_2D, 0);

                    width = @intCast(canvas.width);
                    height = @intCast(canvas.calcHeight());

                    std.debug.print("{d}x{d}\n", .{width, height});
                    uniforms.tex = glyph_tex;
                },
                .solid => |c| {
                    const cr = try self.ttf.cpal.?.colorRecord(c.palette_idx);
                    const r: f32 = @floatFromInt(cr.r);
                    const g: f32 = @floatFromInt(cr.g);
                    const b: f32 = @floatFromInt(cr.b);
                    const a: f32 = @floatFromInt(cr.a);
                    uniforms.color_multiplier = .{ r / 255.0, g / 255.0, b / 255.0, a / 255.0};

                    gl.glBindTexture(gl.GL_TEXTURE_2D, output.inner);
                    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, width, height, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, null);
                    try self.render(scratch_gl, width, height, output, uniforms);
                    return .{ width, height };
                },
                else => unreachable,
            }
        }

        return error.Incomplete;

    }

    fn render(self: ColorRenderer, scratch_gl: *sphtud.render.GlAlloc, width: u31, height: u31, output: sphtud.render.Texture, uniforms: Uniforms) !void {
        const depth_texture = try sphtud.render.makeTextureCommon(scratch_gl);
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_DEPTH24_STENCIL8, width, height, 0, gl.GL_DEPTH_STENCIL, gl.GL_UNSIGNED_INT_24_8, null);

        const fb = try sphtud.render.FramebufferRenderContext.init(output, depth_texture);
        defer fb.reset();

        fb.bind();

        gl.glClearColor(0, 0, 0, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        gl.glViewport(0, 0, width, height);

        self.program.render(self.render_source, uniforms);
    }
};

pub fn main() !void {
    var allocators: sphtud.render.AppAllocators = undefined;
    try allocators.initPinned(10 * 1024 * 1024);

    //const ttf_data = @embedFile("res/Hack-Regular.ttf");
    const ttf_data = @embedFile("res/NotoColorEmoji-Regular.ttf");
    const ttf = try sphtud.text.ttf.Ttf.init(allocators.root.general(), ttf_data);
    const glyph = sphtud.text.ttf.glyphForChar(allocators.root.general(), ttf, 0x1F643);
    std.debug.print("{any}\n", .{glyph});

    const paint_offset = blk: {
        // Upside down smiley man
        //const glyph_idx = ttf.cmap_subtable12.?.getGlyphIndex(0x1f643);

        var it = try ttf.colr.?.baseGlyphListIt();
        while (try it.next()) |item| {
            if (item.glyph_id == 2407) {
                break :blk item.paint_offset;
            }

        }
        return error.Missing;
    };

    const paint_item = try ttf.colr.?.paintItem(.{
        .base_glyph_list = paint_offset,
    });
    std.debug.print("{any}\n", .{paint_item});

    var walker: sphtud.text.ttf.ColorTableV1.PaintItemWalker = undefined;
    walker.initPinned(&ttf.colr.?, .{
        .base_glyph_list = paint_offset,
    });


    var paint_item_buf: [256]sphtud.text.ttf.ColorTableV1.PaintItemWalker.Item = undefined;
    var layer_list = std.ArrayList(sphtud.text.ttf.ColorTableV1.PaintItemWalker.Item).initBuffer(&paint_item_buf);
    while (try walker.next()) |item2| {
        try layer_list.appendBounded(item2);
    }

    var window: sphtud.window.Window = undefined;
    try window.initPinned("text example", 800, 800);

    try sphtud.render.initGl(window.glLoader());

    //gl.glEnable(gl.GL_SCISSOR_TEST);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);


    gl.glDebugMessageCallback(glDebugCallback, null);
    gl.glEnable(gl.GL_DEBUG_OUTPUT);

    const gui_alloc = try allocators.root_render.makeSubAlloc("gui");

    const gui_state = try gui.widget_factory.widgetState(
        GuiAction,
        gui_alloc,
        &allocators.scratch,
        &allocators.scratch_gl,
        .{},
    );

    const widget_factory = gui_state.factory(gui_alloc);
    var layout = try widget_factory.makeLayout();

    var layer_select = LayerSelect{
        .selected = 0,
        .item_list = layer_list.items,
        .cpal = &ttf.cpal.?,
        .text_buf = undefined,
    };

    const selectable_list = try widget_factory.makeSelectableList(&layer_select, &GuiAction.makeSelectLayer);
    try selectable_list.update(.{.width = 300, .height = std.math.maxInt(u31) }, 0);
    try layout.pushWidget(
        try widget_factory.makeBox(
            try widget_factory.makeScrollView(
                selectable_list,
            ),
            .{ .width = 300, .height = @min(selectable_list.getSize().height, 300) },
            .fill_none,
        ),
    );

    var vis_tex = ImageRetriever {
        .tex = try sphtud.render.makeTextureCommon(gui_alloc.gl),
        .width = 1,
        .height = 1,
    };

    var display =  struct {
        selected: enum { none, vis_tex} = .none,

        pub fn get(self: @This()) usize {
            return @intFromEnum(self.selected);
        }
    }{};

    const tex_vis_widget = try widget_factory.makeBox(
        try widget_factory.makeThumbnail(
            &vis_tex,
        ),
        .{ .width = 500, .height = 500 },
        .fill_none,
    );
    try layout.pushWidget(
        try widget_factory.makeOneOf(
            &display,
            &.{
                gui.null_widget.makeNull(GuiAction),
                tex_vis_widget,
            },
        ),
    );

    var runner = try widget_factory.makeRunner(
        try widget_factory.makeScrollView(
            layout.asWidget(),
        ),
    );

    const color_renderer = try ColorRenderer.init(&allocators.root_gl, &ttf);

    var last_step = try std.time.Instant.now();
    while (!window.closed()) {
        allocators.resetScratch();
        const width, const height = window.getWindowSize();

        gl.glViewport(0, 0, @intCast(width), @intCast(height));
        gl.glScissor(0, 0, @intCast(width), @intCast(height));

        const background_color = gui.widget_factory.StyleColors.background_color;
        gl.glClearColor(background_color.r, background_color.g, background_color.b, background_color.a);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        const now = try std.time.Instant.now();
        defer last_step = now;

        var delta: f64 = @floatFromInt(now.since(last_step));
        delta /= 1e9;

        const response = try runner.step(@floatCast(delta), .{
            .width = @intCast(width),
            .height = @intCast(height),
        }, &window.queue);

        if (response.action) |a| switch (a) {
            .select_layer => |idx| {
                layer_select.selected = idx;

                switch (layer_select.item_list[idx].item) {
                    .paint_transform, .glyph =>  {
                        const new_width, const new_height = try color_renderer.renderPaintOffset(allocators.scratch.allocator(), &allocators.scratch_gl, layer_select.item_list[idx].offset, vis_tex.tex);
                        vis_tex.width = new_width;
                        vis_tex.height = new_height;
                        display.selected = .vis_tex;
                    },
                    .solid => |c| {
                        const color = try ttf.cpal.?.colorRecord(c.palette_idx);

                        gl.glBindTexture(gl.GL_TEXTURE_2D, vis_tex.tex.inner);

                        var color_buf: [64 * 4]u8 = undefined;
                        for (0..color_buf.len / 4) |i| {
                            color_buf[i * 4..][0] = color.r;
                            color_buf[i * 4..][1] = color.g;
                            color_buf[i * 4..][2] = color.b;
                            color_buf[i * 4..][3] = color.a;
                        }

                        gl.glBindTexture(gl.GL_TEXTURE_2D, vis_tex.tex.inner);
                        gl.glTexImage2D(
                            gl.GL_TEXTURE_2D,
                            0,
                            gl.GL_RGBA,
                            8,
                            8,
                            0,
                            gl.GL_RGBA,
                            gl.GL_UNSIGNED_BYTE,
                            &color_buf,
                        );

                        vis_tex.width = 8;
                        vis_tex.height = 8;

                        display.selected = .vis_tex;

                    },
                    else => {
                        display.selected = .none;
                    },
                }
            },
        };

        window.swapBuffers();
    }



    //var renderer = try sphtud.text.TextRenderer.init(allocators.root.general(), &allocators.root_gl, 12.0);

    //var text_buffer = try sphtud.render.xyuvt_program.makeFullScreenPlane(&allocators.root_gl);
    //var text_render_source = try sphtud.render.xyuvt_program.RenderSource.init(&allocators.root_gl);
    //text_render_source.bindData(renderer.program.handle(), text_buffer);

    //const glyph_idxs: []const usize =&.{14478};
    //for (glyph_idxs) |glyph_idx| {
    //    const start_offs, const end_offs = ttf.loca.glyphRange(@intCast(glyph_idx)) orelse return error.NoGlpyh;
    //    const gs  = try ttf.glyf.getGlyphSimple(allocators.root.general(), start_offs, end_offs);
    //    std.debug.print("{any}\n", .{gs});

    //    var canvas, _ = try sphtud.text.ttf.renderGlyphAt1PxPerFunit(allocators.root.general(), gs);

    //    var ppm = try std.fs.cwd().createFile("test.ppm", .{});
    //    var writer_buf: [4096]u8 = undefined;
    //    var ppmw = ppm.writer(&writer_buf);
    //    const w = &ppmw.interface;

    //    try w.print(
    //        \\P6
    //        \\{d} {d}
    //        \\255
    //        \\
    //    , .{canvas.width, canvas.calcHeight()});

    //    for (canvas.pixels) |px| {
    //        try w.writeByte(px);
    //        try w.writeByte(px);
    //        try w.writeByte(px);
    //    }
    //    try w.flush();
    //}
    ////for (0..ttf.cmap_subtable12.map_groups.len()) |i| {
    ////    std.debug.print("{any}\n", .{ttf.cmap_subtable12.map_groups.get(i)});
    ////}

    ////std.debug.print("glyph_idx: {d}\n", .{glyph_idx});

    //if (true) return;
    //const df_gen = try sphtud.render.DistanceFieldGenerator.init(&allocators.root_gl);

    //const layout = try renderer.layoutText(allocators.root.general(), "test 🙃🙃", ttf, 800);
    //try renderer.updateTextBuffer(
    //    &allocators.scratch,
    //    &allocators.scratch_gl,
    //    layout,
    //    ttf,
    //    df_gen,
    //    &text_buffer,
    //);

    //text_render_source.setLen(text_buffer.len);

    //while (!window.closed()) {
    //    gl.glClear(gl.GL_COLOR_BUFFER_BIT);
    //    gl.glViewport(0, 0, @intCast(layout.width() * 5), @intCast(layout.height() * 5));

    //    while (window.queue.pop()) |_| {}

    //    renderer.render(text_render_source, .{1.0, 1.0, 1.0}, .identity);
    //    window.swapBuffers();
    //}
}
