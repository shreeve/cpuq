const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{ .name = "cpuq", .root_module = mod });
    b.installArtifact(exe); // `zig build install -p PREFIX` puts it in PREFIX/bin

    // `zig build` (the default step) writes bin/cpuq in the checkout, not zig-out/bin/cpuq.
    const to_bin = b.addUpdateSourceFiles();
    to_bin.addCopyFileToSource(exe.getEmittedBin(), "bin/cpuq");
    const bin = b.step("bin", "Build bin/cpuq (the default step)");
    bin.dependOn(&to_bin.step);
    b.default_step = bin;

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run cpuq").dependOn(&run.step);

    const unit = b.addTest(.{ .root_module = mod });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(unit).step);

    const fmt = b.addFmt(.{ .paths = b.pathList(&.{ "src", "build.zig", "build.zig.zon" }), .check = true });
    b.step("fmt", "Check formatting").dependOn(&fmt.step);
}
