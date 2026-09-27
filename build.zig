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

    // Keep request conversion, streaming, upstream status parsing, and health
    // probe behavior executable through the standard `zig build test` command.
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

    // Upstream status-message handling lives here: Zed reports rejected
    // requests as HTTP 200 plus a `status.failed` line, so the parser that
    // recognizes them needs its own coverage.
    const proxy_test_mod = b.createModule(.{
        .root_source_file = b.path("src/proxy.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const proxy_tests = b.addTest(.{ .root_module = proxy_test_mod });
    if (target.result.os.tag == .windows) {
        proxy_tests.root_module.linkSystemLibrary("advapi32", .{});
        proxy_tests.root_module.linkSystemLibrary("ws2_32", .{});
    }
    const run_proxy_tests = b.addRunArtifact(proxy_tests);

    const server_test_mod = b.createModule(.{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // `zig build test` must also run on a fresh clone where the generated
    // webui/dist/index.html does not exist yet: it is produced by `npm run
    // build` and never committed. Tests never read the page, so substitute a
    // placeholder file; the executable above still requires the real artifact.
    var server_web_index: std.Build.LazyPath = b.path("webui/dist/index.html");
    b.build_root.handle.access("webui/dist/index.html", .{}) catch {
        const placeholder = b.addWriteFiles();
        server_web_index = placeholder.add("index.html", "<!doctype html><title>zed2api</title>");
    };
    server_test_mod.addAnonymousImport("web_index_html", .{ .root_source_file = server_web_index });
    const server_tests = b.addTest(.{ .root_module = server_test_mod });
    if (target.result.os.tag == .windows) {
        server_tests.root_module.linkSystemLibrary("bcrypt", .{});
        server_tests.root_module.linkSystemLibrary("advapi32", .{});
        server_tests.root_module.linkSystemLibrary("crypt32", .{});
        server_tests.root_module.linkSystemLibrary("ws2_32", .{});
    }
    const run_server_tests = b.addRunArtifact(server_tests);

    const test_step = b.step("test", "Run protocol, streaming, and health regression tests");
    test_step.dependOn(&run_providers_tests.step);
    test_step.dependOn(&run_stream_tests.step);
    test_step.dependOn(&run_proxy_tests.step);
    test_step.dependOn(&run_server_tests.step);
}
