const sphtud = @import("sphtud");
const std = @import("std");
const Xdg = @import("Xdg.zig");

// Used to allocate message strings
arena: std.mem.Allocator,
expansion: sphtud.util.ExpansionAlloc,
messages: sphtud.util.RuntimeSegmentedListUnmanaged(Message),

pub const Message = struct {
    chatter: []const u8,
    message: []const u8,
};

const MessageDb = @This();

pub const typical_messages = 1000;
pub const max_messages = 1e9;

pub fn init(arena: std.mem.Allocator, expansion: sphtud.util.ExpansionAlloc) !MessageDb {
    return MessageDb {
        .arena = arena,
        .expansion = expansion,
        .messages = try .init(
            arena,
            expansion,
            typical_messages,
            max_messages
        )
    };
}

pub fn push(self: *MessageDb, chatter_name: []const u8, message_content: []const u8) !void {
    try self.messages.append(self.expansion, .{
        .chatter = try self.arena.dupe(u8, chatter_name),
        .message = try self.arena.dupe(u8, message_content),
    });
}

pub fn get(self: *MessageDb, idx: usize) Message {
    return self.messages.get(idx);
}

pub fn numMessages(self: *MessageDb) usize {
    return self.messages.len;
}
