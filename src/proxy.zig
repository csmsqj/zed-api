const std = @import("std");
const builtin = @import("builtin");

// Must match the system_id the Zed client registered the account/trial under.
// Zed's trial-abuse detection ties trial access to the system_id embedded in
// the minted LLM token; a mismatched id makes /completions return
// `trial_blocked` (403) even though token minting and login both succeed.
// Sourced from the local Zed client DB (AppData/Local/Zed/db/0-global).
pub const SYSTEM_ID = "9d4b8c17-12ae-4091-96bc-1a79ce2de601";

// Zed client version reported to the LLM endpoint. The real client sends the
// bare semantic version from `app_version.to_string()` (e.g. "1.8.2"), NOT the
// "+stable.<build>.<sha>" bundle string — the backend applies trial/model
// restrictions differently to unexpected client versions, which can cause
// spurious "trial_blocked" (403) errors. Keep in sync with the running Zed.
pub const ZED_VERSION = "1.8.2";
pub const ZED_VERSION_HEADER = "x-zed-version: " ++ ZED_VERSION;

// Headers the genuine Zed client attaches to every /completions request. Trial
// accounts are validated against these; omitting them makes the backend reject
// the request as trial_blocked even though the account works in the client.
pub const CLIENT_SUPPORTS_STATUS_MESSAGES_HEADER = "x-zed-client-supports-status-messages: true";
pub const CLIENT_SUPPORTS_STREAM_ENDED_HEADER = "x-zed-client-supports-stream-ended-request-completion-status: true";

// User-Agent the real Zed client sets as a global default on ALL HTTP requests:
//   format!("Zed/{} ({}; {})", AppVersion, std::env::consts::OS, std::env::consts::ARCH)
// The OS and architecture must match the build target, just like the real Zed
// client. The trial-abuse check rejects non-Zed User-Agents such as curl's.
pub const USER_AGENT = "Zed/" ++ ZED_VERSION ++ " (" ++ @tagName(builtin.os.tag) ++ "; " ++ @tagName(builtin.cpu.arch) ++ ")";
pub const USER_AGENT_HEADER = "user-agent: " ++ USER_AGENT;

// Global proxy config
var proxy_initialized: bool = false;
var proxy_host: ?[]const u8 = null;
var proxy_port: u16 = 0;

pub fn init(allocator: std.mem.Allocator) void {
    if (proxy_initialized) return;
    proxy_initialized = true;

    const env_names = [_][]const u8{ "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy" };
    for (env_names) |name| {
        const val = std.process.getEnvVarOwned(allocator, name) catch continue;
        if (val.len == 0) continue;
        if (parseProxyUrl(allocator, val)) return;
    }

    if (comptime builtin.os.tag == .windows) {
        readWindowsSystemProxy(allocator);
    }
}

pub fn getHost() ?[]const u8 {
    return proxy_host;
}

pub fn getPort() u16 {
    return proxy_port;
}

fn parseProxyUrl(allocator: std.mem.Allocator, val: []const u8) bool {
    const uri = std.Uri.parse(val) catch return false;
    const raw_host = uri.host orelse return false;
    const host = switch (raw_host) {
        .raw => |h| h,
        .percent_encoded => |h| h,
    };
    proxy_host = allocator.dupe(u8, host) catch return false;
    proxy_port = uri.port orelse 7890;
    std.debug.print("[zed] using HTTPS proxy: {s}:{d}\n", .{ proxy_host.?, proxy_port });
    return true;
}

fn readWindowsSystemProxy(allocator: std.mem.Allocator) void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "reg", "query", "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings", "/v", "ProxyEnable" },
        .max_output_bytes = 4096,
    }) catch return;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (std.mem.indexOf(u8, result.stdout, "0x1") == null) return;

    const result2 = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "reg", "query", "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings", "/v", "ProxyServer" },
        .max_output_bytes = 4096,
    }) catch return;
    defer allocator.free(result2.stdout);
    defer allocator.free(result2.stderr);

    if (std.mem.indexOf(u8, result2.stdout, "ProxyServer")) |idx| {
        const after = result2.stdout[idx..];
        if (std.mem.indexOf(u8, after, "REG_SZ")) |sz_idx| {
            var val_start = sz_idx + "REG_SZ".len;
            while (val_start < after.len and (after[val_start] == ' ' or after[val_start] == '\t')) val_start += 1;
            var val_end = val_start;
            while (val_end < after.len and after[val_end] != '\r' and after[val_end] != '\n') val_end += 1;
            const proxy_val = std.mem.trim(u8, after[val_start..val_end], " \t");
            if (proxy_val.len > 0) {
                if (std.mem.indexOf(u8, proxy_val, ":")) |colon| {
                    proxy_host = allocator.dupe(u8, proxy_val[0..colon]) catch return;
                    proxy_port = std.fmt.parseInt(u16, proxy_val[colon + 1 ..], 10) catch 7890;
                } else {
                    proxy_host = allocator.dupe(u8, proxy_val) catch return;
                    proxy_port = 7890;
                }
                std.debug.print("[zed] using system proxy: {s}:{d}\n", .{ proxy_host.?, proxy_port });
            }
        }
    }
}

/// Map an upstream HTTP status (and body) to a proxy error.
/// 401 and a "banned/trial blocked" 403 are treated as auth failures (token
/// expiry path + account benching). A 403 that merely says the model isn't in
/// the plan is model-level, so it surfaces as a generic upstream error that can
/// still fail over to an account whose plan includes the model.
pub fn errorForStatus(status: []const u8, body: []const u8) anyerror {
    if (std.mem.startsWith(u8, status, "401")) return error.TokenExpired;
    if (std.mem.startsWith(u8, status, "403")) {
        if (std.mem.indexOf(u8, body, "plan") != null) return error.UpstreamError;
        return error.TokenExpired;
    }
    if (std.mem.startsWith(u8, status, "429")) return error.RateLimited;
    return error.UpstreamError;
}

/// Send HTTP POST via proxy using curl subprocess
pub fn sendViaProxy(allocator: std.mem.Allocator, bearer: []const u8, body: []const u8) ![]const u8 {
    const p_url = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ proxy_host.?, proxy_port });
    defer allocator.free(p_url);

    const auth_header = try std.fmt.allocPrint(allocator, "authorization: {s}", .{bearer});
    defer allocator.free(auth_header);

    var tmp_name_buf: [64]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_name_buf, "zed2api_req_{d}.json", .{std.time.milliTimestamp()}) catch "zed2api_req_tmp.json";
    {
        const f = std.fs.cwd().createFile(tmp_path, .{}) catch return error.UpstreamError;
        defer f.close();
        f.writeAll(body) catch return error.UpstreamError;
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const at_path = try std.fmt.allocPrint(allocator, "@{s}", .{tmp_path});
    defer allocator.free(at_path);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "curl",           "-s",
            "-x",             p_url,
            "-X",             "POST",
            "https://cloud.zed.dev/completions",
            "-H",             auth_header,
            "-H",             "content-type: application/json",
            "-H",             ZED_VERSION_HEADER,
            "-H",             CLIENT_SUPPORTS_STATUS_MESSAGES_HEADER,
            "-H",             CLIENT_SUPPORTS_STREAM_ENDED_HEADER,
            "-H",             USER_AGENT_HEADER,
            "--data-binary",  at_path,
            "--max-time",     "120",
            "-w",             "\n__HTTP_STATUS__%{http_code}",
        },
        .max_output_bytes = 4 * 1024 * 1024,
    }) catch return error.UpstreamError;
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        std.debug.print("[zed] curl failed: {s}\n", .{result.stderr});
        allocator.free(result.stdout);
        return error.UpstreamError;
    }

    if (result.stdout.len == 0) {
        std.debug.print("[zed] proxy: empty response, stderr={s}\n", .{result.stderr});
        allocator.free(result.stdout);
        return error.UpstreamError;
    }

    var response_body = result.stdout;
    var http_status: []const u8 = "unknown";
    if (std.mem.lastIndexOf(u8, result.stdout, "\n__HTTP_STATUS__")) |pos| {
        response_body = result.stdout[0..pos];
        http_status = result.stdout[pos + "\n__HTTP_STATUS__".len ..];
    }

    // Reject on non-2xx status FIRST. Previously the status code was only
    // logged, so a 401/403/500 whose JSON body didn't start with {"error"} or
    // {"detail"} (e.g. Zed's {"code":"trial_blocked",...} 403) slipped through
    // as a "successful" empty response — the app returned 200 with no content
    // and never failed over to another account.
    if (!std.mem.startsWith(u8, http_status, "2")) {
        std.debug.print("[zed] proxy upstream status {s}: {s}\n", .{ http_status, response_body[0..@min(response_body.len, 300)] });
        const e = errorForStatus(http_status, response_body);
        allocator.free(result.stdout);
        return e;
    }

    if (response_body.len == 0) {
        std.debug.print("[zed] proxy: empty body with status {s}\n", .{http_status});
        allocator.free(result.stdout);
        return error.UpstreamError;
    }

    if (std.mem.startsWith(u8, response_body, "<html>") or std.mem.startsWith(u8, response_body, "<!DOCTYPE")) {
        std.debug.print("[zed] proxy: HTML error response (status={s})\n", .{http_status});
        allocator.free(result.stdout);
        return error.UpstreamError;
    }

    if (std.mem.startsWith(u8, response_body, "{\"error\"") or std.mem.startsWith(u8, response_body, "{\"detail\"")) {
        std.debug.print("[zed] upstream error (status={s}): {s}\n", .{ http_status, response_body[0..@min(response_body.len, 500)] });
        allocator.free(result.stdout);
        return error.UpstreamError;
    }

    const owned = allocator.dupe(u8, response_body) catch {
        allocator.free(result.stdout);
        return error.UpstreamError;
    };
    allocator.free(result.stdout);
    return owned;
}

/// Send HTTP POST to Zed with retry logic
pub fn sendToZed(allocator: std.mem.Allocator, jwt: []const u8, body: []const u8) ![]const u8 {
    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{jwt});
    defer allocator.free(bearer);

    init(allocator);

    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        const result = if (proxy_host != null) blk: {
            break :blk sendViaProxy(allocator, bearer, body);
        } else blk: {
            var response_buf: std.io.Writer.Allocating = .init(allocator);
            errdefer response_buf.deinit();

            var client: std.http.Client = .{ .allocator = allocator };
            defer client.deinit();

            const fetch_result = client.fetch(.{
                .location = .{ .url = "https://cloud.zed.dev/completions" },
                .method = .POST,
                .payload = body,
                .response_writer = &response_buf.writer,
                .extra_headers = &.{
                    .{ .name = "authorization", .value = bearer },
                    .{ .name = "content-type", .value = "application/json" },
                    .{ .name = "x-zed-version", .value = ZED_VERSION },
                    .{ .name = "x-zed-client-supports-status-messages", .value = "true" },
                    .{ .name = "x-zed-client-supports-stream-ended-request-completion-status", .value = "true" },
                    .{ .name = "user-agent", .value = USER_AGENT },
                },
            }) catch |err| {
                std.debug.print("[zed] network error attempt {d}: {}\n", .{ attempt + 1, err });
                response_buf.deinit();
                break :blk @as(anyerror![]const u8, error.UpstreamError);
            };

            if (fetch_result.status == .ok) {
                break :blk @as(anyerror![]const u8, response_buf.toOwnedSlice() catch {
                    response_buf.deinit();
                    break :blk @as(anyerror![]const u8, error.UpstreamError);
                });
            }

            const err_body = response_buf.written();
            std.debug.print("[zed] upstream {d} attempt {d}: {s}\n", .{ @intFromEnum(fetch_result.status), attempt + 1, err_body });
            response_buf.deinit();

            if (fetch_result.status == .unauthorized or fetch_result.status == .forbidden) {
                break :blk @as(anyerror![]const u8, error.TokenExpired);
            }
            if (fetch_result.status == .too_many_requests) {
                break :blk @as(anyerror![]const u8, error.RateLimited);
            }
            break :blk @as(anyerror![]const u8, error.UpstreamError);
        };

        if (result) |data| {
            return data;
        } else |err| {
            std.debug.print("[zed] attempt {d} error: {}\n", .{ attempt + 1, err });
            if (err == error.TokenExpired) return error.TokenExpired;
            if (err == error.RateLimited) {
                if (attempt < 2) std.Thread.sleep(3_000_000_000);
                continue;
            }
            if (attempt < 2) std.Thread.sleep(1_000_000_000 * (@as(u64, 1) << @intCast(attempt)));
        }
    }
    return error.UpstreamError;
}
