const std = @import("std");
const sphtud = @import("sphtud");
const EventIdIter = @import("EventIdIter.zig");

// FIXME: Move to sphtud.http
// Connection for an http server, not to an http server
pub fn HttpServerConnection(comptime read_size: usize, comptime write_size: usize) type {
    return struct {
        stream: sphtud.net.Stream(read_size, write_size),

        http_reader: sphtud.http.HttpRequestReader,
        http_writer: sphtud.http.HttpWriter,

        pub fn initPinned(self: *@This(), stream: std.net.Stream) void {
            self.stream.fromStd(stream);

            self.http_reader = .init(self.stream.reader());
            self.http_writer = .init(self.stream.writer());
        }

        pub fn deinit(self: *@This()) void {
            self.stream.stream.close();
        }

        pub fn poll(self: *@This(), alloc: std.mem.Allocator, body_buf: []u8) !sphtud.http.HttpRequestReader.Result {
            return self.http_reader.poll(alloc, body_buf);
        }

        pub fn isWouldBlock(self: *@This(), e: anyerror) bool {
            return self.stream.isWouldBlock(e);
        }
    };
}

fn HttpsClientConnection(comptime read_size: usize, comptime write_size: usize) type {
    return struct {
        tls: sphtud.net.TlsStream(read_size, write_size),

        http_reader: sphtud.http.HttpResponseReader,
        http_writer: sphtud.http.HttpWriter,

        pub fn initPinned(self: *@This(), ca_bundle: std.crypto.Certificate.Bundle, host: []const u8, stream: std.net.Stream) !void {
            try self.tls.initPinned(stream, host, ca_bundle);

            self.http_reader = .init(self.tls.reader());
            self.http_writer = .init(self.tls.writer());
        }

        pub fn flush(self: *@This()) !void {
            try self.tls.flush();
        }

        pub fn deinit(self: *@This()) void {
            self.tls.close();
        }

        pub fn poll(self: *@This(), alloc: std.mem.Allocator, body_buf: []u8) !sphtud.http.HttpResponseReader.Result {
            return self.http_reader.poll(alloc, body_buf);
        }

        pub fn isWouldBlock(self: *@This(), e: anyerror) bool {
            return self.tls.isWouldBlock(e);
        }
    };
}

pub const Client = struct {
    connections: Pool,

    loop: *sphtud.event.Loop2,
    ca_bundle: *std.crypto.Certificate.Bundle,

    pub const FetchHandle = struct {
        inner: usize,

        pub fn fromIdx(idx: usize) FetchHandle {
            return .{ .inner = idx };
        }

        pub fn toIdx(self: FetchHandle) usize {
            return self.inner;
        }
    };

    const Pool = sphtud.util.ObjectPool(HttpsClientConnection(4096, 4096), FetchHandle);
    const WithHandle = Pool.WithHandle;

    pub const max_connections = 100;

    pub const EventIdList = struct {
        start: comptime_int,
        end: comptime_int,

        pub fn generate(id_it: *EventIdIter) EventIdList {
            const start = id_it.markStart();
            _ = id_it.many(max_connections);
            const end = id_it.markEnd();

            return .{
                .start = start,
                .end = end,
            };
        }
    };

    pub fn init(
        loop: *sphtud.event.Loop2,
        arena: std.mem.Allocator,
        ca_bundle: *std.crypto.Certificate.Bundle,
    ) !Client {
        return .{
            .loop = loop,
            .connections = try .init(
                arena,
                .invalid,
                max_connections,
                max_connections,
            ),
            .ca_bundle = ca_bundle,
        };
    }

    pub fn fetch(self: *Client, scratch: std.mem.Allocator, host: []const u8, port: u16, event_id: usize) !WithHandle {
        const stream = try std.net.tcpConnectToHost(scratch, host, port);

        // FIXME: TLS handshaking should be done in it's own thread
        const handle = try self.connections.acquire(.invalid);
        try handle.val.initPinned(self.ca_bundle.*, host, stream);

        try sphtud.event.setNonblock(stream.handle);

        try self.loop.register(.{
            .handle = handle.val.tls.handle(),
            .id = event_id,
            .read = true,
            .write = false,
        });

        return handle;
    }

    pub fn release(self: *Client, handle: FetchHandle) void {
        const connection = self.connections.get(handle);
        self.loop.unregister(connection.tls.handle()) catch {
            std.log.err("Failed to remove from epoll\n", .{});
        };
        connection.deinit();
        self.connections.release(.invalid, handle);
    }

    pub fn get(self: *Client, handle: FetchHandle) *HttpsClientConnection(4096, 4096) {
        return self.connections.get(handle);
    }
};
