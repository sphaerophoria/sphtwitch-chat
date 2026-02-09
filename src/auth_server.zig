const sphtud = @import("sphtud");
const http = @import("http.zig");
const std = @import("std");
const EventIdIter = @import("EventIdIter.zig");
const event_sub = @import("event_sub.zig");

const max_auth_connections = 100;

pub fn AuthServer(comptime ids: EventIdList) type {
    return struct {
        serv: std.net.Server,
        connections: sphtud.util.ObjectPool(Connection, usize),
        //event_sub_reg_state: *event_sub.RegisterState,

        expansion: sphtud.util.ExpansionAlloc,
        loop: *sphtud.event.Loop2,

        const Self = @This();

        pub fn init(loop: *sphtud.event.Loop2, alloc: std.mem.Allocator, expansion: sphtud.util.ExpansionAlloc) !Self {
            const address = std.net.Address.initIp4(.{0, 0, 0, 0}, 9342);
            const serv = try address.listen(.{
                .reuse_address = true,
            });
            try sphtud.event.setNonblock(serv.stream.handle);

            try loop.register(.{
                .handle = serv.stream.handle,
                .id = ids.auth_accept,
                .read = true,
                .write = false,
            });

            return .{
                .serv = serv,
                //.event_sub_reg_state = event_sub_reg_state,
                .connections = try .init(
                    alloc,
                    expansion,
                    max_auth_connections,
                    max_auth_connections,
                ),
                .expansion = expansion,
                .loop = loop,
            };
        }

        // FIXME: Error return type should be well defined here
        pub fn poll(self: *Self, scratch: sphtud.alloc.LinearAllocator, in_event_id: usize) !void {
            sw: switch (in_event_id) {
                ids.auth_accept => {
                    while (true) {
                        const conn = self.serv.accept() catch |e| {
                            if (e == error.WouldBlock) break;
                            return e;
                        };

                        try sphtud.event.setNonblock(conn.stream.handle);

                        const stored = try self.connections.acquire(self.expansion);
                        stored.val.initPinned(conn.stream);

                        const conn_id = ids.auth_connection.start + stored.handle;

                        try self.loop.register(.{
                            .id = conn_id,
                            .handle = conn.stream.handle,
                            .read = true,
                            .write = false,
                        });

                        continue :sw conn_id;
                    }
                },
                ids.auth_connection.start...ids.auth_connection.end => |event_id| {
                    const id = event_id - ids.auth_connection.start;

                    const conn = self.connections.get(id);

                    switch (conn.poll(scratch, self)) {
                        .wait => return,
                        .close => try self.releaseConnection(id),
                    }
                },
                else => unreachable,
            }
        }

        fn releaseConnection(self: *Self, id: usize) !void {
            const conn = self.connections.get(id);
            try self.loop.unregister(conn.http.stream.handle);
            conn.http.deinit();
            self.connections.release(self.expansion, id);
        }
    };
}

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

    fn poll(self: *Connection, scratch: sphtud.alloc.LinearAllocator, parent: anytype) PollResponse {
        const cp = scratch.checkpoint();
        while (true) {
            defer scratch.restore(cp);

            self.pollInner(scratch, parent) catch |e| {
                // FIXME: It feels like this isn't our responsibility
                if (self.http.isWouldBlock2(e)) return .wait;
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

    fn pollInner(self: *Connection, scratch: sphtud.alloc.LinearAllocator, parent: anytype) !void {
        switch (self.state) {
            .default => try self.pollDefault(scratch.allocator()),
            .auth_body => |r| try self.pollAuthBody(scratch.allocator(), r, parent),
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
            try self.http.writer.interface.flush();
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
                try self.http.writer.interface.flush();
            },
            .auth => {
                self.content_writer.end = 0;
                self.state = .{ .auth_body = req.body_reader };
            }
        }
    }

    fn pollAuthBody(self: *Connection, scratch: std.mem.Allocator, r: *std.Io.Reader, parent: anytype) !void {
        _ = try r.streamRemaining(&self.content_writer);
        _ = parent;

        self.state = .default;

        const AuthResponse = struct {
            access_token: []const u8,
            state: []const u8,
        };

        // FIXME: Will fall over if entire body buffer is not in req
        const auth_response = std.json.parseFromSliceLeaky(AuthResponse, scratch, self.content_writer.buffered(), .{
            .ignore_unknown_fields = true,
        }) catch {
            std.debug.print("Unexpected auth: {s}\n", .{self.content_writer.buffered()});
            return;
        };

        std.debug.print("Got auth response {any}\n", .{auth_response});
        //try parent.event_sub_reg_state.setOauthKey(auth_response.access_token, auth_response.state);
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
};
