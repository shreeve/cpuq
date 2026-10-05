const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The version cpuq reports: build.zig.zon's, or -Dversion for a release.
    const zon: struct {
        name: @EnumLiteral(),
        version: []const u8,
        fingerprint: u64,
        minimum_zig_version: []const u8,
        dependencies: struct {},
        paths: []const []const u8,
    } = @import("build.zig.zon");
    const version = b.option([]const u8, "version", "The version cpuq reports (default: build.zig.zon's)") orelse zon.version;
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{ .name = "cpuq", .root_module = mod });
    b.installArtifact(exe); // `zig build install -p PREFIX` puts it in PREFIX/bin

    // `zig build` (the default step) writes bin/cpuq in the checkout.
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
