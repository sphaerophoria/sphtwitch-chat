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

const SelectorUniform = struct {
    tex1: sphtud.render.Texture,
};
const SelectorProgram = sphtud.render.xyuvt_program.Program(SelectorUniform);

pub const selector_frag =
    \\#version 330
    \\in vec2 uv;
    \\out vec4 fragment;
    \\uniform sampler2D tex1;
    \\void main()
    \\{
    \\    float a = texture(tex1, uv).r;
    \\    fragment = (a > 0) ? vec4(abs(a) * 8, 0.0, 0.0, 1.0) : vec4(0.0, abs(a) * 8, 0.0, 1.0);
    //\\    fragment = (a != 0) ? vec4(1, 1, 1, 1) : vec4(0, 0, 0, 1);
    //\\    fragment = vec4(a * 3, a * 3, a * 3, 1.0);
    //\\    fragment = vec4(b * 3, b * 3, b * 3, 1.0);
    \\}
;

const Contour = []const sphtud.math.Vec2;

fn makeSquareContour(buf: []sphtud.math.Vec2, offs_x: f32, offs_y: f32, width: f32, clockwise: bool) void {
    const samples_per_line = buf.len / 4;

    const points: []const sphtud.math.Vec2 = if (clockwise) &.{
        .{ -0.5 * width + offs_x, -0.5 * width + offs_y},
        .{ -0.5 * width + offs_x, 0.5  * width + offs_y},
        .{ 0.5  * width + offs_x, 0.5  * width + offs_y},
        .{ 0.5  * width + offs_x, -0.5 * width + offs_y},
    } else &.{
        .{ 0.5  * width + offs_x, -0.5 * width + offs_y},
        .{ 0.5  * width + offs_x, 0.5  * width + offs_y},
        .{ -0.5 * width + offs_x, 0.5  * width + offs_y},
        .{ -0.5 * width + offs_x, -0.5 * width + offs_y},

};

    for (0..points.len) |i| {
        const a = points[i];
        const b = points[(i + 1) % points.len];

        const ab = b - a;

        const line_buf = buf[i * samples_per_line..][0..samples_per_line];
        for (line_buf, 0..) |*elem, j| {
            elem.* = a + ab * @as(sphtud.math.Vec2, @splat(asf32(j) / asf32(line_buf.len)));
        }
    }
}

fn asf32(v: anytype) f32 {
    return @floatFromInt(v);
}

const slope_divisor = 5;

pub fn main2() !void {
    var allocators: sphtud.render.AppAllocators = undefined;
    try allocators.initPinned(10 * 1024 * 1024);

    var window: sphtud.window.Window = undefined;
    try window.initPinned("text example", 800, 800);

    try sphtud.render.initGl(window.glLoader());
    //gl.glEnable(gl.GL_SCISSOR_TEST);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);
    gl.glEnable(gl.GL_DEPTH_TEST);

    gl.glDepthFunc(gl.GL_LESS);
    gl.glDebugMessageCallback(glDebugCallback, null);
    gl.glEnable(gl.GL_DEBUG_OUTPUT);

    const selector_program = try SelectorProgram.init(&allocators.root_gl, selector_frag);
    const full_screen_plane = try sphtud.render.xyuvt_program.makeFullScreenPlane(&allocators.root_gl);
    var selector_source = try sphtud.render.xyuvt_program.RenderSource.init(&allocators.root_gl);
    selector_source.bindData(selector_program.handle(), full_screen_plane);

    const background_color = gui.widget_factory.StyleColors.background_color;

    const ttf_data = @embedFile("res/Hack-Regular.ttf");
    const ttf = try sphtud.text.ttf.Ttf.init(allocators.root.general(), ttf_data);


    var atlas = try sphtud.text.GlyphAtlas.init(allocators.root.general(), &allocators.root_gl);

    var sdfg = try sphtud.render.SignedDistanceFieldGenerator.init(&allocators.root_gl);
    _ = try atlas.getGlyphLocation2(
        &allocators.scratch,
        &allocators.scratch_gl,
        'a',
        15000,
        ttf,
        &sdfg,
    );

    while (!window.closed()) {
        allocators.resetScratch();
        const width, const height = window.getWindowSize();

        gl.glViewport(0, 0, @intCast(width), @intCast(height));
        gl.glScissor(0, 0, @intCast(width), @intCast(height));

        gl.glClearColor(background_color.r, background_color.g, background_color.b, background_color.a);
        gl.glClearDepth(std.math.inf(f32));
        gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);

        while (window.queue.pop()) |_| {}

        selector_program.render(selector_source, .{
            .tex1 = atlas.texture,
        });

        window.swapBuffers();
    }
}

fn renderContours(out_alloc: *sphtud.render.GlAlloc, scratch: std.mem.Allocator, scratch_gl: *sphtud.render.GlAlloc, tex_width: u31, tex_height: u31, contours: []const Contour, sdf_renderer: *sphtud.render.SignedDistanceFieldGenerator) !sphtud.render.Texture {
    var instance_builder = sphtud.render.SignedDistanceFieldGenerator.InputBuilder {
        .alloc = scratch,
        .gl_alloc = scratch_gl,
        .cone_verts = .{},
        .tent_verts = .{},
        .output = .{},

        .contour_start = undefined,
        .buf = undefined,
        .buf_idx = 0,

        .winding = .cw,
        .rightmost_vert_x = -std.math.inf(f32),
    };

    for (contours) |contour| {
        for (contour) |point| {
            try instance_builder.pushPoint(point);
        }
        try instance_builder.finishContour();
    }

    return sdf_renderer.render(
        out_alloc,
        scratch_gl,
        instance_builder.output.items,
        tex_width,
        tex_height,
    );
}

pub fn main() !void {
    //if (true) {
    //    try main2();
    //    return;
    //}
    var allocators: sphtud.render.AppAllocators = undefined;
    try allocators.initPinned(10 * 1024 * 1024);

    var window: sphtud.window.Window = undefined;
    try window.initPinned("text example", 800, 800);

    try sphtud.render.initGl(window.glLoader());
    //gl.glEnable(gl.GL_SCISSOR_TEST);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);
    gl.glEnable(gl.GL_DEPTH_TEST);

    gl.glDepthFunc(gl.GL_LESS);
    gl.glDebugMessageCallback(glDebugCallback, null);
    gl.glEnable(gl.GL_DEBUG_OUTPUT);

    var contour: [4]sphtud.math.Vec2 = undefined;
    makeSquareContour(&contour, 0.0, 0.0, 1.0, false);
    var contour2: [4]sphtud.math.Vec2 = undefined;
    makeSquareContour(&contour2, 0.5, 0.0, 0.5, true);
    var contour3: [4]sphtud.math.Vec2 = undefined;
    makeSquareContour(&contour3, 0.25, 0.0, 0.25, false);

    const selector_program = try SelectorProgram.init(&allocators.root_gl, selector_frag);
    const full_screen_plane = try sphtud.render.xyuvt_program.makeFullScreenPlane(&allocators.root_gl);
    var selector_source = try sphtud.render.xyuvt_program.RenderSource.init(&allocators.root_gl);
    selector_source.bindData(selector_program.handle(), full_screen_plane);

    const tex_width = 20;
    const tex_height = 20;

    const background_color = gui.widget_factory.StyleColors.background_color;

    var sdf_renderer = try sphtud.render.SignedDistanceFieldGenerator.init(&allocators.root_gl);

    const tex = try renderContours(
        &allocators.root_gl,
        allocators.scratch.allocator(),
        &allocators.scratch_gl,
        tex_width,
        tex_height,
        &.{&contour2, &contour3},
        &sdf_renderer,
    );

    while (!window.closed()) {
        allocators.resetScratch();
        const width, const height = window.getWindowSize();

        gl.glViewport(0, 0, @intCast(width), @intCast(height));
        gl.glScissor(0, 0, @intCast(width), @intCast(height));

        gl.glClearColor(background_color.r, background_color.g, background_color.b, background_color.a);
        gl.glClearDepth(std.math.inf(f32));
        gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);

        while (window.queue.pop()) |_| {}

        selector_program.render(selector_source, .{
            .tex1 = tex,
        });

        window.swapBuffers();
    }
}
