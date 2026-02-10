const std = @import("std");
const sphtud = @import("sphtud");
const sphws = @import("sphws");
const EventIdIter = @import("EventIdIter.zig");
const http = @import("http.zig");
const Xdg = @import("Xdg.zig");

pub const RegisterState = struct {
    http_client: *http.Client,
    xdg: *const Xdg,

    alloc: std.mem.Allocator,

    websocket_id: []const u8 = "",
    access_token: []const u8 = "",
    client_id: []const u8,

    outstanding_req: ?http.Client.FetchHandle,

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
            .alloc = gpa,
            .xdg = xdg,
            .access_token = access_token,
            .http_client = http_client,
            .id_list = id_list,
            .outstanding_req = null,
            .client_id = client_id,
        };
    }

    pub fn setWsId(self: *Self, scratch: sphtud.alloc.LinearAllocator, id: []const u8) !void {
        const new_id = try self.alloc.dupe(u8, id);
        self.alloc.free(self.websocket_id);
        self.websocket_id = new_id;

        try self.maybeRegisterSocket(scratch);
    }

    pub fn setAccessToken(self: *Self, scratch: sphtud.alloc.LinearAllocator, token: []const u8) !void {
        const new_token = try self.alloc.dupe(u8, token);
        self.alloc.free(self.access_token);
        self.access_token = new_token;

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

    fn maybeRegisterSocket(self: *Self, scratch: sphtud.alloc.LinearAllocator) !void {
        if (self.websocket_id.len == 0) return;
        if (self.access_token.len == 0) return;

        std.debug.print("Have WS ID and key\n", .{});

        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        const conn = try self.http_client.fetch(scratch.allocator(), "api.twitch.tv", 443, self.id_list.register_websocket);
        self.outstanding_req = conn.handle;
        const chat_id = "51219542";
        const bot_id = "51219542";

        const RegisterMesage = struct { type: []const u8, version: []const u8, condition: struct { broadcaster_user_id: []const u8, user_id: []const u8 }, transport: struct {
            method: []const u8,
            session_id: []const u8,
        } };

        const post_body = try std.json.Stringify.valueAlloc(scratch.allocator(), RegisterMesage{
            .type = "channel.chat.message",
            .version = "1",
            .condition = .{
                .broadcaster_user_id = chat_id,
                .user_id = bot_id,
            },
            .transport = .{
                .method = "websocket",
                .session_id = self.websocket_id,
            },
        }, .{ .whitespace = .indent_2 });

        const bear_string = try std.fmt.allocPrint(scratch.allocator(), "Bearer {s}", .{self.access_token});

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

        std.debug.print("ws registration {t}\n", .{res.header.status});
        self.http_client.release(outstanding_req);
    }
};

pub const Connection = struct {
    tls: sphtud.net.TlsStream(4096, 4096),
    ws: sphws.Websocket,

    ws_data_buf: [8192]u8 = undefined,

    message_content: struct {
        buf: [max_message_size]u8 = undefined,
        writer: std.Io.Writer,
    },

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

        self.message_content.writer = std.Io.Writer.fixed(&self.message_content.buf);
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
        // Read json message
        const CommonMessage = struct {
            metadata: struct {
                message_type: []const u8,
            },
        };

        // FIXME: These types need to live somewhere else
        const MessageType = enum { session_welcome, notification };

        _ = try data.streamRemaining(&self.message_content.writer);

        self.state = .default;

        // FIXME: We probably actually want to reset the scratch allocator here
        const message = std.json.parseFromSliceLeaky(CommonMessage, scratch.allocator(), self.message_content.writer.buffered(), .{ .ignore_unknown_fields = true }) catch {
            std.log.err("Invalid json message: {s}\n", .{self.message_content.writer.buffered()});
            return;
        };

        std.debug.print("Received message: {any}\n", .{message});

        const message_type = std.meta.stringToEnum(MessageType, message.metadata.message_type) orelse return;
        switch (message_type) {
            .session_welcome => {
                const SessionWelcome = struct {
                    payload: struct {
                        session: struct {
                            id: []const u8,
                            keepalive_timeout_seconds: u32,
                        },
                    },
                };

                const welcome = std.json.parseFromSliceLeaky(SessionWelcome, scratch.allocator(), self.message_content.writer.buffered(), .{ .ignore_unknown_fields = true }) catch {
                    std.log.err("Invalid welcome message: {s}\n", .{self.message_content.writer.buffered()});
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

// FIXME: This surely will come up a lot, move into sphtud
fn isWouldBlock(r: *std.net.Stream.Reader, e: anyerror) bool {
    switch (e) {
        error.ReadFailed => {
            const se = r.getError() orelse return false;
            switch (se) {
                error.WouldBlock => return true,
                else => {},
            }
        },
        else => {},
    }

    return false;
}
