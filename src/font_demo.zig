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

pub const ColorRenderer2 = struct {
    program: sphtud.render.xyuvt_program.Program(Uniforms),
    render_source: sphtud.render.xyuvt_program.RenderSource,

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

    pub fn init(alloc: *sphtud.render.GlAlloc) !ColorRenderer2 {
        const program = try sphtud.render.xyuvt_program.Program(Uniforms).init(alloc, frag);

        var render_source = try sphtud.render.xyuvt_program.RenderSource.init(alloc);
        render_source.bindData(program.handle(), try sphtud.render.xyuvt_program.makeFullScreenPlane(alloc));

        return .{
            .program = program,
            .render_source = render_source,
        };
    }

    const SequenceItem = union(enum) {
        paint_transform: sphtud.math.Transform,
        pop_transform,
        glyph: struct {
            tex: sphtud.render.Texture,
            bbox: BBox,
        },
        pop_glyph,
        solid: sphtud.math.Vec4,
        paint_radial_gradient,
    };

    pub fn sequenceFromTtfPaintOffset(alloc: std.mem.Allocator, scratch: sphtud.alloc.LinearAllocator, scratch_gl: *sphtud.render.GlAlloc, ttf: *const sphtud.text.ttf.Ttf, offs: sphtud.text.ttf.ColorTableV1.PaintItemOffset) ![]const SequenceItem {
        var walker: sphtud.text.ttf.ColorTableV1.PaintItemWalker = undefined;

        // FIXME: shouldn't hard deref
        walker.initPinned(&ttf.colr.?, offs);

        var ret = std.ArrayList(SequenceItem){};

        while (try walker.next()) |item| {
            switch (item.action) {
                .enter => {
                    switch (item.item) {
                        .paint_transform => |txfm| {
                            try ret.append(alloc, .{
                                .paint_transform = affineToMat(txfm.txfm),
                            });
                        },
                        .glyph => |g| {
                            const cp = scratch.checkpoint();
                            defer scratch.restore(cp);

                            const start_offs, const end_offs = ttf.loca.glyphRange(g.glyph_id) orelse return error.NoGlpyh;
                            // FIXME: We should use a proper LinearAlloc here to avoid leaking like mad
                            const gs  = try ttf.glyf.getGlyphSimple(scratch.allocator(), start_offs, end_offs);
                            const canvas, const ttf_bbox = try sphtud.text.ttf.renderGlyphAt1PxPerFunit(scratch.allocator(), gs);

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

                            try ret.append(alloc, .{
                                .glyph = .{
                                    .tex = glyph_tex,
                                    .bbox = .fromTtf(ttf_bbox),
                                },
                            });
                        },
                        .solid => |c| {
                            // FIXME: Do not hard deref
                            const cr = try ttf.cpal.?.colorRecord(c.palette_idx);
                            const r: f32 = @floatFromInt(cr.r);
                            const g: f32 = @floatFromInt(cr.g);
                            const b: f32 = @floatFromInt(cr.b);
                            const a: f32 = @floatFromInt(cr.a);
                            try ret.append(alloc, .{
                                .solid = .{ r / 255.0, g / 255.0, b / 255.0, a / 255.0},
                            });
                        },
                        .paint_radial_gradient => {
                            try ret.append(alloc, .paint_radial_gradient);
                        },
                        else => {},
                    }
                },
                .leave => {
                    switch (item.item) {
                        .paint_transform => try ret.append(alloc, .pop_transform),
                        .glyph => try ret.append(alloc, .pop_glyph),
                        else => {},
                    }
                },
            }
        }

        return ret.items;
    }

    fn findDestBbox(sequence: []const SequenceItem) !BBox {
        var ret = BBox {
            .max_x = -std.math.inf(f32),
            .min_x = std.math.inf(f32),
            .max_y = -std.math.inf(f32),
            .min_y = std.math.inf(f32),
        };
        var transform_list: TransformList(256) = undefined;
        transform_list.initPinned();

        for (sequence) |item| {
            try transform_list.push(item);

            switch (item) {
                .glyph => |g| {
                    ret = ret.combine(
                        adjustBboxForTxfm(g.bbox, transform_list.transform().inner),
                    );
                },
                else => {},
            }
        }

        return ret;
    }

    fn TransformList(comptime max_depth: usize) type {
        return struct {
            transforms_buf: [max_depth]sphtud.math.Transform,
            transforms: std.ArrayList(sphtud.math.Transform),

            pub fn initPinned(self: *@This()) void {
                self.transforms = .initBuffer(&self.transforms_buf);
            }

            pub fn push(self: *@This(), item: SequenceItem) !void {
                switch (item) {
                    .paint_transform => |txfm| {
                        try self.transforms.appendBounded(txfm);
                    },
                    .pop_transform => {
                        _ = self.transforms.pop();
                    },
                    else => {},
                }
            }

            pub fn transform(self: @This()) sphtud.math.Transform {
                var i = self.transforms.items.len;
                var ret = sphtud.math.Transform.identity;
                while (i > 0) {
                    i -= 1;
                    ret = ret.then(self.transforms.items[i]);
                }

                return ret;
            }
        };
    }

    pub fn renderSequence(self: ColorRenderer2, scratch_gl: *sphtud.render.GlAlloc, sequence: []const SequenceItem, output: sphtud.render.Texture) !struct { u31, u31 } {
        const dest_bbox = try findDestBbox(sequence);
        var source_bbox = BBox {
            .max_x = 0,
            .min_x = 0,
            .max_y = 0,
            .min_y = 0,
        };

        const width = dest_bbox.width();
        const height = dest_bbox.height();

        const depth_texture = try sphtud.render.makeTextureCommon(scratch_gl);
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_DEPTH24_STENCIL8, @intFromFloat(width), @intFromFloat(height), 0, gl.GL_DEPTH_STENCIL, gl.GL_UNSIGNED_INT_24_8, null);

        gl.glBindTexture(gl.GL_TEXTURE_2D, output.inner);
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, @intFromFloat(width), @intFromFloat(height), 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, null);

        const fb = try sphtud.render.FramebufferRenderContext.init(output, depth_texture);
        defer fb.reset();

        gl.glViewport(0, 0, @intFromFloat(width), @intFromFloat(height));

        gl.glClearColor(0, 0, 0, 0.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        // FIXME: Unsure if there's a max depth
        var transform_list: TransformList(256) = undefined;
        transform_list.initPinned();

        var tex: sphtud.render.Texture = .invalid;

        for (sequence) |item| {
            try transform_list.push(item);

            switch (item) {
                .glyph => |g| {
                    source_bbox = g.bbox;
                    // FIXME: This should combine the masks of this glyph and previous glyphs
                    tex = g.tex;
                },
                .solid => |c| {
                    const transform = transform_list.transform();
                    logBboxPlacement(source_bbox, transform, dest_bbox);

                    const uniforms = Uniforms {
                        .transform = oglToBbox(source_bbox).then(transform).then(bboxToOgl(dest_bbox)).inner,
                        .tex = tex,
                        .color_multiplier = c,
                    };

                    self.program.render(self.render_source, uniforms);
                },
                else => {},
            }
        }

        return .{ @intFromFloat(width), @intFromFloat(height) };
    }
};

fn logBboxPlacement(source_bbox: BBox, transform: sphtud.math.Transform, dest_bbox: BBox) void {
    const bl = sphtud.math.Vec3 {source_bbox.min_x, source_bbox.min_y, 1.0 };
    const tr = sphtud.math.Vec3 {source_bbox.max_x, source_bbox.max_y, 1.0 };
    const placed_bl = transform.apply(bl);
    const placed_tr = transform.apply(tr);

    std.debug.print("Placing {d},{d}-{d},{d} in {d},{d}-{d},{d}\n", .{
        placed_bl[0] / placed_bl[2],
        placed_bl[1] / placed_bl[2],
        placed_tr[0] / placed_bl[2],
        placed_tr[1] / placed_bl[2],

        dest_bbox.min_x,
        dest_bbox.min_y,
        dest_bbox.max_x,
        dest_bbox.max_y,
    });

}
fn affineToMat(affine: sphtud.text.ttf.ColorTableV1.PaintItem.Affine2x3) sphtud.math.Transform {
    return .{
        .inner = .{
            .data = .{
                affine.xx.toF32(), affine.xy.toF32(), affine.dx.toF32(),
                affine.yx.toF32(), affine.yy.toF32(), affine.dy.toF32(),
                0.0, 0.0, 1.0,
            }
        },
    };
}

fn oglToBbox(bbox: BBox) sphtud.math.Transform {
    // OpenGL space is -1, -1, to 1, 1
    const ogl_width = 2;
    const ogl_height = 2;
    const bbox_height = bbox.height();
    const bbox_width = bbox.width();

    return sphtud.math.Transform.scale(bbox_width / ogl_width, bbox_height / ogl_height).then(
        .translate(
            (bbox.min_x + bbox.max_x) / 2.0,
            (bbox.min_y + bbox.max_y) / 2.0,
        ),
    );
}

test oglToBbox {
    const txfm = oglToBbox(.{
        .min_x = 50,
        .max_x = 100,
        .min_y = 20,
        .max_y = 40,
    });

    {
        const res = txfm.apply(.{-1, -1, 1});
        try std.testing.expectApproxEqAbs(50, res[0], 0.01);
        try std.testing.expectApproxEqAbs(20, res[1], 0.01);
        try std.testing.expectApproxEqAbs(1, res[2], 0.01);
    }

    {
        const res = txfm.apply(.{1, 1, 1});
        try std.testing.expectApproxEqAbs(100, res[0], 0.01);
        try std.testing.expectApproxEqAbs(40, res[1], 0.01);
        try std.testing.expectApproxEqAbs(1, res[2], 0.01);
    }

}

fn bboxToOgl(bbox: BBox) sphtud.math.Transform {
    // OpenGL space is -1, -1, to 1, 1
    // FIXME: duped consts
    const ogl_width = 2;
    const ogl_height = 2;
    const bbox_height = bbox.height();
    const bbox_width = bbox.width();

    return sphtud.math.Transform.translate(
        -(bbox.min_x + bbox.max_x) / 2.0,
        -(bbox.min_y + bbox.max_y) / 2.0,
    ).then(.scale(
        ogl_width / bbox_width, ogl_height / bbox_height
    ));
}

test bboxToOgl {
    const txfm = bboxToOgl(.{
        .min_x = 50,
        .max_x = 100,
        .min_y = 20,
        .max_y = 40,
    });

    {
        const res = txfm.apply(.{50, 20, 1});
        try std.testing.expectApproxEqAbs(-1, res[0], 0.01);
        try std.testing.expectApproxEqAbs(-1, res[1], 0.01);
        try std.testing.expectApproxEqAbs(1, res[2], 0.01);
    }

    {
        const res = txfm.apply(.{100, 40, 1});
        try std.testing.expectApproxEqAbs(1, res[0], 0.01);
        try std.testing.expectApproxEqAbs(1, res[1], 0.01);
        try std.testing.expectApproxEqAbs(1, res[2], 0.01);
    }
}

const BBox = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,


    fn combine(a: BBox, b: BBox) BBox {
        return .{
            .min_x = @min(a.min_x, b.min_x),
            .max_x = @max(a.max_x, b.max_x),
            .min_y = @min(a.min_y, b.min_y),
            .max_y = @max(a.max_y, b.max_y),
        };

    }
    fn height(self: BBox) f32 {
        return self.max_y - self.min_y;
    }

    fn width(self: BBox) f32 {
        return self.max_x - self.min_x;
    }

    fn fromTtf(bbox: sphtud.text.ttf.BBox) BBox {
        return .{
            .min_x = @floatFromInt(bbox.min_x),
            .min_y = @floatFromInt(bbox.min_y),
            .max_x = @floatFromInt(bbox.max_x),
            .max_y = @floatFromInt(bbox.max_y),
        };
    }
};

fn adjustBboxForTxfm(bbox: BBox, txfm: sphtud.math.Mat3x3) BBox {

    const corners: [4]sphtud.math.Vec3 = .{
        .{ bbox.min_x, bbox.min_y, 1 },
        .{ bbox.min_x, bbox.max_y, 1 },
        .{ bbox.max_x, bbox.max_y, 1 },
        .{ bbox.max_x, bbox.min_y, 1 },
    };

    var new_bbox = BBox {
        .min_x = std.math.inf(f32),
        .min_y = std.math.inf(f32),
        .max_y = -std.math.inf(f32),
        .max_x = -std.math.inf(f32),
    };

    for (corners) |c| {
        const output = txfm.mul(c);
        const x = output[0] / output[2];
        const y = output[1] / output[2];
        new_bbox.min_x = @min(new_bbox.min_x, x);
        new_bbox.min_y = @min(new_bbox.min_y, y);
        new_bbox.max_x = @max(new_bbox.max_x, x);
        new_bbox.max_y = @max(new_bbox.max_y, y);
    }

    return new_bbox;
}


test adjustBboxForTxfm {
    const txfm = sphtud.math.Transform.scale(0.7, 0.3).then(.translate(1, -1));
    const new_bbox = adjustBboxForTxfm(.{
        .min_x = 5,
        .max_x = 10,
        .min_y = -3,
        .max_y = 7,
    }, txfm.inner);

    try std.testing.expectApproxEqAbs(5 * 0.7 + 1, new_bbox.min_x, 0.001);
    try std.testing.expectApproxEqAbs(10 * 0.7 + 1, new_bbox.max_x, 0.001);
    try std.testing.expectApproxEqAbs(-3 * 0.3 - 1, new_bbox.min_y, 0.001);
    try std.testing.expectApproxEqAbs(7 * 0.3 - 1, new_bbox.max_y, 0.001);

}

fn asf32(v: anytype) f32 {
    return @floatFromInt(v);
}

pub fn main() !void {
    var allocators: sphtud.render.AppAllocators = undefined;
    try allocators.initPinned(10 * 1024 * 1024);

    //const ttf_data = @embedFile("res/Hack-Regular.ttf");
    const ttf_data = @embedFile("res/NotoColorEmoji-Regular.ttf");
    const ttf = try sphtud.text.ttf.Ttf.init(allocators.root.general(), ttf_data);
    const glyph_id = ttf.cmap_subtable12.?.getGlyphIndex(0x1f62d);
    //const glyph_id = ttf.cmap_subtable12.?.getGlyphIndex(0x1F643);
    //const glyph_id = ttf.cmap_subtable12.?.getGlyphIndex(0x1FAE0);
    //const glyph_id = ttf.cmap_subtable12.?.getGlyphIndex(0x26a1);

    //const metrics = ttf.hmtx.getMetrics(ttf.hhea.num_of_long_hor_metrics, 2407);
    //std.debug.print("{any}\n", .{metrics});

    const paint_offset = blk: {
        // Upside down smiley man
        //const glyph_idx = ttf.cmap_subtable12.?.getGlyphIndex(0x1f643);

        var it = try ttf.colr.?.baseGlyphListIt();
        while (try it.next()) |item| {
            if (item.glyph_id == glyph_id) {
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
        if (item2.action != .enter) continue;
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

    const color_renderer = try ColorRenderer2.init(&allocators.root_gl);

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
                    .color_layers, .paint_transform, .glyph =>  {
                        const sequence = try ColorRenderer2.sequenceFromTtfPaintOffset(
                            allocators.scratch.allocator(),
                            allocators.scratch.backLinear(),
                            &allocators.scratch_gl,
                            &ttf,
                            layer_select.item_list[idx].offset,
                        );
                        std.debug.print("Sequence: {any}\n", .{sequence});
                        const new_width, const new_height = try color_renderer.renderSequence(&allocators.scratch_gl, sequence, vis_tex.tex);
                        vis_tex.width = new_width;
                        vis_tex.height = new_height;
                        std.debug.print("width: {d}, height: {d}\n", .{new_width, new_height});
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
