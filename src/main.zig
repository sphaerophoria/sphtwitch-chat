const std = @import("std");
const sphtud = @import("sphtud");
const builtin = @import("builtin");
const http = @import("http.zig");
const sphws = @import("sphws");
const EventIdIter = @import("EventIdIter.zig");
const as = @import("auth_server.zig");
const event_sub = @import("event_sub.zig");
const Xdg = @import("Xdg.zig");
const gl = sphtud.render.gl;
const MessageDb = @import("MessageDb.zig");

const GuiAction = union(enum) {
    delete_message,
};

const EventIdList = struct {
    auth: as.EventIdList,
    fetch: http.Client.EventIdList,
    es: event_sub.EventIdList,

    pub fn generate() EventIdList {
        var id_iter = EventIdIter{};
        return .{
            .auth = as.EventIdList.generate(&id_iter),
            .fetch = .generate(&id_iter),
            .es = .generate(&id_iter),
        };
    }
};

fn makeCryptoRng() !std.Random.DefaultCsprng {
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));
    const rng = std.Random.DefaultCsprng.init(seed);

    @memset(&seed, 0x0);
    // So secure right now... also we didn't check that the memset gets
    // optimized out without this... but it seems like it could :)
    std.mem.doNotOptimizeAway(&seed);

    return rng;
}

const id_list = EventIdList.generate();

const client_id = "1v2vig9jqtst8h28yaaouxt0fgq5z7";

pub const TintedImageWidget = struct {
    tex: sphtud.render.Texture,
    on_click: GuiAction,
    size: sphtud.ui.PixelSize,
    hovered: bool,
    shared: *const Shared,

    const Uniforms = struct {
        transform: sphtud.math.Mat3x3,
        mix_color: sphtud.math.Vec3,
        tex: sphtud.render.Texture,
    };

    const Shared = struct {
        render_source: sphtud.render.xyuvt_program.RenderSource,
        program: sphtud.render.xyuvt_program.Program(Uniforms),

        pub fn init(alloc: sphtud.ui.GuiAlloc) !Shared {
            const program = try sphtud.render.xyuvt_program.Program(Uniforms).init(alloc.gl, frag);
            var render_source = try sphtud.render.xyuvt_program.RenderSource.init(alloc.gl);
            render_source.bindData(program.handle(), try sphtud.render.xyuvt_program.makeFullScreenPlane(alloc.gl));
            return .{
                .program = program,
                .render_source = render_source,
            };
        }
    };

    pub const frag =
        \\#version 330
        \\in vec2 uv;
        \\out vec4 fragment;
        \\uniform vec3 mix_color;
        \\uniform sampler2D tex;
        \\void main()
        \\{
        \\    fragment = texture(tex, uv) * vec4(mix_color, 1.0);
        \\}
    ;

    pub fn init(shared: *const Shared, tex: sphtud.render.Texture) TintedImageWidget {
        return .{
            .shared = shared,
            .tex = tex,
            .on_click = .delete_message,
            .size = .{
                .width = 32, .height = 32,
            },
            .hovered = false,
        };
    }

    pub fn render(self: TintedImageWidget, widget_bounds: sphtud.ui.PixelBBox, window_bounds: sphtud.ui.PixelBBox) void {
        const mix_color: sphtud.math.Vec3 = switch (self.hovered) {
            false => .{ 1.0, 1.0, 1.0 },
            true => .{ 1.0, 0.0, 0.0 },
        };

        const transform = sphtud.ui.util.widgetToClipTransform(widget_bounds, window_bounds);
        self.shared.program.render(self.shared.render_source, .{
            .transform = transform.inner,
            .mix_color = mix_color,
            .tex = self.tex,
        });
    }

    pub fn getSize(self: TintedImageWidget) sphtud.ui.PixelSize {
        return self.size;
    }

    pub fn setInputState(self: *TintedImageWidget, widget_bounds: sphtud.ui.PixelBBox, input_bounds: sphtud.ui.PixelBBox, input_state: *sphtud.ui.InputState) sphtud.ui.InputResponse(GuiAction) {
        self.hovered = input_bounds.containsMousePos(input_state.mouse_pos);
        _ = widget_bounds;

        if (input_state.mouse_pressed and self.hovered) {
            return .{
                .action = self.on_click,
            };
        }

        return .{};
    }
};

const MessageWidgetFactory = struct {
    alloc: sphtud.ui.GuiAlloc,

    state: *sphtud.ui.widget_factory.WidgetState(GuiAction),
    allocators: sphtud.util.AutoHashMap(usize, sphtud.ui.GuiAlloc),

    message_db: *MessageDb,
    tinted_shared: *const TintedImageWidget.Shared,
    trash_tex: sphtud.render.Texture,
    //guitext_shared: sphtud.ui.gui_text.SharedState,

    pub fn createWidget(self: *MessageWidgetFactory, idx: usize) !sphtud.ui.Widget(GuiAction) {
        const message = self.message_db.get(idx);

        const gop = try self.allocators.getOrPut(idx);
        if (!gop.found_existing) {
            gop.val.* = try self.alloc.makeSubAlloc("chat message");
        }

        const factory = self.state.factory(gop.val.*);

        const layout = try factory.makeLayout();
        layout.cursor.direction = .left_to_right;

        const trash_widget = try gop.val.heap.arena().create(TintedImageWidget);
        trash_widget.* = .init(self.tinted_shared, self.trash_tex);

        try layout.pushWidget(
            sphtud.ui.Widget(GuiAction).fromConcrete(
                trash_widget,
                "trash",
            ),
        );

        try layout.pushWidget(try factory.makeLabel(message.chatter, .{ .color = .{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 } }));
        try layout.pushWidget(try factory.makeLabel(message.message, .{}));
        return layout.asWidget();
    }

    pub fn destroyWidget(self: *MessageWidgetFactory, idx: usize, widget: sphtud.ui.Widget(GuiAction)) void {
        _ = widget;
        const arena = self.allocators.remove(idx) orelse return;
        arena.deinit();
    }

    pub fn numItems(self: *const MessageWidgetFactory) usize {
        return self.message_db.numMessages();
    }
};

pub fn makeGui(scratch: *sphtud.alloc.BufAllocator, scratch_gl: *sphtud.render.GlAlloc, gui_alloc: sphtud.render.RenderAlloc, message_db: *MessageDb, font_size: f32) !*sphtud.ui.runner.Runner(GuiAction) {
    try gui_alloc.reset();

    const gui_state = try sphtud.ui.widget_factory.widgetState(
        GuiAction,
        gui_alloc,
        scratch,
        scratch_gl,
        .{
            .font_size = font_size,
        },
    );

    const widget_factory = gui_state.factory(gui_alloc);
    const tex = blk: {
        //F IXME: fn please
        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        const img_content = @embedFile("res/trash.png");
        var img_reader = std.Io.Reader.fixed(img_content);

        std.debug.print("Hi mom\n", .{});
        const img_data = try sphtud.img.png.read(scratch.allocator(), scratch.allocator(), &img_reader, .{
            .force_color_space = .srgb,
            .force_transfer_fn = .srgb,
            .force_pixel_format = .rgba_8888,
            .vflip = true,
        });

        std.debug.print("bye mom\n", .{});

        const img_data_data = img_data.data.rgba_8888;
        const width_bytes = img_data.width * 4;
        for (0..img_data.calcHeight()) |y| {
            for (0..img_data.width) |x| {
                const a = img_data_data.data[y * width_bytes + x * 4 + 3];
                std.debug.print("{d}\n", .{a});
            }
        }

        break :blk try  sphtud.render.makeTextureFromRgba(gui_alloc.gl, img_data.data.rgba_8888.data, img_data.width);
    };

    const tinted_shared = try gui_alloc.heap.arena().create(TintedImageWidget.Shared);
    tinted_shared.* = try TintedImageWidget.Shared.init(gui_alloc);

    const message_factory = try gui_alloc.heap.arena().create(MessageWidgetFactory);
    message_factory.* = MessageWidgetFactory{
        .alloc = try gui_alloc.makeSubAlloc("messages"),
        .state = gui_state,
        .allocators = try .init(
            gui_alloc.heap.arena(),
            gui_alloc.heap.expansion(),
            MessageDb.typical_messages,
            MessageDb.max_messages,
        ),
        .message_db = message_db,
        .tinted_shared = tinted_shared,
        .trash_tex = tex,
    };

    const ret = try gui_alloc.heap.arena().create(sphtud.ui.runner.Runner(GuiAction));
    ret.* = try widget_factory.makeRunner(try widget_factory.makeScrollList(message_factory));
    return ret;
}

pub fn main() !void {
    var allocators: sphtud.render.AppAllocators = undefined;
    try allocators.initPinned(10 * 1024 * 1024);

    var window: sphtud.window.Window = undefined;
    try window.initPinned("sphui demo", 800, 600);

    const root_alloc = &allocators.root;
    const scratch = &allocators.scratch;

    try sphtud.render.initGl(window.glLoader());

    gl.glEnable(gl.GL_SCISSOR_TEST);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);

    var loop = try sphtud.event.Loop2.init();

    var ca_bundle = std.crypto.Certificate.Bundle{};
    try ca_bundle.rescan(root_alloc.general());

    var http_client = try http.Client.init(&loop, root_alloc.arena(), &ca_bundle);

    var rng = try makeCryptoRng();

    const xdg = try Xdg.init(root_alloc.arena());

    var message_db = try MessageDb.init(root_alloc.arena(), root_alloc.expansion());

    const event_sub_conn = try root_alloc.arena().create(event_sub.Connection);
    try event_sub_conn.initPinned(
        root_alloc.general(),
        scratch.linear(),
        .{
            .http_client = &http_client,
            .xdg = &xdg,
            .ca_bundle = &ca_bundle,
            .random = rng.random(),
            .loop = &loop,
            .client_id = client_id,
            .message_db = &message_db,
        },
        id_list.es,
    );

    var auth_server = try as.AuthServer.init(
        &loop,
        root_alloc.arena(),
        event_sub_conn,
        rng.random(),
        client_id,
        id_list.auth,
    );

    const gui_alloc = try allocators.root_render.makeSubAlloc("gui");
    var font_size: f32 = 11.0;
    var runner = try makeGui(scratch, &allocators.scratch_gl, gui_alloc, &message_db, font_size);

    while (!window.closed()) {
        allocators.resetScratch();

        const event_opt = try loop.poll(0);

        if (event_opt) |event| switch (event) {
            id_list.auth.start...id_list.auth.end => {
                try auth_server.poll(scratch.linear(), event, id_list.auth);
            },
            id_list.es.start...id_list.es.end => {
                try event_sub_conn.poll(scratch.linear(), event, id_list.es);
            },
            else => unreachable,
        };

        const width, const height = window.getWindowSize();

        gl.glViewport(0, 0, @intCast(width), @intCast(height));
        gl.glScissor(0, 0, @intCast(width), @intCast(height));

        const background_color = sphtud.ui.widget_factory.StyleColors.background_color;
        gl.glClearColor(background_color.r, background_color.g, background_color.b, background_color.a);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        const response = try runner.step(1.0, .{
            .width = @intCast(width),
            .height = @intCast(height),
        }, &window.queue);

        if (response.action) |a| switch (a) {
            .delete_message => std.debug.print("delete me\n", .{}),
        };

        for (runner.input_state.key_tracker.pressed_this_frame.items) |key_event| {
            // A bit of a hack, but re-initializing the GUI is easy (even if it's slow)
            if (key_event.key.eql(.{ .ascii = '='}) and key_event.ctrl) {
                font_size += 1;
                runner = try makeGui(scratch, &allocators.scratch_gl, gui_alloc, &message_db, font_size);
                break;
            }

            if (key_event.key.eql(.{ .ascii = '-'}) and key_event.ctrl) {
                font_size -= 1;
                runner = try makeGui(scratch, &allocators.scratch_gl, gui_alloc, &message_db, font_size);
                break;
            }
        }

        window.swapBuffers();
    }
}
