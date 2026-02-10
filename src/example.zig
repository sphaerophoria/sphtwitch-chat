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
    websocket: comptime_int,
    fetch: http.Client.EventIdList,
    event_sub_reg: event_sub.RegisterState.EventIdList,

    pub fn generate() EventIdList {
        var id_iter = EventIdIter{};
        return .{
            .auth = as.EventIdList.generate(&id_iter),
            .websocket = id_iter.one(),
            .fetch = .generate(&id_iter),
            .event_sub_reg = .generate(&id_iter),
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

    var register_state = try event_sub.RegisterState.init(
        root_alloc.general(),
        scratch.linear(),
        &http_client,
        id_list.event_sub_reg,
        &xdg,
        client_id,
    );

    var auth_server = try as.AuthServer(id_list.auth).init(
        &loop,
        root_alloc.arena(),
        &register_state,
        rng.random(),
        client_id,
    );

    var event_sub_conn: event_sub.Connection = undefined;
    try event_sub_conn.initPinned(
        scratch.allocator(),
        ca_bundle,
        rng.random(),
        &register_state,
        &loop,
        id_list.websocket,
    );

    while (true) {
        scratch.reset();

        const event = try loop.poll();
        switch (event) {
            id_list.auth.start...id_list.auth.end => {
                try auth_server.poll(scratch.linear(), event);
            },
            id_list.websocket => {
                try event_sub_conn.poll(scratch.linear());
            },
            id_list.event_sub_reg.start...id_list.event_sub_reg.end => {
                try register_state.poll(scratch.linear());
            },
            else => unreachable,
        }
    }
}
