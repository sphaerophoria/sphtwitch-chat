const sphtud = @import("sphtud");
const http = @import("http.zig");
const std = @import("std");
const EventIdIter = @import("EventIdIter.zig");
const event_sub = @import("event_sub.zig");

const max_auth_connections = 100;

const OauthState = [16]u8;

pub const AuthServer = struct {
    serv: std.net.Server,
    // FIXME: Basically no one will ever be here, one connection is good enough
    connections: sphtud.util.ObjectPool(Connection, usize),
    websocket: *event_sub.Connection,

    oauth_state: OauthState,

    loop: *sphtud.event.Loop2,

    const expansion_alloc = sphtud.util.ExpansionAlloc.invalid;

    const Self = @This();

    pub fn init(loop: *sphtud.event.Loop2, alloc: std.mem.Allocator, websocket: *event_sub.Connection, rand: std.Random, client_id: []const u8, comptime id_list: EventIdList) !Self {
        // FIXME: Do we need to re-gen oauth state after accepting?
        const oauth_state = generateOauthState(rand);

        // FIXME: At some point this probably needs to re-attmept to auth
        // if we lose auth or something, so this shoiuldn't live here. but
        // for now it's ok probably maybe
        //
        // FIXME: On init we likely already have a key, so like, why are we
        // printing this here?
        printAuthUrl(client_id, &oauth_state);

        const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 3000);
        const serv = try address.listen(.{
            .reuse_address = true,
        });
        try sphtud.event.setNonblock(serv.stream.handle);

        try loop.register(.{
            .handle = serv.stream.handle,
            .id = id_list.auth_accept,
            .read = true,
            .write = false,
        });

        return .{
            .serv = serv,
            .websocket = websocket,
            .connections = try .init(
                alloc,
                expansion_alloc,
                // The vast majority of the time no one will be here
                8,
                max_auth_connections,
            ),
            .oauth_state = oauth_state,
            .loop = loop,
        };
    }

    // FIXME: Error return type should be well defined here
    pub fn poll(self: *Self, scratch: sphtud.alloc.LinearAllocator, in_event_id: usize, comptime id_list: EventIdList) !void {
        switch (in_event_id) {
            id_list.auth_accept => try self.pollAccept(scratch, id_list),
            id_list.auth_connection.start...id_list.auth_connection.end => |event_id| {
                try self.pollConnection(scratch, event_id - id_list.auth_connection.start);
            },
            else => unreachable,
        }
    }

    fn pollAccept(self: *Self, scratch: sphtud.alloc.LinearAllocator, comptime id_list: EventIdList) !void {
        while (true) {
            const conn = self.serv.accept() catch |e| {
                if (e == error.WouldBlock) break;
                return e;
            };

            try sphtud.event.setNonblock(conn.stream.handle);

            const stored = try self.connections.acquire(expansion_alloc);
            stored.val.initPinned(conn.stream);

            const event_id = id_list.auth_connection.start + stored.handle;

            try self.loop.register(.{
                .id = event_id,
                .handle = conn.stream.handle,
                .read = true,
                .write = false,
            });

            try self.pollConnection(scratch, stored.handle);
        }
    }

    fn pollConnection(self: *Self, scratch: sphtud.alloc.LinearAllocator, conn_id: usize) !void {
        const conn = self.connections.get(conn_id);

        switch (conn.poll(scratch, self)) {
            .wait => return,
            .close => try self.releaseConnection(conn_id),
        }
    }

    fn releaseConnection(self: *Self, id: usize) !void {
        const conn = self.connections.get(id);
        try self.loop.unregister(conn.http.stream.stream.handle);
        conn.http.deinit();
        self.connections.release(expansion_alloc, id);
    }
};

pub const EventIdList = struct {
    auth_accept: comptime_int,
    auth_connection: EventIdIter.Range,

    start: comptime_int,
    end: comptime_int,

    pub fn generate(it: *EventIdIter) EventIdList {
        return .{
            .start = it.markStart(),
            .auth_accept = it.one(),
            .auth_connection = it.many(max_auth_connections),
            .end = it.markEnd(),
        };
    }
};

const index_html = @embedFile("res/index.html");

const Connection = struct {
    http: http.HttpServerConnection(4096, 4096),

    // Generated HTTP readers write into this buffer, needs to survive across polls
    poll_buf: [4096]u8 = undefined,

    // HTTP body streams here, our auth server expects relatively small
    // messages, so this is fine
    content_buf: [16384]u8 = undefined,
    content_writer: std.Io.Writer,

    state: union(enum) {
        default,
        auth_body: *std.Io.Reader,
    },

    fn initPinned(self: *Connection, stream: std.net.Stream) void {
        self.http.initPinned(stream);
        self.content_writer = std.Io.Writer.fixed(&self.content_buf);
        self.state = .default;
    }

    const PollResponse = enum {
        wait,
        close,
    };

    fn poll(self: *Connection, scratch: sphtud.alloc.LinearAllocator, parent: *AuthServer) PollResponse {
        const cp = scratch.checkpoint();
        while (true) {
            defer scratch.restore(cp);

            self.pollInner(scratch, parent) catch |e| {
                // FIXME: It feels like this isn't our responsibility
                if (self.http.isWouldBlock(e)) return .wait;
                if (e == error.EndOfStream) return .close;

                // FIXME: Someone up here needs to return 500, but only if we
                // haven't started writing another status
                std.log.err("Auth connection failure {t}, closing\n", .{e});

                // FIXME: Maybe all errors aren't recoverable, we need to
                // evaluate the types of errors that can occur downstream
                return .close;
            };
        }
    }

    fn pollInner(self: *Connection, scratch: sphtud.alloc.LinearAllocator, parent: *AuthServer) !void {
        switch (self.state) {
            .default => try self.pollDefault(scratch.allocator()),
            .auth_body => |r| try self.pollAuthBody(scratch, r, parent),
        }
    }

    fn pollDefault(self: *Connection, scratch: std.mem.Allocator) !void {

        // FIXME: Close connection if body has been read and last header indicated we should close

        const req = try self.http.poll(scratch, &self.poll_buf);

        std.debug.print("{s}\n", .{req.header.target});

        const target = Target.parse(req.header.target) orelse {
            try self.http.http_writer.startResponse(.{
                .content_length = 0,
                .status = .not_found,
            });
            try self.http.http_writer.writeBody("");
            try self.http.stream.flush();
            return;
        };

        // FIXME: Target needs to switch long lived conneciton state machine
        // into auth request mode so that he can read the body between polls
        switch (target) {
            .index => {
                try self.http.http_writer.startResponse(.{
                    .content_length = index_html.len,
                    .status = .ok,
                    .content_type = "text/html",
                });
                try self.http.http_writer.writeBody(index_html);
                try self.http.stream.flush();
            },
            .auth => {
                self.content_writer.end = 0;
                self.state = .{ .auth_body = req.body_reader };
            },
        }
    }

    fn pollAuthBody(self: *Connection, scratch: sphtud.alloc.LinearAllocator, r: *std.Io.Reader, parent: *AuthServer) !void {
        _ = try r.streamRemaining(&self.content_writer);

        // If anything below fails, it fails, but we will be ready to read the
        // next http header
        self.state = .default;

        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        const AuthResponse = struct {
            access_token: []const u8,
            state: []const u8,
        };

        const auth_response = std.json.parseFromSliceLeaky(
            AuthResponse,
            scratch.allocator(),
            self.content_writer.buffered(),
            .{
                .ignore_unknown_fields = true,
            },
        ) catch {
            std.log.err("Failed to parse auth response\n", .{});
            return;
        };

        // FIXME: Surely we should unit test this as it's somewhat security relevant
        if (!std.mem.eql(u8, auth_response.state, &parent.oauth_state)) {
            std.log.err(
                "Got auth response with bad state \"{s}\" != \"{s}\"",
                .{ auth_response.state, parent.oauth_state },
            );

            // FIXME: Do we need to force close this connection on error
            //
            // FIXME: We should probably inform the client somehow? (maybe not, maybe showing in app UI is good enough)
            return;
        }

        // FIXME: Do we need to force close this connection and on success
        //
        // FIXME: Thinka bout error types you ding dong
        try parent.websocket.setAccessToken(scratch, auth_response.access_token);
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
};

fn generateOauthState(rand: std.Random) OauthState {
    var oauth_state: OauthState = undefined;
    for (&oauth_state) |*c| {
        // Technically (as per RFC 6749) we can use any characters in
        // the range [0x20,0x7e], however we also send this in a URL.
        // We could do something more clever, but this is the easiest
        // thing for me to type in a single line :)
        c.* = rand.intRangeAtMost(u8, 'a', 'z');
    }

    return oauth_state;
}

fn printAuthUrl(client_id: []const u8, oauth_state: *const OauthState) void {
    const loc = "https://id.twitch.tv/oauth2/authorize" ++
        "?response_type=token" ++
        "&client_id={s}" ++
        "&redirect_uri=http://localhost:3000" ++
        "&scope=user%3Abot+user%3Aread%3Achat+user%3Awrite%3Achat" ++
        "&state={s}";

    std.debug.print("Go here if you aren't authenticated (not on stream) " ++ loc ++ "\n", .{ client_id, oauth_state });
}
