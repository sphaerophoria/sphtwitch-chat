const std = @import("std");
const sphtud = @import("sphtud");
const http = @import("http.zig");
const sphws = @import("sphws");
const EventIdIter = @import("EventIdIter.zig");
const as = @import("auth_server.zig");
const event_sub = @import("event_sub.zig");
const Xdg = @import("Xdg.zig");
const gl = sphtud.render.gl;
const MessageDb = @import("MessageDb.zig");

const GuiAction = struct {};

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

const MessageWidgetFactory = struct {
    alloc: sphtud.ui.GuiAlloc,

    state: *sphtud.ui.widget_factory.WidgetState(GuiAction),
    allocators: sphtud.util.AutoHashMap(usize, sphtud.ui.GuiAlloc),

    message_db: *MessageDb,
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

    const message_factory =try gui_alloc.heap.arena().create(MessageWidgetFactory);
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
        _ = response;

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
