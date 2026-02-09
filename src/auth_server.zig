const sphtud = @import("sphtud");
const http = @import("http.zig");
const std = @import("std");
const EventIdIter = @import("EventIdIter.zig");

const max_auth_connections = 100;

pub fn AuthServer(comptime ids: EventIdList) type {
    return struct {
        serv: std.net.Server,
        connections: sphtud.util.ObjectPool(Connection, usize),

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
                    const cp = scratch.checkpoint();
                    while (true) {
                        defer scratch.restore(cp);

                        conn.poll(scratch) catch |e| {
                            if (conn.http.isWouldBlock2(e)) continue;
                            if (e == error.EndOfStream) {
                                try self.loop.unregister(conn.http.stream.handle);
                                conn.http.deinit();
                                self.connections.release(self.expansion, id);
                                break;
                            }
                            return e;
                        };
                    }
                },
                else => unreachable,
            }
        }
    };
}

pub const EventIdList = struct {
    auth_accept: usize,
    auth_connection: EventIdIter.Range,
    total_range: EventIdIter.Range,

    pub fn generate(it: *EventIdIter) EventIdList {
        const total_start = it.markStart();

        return .{
            .auth_accept = it.one(),
            .auth_connection = it.many(max_auth_connections),
            .total_range = total_start.markEnd(),
        };
    }
};


const index_html = @embedFile("res/index.html");

const Connection = struct {
    http: http.HttpServerConnection(4096, 4096),

    fn initPinned(self: *Connection, stream: std.net.Stream) void {
        self.http.initPinned(stream);
    }

    // FIXME: Catch return 500
    fn poll(self: *Connection, scratch: sphtud.alloc.LinearAllocator) !void {
        var body_buf: [4096]u8 = undefined;
        const req = try self.http.poll(scratch.allocator(), &body_buf);

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
                const AuthResponse = struct {
                    access_token: []const u8,
                    state: []const u8,
                };

                var json_reader = std.json.Reader.init(scratch.allocator(), req.body_reader);

                // FIXME: Will fall over if entire body buffer is not in req
                const auth_response = try std.json.parseFromTokenSourceLeaky(AuthResponse, scratch.allocator(), &json_reader, .{
                    .ignore_unknown_fields = true,
                });

                std.debug.print("Got auth response {any}\n", .{auth_response});
                //try self.parent.event_sub_reg_state.setOauthKey(auth_response.access_token, auth_response.state);
            },
        }
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
