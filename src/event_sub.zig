const std = @import("std");
const sphtud = @import("sphtud");
const sphws = @import("sphws");
const EventIdIter = @import("EventIdIter.zig");
const http = @import("http.zig");
const Xdg = @import("Xdg.zig");
const twitch_api = @import("twitch_api.zig");

pub const RegisterState = struct {
    http_client: *http.Client,
    xdg: *const Xdg,

    // Needs to out-live state
    client_id: []const u8,

    // websocket_id/access_token have uncapped lengths, so we "have" to
    // allocate them on the fly when we see them
    managed: struct {
        alloc: std.mem.Allocator,
        websocket_id: []const u8 = "",
        access_token: []const u8 = "",
    },

    // Register websocket http request if we are currently doing one
    outstanding_req: ?http.Client.FetchHandle,

    // Even those this is comptime known, feeding that comptime known data this
    // deep down the call stack is annoying. Just stash it at runtime and
    // reference
    id_list: EventIdList,

    const empty = "";

    pub const EventIdList = struct {
        register_websocket: usize,
        start: usize,
        end: usize,

        pub fn generate(id_iter: *EventIdIter) EventIdList {
            return .{
                .start = id_iter.markStart(),
                .register_websocket = id_iter.one(),
                .end = id_iter.markEnd(),
            };
        }
    };

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator, scratch: sphtud.alloc.LinearAllocator, http_client: *http.Client, id_list: EventIdList, xdg: *const Xdg, client_id: []const u8) !RegisterState {
        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        const app_data_path = try getAccessTokenPath(scratch.allocator(), xdg.*);
        const access_token = std.fs.cwd().readFileAlloc(gpa, app_data_path, std.math.maxInt(usize)) catch "";

        return .{
            .managed = .{
                .alloc = gpa,
                .access_token = access_token,
            },
            .xdg = xdg,
            .http_client = http_client,
            .id_list = id_list,
            .outstanding_req = null,
            .client_id = client_id,
        };
    }

    pub fn setWsId(self: *Self, scratch: sphtud.alloc.LinearAllocator, id: []const u8) !void {
        try replaceManaged(self.managed.alloc, &self.managed.websocket_id, id);
        try self.maybeRegisterSocket(scratch);
    }

    pub fn setAccessToken(self: *Self, scratch: sphtud.alloc.LinearAllocator, token: []const u8) !void {
        try replaceManaged(self.managed.alloc, &self.managed.access_token, token);

        const app_data_path = try getAccessTokenPath(scratch.allocator(), self.xdg.*);

        std.fs.cwd().writeFile(.{
            .sub_path = app_data_path,
            .data = token,
        }) catch |e| {
            std.log.err("Failed to save access token: {t}", .{e});
        };

        try self.maybeRegisterSocket(scratch);
    }

    fn getAccessTokenPath(alloc: std.mem.Allocator, xdg: Xdg) ![]const u8 {
        return xdg.appdata(alloc, "auth_state.txt");
    }

    fn replaceManaged(alloc: std.mem.Allocator, stored: *[]const u8, data: []const u8) !void {
        const new_stored = try alloc.dupe(u8, data);
        alloc.free(stored.*);
        stored.* = new_stored;
    }

    fn maybeRegisterSocket(self: *Self, scratch: sphtud.alloc.LinearAllocator) !void {
        if (self.managed.websocket_id.len == 0) return;
        if (self.managed.access_token.len == 0) return;

        std.debug.print("Have WS ID and key\n", .{});

        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        const conn = try self.http_client.fetch(
            scratch.allocator(),
            "api.twitch.tv",
            443,
            self.id_list.register_websocket,
        );
        self.outstanding_req = conn.handle;

        // FIXME: Probably should be resolved in main() or something
        const chat_id = "51219542";
        const bot_id = "51219542";

        const post_body = try std.json.Stringify.valueAlloc(
            scratch.allocator(),
            twitch_api.RegisterWebsocket{
                .type = "channel.chat.message",
                .version = "1",
                .condition = .{
                    .broadcaster_user_id = chat_id,
                    .user_id = bot_id,
                },
                .transport = .{
                    .method = "websocket",
                    .session_id = self.managed.websocket_id,
                },
            },
            .{ .whitespace = .indent_2 },
        );

        const bear_string = try std.fmt.allocPrint(scratch.allocator(), "Bearer {s}", .{self.managed.access_token});

        const http_w = &conn.val.http_writer;
        try http_w.startRequest(.{
            .method = .POST,
            .target = "/helix/eventsub/subscriptions",
            .content_length = post_body.len,
            .content_type = "application/json",
        });
        try http_w.appendHeader("Authorization", bear_string);
        try http_w.appendHeader("Client-Id", self.client_id);
        try http_w.appendHeader("Host", "api.twitch.tv");
        try http_w.writeBody(post_body);

        try conn.val.flush();
    }

    pub fn poll(self: *Self, scratch: sphtud.alloc.LinearAllocator) !void {
        const outstanding_req = self.outstanding_req orelse return;
        const conn = self.http_client.get(outstanding_req);

        const res = conn.poll(scratch.allocator(), &.{}) catch |e| {
            if (conn.isWouldBlock(e)) return;
            return e;
        };

        // FIXME: Maybe we should close the app if it can't do anything?
        std.debug.print("ws registration {t}\n", .{res.header.status});
        self.http_client.release(outstanding_req);
    }
};

pub const Connection = struct {
    tls: sphtud.net.TlsStream(4096, 4096),
    ws: sphws.Websocket,

    // std.Io.Reader returned by websocket message notification uses this as
    // the backing buffer. We buffer the entire json message into here before
    // parsing
    ws_data_buf: [max_message_size]u8 = undefined,

    state: union(enum) {
        default,
        message: *std.Io.Reader,
    },

    event_sub_reg_state: *RegisterState,

    // We are expecting to have 1, mayyyybe 2 websockets for the whole app, so
    // we can just shove our entire message content in here for now
    const max_message_size = 512 * 1024;

    pub fn initPinned(self: *Connection, scratch: std.mem.Allocator, ca_bundle: std.crypto.Certificate.Bundle, random: std.Random, event_sub_reg_state: *RegisterState, loop: *sphtud.event.Loop2, comptime ws_id: usize) !void {
        const uri_meta = try sphws.UriMetadata.fromString(scratch, "wss://eventsub.wss.twitch.tv/ws");

        const std_stream = try std.net.tcpConnectToHost(scratch, uri_meta.host, uri_meta.port);
        try self.tls.initPinned(std_stream, uri_meta.host, ca_bundle);

        self.ws = try sphws.Websocket.init(self.tls.reader(), self.tls.writer(), uri_meta.host, uri_meta.path, random);
        try self.tls.flush();

        try sphtud.event.setNonblock(self.tls.handle());

        self.state = .default;
        self.event_sub_reg_state = event_sub_reg_state;

        try loop.register(.{
            .handle = self.tls.handle(),
            .id = ws_id,
            .read = true,
            .write = false,
        });
    }

    // FIXME: Evaluate and limit errors
    //
    // FIXME: On EndOfStream re-init the connection? Maybe on a timer
    pub fn poll(self: *Connection, scratch: sphtud.alloc.LinearAllocator) !void {
        const cp = scratch.checkpoint();
        while (true) {
            defer scratch.restore(cp);

            self.pollInner(scratch) catch |e| {
                if (self.tls.isWouldBlock(e)) return;
                return e;
            };
        }
    }

    pub fn pollInner(self: *Connection, scratch: sphtud.alloc.LinearAllocator) !void {
        switch (self.state) {
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
                try self.event_sub_reg_state.setWsId(scratch, welcome.payload.session.id);
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
