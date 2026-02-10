const std = @import("std");

const Xdg = @This();

data_root: []const u8,

const app_path = "sphaerophoria/sphtwitch";

pub fn init(alloc: std.mem.Allocator) !Xdg {
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    const data_root = try resolveDataRoot(&buf);
    const full_data_root = try std.fs.path.join(alloc, &.{ data_root, app_path });

    try std.fs.cwd().makePath(full_data_root);

    return .{
        .data_root = full_data_root,
    };
}

pub fn appdata(self: Xdg, alloc: std.mem.Allocator, sub_path: []const u8) ![]const u8 {
    return std.fs.path.join(alloc, &.{ self.data_root, sub_path });
}

fn resolveDataRoot(buf: []u8) ![]const u8 {
    if (std.posix.getenv("XDG_DATA_HOME")) |p| return p;
    const home = std.posix.getenv("HOME") orelse return error.UnresolvableDataRoot;

    return try std.fmt.bufPrint(buf, "{f}", .{std.fs.path.fmtJoin(&.{ home, ".local/share" })});
}
