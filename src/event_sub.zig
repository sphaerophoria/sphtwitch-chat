const std = @import("std");
const sphtud = @import("sphtud");
const sphws = @import("sphws");
const EventIdIter = @import("EventIdIter.zig");
const http = @import("http.zig");
const Xdg = @import("Xdg.zig");
const twitch_api = @import("twitch_api.zig");
const MessageDb = @import("MessageDb.zig");

pub const EventIdList = struct {
    start: usize,
    register_websocket: usize,
    websocket_message: usize,
    end: usize,

    pub fn generate(id_iter: *EventIdIter) EventIdList {
        return .{
            .start = id_iter.markStart(),
            .register_websocket = id_iter.one(),
            .websocket_message = id_iter.one(),
            .end = id_iter.markEnd(),
        };
    }
};

pub const ConnectionRefs = struct {
    ca_bundle: *std.crypto.Certificate.Bundle,
    random: std.Random,
    loop: *sphtud.event.Loop2,
    xdg: *const Xdg,
    http_client: *http.Client,
    client_id: []const u8,
    message_db: *MessageDb,
};

pub const Connection = struct {
    tls: sphtud.net.TlsStream(4096, 4096),
    ws: sphws.Websocket,

    refs: ConnectionRefs,

    // std.Io.Reader returned by websocket message notification uses this as
    // the backing buffer. We buffer the entire json message into here before
    // parsing
    ws_data_buf: [max_message_size]u8 = undefined,

    managed: struct {
        gpa: std.mem.Allocator,
        // Access token has no defined length, so we "have" to allocate it
        access_token: []const u8 = "",
    },

    state: union(enum) {
        wait_access_token,
        init_tls,
        default,
        message: *std.Io.Reader,
    },

    // Register websocket http request if we are currently doing one
    register_req: ?http.Client.FetchHandle,

    id_list: EventIdList,

    record_file: std.fs.File,
    record_writer_buf: [4096]u8 = undefined,
    record_writer: std.fs.File.Writer,

    // We are expecting to have 1, mayyyybe 2 websockets for the whole app, so
    // we can be fairly loose with this
    const max_message_size = 512 * 1024;

    pub fn initPinned(self: *Connection, gpa: std.mem.Allocator, scratch: sphtud.alloc.LinearAllocator, refs: ConnectionRefs, id_list: EventIdList) !void {
        const access_token = getStoredAccessToken(gpa, scratch.allocator(), refs.xdg) catch "";

        const record_path = try refs.xdg.appdata(scratch.allocator(), "ws_record.txt");
        const record_file = try std.fs.cwd().createFile(record_path, .{
            .read = true,
            .truncate = false,
        });

        self.* = .{
            .tls = undefined,
            .ws = undefined,
            .refs = refs,
            .state = .wait_access_token,
            .register_req = null,
            .managed = .{
                .gpa = gpa,
                .access_token = access_token,
            },
            .id_list = id_list,
            .record_file = record_file,
            .record_writer = record_file.writer(&self.record_writer_buf),
        };

        var reader_buf: [4096]u8 = undefined;
        var record_reader = record_file.reader(&reader_buf);

        try self.loadFromHistory(scratch, &record_reader.interface);
        try self.record_writer.seekTo(try record_file.getEndPos());

        if (self.managed.access_token.len > 0) {
            try self.connectWebsocket(scratch);
        }
    }

    pub fn deinit(self: *Connection) void {
        if (self.connectionValid()) {
            self.tls.close();
        }

        self.record_file.close();
    }

    pub fn setAccessToken(self: *Connection, scratch: sphtud.alloc.LinearAllocator, token: []const u8) !void {
        try replaceManaged(self.managed.gpa, &self.managed.access_token, token);

        const app_data_path = try getAccessTokenPath(scratch.allocator(), self.refs.xdg.*);

        std.fs.cwd().writeFile(.{
            .sub_path = app_data_path,
            .data = token,
        }) catch |e| {
            std.log.err("Failed to save access token: {t}", .{e});
        };

        try self.connectWebsocket(scratch);
    }

    fn connectWebsocket(self: *Connection, scratch: sphtud.alloc.LinearAllocator) !void {
        if (self.connectionValid()) {
            try self.refs.loop.unregister(self.tls.handle());
            self.tls.close();
            self.tls = undefined;
            self.ws = undefined;
        }

        self.state = .init_tls;

        const uri_meta = try sphws.UriMetadata.fromString(scratch.allocator(), "wss://eventsub.wss.twitch.tv/ws");

        const std_stream = try std.net.tcpConnectToHost(scratch.allocator(), uri_meta.host, uri_meta.port);
        try self.tls.initPinned(std_stream, uri_meta.host, self.refs.ca_bundle.*);
        errdefer self.tls.close();

        self.ws = try sphws.Websocket.init(self.tls.reader(), self.tls.writer(), uri_meta.host, uri_meta.path, self.refs.random);
        try self.tls.flush();

        try sphtud.event.setNonblock(self.tls.handle());

        try self.refs.loop.register(.{
            .handle = self.tls.handle(),
            .id = self.id_list.websocket_message,
            .read = true,
            .write = false,
        });

        self.state = .default;
    }

    fn connectionValid(self: *Connection) bool {
        return switch (self.state) {
            .wait_access_token, .init_tls => false,
            .default, .message => true,
        };
    }

    // FIXME: Evaluate and limit errors
    //
    // FIXME: On EndOfStream re-init the connection? Maybe on a timer
    pub fn poll(self: *Connection, scratch: sphtud.alloc.LinearAllocator, event: usize, comptime id_list: EventIdList) !void {
        switch (event) {
            id_list.websocket_message => try self.pollWs(scratch),
            id_list.register_websocket => try self.pollRegister(scratch),
            else => unreachable,
        }
    }

    pub fn pollRegister(self: *Connection, scratch: sphtud.alloc.LinearAllocator) !void {
        const register_req = self.register_req orelse return;
        const conn = self.refs.http_client.get(register_req);

        const res = conn.poll(scratch.allocator(), &.{}) catch |e| {
            if (conn.isWouldBlock(e)) return;
            return e;
        };

        self.register_req = null;

        // FIXME: Maybe we should close the app if it can't do anything?
        std.debug.print("ws registration {t}\n", .{res.header.status});
        self.refs.http_client.release(register_req);
    }

    pub fn pollWs(self: *Connection, scratch: sphtud.alloc.LinearAllocator) !void {
        const cp = scratch.checkpoint();
        while (true) {
            defer scratch.restore(cp);

            self.pollWsInner(scratch) catch |e| {
                if (self.tls.isWouldBlock(e)) return;
                return e;
            };
        }
    }

    pub fn pollWsInner(self: *Connection, scratch: sphtud.alloc.LinearAllocator) !void {
        switch (self.state) {
            .wait_access_token, .init_tls => unreachable,
            .default => try self.pollDefault(),
            .message => |data| self.pollMessageData(scratch, data) catch |e| {
                if (self.tls.isWouldBlock(e)) return;

                self.state = .default;
                std.log.err("Dropped message: {t}\n", .{e});
            },
        }

        try self.tls.flush();
    }

    fn pollMessageData(self: *Connection, scratch: sphtud.alloc.LinearAllocator, data_reader: *std.Io.Reader) !void {
        const message = try entireStreamBuffered(data_reader);

        recordMessage(message, &self.record_writer.interface) catch |e| {
            std.log.err("Droppping record {t}\n", .{e});
        };

        // FIXME: Read segment probably wants it's own fn
        self.state = .default;

        const common = std.json.parseFromSliceLeaky(
            twitch_api.websocket.CommonMessage,
            scratch.allocator(),
            message,
            .{ .ignore_unknown_fields = true },
        ) catch {
            std.log.err("Invalid json message: {s}\n", .{message});
            return;
        };


        std.debug.print("Received message: {any}\n", .{common});

        const message_type = common.messageType() orelse return;

        switch (message_type) {
            .session_welcome => {
                const welcome = std.json.parseFromSliceLeaky(
                    twitch_api.websocket.SessionWelcome,
                    scratch.allocator(),
                    message,
                    .{ .ignore_unknown_fields = true },
                ) catch {
                    std.log.err("Invalid welcome message: {s}\n", .{message});
                    return;
                };

                std.debug.print("Setting websocket id: {s}\n", .{welcome.payload.session.id});

                if (self.managed.access_token.len == 0) return error.NoAccessToken;

                self.register_req = try registerSocket(
                    scratch.allocator(),
                    self.refs.http_client,
                    self.managed.access_token,
                    self.refs.client_id,
                    welcome.payload.session.id,
                    self.id_list.register_websocket,
                );
            },
            .notification => try self.handleNotification(scratch,message),
        }
    }

    fn pollDefault(self: *Connection) !void {
        const res = try self.ws.poll(&self.ws_data_buf);

        switch (res) {
            .initialized => {},
            .message => |message| {
                self.state = .{ .message = message.data };
                return;
            },
            .redirect => unreachable,
            .none => {},
        }
    }

    fn handleNotification(self: *Connection, scratch: sphtud.alloc.LinearAllocator, message: []const u8) !void {
        // FIXME: Insert into message db
        const notification = try std.json.parseFromSliceLeaky(
            twitch_api.websocket.Notification,
            scratch.allocator(),
            message,
            .{ .ignore_unknown_fields = true },
        );

        if (!std.mem.eql(u8, "channel.chat.message", notification.payload.subscription.type)) return;

        const chat_message = try std.json.parseFromValueLeaky(
            twitch_api.websocket.ChatMessageEvent,
            scratch.allocator(),
            notification.payload.event,
            .{ .ignore_unknown_fields = true },
        );

        try self.refs.message_db.push( chat_message.chatter_user_name, chat_message.message.text );
    }


    fn recordMessage(message: []const u8, writer: *std.Io.Writer) !void {
        try writer.writeAll(message);
        try writer.writeByte(0);
        try writer.writeByte('\n');
        try writer.flush();
    }

    fn loadFromHistory(self: *Connection, scratch: sphtud.alloc.LinearAllocator, reader: *std.Io.Reader) !void {

        const cp = scratch.checkpoint();
        // Advance cursor until we see '\0\n'
        while (true) {
            defer scratch.restore(cp);

            const buffer = reader.buffered();
            std.debug.print("Buffered data: {s}\n", .{buffer});
            const message_len = std.mem.indexOf(u8, buffer, &.{0, '\n'}) orelse {
                reader.fillMore() catch |e| switch (e) {
                    error.EndOfStream => break,
                    else => return e,
                };
                continue;
            };

            reader.toss(message_len + 2);
            const message = buffer[0..message_len];
            std.debug.print("message_len: {d}, message data: {s}\n", .{message_len, message});

            const common = std.json.parseFromSliceLeaky(
                twitch_api.websocket.CommonMessage,
                scratch.allocator(),
                message,
                .{ .ignore_unknown_fields = true },
            ) catch {
                std.log.err("Invalid json message: {s}\n", .{message});
                return;
            };

            const message_type = common.messageType() orelse continue;
            switch (message_type) {
                .session_welcome => {},
                .notification => try self.handleNotification(scratch,message),
            }
        }
    }
};

fn registerSocket(
    scratch: std.mem.Allocator,
    http_client: *http.Client,
    access_token: []const u8,
    client_id: []const u8,
    websocket_id: []const u8,
    event_id: usize,
) !http.Client.FetchHandle {
    const conn = try http_client.fetch(
        scratch,
        "api.twitch.tv",
        443,
        event_id,
    );

    // FIXME: Probably should be resolved in main() or something
    const chat_id = "51219542";
    const bot_id = "51219542";

    const post_body = try std.json.Stringify.valueAlloc(
        scratch,
        twitch_api.RegisterWebsocket{
            .type = "channel.chat.message",
            .version = "1",
            .condition = .{
                .broadcaster_user_id = chat_id,
                .user_id = bot_id,
            },
            .transport = .{
                .method = "websocket",
                .session_id = websocket_id,
            },
        },
        .{ .whitespace = .indent_2 },
    );

    const bear_string = try std.fmt.allocPrint(scratch, "Bearer {s}", .{access_token});

    const http_w = &conn.val.http_writer;
    try http_w.startRequest(.{
        .method = .POST,
        .target = "/helix/eventsub/subscriptions",
        .content_length = post_body.len,
        .content_type = "application/json",
    });
    try http_w.appendHeader("Authorization", bear_string);
    try http_w.appendHeader("Client-Id", client_id);
    try http_w.appendHeader("Host", "api.twitch.tv");
    try http_w.writeBody(post_body);

    try conn.val.flush();
    return conn.handle;
}

fn getAccessTokenPath(alloc: std.mem.Allocator, xdg: Xdg) ![]const u8 {
    return xdg.appdata(alloc, "auth_state.txt");
}

fn replaceManaged(alloc: std.mem.Allocator, stored: *[]const u8, data: []const u8) !void {
    const new_stored = try alloc.dupe(u8, data);
    alloc.free(stored.*);
    stored.* = new_stored;
}

fn getStoredAccessToken(alloc: std.mem.Allocator, scratch: std.mem.Allocator, xdg: *const Xdg) ![]const u8 {
    const app_data_path = try getAccessTokenPath(scratch, xdg.*);
    return std.fs.cwd().readFileAlloc(alloc, app_data_path, std.math.maxInt(usize));
}

fn entireStreamBuffered(data: *std.Io.Reader) ![]const u8 {
    while (data.end < data.buffer.len) {
        _ = data.fillMore() catch |e| {
            if (e == error.EndOfStream) return data.buffered();
            return e;
        };
    }

    return error.MessageTooLarge;
}
