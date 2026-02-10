const std = @import("std");
const sphws = @import("sphws");
const sphtud = @import("sphtud");

const CommonMessage = struct {
    metadata: struct {
        message_type: []const u8,
    },
};

const MessageType = enum { session_welcome, notification };

const SessionWelcome = struct {
    payload: struct {
        session: struct {
            id: []const u8,
            keepalive_timeout_seconds: u32,
        },
    },
};

const ChatMessageEvent = struct {
    chatter_user_name: []const u8,
    message: struct {
        text: []const u8,
        // FIXME: Parse fragments and render emotes, @s, etc.
    },
};

const Notification = struct {
    payload: struct {
        subscription: struct {
            type: []const u8,
        },
        event: std.json.Value,
    },
};
//{
//  "metadata": {
//    "message_id": "3i3yYblUQkYBfVEvNVm6MdFJYS0Suj0gHch7cJEssI0=",
//    "message_type": "notification",
//    "message_timestamp": "2026-02-01T22:49:57.09607444Z",
//    "subscription_type": "channel.chat.message",
//    "subscription_version": "1"
//  },
//  "payload": {
//    "subscription": {
//      "id": "beb2737c-a67b-4641-9135-28204f6dd4a5",
//      "status": "enabled",
//      "type": "channel.chat.message",
//      "version": "1",
//      "condition": {
//        "broadcaster_user_id": "51219542",
//        "user_id": "51219542"
//      },
//      "transport": {
//        "method": "websocket",
//        "session_id": "AgoQo7Q7o8s_TZi4CQWSi2hWtxIGY2VsbC1h"
//      },
//      "created_at": "2026-02-01T22:49:45.286027766Z",
//      "cost": 0
//    },
//    "event": {
//      "broadcaster_user_id": "51219542",
//      "broadcaster_user_login": "sphaerophoria",
//      "broadcaster_user_name": "sphaerophoria",
//      "source_broadcaster_user_id": null,
//      "source_broadcaster_user_login": null,
//      "source_broadcaster_user_name": null,
//      "chatter_user_id": "185321156",
//      "chatter_user_login": "grayhatter_",
//      "chatter_user_name": "grayhatter_",
//      "message_id": "3fb6d62d-c9ae-44fd-a760-59dca732d28e",
//      "source_message_id": null,
//      "is_source_only": null,
//      "message": {
//        "text": "LETS FUCKING GO!",
//        "fragments": [
//          {
//            "type": "text",
//            "text": "LETS FUCKING GO!",
//            "cheermote": null,
//            "emote": null,
//            "mention": null
//          }
//        ]
//      },
//      "color": "#B22222",
//      "badges": [
//        {
//          "set_id": "subscriber",
//          "id": "0",
//          "info": "4"
//        }
//      ],
//      "source_badges": null,
//      "message_type": "text",
//      "cheer": null,
//      "reply": null,
//      "channel_points_custom_reward_id": null,
//      "channel_points_animation_id": null
//    }
//  }
//}

fn registerForChat(scratch: std.mem.Allocator, client: *std.http.Client, welcome_message: SessionWelcome, client_id: []const u8, secret: []const u8, chat_id: []const u8, bot_id: []const u8) !void {
    const bear_string = try std.fmt.allocPrint(scratch, "Bearer {s}", .{secret});

    const RegisterMesage = struct { type: []const u8, version: []const u8, condition: struct { broadcaster_user_id: []const u8, user_id: []const u8 }, transport: struct {
        method: []const u8,
        session_id: []const u8,
    } };

    const post_body = try std.json.Stringify.valueAlloc(scratch, RegisterMesage{
        .type = "channel.chat.message",
        .version = "1",
        .condition = .{
            .broadcaster_user_id = chat_id,
            .user_id = bot_id,
        },
        .transport = .{
            .method = "websocket",
            .session_id = welcome_message.payload.session.id,
        },
    }, .{ .whitespace = .indent_2 });

    var response_writer = std.Io.Writer.Allocating.init(scratch);

    const response = try client.fetch(.{
        .method = .POST,
        .response_writer = &response_writer.writer,
        .location = .{ .uri = try .parse("https://api.twitch.tv/helix/eventsub/subscriptions") },
        .headers = .{
            .authorization = .{
                .override = bear_string,
            },
            .content_type = .{
                .override = "application/json",
            },
        },
        .extra_headers = &.{
            .{ .name = "Client-Id", .value = client_id },
        },
        .payload = post_body,
    });

    std.debug.print("status: {d}\n", .{response.status});
    std.debug.print("body: {s}\n", .{response_writer.written()});
}

//{"metadata":{"message_id":"aeb3ba8b-7595-46fb-817e-c685a878f0e4","message_type":"session_welcome","message_timestamp":"2026-02-01T22:19:28.109022754Z"},"payload":{"session":{"id":"AgoQqRwUUsmySNezH4ZTJ8KsuxIGY2VsbC1h","status":"connected","connected_at":"2026-02-01T22:19:28.104472057Z","keepalive_timeout_seconds":10,"reconnect_url":null,"recovery_url":null}}}
pub fn main() !void {
    // I think we waste a lot of memory building the ca_bundle, but whatever.
    // We have 8M of stack space to waste
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var scratch_buf: [1 * 1024 * 1024]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&scratch_buf);

    const alloc = arena.allocator();

    var seed: u64 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));
    var rng = std.Random.DefaultPrng.init(seed);

    var http_client = std.http.Client{
        .allocator = gpa.allocator(),
    };

    const uri_meta = try sphws.UriMetadata.fromString(arena.allocator(), "wss://eventsub.wss.twitch.tv/ws");

    var ca_bundle = std.crypto.Certificate.Bundle{};
    try ca_bundle.rescan(alloc);

    const connection = try alloc.create(sphws.conn.Connection);

    // FIXME: If not using TLS do we really want our bundle?
    try connection.initPinned(alloc, ca_bundle, uri_meta);

    std.debug.print("Connected!\n", .{});

    const reader = connection.reader();
    const writer = connection.writer();
    var ws = try sphws.Websocket.init(reader, writer, uri_meta.host, uri_meta.path, rng.random());
    try connection.flush();

    const secret_file = try std.fs.cwd().openFile("secret/sphaerobot_token.txt", .{});
    const secret = std.mem.trim(u8, try secret_file.readToEndAlloc(alloc, 1000), &std.ascii.whitespace);
    const client_id = "1v2vig9jqtst8h28yaaouxt0fgq5z7";
    const chat_id = "51219542";
    const bot_id = "51219542";

    var body_buf: [16384]u8 = undefined;
    while (true) {
        scratch.end_index = 0;

        const res = try ws.poll(&body_buf);

        // The websocket abstraction does not flush, but may try to write
        // things out. We check manually if anything was written and flush the
        // pipeline if needed
        if (connection.hasBufferedData()) {
            try connection.flush();
        }

        switch (res) {
            .initialized => {},
            // FIXME: At least indicate what we would do here, even if we don't
            // want to do it
            .redirect => {
                // Need to...
                // * re-parse URI
                // * close/open connection to new place (if host/port/scheme combo changed)
                // * re-init self.ws
                unreachable;
            },
            .message => |f| {
                const data = try f.data.allocRemaining(scratch.allocator(), .unlimited);

                const common = try std.json.parseFromSliceLeaky(CommonMessage, scratch.allocator(), data, .{ .ignore_unknown_fields = true });

                const message_type = std.meta.stringToEnum(MessageType, common.metadata.message_type) orelse continue;
                switch (message_type) {
                    .session_welcome => {
                        const welcome_message = try std.json.parseFromSliceLeaky(SessionWelcome, scratch.allocator(), data, .{ .ignore_unknown_fields = true });
                        try registerForChat(scratch.allocator(), &http_client, welcome_message, client_id, secret, chat_id, bot_id);
                    },
                    .notification => {
                        const notification = try std.json.parseFromSliceLeaky(Notification, scratch.allocator(), data, .{ .ignore_unknown_fields = true });
                        if (!std.mem.eql(u8, "channel.chat.message", notification.payload.subscription.type)) continue;

                        const chat_message = try std.json.parseFromValueLeaky(ChatMessageEvent, scratch.allocator(), notification.payload.event, .{ .ignore_unknown_fields = true });
                        std.debug.print("{s}: {s}\n", .{ chat_message.chatter_user_name, chat_message.message.text });
                    },
                }
            },
            .none => {},
        }
    }
}
