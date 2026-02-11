const std = @import("std");

pub const RegisterWebsocket = struct {
    type: []const u8,
    version: []const u8,
    condition: struct { broadcaster_user_id: []const u8, user_id: []const u8 },
    transport: struct {
        method: []const u8,
        session_id: []const u8,
    },
};

pub const websocket = struct {
    pub const CommonMessage = struct {
        metadata: struct {
            message_type: []const u8,
        },

        pub fn messageType(self: CommonMessage) ?MessageType {
            return std.meta.stringToEnum(MessageType, self.metadata.message_type);
        }
    };

    pub const MessageType = enum { session_welcome, notification };

    pub const SessionWelcome = struct {
        payload: struct {
            session: struct {
                id: []const u8,
                keepalive_timeout_seconds: u32,
            },
        },
    };
};
