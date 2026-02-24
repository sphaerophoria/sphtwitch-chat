const std = @import("std");

// FIXME: Export sphws as proper module

pub fn build(b: *std.Build) !void {
    const sphws_dep = b.dependency("sphws", .{});
    const sphws = sphws_dep.module("sphws");

    const sphtud_dep = b.dependency("sphtud", .{
        .with_gl = true,
        .with_glfw = true,
    });
    const sphtud = sphtud_dep.module("sphtud");

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sphtwitch_chat = b.addExecutable(.{
        .name = "sphtwitch_chat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sphtwitch_chat.root_module.addImport("sphws", sphws);
    sphtwitch_chat.root_module.addImport("sphtud", sphtud);


    const gif = b.addExecutable(.{
        .name = "gif",
        .root_module = b.createModule(.{
            .root_source_file = b.path("gif.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    gif.root_module.addImport("sphtud", sphtud);

    b.installArtifact(sphtwitch_chat);
    b.installArtifact(gif);


    const font_demo = b.addExecutable(.{
        .name = "font_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/font_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    font_demo.root_module.addImport("sphtud", sphtud);
    b.installArtifact(font_demo);
}
