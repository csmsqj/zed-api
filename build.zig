const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // WebUI build step skipped: embedding the pre-built webui/dist/index.html
    // (avoids needing webui/node_modules for tsc + vite).

    // Zig module
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addAnonymousImport("web_index_html", .{ .root_source_file = b.path("webui/dist/index.html") });

    const exe = b.addExecutable(.{
        .name = "zed2api",
        .root_module = mod,
    });

    // WebUI is pre-built; HTML embedded directly from webui/dist/index.html.

    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("bcrypt", .{});
        exe.root_module.linkSystemLibrary("advapi32", .{});
        exe.root_module.linkSystemLibrary("crypt32", .{});
        exe.root_module.linkSystemLibrary("ws2_32", .{});
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zed2api server");
    run_step.dependOn(&run_cmd.step);

    // Keep protocol conversion and streaming behavior executable through the
    // standard `zig build test` command. These two modules contain the request
    // compatibility and SSE regression tests used by Codex/Claude Code.
    const providers_test_mod = b.createModule(.{
        .root_source_file = b.path("src/providers.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const providers_tests = b.addTest(.{ .root_module = providers_test_mod });
    const run_providers_tests = b.addRunArtifact(providers_tests);

    const stream_test_mod = b.createModule(.{
        .root_source_file = b.path("src/stream.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const stream_tests = b.addTest(.{ .root_module = stream_test_mod });
    if (target.result.os.tag == .windows) {
        stream_tests.root_module.linkSystemLibrary("bcrypt", .{});
        stream_tests.root_module.linkSystemLibrary("advapi32", .{});
        stream_tests.root_module.linkSystemLibrary("crypt32", .{});
        stream_tests.root_module.linkSystemLibrary("ws2_32", .{});
    }
    const run_stream_tests = b.addRunArtifact(stream_tests);

    const test_step = b.step("test", "Run protocol and streaming regression tests");
    test_step.dependOn(&run_providers_tests.step);
    test_step.dependOn(&run_stream_tests.step);
}
