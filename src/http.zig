 const std = @import("std");
 const sphtud = @import("sphtud");
 const EventIdIter = @import("EventIdIter.zig");
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


// FIXME: Move to sphtud.http
// Connection for an http server, not to an http server
pub fn HttpServerConnection(comptime read_size: usize, comptime write_size: usize) type {
    return struct {
        stream: std.net.Stream,

        reader_buf: [read_size]u8,
        writer_buf: [write_size]u8,

        reader: std.net.Stream.Reader,
        writer: std.net.Stream.Writer,

        http_reader: sphtud.http.HttpRequestReader,
        http_writer: sphtud.http.HttpWriter,

        pub fn initPinned(self: *@This(), stream: std.net.Stream) void {
            self.stream = stream;

            self.reader = self.stream.reader(&self.reader_buf);
            self.writer = self.stream.writer(&self.writer_buf);

            self.http_reader = .init(self.reader.interface());
            self.http_writer = .init(&self.writer.interface);
        }

        pub fn deinit(self: *@This()) void {
            self.stream.close();
        }

        pub fn poll(self: *@This(), alloc: std.mem.Allocator, body_buf: []u8) !sphtud.http.HttpRequestReader.Result {
            return self.http_reader.poll(alloc, body_buf);
        }

        // FIXME: name
        pub fn isWouldBlock2(self: *@This(), e: anyerror) bool {
            return isWouldBlock(&self.reader, e);
        }
    };
}

fn HttpClientConnection(comptime read_size: usize, comptime write_size: usize) type {
    return struct {
        stream: std.net.Stream,

        reader_buf: [read_size]u8,
        writer_buf: [write_size]u8,

        reader: std.net.Stream.Reader,
        writer: std.net.Stream.Writer,

        http_reader: sphtud.http.HttpResponseReader,
        http_writer: sphtud.http.HttpWriter,

        pub fn initPinned(self: *@This(), stream: std.net.Stream) void {
            self.stream = stream;

            self.reader = self.stream.reader(&self.reader_buf);
            self.writer = self.stream.writer(&self.writer_buf);

            self.http_reader = .init(self.reader.interface());
            self.http_writer = .init(&self.writer.interface);
        }

        pub fn deinit(self: *@This()) void {
            self.stream.close();
        }

        pub fn poll(self: *@This(), alloc: std.mem.Allocator, body_buf: []u8) !sphtud.http.HttpResponseReader.Result {
            return self.http_reader.poll(alloc, body_buf);
        }

        // FIXME: name
        pub fn isWouldBlock2(self: *@This(), e: anyerror) bool {
            return isWouldBlock(&self.reader, e);
        }
    };
}


// IDS 100-200 are for http fetches,
pub const Client = struct {
    connections: sphtud.util.ObjectPool(ConnectionState, usize),
    expansion: sphtud.util.ExpansionAlloc,
    base_id: usize,

    loop: *sphtud.event.Loop2,

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

    pub const ConnectionState = struct {
        fetch_id: usize,
        connection: HttpClientConnection(4096, 4096),

        // FIXME: Clearly this shouldn't be here
        index: usize,
        parent: *Client,

        pub fn deinit(self: *ConnectionState) void {
            self.parent.release(self);
        }
    };

    pub fn fetch(self: *Client, scratch: std.mem.Allocator, host: []const u8, port: u16, fetch_id: usize) !*HttpClientConnection(4096, 4096) {
        const stream = try std.net.tcpConnectToHost(scratch, host, port);

        const handle = try self.connections.acquire(self.expansion);
        handle.val.connection.initPinned(stream);
        handle.val.fetch_id = fetch_id;

        // FIXME: lol this is stupid
        handle.val.index = handle.handle;
        handle.val.parent = self;

        try self.loop.register(.{
            .handle = handle.val.connection.stream.handle,
            .id = self.base_id + handle.handle,
            .read = true,
            .write = false,
        });

        return &handle.val.connection;
    }

    pub fn release(self: *Client, state: *ConnectionState) void {
        self.loop.unregister(state.connection.stream.handle) catch {
            std.log.err("Failed to remove from epoll\n", .{});
        };
        state.connection.deinit();
        self.connections.release(self.expansion, state.index);
    }

    pub fn getState(self: *Client, event: usize) *ConnectionState {
        const connection_id = event - self.base_id;
        return self.connections.get(connection_id);
    }

};
