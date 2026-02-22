const std = @import("std");
const sphtud = @import("sphtud");
const img_mod = sphtud.img;
const sphrender = sphtud.render;
const gl = sphrender.gl;
const sphwindow = sphtud.window;
const gui = sphtud.ui;
const sphmath = sphtud.math;
const GifReader = sphtud.img.gif.GifReader;

pub fn imgSequenceToOpengl(alloc: sphtud.render.RenderAlloc, atlas: img_mod.ImageSequence) !ImageSequenceWidget.ImageSequence {
    if (atlas.data != .rgba_8888) return error.Unsupported;

    // FIXME: Polled from OpenGL
    const max_tex_height = 16384;
    const max_tex_width = 16384;

    // How many images can we fit in one column
    const images_per_col = @min(atlas.numImages(), max_tex_height / atlas.height);
    const images_per_row = atlas.numImages() / images_per_col;

    const tex_height_px = images_per_col * atlas.height;
    const tex_width_px = images_per_row * atlas.width;

    if (tex_width_px >= max_tex_width) return error.Unimplemented;

    var framedata = std.ArrayList(ImageSequenceWidget.FrameData){};

    const tex = try sphrender.makeTextureCommon(alloc.gl);
    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, @intCast(tex_width_px), @intCast(tex_height_px), 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, null);

    // FIXME: last column will be smaller
    for (0..images_per_row) |x| {
        const col_first_image_idx = x * images_per_col;
        const px_idx = col_first_image_idx * atlas.width * atlas.height;

        const col_height_images = atlas.numImages() - col_first_image_idx;
        const col_height_px = col_height_images * atlas.height;

        const data = atlas.data.rgba_8888.getByteSlice(px_idx, col_height_px);

        const lod = 0;
        const x_offs = x * atlas.width;
        const y_offs = 0;

        // FIXME: intcast is dangerouso
        gl.glTexSubImage2D(
            gl.GL_TEXTURE_2D,
            lod,
            @intCast(x_offs),
            y_offs,
            @intCast(atlas.width),
            @intCast(col_height_px),
            gl.GL_RGBA,
            gl.GL_UNSIGNED_BYTE,
            // FIXME: This will probably crash on the last col??
            data.ptr,
        );

        const timestep_col_start = x * images_per_col;
        const timestep_col_end = timestep_col_start + col_height_images;
        for (atlas.timesteps_ms[timestep_col_start..timestep_col_end], 0..) |ts, y| {
            try framedata.append(alloc.heap.arena(), .{
                .timestep_ms = ts,
                .offs_x_norm = asf32(x) / asf32(tex_width_px),
                .offs_y_norm = asf32(y * atlas.height) / asf32(tex_height_px),
            });
        }
    }

    return .{
        .tex = tex,
        .frames = framedata.items,
        .frame_height_norm = asf32(atlas.height) / asf32(tex_height_px),
        .frame_width_norm = asf32(atlas.width) / asf32(tex_width_px),
    };

}

// FIXME: ImageSequenceWidget
pub const ImageSequenceWidget = struct {
    prog: sphtud.render.xyuvt_program.Program(Uniform),
    render_source: sphrender.xyuvt_program.RenderSource,

    timestep_idx: usize,
    current_time_ms: usize,

    image_sequence: ImageSequence,

    pub const FrameData = struct {
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

    pub const ImageSequence = struct {
        tex: sphtud.render.Texture,
        frames: []FrameData,
        frame_width_norm: f32,
        frame_height_norm: f32,
    };

    pub fn init(alloc: sphtud.render.RenderAlloc, image_sequence: ImageSequence) !ImageSequenceWidget {

        const prog = try sphrender.xyuvt_program.Program(Uniform).init(alloc.gl, fragment_shader);
        var render_source = try sphrender.xyuvt_program.RenderSource.init(alloc.gl);
        render_source.bindData(prog.handle(), try sphrender.xyuvt_program.makeFullScreenPlane(alloc.gl));

        return .{
            .prog = prog,
            .image_sequence = image_sequence,
            .timestep_idx = 0,
            .render_source = render_source,
            .current_time_ms = 0,
        };
    }

    pub fn render(self: ImageSequenceWidget, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
        const transform = gui.util.widgetToClipTransform(widget_bounds, window_bounds);

        const timestep = self.image_sequence.frames[self.timestep_idx];
        self.prog.render(self.render_source, .{
            .transform = transform.inner,
            .input_image = self.image_sequence.tex,
            .offs_x = timestep.offs_x_norm,
            .offs_y = timestep.offs_y_norm,
            .width = self.image_sequence.frame_width_norm,
            .height = self.image_sequence.frame_height_norm,
        });
    }

    pub fn getSize(_: ImageSequenceWidget) gui.PixelSize {
        return .{ .width = 300, .height = 300 };
    }

    pub fn update(self: *ImageSequenceWidget, _: gui.PixelSize, delta_s: f32) anyerror!void {
        const delta_ms = delta_s * 1000;
        self.current_time_ms += @intFromFloat(delta_ms);

        while (self.current_time_ms >= self.image_sequence.frames[self.timestep_idx].timestep_ms) {
            std.debug.print("advancing because frame time {d} > {d}\n", .{self.current_time_ms, self.image_sequence.frames[self.timestep_idx].timestep_ms});
            self.timestep_idx = (self.timestep_idx + 1);
            if (self.timestep_idx >= self.image_sequence.frames.len) {
                self.timestep_idx = 0;
                self.current_time_ms = 0;

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

    const atlas = try img_mod.gif.read(allocators.root.arena(), &r, .{
        .force_transfer_fn = .srgb,
        .force_color_space = .srgb,
        .force_pixel_format = .rgba_8888,
    });

    const widget_factory = gui_state.factory(gui_alloc);

    const image_sequence_srgb = try imgSequenceToOpengl(gui_alloc, atlas);

    var gif_widget_srgb = try ImageSequenceWidget.init(gui_alloc, image_sequence_srgb);

    var layout = try widget_factory.makeLayout();
    try layout.pushWidget(
        gui.Widget(GuiAction).fromConcrete(&gif_widget_srgb, "gif viewer"),
    );
    var runner = try widget_factory.makeRunner(
        layout.asWidget(),
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
}
