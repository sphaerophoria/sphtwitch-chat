 const std = @import("std");
 const sphtud = @import("sphtud");
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

