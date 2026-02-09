const std = @import("std");

const EventIdIter = @This();

id: comptime_int = 0,

// Note that start..end is inclusive for easier usage in switch statements
pub const Range = struct { start: comptime_int, end: comptime_int };

pub const TotalRange = struct {
    start: comptime_int,
    parent: *EventIdIter,

    pub fn markEnd(self: TotalRange) Range {
        return .{
            .start = self.start,
            .end = self.parent.id - 1,
        };
    }
};

pub fn markStart(self: *EventIdIter) TotalRange {
    return .{
        .start = self.id,
        .parent = self,
    };
}

pub fn one(self: *EventIdIter) comptime_int {
    defer self.id += 1;
    return self.id;
}

pub fn many(self: *EventIdIter, amount: comptime_int) Range {
    std.debug.assert(amount >= 1);
    defer self.id += amount;
    return .{ .start = self.id, .end = self.id + amount - 1 };
}
