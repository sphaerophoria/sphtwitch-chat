const std = @import("std");

// FIXME: Export sphws as proper module

pub fn build(b: *std.Build) !void {
    const sphws_dep = b.dependency("sphws", .{});
    const sphws = sphws_dep.module("sphws");

    const sphtud_dep = b.dependency("sphtud", .{});
    const sphtud = sphtud_dep.module("sphtud");

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "twitch_chat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/twitch_chat.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("sphws", sphws);
    exe.root_module.addImport("sphtud", sphtud);

    const example = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    example.root_module.addImport("sphws", sphws);
    example.root_module.addImport("sphtud", sphtud);

    b.installArtifact(exe);
    b.installArtifact(example);
}
