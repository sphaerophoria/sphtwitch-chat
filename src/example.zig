const std = @import("std");
const sphtud = @import("sphtud");
const http = @import("http.zig");
const sphws = @import("sphws");
const EventIdIter = @import("EventIdIter.zig");
const as = @import("auth_server.zig");
const event_sub = @import("event_sub.zig");

const EventIdList = struct {
    auth: as.EventIdList,
    websocket: comptime_int,

    pub fn generate() EventIdList {
        var id_iter = EventIdIter{};
        return .{
            .auth = as.EventIdList.generate(&id_iter),
            .websocket = id_iter.one(),
        };
    }
};


//const TwitchWebsocketSub = struct {
//    parent: *TwitchApiConnectionSpawner,
//    tls: TlsConnection,
//    response_reader: sphtud.http.HttpResponseReader,
//
//    pub fn initPinned(self: *TwitchWebsocketSub, scratch: std.mem.Allocator, parent: *TwitchApiConnectionSpawner) !void {
//        self.parent = parent;
//        try self.tls.initPinned(scratch, parent.ca_bundle.*, "api.twitch.tv", 443);
//        self.response_reader = .init(&self.tls.tls_client.reader);
//    }
//
//    fn handler(self: *TwitchWebsocketSub) sphtud.event.Loop.Handler {
//        return .{
//            .ptr = self,
//            .fd = self.tls.stream.handle,
//            .vtable = &.{
//                .poll = poll,
//                .close = close,
//            },
//            .desired_events = .{
//                .read = true,
//                .write = false,
//            },
//        };
//    }
//
//    fn poll(ctx: ?*anyopaque, loop: *sphtud.event.Loop, reason: sphtud.event.PollReason) sphtud.event.Loop.PollResult {
//        // if ok, close
//        // if not ok shutdown = trrue and close
//        _ = loop;
//        _ = reason;
//
//        const self: *TwitchWebsocketSub = @ptrCast(@alignCast(ctx));
//        return self.pollInner() catch |e| {
//
//            if (isWouldBlock(&self.tls.stream_reader, e))  {
//                std.debug.print("He hasn't said anything, give him a minute bitch\n", .{});
//                return .in_progress;
//            }
//
//            std.log.err("Killing connection {t}\n", .{e});
//            return .complete;
//        };
//    }
//
//    fn pollInner(self: *TwitchWebsocketSub) !sphtud.event.Loop.PollResult {
//        std.debug.print("Twitch API is talking to me\n", .{});
//
//        var body_buf: [4096]u8 = undefined;
//        std.debug.print("Waiting for response\n", .{});
//        std.debug.print("stream buf: {d}\n", .{self.tls.stream_reader.interface().buffered().len});
//        std.debug.print("tls buf: {d}\n", .{self.tls.tls_client.reader.buffered().len});
//        const res = try self.response_reader.poll(self.parent.scratch, &body_buf);
//        std.debug.print("Got {t}\n", .{res.header.status});
//        return .complete;
//        //while (true) {
//        //    const content = self.tls.tls_client.reader.peekGreedy(1) catch |e| {
//        //        std.debug.print("No more body {t}\n", .{e});
//        //        break;
//        //    };
//        //    std.debug.print("{s}\n", .{content});
//        //    self.tls.tls_client.reader.toss(content.len);
//        //}
//    }
//
//    fn close(ctx: ?*anyopaque) void {
//        const self: *TwitchWebsocketSub = @ptrCast(@alignCast(ctx));
//        self.parent.destroyWsSub(self);
//    }
//};
//
//// FIXME: This needs to live in sphtud.net or something
//pub const TlsConnection = struct {
//    tls_read_buffer: [tls_read_buffer_len]u8,
//    tls_write_buffer: [write_buffer_size]u8,
//
//    socket_write_buffer: [tls_buffer_size]u8,
//    socket_read_buffer: [tls_buffer_size]u8,
//
//    stream: std.net.Stream,
//    stream_reader: std.net.Stream.Reader,
//    stream_writer: std.net.Stream.Writer,
//
//    tls_client: std.crypto.tls.Client,
//
//    const tls_buffer_size = std.crypto.tls.Client.min_buffer_len;
//    const read_buffer_size = 8192;
//    const write_buffer_size = 1024;
//
//    // The TLS client wants enough buffer for the max encrypted frame
//    // size, and the HTTP body reader wants enough buffer for the
//    // entire HTTP header. This means we need a combined upper bound.
//    const tls_read_buffer_len = tls_buffer_size + read_buffer_size;
//
//    pub fn initPinned(self: *TlsConnection, scratch: std.mem.Allocator, ca_bundle: std.crypto.Certificate.Bundle, host: []const u8, port: u16) !void {
//        self.stream = try std.net.tcpConnectToHost(scratch, host, port);
//
//        self.stream_reader = self.stream.reader(&self.socket_read_buffer);
//        self.stream_writer = self.stream.writer(&self.socket_write_buffer);
//
//        self.tls_client = try std.crypto.tls.Client.init(
//            self.stream_reader.interface(),
//            &self.stream_writer.interface,
//            .{
//                .host = .{ .explicit = host },
//                .ca = .{ .bundle = ca_bundle },
//                .ssl_key_log = null,
//                .read_buffer = &self.tls_read_buffer,
//                .write_buffer = &self.tls_write_buffer,
//                // This is appropriate for HTTPS because the HTTP headers contain
//                // the content length which is used to detect truncation attacks.
//                .allow_truncation_attacks = true,
//            },
//        );
//
//        try sphtud.event.setNonblock(self.stream.handle);
//    }
//
//    pub fn deinit(self: *TlsConnection) void {
//        self.stream.close();
//    }
//
//    pub fn hasBufferedData(self: *TlsConnection) bool {
//        return self.stream_writer.interface.buffered().len > 0 or
//            self.tls_client.writer.buffered().len > 0;
//    }
//
//
//    pub fn flush(self: *TlsConnection) !void {
//        try self.tls_client.writer.flush();
//        try self.stream_writer.interface.flush();
//    }
//};
//
//
//const TwitchApiConnectionSpawner = struct {
//    loop: *sphtud.event.Loop2,
//    ca_bundle: *std.crypto.Certificate.Bundle,
//    alloc: std.mem.Allocator,
//    scratch: std.mem.Allocator,
//
//    pub fn makeWsSub(self: *TwitchApiConnectionSpawner) !*TwitchWebsocketSub {
//        const ret = try self.alloc.create(TwitchWebsocketSub);
//        try ret.initPinned(self.scratch, self);
//        return ret;
//    }
//
//    pub fn destroyWsSub(self: *TwitchApiConnectionSpawner, sub: *TwitchWebsocketSub) void {
//        sub.tls.deinit();
//        self.alloc.destroy(sub);
//    }
//
//    pub fn spawnRegisterEventSub(self: *TwitchApiConnectionSpawner, chat_id: []const u8, bot_id: []const u8, ws_id: []const u8, oauth_key: []const u8) !void {
//
//        const conn = try self.makeWsSub();
//        errdefer self.destroyWsSub(conn);
//
//        const client_id = "1v2vig9jqtst8h28yaaouxt0fgq5z7";
//
//        var http_w = sphtud.http.HttpWriter.init(&conn.tls.tls_client.writer);
//
//        const RegisterMesage = struct {
//            @"type": []const u8,
//            version: []const u8,
//            condition: struct {
//                    broadcaster_user_id: []const u8,
//                    user_id: []const u8
//            },
//            transport: struct {
//                    method: []const u8,
//                    session_id: []const u8,
//            }
//        };
//
//
//        const post_body = try std.json.Stringify.valueAlloc(self.scratch, RegisterMesage {
//            .@"type" = "channel.chat.message",
//            .version = "1",
//            .condition = .{
//                .broadcaster_user_id = chat_id,
//                .user_id = bot_id,
//            },
//            .transport = .{
//                .method = "websocket",
//                .session_id = ws_id,
//            },
//
//        }, .{ .whitespace = .indent_2 });
//
//        const bear_string = try std.fmt.allocPrint(self.scratch, "Bearer {s}", .{oauth_key});
//
//        try http_w.startRequest(.{
//            .method = .POST,
//            .target = "/helix/eventsub/subscriptions",
//            .content_length = post_body.len,
//            .content_type = "application/json",
//        });
//        try http_w.appendHeader("Authorization", bear_string);
//        try http_w.appendHeader("Client-Id", client_id);
//        try http_w.writeBody(post_body);
//
//        try conn.tls.flush();
//
//        try self.loop.register(conn.handler());
//
//        // Errdefer at top of block assumes that loop registration is the last thing that happens
//        errdefer comptime unreachable;
//    }
//};
//



// An idea on how to do generic HTTP fetches
//
//const HttpClient = struct {
//    max_fetches: usize,
//
//    loop: sphtud.event.Loop2,
//
//    // id_range is allocated for each sub-service for Http.max_fetches size.
//    // We probably assert that this range is <= our connection pool
//    fn fetch(self: *HttpClient, id_range: EventIdIter.Range) !*HttpClientConnection {
//        const acq = self.pool.acquire();
//
//        try self.loop.register(.{
//            .id = id_range.start + acq.handle,
//            .handle = acq.val.stream.handle,
//            .read = true,
//            .write = false,
//        });
//
//        return acq.val;
//    }
//};
//
//const SomethingIds = struct {
//    handle_thing: EventIdIter.Range,
//};
//
//fn Something(comptime ids: SomethingIds) type {
//    return struct {
//        client: HttpClient,
//
//        fn poll(self: @This(), event_id: usize) {
//            switch (event_id) {
//                ids.handle_thing.start...ids.handle_thing.end => {
//                    const conn_id = event_id - ids.handle_thing.start;
//                    const conn  = self.client.get(conn_id);
//                    const res = try conn.poll();
//                    // Do thing with result
//                },
//            }
//        }
//
//        fn startHttpReq(self: @This(), loop: *sphtud.event.Loop2) !void {
//            const conn = try self.client.fetch(.{.start = handle_thing, .end = handle_thing });
//            conn.flush();
//            // Do connection and dispatch
//
//        }
//    };
//}

const id_list = EventIdList.generate();

pub fn main() !void {
    std.debug.print("{any}\n", .{id_list});

    var alloc_buf: [4 * 1024 * 1024]u8 = undefined;
    var ba = sphtud.alloc.BufAllocator.init(&alloc_buf);

    const alloc = ba.allocator();
    const expansion = ba.expansion();
    const scratch = ba.backLinear();

    var loop = try sphtud.event.Loop2.init();

    // FIXME: I feel like this should be completely nuked after registration is
    // complete. Surely there's some union somewhere
    var es_state = event_sub.RegisterState {
        .oauth_key = null,
        .websocket_id = null,
        .alloc = alloc,
        .state = "1234",
    };

    var auth_server = try as.AuthServer(id_list.auth).init(&loop, alloc, expansion, &es_state);

    var ca_bundle = std.crypto.Certificate.Bundle{};
    // FIXME: LOL GPA please
    try ca_bundle.rescan(alloc);

    var seed: u64 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));
    var rng = std.Random.DefaultPrng.init(seed);

    const uri_meta = try sphws.UriMetadata.fromString(alloc, "wss://eventsub.wss.twitch.tv/ws");
    var event_sub_conn: event_sub.Connection = undefined;
    try event_sub_conn.initPinned(scratch.allocator(), ca_bundle, uri_meta, rng.random(), &es_state);
    // FIXME: event_sub.Connection can probably be event loop aware which cuts
    // down on this clutter in main
    try sphtud.event.setNonblock(event_sub_conn.conn.stream.handle);

    try loop.register(.{
        .handle = event_sub_conn.conn.stream.handle,
        .id = id_list.websocket,
        .read = true,
        .write = false,
    });

    while (true) {
        const event = try loop.poll();
        switch (event) {
            id_list.auth.start...id_list.auth.end => {
                try auth_server.poll(scratch, event);
            },
            id_list.websocket => {
                try event_sub_conn.poll(scratch);
            },
            else => unreachable,
        }

    }
}
