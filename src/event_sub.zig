const std = @import("std");
const sphtud = @import("sphtud");
const sphws = @import("sphws");
const EventIdIter = @import("EventIdIter.zig");
const http = @import("http.zig");

pub const RegisterStateFetchIdList = struct {
    register_websocket: comptime_int,
    start: comptime_int,
    end: comptime_int,

    pub fn generate(id_iter: *EventIdIter) RegisterStateFetchIdList {
        return .{
            .start = id_iter.markStart(),
            .register_websocket = id_iter.one(),
            .end = id_iter.markEnd(),
        };
    }
};

pub fn RegisterState(comptime fetch_id_list: RegisterStateFetchIdList) type {
    return  struct {
        alloc: std.mem.Allocator,
        http_client: *http.Client,

        websocket_id: ?[]const u8,
        oauth_key: ?[]const u8,
        state: ?[]const u8,

        const Self = @This();

        pub fn setWsId(self: *Self, id: []const u8) !void {
            std.debug.assert(self.websocket_id == null);
            self.websocket_id = try self.alloc.dupe(u8, id);
            try self.maybeRegisterSocket();
        }

        pub fn setOauthKey(self: *Self, key: []const u8, state: []const u8) !void {
            const expected_state = self.state orelse return error.NoOutstandingRequest;
            if (!std.mem.eql(u8, state, expected_state)) return error.UnexpectedState;

            std.debug.assert(self.oauth_key == null);
            self.oauth_key = try self.alloc.dupe(u8, key);
            try self.maybeRegisterSocket();
        }

        fn maybeRegisterSocket(self: *Self, scratch: sphtud.alloc.LinearAllocator) !void {
            const ws_id = self.websocket_id orelse return;
            const oauth_key = self.oauth_key orelse return;
            _ = ws_id;
            _ = oauth_key;

            std.debug.print("Have WS ID and key\n", .{});

            const conn = try self.http_client.fetch(scratch, "api.twitch.tv", 443, fetch_id_list.register_websocket);
            _ = conn;
            //const chat_id = "51219542";
            //const bot_id = "51219542";
            //try self.spawner.spawnRegisterEventSub(chat_id, bot_id, ws_id, oauth_key);
        }

        pub fn pollFetch(self: *Self, scratch: sphtud.alloc.LinearAllocator, state: *http.Client.ConnectionState) !void {
            _ = self;
            switch (state.fetch_id) {
                fetch_id_list.register_websocket => {
                    const cp = scratch.checkpoint();

                    var body_buf: [4096]u8 = undefined;

                    while (true) {
                        defer scratch.restore(cp);

                        const response = try state.connection.poll(scratch.allocator(), &body_buf);
                        std.debug.print("{t}\n", .{response.header.status});
                    }
                },
                else => unreachable,
            }
        }
    };
}

pub const Connection = struct {
    // FIXME: Looks like duplication with our http.TlsConnection
    conn: sphws.conn.TlsConnection,
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

    //event_sub_reg_state: *RegisterState,

    // We are expecting to have 1, mayyyybe 2 websockets for the whole app, so
    // we can just shove our entire message content in here for now
    const max_message_size = 512 * 1024;

    pub fn initPinned(self: *Connection, scratch: std.mem.Allocator, ca_bundle: std.crypto.Certificate.Bundle, uri_meta: sphws.UriMetadata, random: std.Random) !void {
        try self.conn.initPinned(scratch, ca_bundle, uri_meta);
        self.ws = try sphws.Websocket.init(&self.conn.tls_client.reader, &self.conn.tls_client.writer, uri_meta.host, uri_meta.path, random);
        try self.conn.flush();
        self.message_content.writer = std.Io.Writer.fixed(&self.message_content.buf);
        self.state = .default;
        //self.event_sub_reg_state = event_sub_reg_state;
    }

    // FIXME: Evaluate and limit errors
    pub fn poll(self: *Connection, scratch: sphtud.alloc.LinearAllocator) !void {
        const cp = scratch.checkpoint();
        while (true) {
            defer scratch.restore(cp);

            self.pollInner(scratch.allocator()) catch |e| {
                if (isWouldBlock(&self.conn.stream_reader, e)) return;
                return e;
            };
        }
    }

    pub fn pollInner(self: *Connection, scratch: std.mem.Allocator) !void {
        switch (self.state) {
            .default => try self.pollDefault(),
            .message => |data| try self.pollMessageData(scratch, data),
        }
    }

    fn pollMessageData(self: *Connection, scratch: std.mem.Allocator, data: *std.Io.Reader) !void {
        // Read json message
        const CommonMessage  = struct {
            metadata: struct {
                message_type: []const u8,
            },
        };

        // FIXME: These types need to live somewhere else
        const MessageType = enum {
            session_welcome,
            notification
        };

        _ = try data.streamRemaining(&self.message_content.writer);

        self.state = .default;

        // FIXME: We probably actually want to reset the scratch allocator here
        const message = std.json.parseFromSliceLeaky(CommonMessage, scratch, self.message_content.writer.buffered(), .{ .ignore_unknown_fields = true }) catch {
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

                const welcome = std.json.parseFromSliceLeaky(SessionWelcome, scratch, self.message_content.writer.buffered(), .{ .ignore_unknown_fields = true }) catch {
                    std.log.err("Invalid welcome message: {s}\n", .{self.message_content.writer.buffered()});
                    return;
                };

                std.debug.print("Setting websocket id: {s}\n", .{welcome.payload.session.id});
                //try self.event_sub_reg_state.setWsId(welcome.payload.session.id);
            },
            .notification => {},
        }
    }

    fn pollDefault(self: *Connection) !void {
        const res = try self.ws.poll(&self.ws_data_buf);

        switch (res) {
            .initialized => {},
            .message => |message| {
                self.state = .{ .message =  message.data } ;
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

