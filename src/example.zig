const std = @import("std");
const sphtud = @import("sphtud");
const http = @import("http.zig");
const sphws = @import("sphws");
const EventIdIter = @import("EventIdIter.zig");
const as = @import("auth_server.zig");
const event_sub = @import("event_sub.zig");
const Xdg = @import("Xdg.zig");

const EventIdList = struct {
    auth: as.EventIdList,
    fetch: http.Client.EventIdList,
    es: event_sub.EventIdList,

    pub fn generate() EventIdList {
        var id_iter = EventIdIter{};
        return .{
            .auth = as.EventIdList.generate(&id_iter),
            .fetch = .generate(&id_iter),
            .es = .generate(&id_iter),
        };
    }
};

fn makeCryptoRng() !std.Random.DefaultCsprng {
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));
    const rng = std.Random.DefaultCsprng.init(seed);

    @memset(&seed, 0x0);
    // So secure right now... also we didn't check that the memset gets
    // optimized out without this... but it seems like it could :)
    std.mem.doNotOptimizeAway(&seed);

    return rng;
}

const id_list = EventIdList.generate();

const client_id = "1v2vig9jqtst8h28yaaouxt0fgq5z7";

pub fn main() !void {
    var tpa: sphtud.alloc.TinyPageAllocator = undefined;
    try tpa.initPinned();

    var root_alloc: sphtud.alloc.Sphalloc = undefined;
    try root_alloc.initPinned(tpa.allocator(), "root");

    var scratch = sphtud.alloc.BufAllocator.init(try root_alloc.arena().alloc(u8, 1 * 1024 * 1024));

    var loop = try sphtud.event.Loop2.init();

    var ca_bundle = std.crypto.Certificate.Bundle{};
    try ca_bundle.rescan(root_alloc.general());

    var http_client = try http.Client.init(&loop, root_alloc.arena(), &ca_bundle);

    var rng = try makeCryptoRng();

    const xdg = try Xdg.init(root_alloc.arena());

    const event_sub_conn = try root_alloc.arena().create(event_sub.Connection);
    try event_sub_conn.initPinned(
        root_alloc.general(),
        scratch.linear(),
        .{
            .http_client = &http_client,
            .xdg = &xdg,
            .ca_bundle = &ca_bundle,
            .random = rng.random(),
            .loop = &loop,
            .client_id = client_id,
        },
        id_list.es,
    );

    var auth_server = try as.AuthServer.init(
        &loop,
        root_alloc.arena(),
        event_sub_conn,
        rng.random(),
        client_id,
        id_list.auth,
    );

    while (true) {
        scratch.reset();

        const event = try loop.poll();
        switch (event) {
            id_list.auth.start...id_list.auth.end => {
                try auth_server.poll(scratch.linear(), event, id_list.auth);
            },
            id_list.es.start...id_list.es.end => {
                try event_sub_conn.poll(scratch.linear(), event, id_list.es);
            },
            else => unreachable,
        }
    }
}
