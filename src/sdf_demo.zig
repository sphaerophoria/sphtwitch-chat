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

pub const cone_vertex_shader =
    \\#version 330
    \\ const float PI = 3.1415926535897932384626433832795;
    \\in float angle_mul;
    \\in vec2 center;
    \\in float total_angle;
    \\in vec2 direction;
    \\in int inside;
    \\out float depth;
    \\void main()
    \\{
    \\    float adjusted_total_angle = (inside != 0) ? total_angle : 2.0 * PI - total_angle;
    \\    vec2 adjusted_direction = (inside != 0) ? direction : -direction;
    \\
    \\    if (isinf(angle_mul)) {
    \\        gl_Position = vec4(center, 0.0, 1.0);
    \\    } else {
    \\        float cx = cos(adjusted_total_angle * angle_mul);
    \\        float sx = sin(adjusted_total_angle * angle_mul);
    \\        mat2x2 rot;
    \\        rot[0] = vec2(cx, sx);
    \\        rot[1] = vec2(-sx, cx);
    \\        vec2 rotated = rot * adjusted_direction;
    \\
    \\        gl_Position = vec4(
    \\            center + rotated,
    \\            1.0,
    \\            1.0);
    \\    }
    \\    depth = gl_Position.z;
    \\    if (inside == 0) depth *= -1;
    \\}
;

pub const fragment_shader =
    \\#version 330
    \\out vec4 fragment;
    \\in float depth;
    \\void main()
    \\{
    \\    fragment = vec4(depth, depth, depth, 1.0);
    \\}
;

const Uniform = struct {};
const Program = sphtud.render.shader_program.Program(Uniform);

const SelectorUniform = struct {
    inside: sphtud.render.Texture,
};
const SelectorProgram = sphtud.render.xyuvt_program.Program(SelectorUniform);

pub const selector_frag =
    \\#version 330
    \\in vec2 uv;
    \\out vec4 fragment;
    \\uniform sampler2D inside;
    \\void main()
    \\{
    \\    float a = texture(inside, uv).r;
    \\    fragment = (a > 0) ? vec4(abs(a) * 3, 0.0, 0.0, 1.0) : vec4(0.0, abs(a) * 3, 0.0, 1.0);
    //\\    fragment = vec4(a * 3, a * 3, a * 3, 1.0);
    //\\    fragment = vec4(b * 3, b * 3, b * 3, 1.0);
    \\}
;

const ConeRenderer = struct {
    program: sphtud.render.shader_program.Program(Uniform),
    source: sphtud.render.shader_program.RenderSource,

    const Vertex = struct {
        angle_mul: f32,
    };

    const Instance = struct {
        center: sphtud.math.Vec2,
        total_angle: f32,
        direction: sphtud.math.Vec2,
        inside: i32,
    };

    const vertex_binding_idx = 0;
    const instance_binding_idx = 1;

    const vertices_len = 20;

    pub fn init(alloc: *sphtud.render.GlAlloc) !ConeRenderer {
        const program = try Program.init(alloc, cone_vertex_shader, fragment_shader);

        const vertices = comptime makeFanVerts(vertices_len);
        const vbo = try sphtud.render.shader_program.Buffer(Vertex).init(alloc, vertices);
        var source = try sphtud.render.shader_program.RenderSource.init(alloc);
        source.bindDataToSlot(Vertex, program.handle, vertex_binding_idx, vbo);
        return .{
            .program = program,
            .source = source,
        };
    }

    pub fn render(self: *ConeRenderer, scratch: std.mem.Allocator, scratch_gl: *sphtud.render.GlAlloc, contours: []const Contour) !void {
        var total_points: usize = 0;
        for (contours) |c| total_points += c.len;

        const instance_data = try scratch.alloc(Instance, total_points * 2);
        makeVertexBFromContour(contours, instance_data);
        const vbb = try sphtud.render.shader_program.Buffer(ConeRenderer.Instance).init(scratch_gl, instance_data);

        self.source.bindDataToSlot(Instance, self.program.handle, instance_binding_idx, vbb);
        self.source.setSlotDivisor(instance_binding_idx, 1);

        self.source.len = .{ .instanced = .{
            .instance_len = vertices_len,
            .num_instances = @intCast(vbb.len),
        }};

        self.program.renderFan(self.source, .{});
    }
};

const Contour = []const sphtud.math.Vec2;

fn makeSquareContour(buf: []sphtud.math.Vec2, width: f32, clockwise: bool) void {
    const samples_per_line = buf.len / 4;

    const points: []const sphtud.math.Vec2 = if (clockwise) &.{
        .{ -0.5 * width, -0.5 * width},
        .{ -0.5 * width, 0.5  * width},
        .{ 0.5  * width, 0.5  * width},
        .{ 0.5  * width, -0.5 * width},
    } else &.{
        .{ 0.5  * width, -0.5 * width},
        .{ 0.5  * width, 0.5  * width},
        .{ -0.5 * width, 0.5  * width},
        .{ -0.5 * width, -0.5 * width},

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

fn makeVertexBFromContour(contours: []const Contour, out: []ConeRenderer.Instance) void {
    var out_idx: usize = 0;
    for (contours) |contour| {
        for (0..contour.len) |i| {
            defer out_idx += 2;
            const a = contour[(i + contour.len - 1) % contour.len];
            const b = contour[i];
            const c = contour[(i + 1) % contour.len];

            const ab = sphtud.math.normalize(b - a);
            const ba = sphtud.math.normalize(a - b);
            const bc = sphtud.math.normalize(c - b);

            var sum = ba + bc;
            if (sphtud.math.length(sum) < 1e-9) sum = .{ -bc[1], bc[0] };
            var direction = sphtud.math.normalize(sum) * @as(sphtud.math.Vec2, @splat(5));
            const sx = sphtud.math.cross2(ab, bc);

            var angle = std.math.acos(sphtud.math.dot(ba, bc));
            std.debug.print("angle: {d}, sx: {d}\n", .{angle, sx});
            if (sx < 0) {
                angle = std.math.pi * 2 - angle;
                direction = -direction;
            }

            out[out_idx] = .{
                .total_angle = angle,
                .center = b,
                .direction = direction,
                .inside = 1,
            };

            out[out_idx + 1] = .{
                .total_angle = angle,
                .center = b,
                .direction = direction,
                .inside = 0,
            };
        }
    }
}

fn makeFanVerts(comptime n: comptime_int) []const ConeRenderer.Vertex {
    comptime {
        var ret: []const ConeRenderer.Vertex = &.{.{
            .angle_mul = std.math.inf(f32),
        }};

         const max: f32 = @floatFromInt(n - 1);
         const offset: f32 = max / 2.0;
         for (0..n) |i| {
            var multiplier: f32 = i;
            multiplier -= offset;
            multiplier /= max;
            const next: [1]ConeRenderer.Vertex = .{ .{ .angle_mul = multiplier} };
            ret = ret ++ &next;
        }

        return ret;
    }
}

pub fn main() !void {
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

    var contour: [40]sphtud.math.Vec2 = undefined;
    makeSquareContour(&contour, 1.0, false);
    var contour2: [40]sphtud.math.Vec2 = undefined;
    makeSquareContour(&contour2, 0.5, true);


    const selector_program = try SelectorProgram.init(&allocators.root_gl, selector_frag);
    const full_screen_plane = try sphtud.render.xyuvt_program.makeFullScreenPlane(&allocators.root_gl);
    var selector_source = try sphtud.render.xyuvt_program.RenderSource.init(&allocators.root_gl);
    selector_source.bindData(selector_program.handle(), full_screen_plane);

    const tex_width = 100;
    const tex_height = 100;


    const inside_tex = try sphtud.render.makeTextureCommon(&allocators.root_gl);
    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_R32F, tex_width, tex_height, 0, gl.GL_RED, gl.GL_UNSIGNED_BYTE, null);

    const depth_texture = try sphtud.render.makeTextureCommon(&allocators.scratch_gl);

    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_DEPTH_STENCIL, tex_width, tex_height, 0, gl.GL_DEPTH_STENCIL, gl.GL_UNSIGNED_INT_24_8, null);


    const background_color = gui.widget_factory.StyleColors.background_color;
    var cone_renderer = try ConeRenderer.init(&allocators.root_gl);
    {
        const fb = try sphtud.render.FramebufferRenderContext.init(inside_tex, depth_texture);
        defer fb.reset();

        gl.glViewport(0, 0, @intCast(tex_width), @intCast(tex_height));
        gl.glScissor(0, 0, @intCast(tex_width), @intCast(tex_height));

        gl.glClearColor(0, 0, 0, 0);
        gl.glClearDepth(std.math.inf(f32));
        gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);

        try cone_renderer.render(allocators.scratch.allocator(), &allocators.scratch_gl, &.{&contour, &contour2});

    }


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
            .inside = inside_tex,
        });

        window.swapBuffers();
    }
}
