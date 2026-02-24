const std = @import("std");
const sphtud = @import("sphtud");
const gl = sphtud.render.gl;

pub fn main() !void {
    var allocators: sphtud.render.AppAllocators = undefined;
    try allocators.initPinned(10 * 1024 * 1024);

    // 0x1F643
    //const ttf_data = @embedFile("res/Hack-Regular.ttf");
    const ttf_data = @embedFile("res/NotoColorEmoji-Regular.ttf");
    const ttf = try sphtud.text.ttf.Ttf.init(allocators.root.general(), ttf_data);
    const glyph = sphtud.text.ttf.glyphForChar(allocators.root.general(), ttf, 0x1F643);
    std.debug.print("{any}\n", .{glyph});


    var window: sphtud.window.Window = undefined;
    try window.initPinned("text example", 800, 600);

    try sphtud.render.initGl(window.glLoader());

    //gl.glEnable(gl.GL_SCISSOR_TEST);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);

    var renderer = try sphtud.text.TextRenderer.init(allocators.root.general(), &allocators.root_gl, 12.0);

    var text_buffer = try sphtud.render.xyuvt_program.makeFullScreenPlane(&allocators.root_gl);
    var text_render_source = try sphtud.render.xyuvt_program.RenderSource.init(&allocators.root_gl);
    text_render_source.bindData(renderer.program.handle(), text_buffer);

    const glyph_idxs: []const usize =&.{4133};
    for (glyph_idxs) |glyph_idx| {
        const start_offs, const end_offs = ttf.loca.glyphRange(@intCast(glyph_idx)) orelse return error.NoGlpyh;
        const gs  = try ttf.glyf.getGlyphSimple(allocators.root.general(), start_offs, end_offs);
        std.debug.print("{any}\n", .{gs});

        var canvas, _ = try sphtud.text.ttf.renderGlyphAt1PxPerFunit(allocators.root.general(), gs);

        var ppm = try std.fs.cwd().createFile("test.ppm", .{});
        var writer_buf: [4096]u8 = undefined;
        var ppmw = ppm.writer(&writer_buf);
        const w = &ppmw.interface;

        try w.print(
            \\P6
            \\{d} {d}
            \\255
            \\
        , .{canvas.width, canvas.calcHeight()});

        for (canvas.pixels) |px| {
            try w.writeByte(px);
            try w.writeByte(px);
            try w.writeByte(px);
        }
        try w.flush();
    }
    //for (0..ttf.cmap_subtable12.map_groups.len()) |i| {
    //    std.debug.print("{any}\n", .{ttf.cmap_subtable12.map_groups.get(i)});
    //}

    //std.debug.print("glyph_idx: {d}\n", .{glyph_idx});

    if (true) return;
    const df_gen = try sphtud.render.DistanceFieldGenerator.init(&allocators.root_gl);

    const layout = try renderer.layoutText(allocators.root.general(), "test 🙃🙃", ttf, 800);
    try renderer.updateTextBuffer(
        &allocators.scratch,
        &allocators.scratch_gl,
        layout,
        ttf,
        df_gen,
        &text_buffer,
    );

    text_render_source.setLen(text_buffer.len);

    while (!window.closed()) {
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        gl.glViewport(0, 0, @intCast(layout.width() * 5), @intCast(layout.height() * 5));

        while (window.queue.pop()) |_| {}

        renderer.render(text_render_source, .{1.0, 1.0, 1.0}, .identity);
        window.swapBuffers();
    }
}
