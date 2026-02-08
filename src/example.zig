const std = @import("std");
const sphtud = @import("sphtud");
const sphws = @import("sphws");

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

const index_html = @embedFile("res/index.html");

const TwitchWebsocketSub = struct {
    parent: *TwitchApiConnectionSpawner,
    tls: TlsConnection,
    response_reader: sphtud.http.HttpResponseReader,

    pub fn initPinned(self: *TwitchWebsocketSub, scratch: std.mem.Allocator, parent: *TwitchApiConnectionSpawner) !void {
        self.parent = parent;
        try self.tls.initPinned(scratch, parent.ca_bundle.*, "api.twitch.tv", 443);
        self.response_reader = .init(&self.tls.tls_client.reader);
    }

    fn handler(self: *TwitchWebsocketSub) sphtud.event.Loop.Handler {
        return .{
            .ptr = self,
            .fd = self.tls.stream.handle,
            .vtable = &.{
                .poll = poll,
                .close = close,
            },
            .desired_events = .{
                .read = true,
                .write = false,
            },
        };
    }

    fn poll(ctx: ?*anyopaque, loop: *sphtud.event.Loop, reason: sphtud.event.PollReason) sphtud.event.Loop.PollResult {
        // if ok, close
        // if not ok shutdown = trrue and close
        _ = loop;
        _ = reason;

        const self: *TwitchWebsocketSub = @ptrCast(@alignCast(ctx));
        return self.pollInner() catch |e| {

            if (isWouldBlock(&self.tls.stream_reader, e))  {
                std.debug.print("He hasn't said anything, give him a minute bitch\n", .{});
                return .in_progress;
            }

            std.log.err("Killing connection {t}\n", .{e});
            return .complete;
        };
    }

    fn pollInner(self: *TwitchWebsocketSub) !sphtud.event.Loop.PollResult {
        std.debug.print("Twitch API is talking to me\n", .{});

        var body_buf: [4096]u8 = undefined;
        std.debug.print("Waiting for response\n", .{});
        std.debug.print("stream buf: {d}\n", .{self.tls.stream_reader.interface().buffered().len});
        std.debug.print("tls buf: {d}\n", .{self.tls.tls_client.reader.buffered().len});
        const res = try self.response_reader.poll(self.parent.scratch, &body_buf);
        std.debug.print("Got {t}\n", .{res.header.status});
        return .complete;
        //while (true) {
        //    const content = self.tls.tls_client.reader.peekGreedy(1) catch |e| {
        //        std.debug.print("No more body {t}\n", .{e});
        //        break;
        //    };
        //    std.debug.print("{s}\n", .{content});
        //    self.tls.tls_client.reader.toss(content.len);
        //}
    }

    fn close(ctx: ?*anyopaque) void {
        const self: *TwitchWebsocketSub = @ptrCast(@alignCast(ctx));
        self.parent.destroyWsSub(self);
    }
};

// FIXME: This needs to live in sphtud.net or something
pub const TlsConnection = struct {
    tls_read_buffer: [tls_read_buffer_len]u8,
    tls_write_buffer: [write_buffer_size]u8,

    socket_write_buffer: [tls_buffer_size]u8,
    socket_read_buffer: [tls_buffer_size]u8,

    stream: std.net.Stream,
    stream_reader: std.net.Stream.Reader,
    stream_writer: std.net.Stream.Writer,

    tls_client: std.crypto.tls.Client,

    const tls_buffer_size = std.crypto.tls.Client.min_buffer_len;
    const read_buffer_size = 8192;
    const write_buffer_size = 1024;

    // The TLS client wants enough buffer for the max encrypted frame
    // size, and the HTTP body reader wants enough buffer for the
    // entire HTTP header. This means we need a combined upper bound.
    const tls_read_buffer_len = tls_buffer_size + read_buffer_size;

    pub fn initPinned(self: *TlsConnection, scratch: std.mem.Allocator, ca_bundle: std.crypto.Certificate.Bundle, host: []const u8, port: u16) !void {
        self.stream = try std.net.tcpConnectToHost(scratch, host, port);

        self.stream_reader = self.stream.reader(&self.socket_read_buffer);
        self.stream_writer = self.stream.writer(&self.socket_write_buffer);

        self.tls_client = try std.crypto.tls.Client.init(
            self.stream_reader.interface(),
            &self.stream_writer.interface,
            .{
                .host = .{ .explicit = host },
                .ca = .{ .bundle = ca_bundle },
                .ssl_key_log = null,
                .read_buffer = &self.tls_read_buffer,
                .write_buffer = &self.tls_write_buffer,
                // This is appropriate for HTTPS because the HTTP headers contain
                // the content length which is used to detect truncation attacks.
                .allow_truncation_attacks = true,
            },
        );

        try sphtud.event.setNonblock(self.stream.handle);
    }

    pub fn deinit(self: *TlsConnection) void {
        self.stream.close();
    }

    pub fn hasBufferedData(self: *TlsConnection) bool {
        return self.stream_writer.interface.buffered().len > 0 or
            self.tls_client.writer.buffered().len > 0;
    }


    pub fn flush(self: *TlsConnection) !void {
        try self.tls_client.writer.flush();
        try self.stream_writer.interface.flush();
    }
};


const TwitchApiConnectionSpawner = struct {
    loop: *sphtud.event.Loop,
    ca_bundle: *std.crypto.Certificate.Bundle,
    alloc: std.mem.Allocator,
    scratch: std.mem.Allocator,

    pub fn makeWsSub(self: *TwitchApiConnectionSpawner) !*TwitchWebsocketSub {
        const ret = try self.alloc.create(TwitchWebsocketSub);
        try ret.initPinned(self.scratch, self);
        return ret;
    }

    pub fn destroyWsSub(self: *TwitchApiConnectionSpawner, sub: *TwitchWebsocketSub) void {
        sub.tls.deinit();
        self.alloc.destroy(sub);
    }

    pub fn spawnRegisterEventSub(self: *TwitchApiConnectionSpawner, chat_id: []const u8, bot_id: []const u8, ws_id: []const u8, oauth_key: []const u8) !void {

        const conn = try self.makeWsSub();
        errdefer self.destroyWsSub(conn);

        const client_id = "1v2vig9jqtst8h28yaaouxt0fgq5z7";

        var http_w = sphtud.http.HttpWriter.init(&conn.tls.tls_client.writer);

        const RegisterMesage = struct {
            @"type": []const u8,
            version: []const u8,
            condition: struct {
                    broadcaster_user_id: []const u8,
                    user_id: []const u8
            },
            transport: struct {
                    method: []const u8,
                    session_id: []const u8,
            }
        };


        const post_body = try std.json.Stringify.valueAlloc(self.scratch, RegisterMesage {
            .@"type" = "channel.chat.message",
            .version = "1",
            .condition = .{
                .broadcaster_user_id = chat_id,
                .user_id = bot_id,
            },
            .transport = .{
                .method = "websocket",
                .session_id = ws_id,
            },

        }, .{ .whitespace = .indent_2 });

        const bear_string = try std.fmt.allocPrint(self.scratch, "Bearer {s}", .{oauth_key});

        try http_w.startRequest(.{
            .method = .POST,
            .target = "/helix/eventsub/subscriptions",
            .content_length = post_body.len,
            .content_type = "application/json",
        });
        try http_w.appendHeader("Authorization", bear_string);
        try http_w.appendHeader("Client-Id", client_id);
        try http_w.writeBody(post_body);

        try conn.tls.flush();

        try self.loop.register(conn.handler());

        // Errdefer at top of block assumes that loop registration is the last thing that happens
        errdefer comptime unreachable;
    }
};

const EventSubRegisterState = struct {
    alloc: std.mem.Allocator,
    scratch: std.mem.Allocator,

    websocket_id: ?[]const u8,
    oauth_key: ?[]const u8,
    state: ?[]const u8,

    spawner: *TwitchApiConnectionSpawner,

    fn setWsId(self: *EventSubRegisterState, id: []const u8) !void {
        std.debug.assert(self.websocket_id == null);
        self.websocket_id = try self.alloc.dupe(id);
        self.maybeRegisterSocket();
    }

    fn setOauthKey(self: *EventSubRegisterState, key: []const u8, state: []const u8) !void {
        const expected_state = self.state orelse return error.NoOutstandingRequest;
        if (!std.mem.eql(u8, state, expected_state)) return error.UnexpectedState;

        std.debug.assert(self.oauth_key == null);
        self.oauth_key = try self.alloc.dupe(u8, key);
        try self.maybeRegisterSocket();
    }

    fn maybeRegisterSocket(self: *EventSubRegisterState) !void {
        const ws_id = self.websocket_id orelse return;
        const oauth_key = self.oauth_key orelse return;

        const chat_id = "51219542";
        const bot_id = "51219542";
        try self.spawner.spawnRegisterEventSub(chat_id, bot_id, ws_id, oauth_key);
    }
};

const AuthServerConnection = struct {
    // FIXME: Maybe we can remove scratch
    scratch: sphtud.alloc.LinearAllocator,

    parent: *AuthServer,

    stream: std.net.Stream,
    reader_buf: [4096]u8,
    reader: std.net.Stream.Reader,

    req_reader: sphtud.http.HttpRequestReader,

    fn initPinned(self: *AuthServerConnection, stream: std.net.Stream, parent: *AuthServer, scratch: sphtud.alloc.LinearAllocator) void {
        self.stream = stream;
        self.parent = parent;
        self.scratch = scratch;
        self.reader = self.stream.reader(&self.reader_buf);
        self.req_reader = .init(self.reader.interface());
    }

    fn handler(self: *AuthServerConnection) sphtud.event.Loop.Handler {
        return .{
            .ptr = self,
            .vtable = &.{
                .poll = poll,
                .close = close,
            },
            .fd = self.stream.handle,
            .desired_events = .{
                .read = true,
                .write = false,
            },
        };
    }

    fn poll(ctx: ?*anyopaque, loop: *sphtud.event.Loop, reason: sphtud.event.PollReason) sphtud.event.Loop.PollResult {
        _ = loop;
        _ = reason;

        const self: *AuthServerConnection = @ptrCast(@alignCast(ctx));
        return self.pollInner() catch |e| {
            if (isWouldBlock(&self.reader, e)) {
                return .in_progress;
            }

            // FIXME: Check for would block
            std.log.err("Something went wrong {t}\n", .{e});
            return .complete;
        };
    }

    fn pollInner(self: *AuthServerConnection) !sphtud.event.Loop.PollResult {
        var body_buf: [4096]u8 = undefined;
        const req = try self.req_reader.poll(self.scratch.allocator(), &body_buf);

        std.debug.print("{s}\n", .{req.header.target});

        // FIXME: Check for response with state but no code

        //if (!std.mem.eql(u8, req.header.target, "/")) {
        //    // We don't want to talk to you :)
        //    return .complete;
        //}


        var write_buf: [4096]u8 = undefined;
        var writer = self.stream.writer(&write_buf);
        var http_writer = sphtud.http.HttpWriter.init(&writer.interface);

        const target = Target.parse(req.header.target) orelse {
            try http_writer.startResponse(.{
                .content_length = 0,
                .status = .not_found,
            });
            try http_writer.writeBody("");
            try writer.interface.flush();
            return .in_progress;
        };

        // FIXME: Target needs to switch long lived conneciton state machine
        // into auth request mode so that he can read the body between polls
        switch (target) {
            .index => {
                try http_writer.startResponse(.{
                    .content_length = index_html.len,
                    .status = .ok,
                    .content_type = "text/html",
                });
                try http_writer.writeBody(index_html);
                try writer.interface.flush();
            },
            .auth => {
                const AuthResponse = struct {
                    access_token: []const u8,
                    state: []const u8,
                };

                var json_reader = std.json.Reader.init(self.scratch.allocator(), req.body_reader);

                // FIXME: Will fall over if entire body buffer is not in req
                const auth_response = try std.json.parseFromTokenSourceLeaky(AuthResponse, self.scratch.allocator(), &json_reader, .{
                    .ignore_unknown_fields = true,
                });

                try self.parent.event_sub_reg_state.setOauthKey(auth_response.access_token, auth_response.state);
            },
        }

        return .in_progress;
    }

    const RelevantParams = struct {
        code: []const u8,
        state: []const u8,
    };

    fn extractRelevantParams(target: []const u8) !RelevantParams {
        var it = sphtud.http.url.QueryParamIter.init(target);

        const ParamName = enum {
            code,
            state,
        };

        var code: []const u8 = "";
        var state: []const u8  = "";

        while (it.next()) |kv| {
            const param_name = std.meta.stringToEnum(ParamName, kv.key) orelse continue;

            switch (param_name) {
                .code => code = kv.val,
                .state => state = kv.val,
            }
        }

        if (code.len == 0) return error.EmptyCode;
        if (state.len == 0) return error.EmptyState;

        return .{
            .code = code,
            .state = state,
        };
    }

    const Target = enum {
        index,
        auth,

        fn parse(target: []const u8) ?Target {
            const without_query_idx = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
            const without_query = target[0..without_query_idx];

            if (std.mem.eql(u8, without_query, "/")) return .index;
            if (std.mem.eql(u8, without_query, "/auth")) return .auth;

            return null;
        }
    };

    fn close(ctx: ?*anyopaque) void {
        const self: *AuthServerConnection = @ptrCast(@alignCast(ctx));
        self.stream.close();
        self.parent.pool.append(self) catch {
            std.log.err("Leaking request handler\n", .{});
        };
    }
};

const AuthServer = struct {
    alloc: std.mem.Allocator,
    scratch: sphtud.alloc.LinearAllocator,
    pool: sphtud.util.RuntimeSegmentedList(*AuthServerConnection),
    event_sub_reg_state: *EventSubRegisterState,

    pub fn generate(self: *AuthServer, conn: std.net.Server.Connection) !sphtud.event.Loop.Handler {
        const ret = self.pool.pop() orelse try self.alloc.create(AuthServerConnection);
        ret.initPinned(conn.stream, self, self.scratch);

        return ret.handler();
    }

    pub fn close(self: *AuthServer) void {
        _ = self;
    }
};

const EventSubWs = struct {
    // FIXME: Looks like duplication with our above TlsConnection
    conn: sphws.conn.TlsConnection,
    ws: sphws.Websocket,

    scratch: std.mem.Allocator,
    ws_data_buf: [8192]u8 = undefined,

    message_content: struct {
        buf: [max_message_size]u8 = undefined,
        writer: std.Io.Writer,
    },

    state: union(enum) {
        default,
        message: *std.Io.Reader,
    },

    // We are expecting to have 1, mayyyybe 2 websockets for the whole app, so
    // we can just shove our entire message content in here for now
    const max_message_size = 512 * 1024;

    pub fn initPinned(self: *EventSubWs, scratch: std.mem.Allocator, ca_bundle: std.crypto.Certificate.Bundle, uri_meta: sphws.UriMetadata, random: std.Random) !void {
        try self.conn.initPinned(scratch, ca_bundle, uri_meta);
        self.ws = try sphws.Websocket.init(&self.conn.tls_client.reader, &self.conn.tls_client.writer, uri_meta.host, uri_meta.path, random);
        try self.conn.flush();
        self.message_content.writer = std.Io.Writer.fixed(&self.message_content.buf);
        self.scratch = scratch;
        self.state = .default;
    }

    pub fn handler(self: *EventSubWs) sphtud.event.Loop.Handler {
        return .{
            .ptr = self,
            .vtable = &.{
                .poll = poll,
                .close = close,
            },
            .fd = self.conn.stream.handle,
            .desired_events = .{
                .read = true,
                .write = false,
            },
        };

    }

    fn poll(ctx: ?*anyopaque, loop: *sphtud.event.Loop, reason: sphtud.event.PollReason) sphtud.event.Loop.PollResult {
        const self: *EventSubWs = @ptrCast(@alignCast(ctx));
        _ = loop;
        _ = reason;

        self.pollInner() catch |e| {
            if (isWouldBlock(&self.conn.stream_reader, e)) return .in_progress;

            std.log.err("Unexpected ws error, shutting down {t}\n", .{e});
            return .complete;
        };
    }

    fn pollInner(self: *EventSubWs) !noreturn {
        while (true) {
            switch (self.state) {
                .default => try self.pollDefault(),
                .message => |data| try self.pollMessageData(data),
            }
        }
    }

    fn pollMessageData(self: *EventSubWs, data: *std.Io.Reader) !void {
        // Read json message
        const CommonMessage  = struct {
            metadata: struct {
                message_type: []const u8,
            },
        };

        _ = try data.streamRemaining(&self.message_content.writer);

        // FIXME: We probably actually want to reset the scratch allocator here
        const message = try std.json.parseFromSliceLeaky(CommonMessage, self.scratch, self.message_content.writer.buffered(), .{ .ignore_unknown_fields = true });
        std.debug.print("Received message: {any}\n", .{message});
        self.state = .default;
    }

    fn pollDefault(self: *EventSubWs) !void {
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

    fn close(ctx: ?*anyopaque) void {
        _ = ctx;

    }
};

pub fn main() !void {
    var alloc_buf: [2 * 1024 * 1024]u8 = undefined;
    var ba = sphtud.alloc.BufAllocator.init(&alloc_buf);

    const alloc = ba.allocator();
    const scratch = ba.backLinear();

    var loop = try sphtud.event.Loop.init(alloc, .linear(alloc));

    const address = std.net.Address.initIp4(.{0, 0, 0, 0}, 9342);
    const std_serv = try address.listen(.{
        .reuse_address = true,
    });

    var ca_bundle = std.crypto.Certificate.Bundle{};
    // FIXME: LOL GPA please
    try ca_bundle.rescan(alloc);

    var twitch_api_spawner = TwitchApiConnectionSpawner {
        // FIXME: needs to be a GPA that actually frees shit lol
        .alloc = alloc,
        .ca_bundle = &ca_bundle,
        .scratch = scratch.allocator(),
        .loop = &loop,
    };

    var event_sub_reg_state = EventSubRegisterState {
        .alloc = alloc,
        .scratch = scratch.allocator(),
        .spawner = &twitch_api_spawner,
        .oauth_key = null,
        // FIXME: Get these from actually making URL + websocket lol
        .websocket_id = "1234",
        .state = "c3ab8aa609ea11e793ae92361f002671",
    };

    var http_server_spawner = AuthServer {
        .alloc = alloc,
        .event_sub_reg_state = &event_sub_reg_state,
        .scratch = scratch,
        .pool = try .init(
            alloc,
            .linear(alloc),
            8,
            1000,
        ),
    };

    var seed: u64 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));
    var rng = std.Random.DefaultPrng.init(seed);

    const uri_meta = try sphws.UriMetadata.fromString(alloc, "wss://eventsub.wss.twitch.tv/ws");

    var event_sub_ws: EventSubWs = undefined;
    try event_sub_ws.initPinned(scratch.allocator(), ca_bundle, uri_meta, rng.random());
    try loop.register(event_sub_ws.handler());

    var server = try sphtud.event.net.server(std_serv, &http_server_spawner);
    try loop.register(server.handler());

    const cp = scratch.checkpoint();
    while (true) {
        scratch.restore(cp);
        try loop.wait(scratch);
    }
}
