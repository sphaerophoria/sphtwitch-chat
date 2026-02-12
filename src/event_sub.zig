// FIXME: Generally this file is structured pretty poorly. Evolved from
// RegisterState and Connection being split, but realized that the websocket
// needs to be initialized when we have an oauth key ready to go
//
// * Probably the connection state machine should have a waiting_welcome and waiting_welcome_body_state

const std = @import("std");
const sphtud = @import("sphtud");
const sphws = @import("sphws");
const EventIdIter = @import("EventIdIter.zig");
const http = @import("http.zig");
const Xdg = @import("Xdg.zig");
const twitch_api = @import("twitch_api.zig");

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

    // We are expecting to have 1, mayyyybe 2 websockets for the whole app, so
    // we can be fairly loose with this
    const max_message_size = 512 * 1024;

    pub fn initPinned(self: *Connection, gpa: std.mem.Allocator, scratch: sphtud.alloc.LinearAllocator, refs: ConnectionRefs, id_list: EventIdList) !void {
        const access_token = getStoredAccessToken(gpa, scratch.allocator(), refs.xdg) catch "";

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
        };

        if (self.managed.access_token.len > 0) {
            try self.connectWebsocket(scratch);
        }
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
            .message => |data| try self.pollMessageData(scratch, data),
        }

        try self.tls.flush();
    }

    fn pollMessageData(self: *Connection, scratch: sphtud.alloc.LinearAllocator, data: *std.Io.Reader) !void {
        // Fill data's buffer until literally end of stream

        // FIXME: Read segment probably wants it's own fn
        if (data.end == data.buffer.len) {
            return error.MessageTooLarge;
        }

        while (true) {
            _ = data.fillMore() catch |e| {
                if (e == error.EndOfStream) break;
                return e;
            };
        }

        self.state = .default;

        const common = std.json.parseFromSliceLeaky(
            twitch_api.websocket.CommonMessage,
            scratch.allocator(),
            data.buffered(),
            .{ .ignore_unknown_fields = true },
        ) catch {
            std.log.err("Invalid json message: {s}\n", .{data.buffered()});
            return;
        };

        std.debug.print("Received message: {any}\n", .{common});

        const message_type = common.messageType() orelse return;

        switch (message_type) {
            .session_welcome => {
                const welcome = std.json.parseFromSliceLeaky(
                    twitch_api.websocket.SessionWelcome,
                    scratch.allocator(),
                    data.buffered(),
                    .{ .ignore_unknown_fields = true },
                ) catch {
                    std.log.err("Invalid welcome message: {s}\n", .{data.buffered()});
                    return;
                };

                std.debug.print("Setting websocket id: {s}\n", .{welcome.payload.session.id});

                if (self.managed.access_token.len == 0) return error.NoAccessToken;
                self.register_req = try registerSocket(scratch.allocator(), self.refs.http_client, self.managed.access_token, self.refs.client_id, welcome.payload.session.id, self.id_list.register_websocket,);
            },
            .notification => {},
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
};

fn registerSocket(scratch: std.mem.Allocator, http_client: *http.Client, access_token: []const u8, client_id: []const u8, websocket_id: []const u8, event_id: usize,) !http.Client.FetchHandle {
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
