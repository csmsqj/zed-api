const std = @import("std");
const accounts = @import("accounts.zig");
const auth = @import("auth.zig");
const zed = @import("zed.zig");
const proxy = @import("proxy.zig");
const providers = @import("providers.zig");
const account_status = @import("account_status.zig");
const stream = @import("stream.zig");
const socket = @import("socket.zig");
const web_ui = @embedFile("web_index_html");

// Explicit health probes are intentionally tiny. Passive quota checks never
// invoke a model; when the user asks for a real inference check, use the
// lowest project model tier, disable reasoning, and cap visible output.
const HEALTH_PROBE_MODEL = "gpt-5.6-luna";
const HEALTH_PROBE_EFFORT = "none";
const HEALTH_PROBE_MAX_OUTPUT_TOKENS: i64 = 16;
const HEALTH_PROBE_BODY =
    \\{"model":"gpt-5.6-luna","messages":[{"role":"user","content":"Reply only OK"}],"reasoning_effort":"none","max_completion_tokens":16,"stream":false}
;

var account_mgr: accounts.AccountManager = undefined;
var global_allocator: std.mem.Allocator = undefined;

// Dynamic models cache
var cached_models_openai: ?[]const u8 = null;
var cached_models_time: i64 = 0;
const MODELS_CACHE_TTL: i64 = 3600; // 1 hour

pub fn run(allocator: std.mem.Allocator, port: u16) !void {
    global_allocator = allocator;
    account_mgr = accounts.AccountManager.init(allocator);
    defer account_mgr.deinit();
    account_mgr.loadFromFile() catch {};

    std.debug.print("[zed2api] http://127.0.0.1:{d}\n[zed2api] {d} account(s) loaded\n", .{ port, account_mgr.list.items.len });

    proxy.init(allocator);
    if (proxy.getHost()) |host| {
        std.debug.print("[zed2api] proxy: {s}:{d}\n", .{ host, proxy.getPort() });
    } else {
        std.debug.print("[zed2api] proxy: none (set HTTPS_PROXY to use)\n", .{});
    }

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    // On Windows SO_REUSEADDR allows two zed2api processes to bind the same
    // loopback port, which makes requests and logs land in different instances.
    // Fail the second start instead so one port always identifies one process.
    var tcp_server = try addr.listen(.{ .reuse_address = false });
    defer tcp_server.deinit();

    while (true) {
        const conn = tcp_server.accept() catch continue;
        const thread = std.Thread.spawn(.{}, handleConnection, .{conn.stream}) catch {
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(conn_stream: std.net.Stream) void {
    defer conn_stream.close();

    var hdr_buf: [8192]u8 = undefined;
    var hdr_total: usize = 0;

    while (hdr_total < hdr_buf.len) {
        const n = socket.recv(conn_stream, hdr_buf[hdr_total..]) catch return;
        if (n == 0) return;
        hdr_total += n;
        if (std.mem.indexOf(u8, hdr_buf[0..hdr_total], "\r\n\r\n") != null) break;
    }

    const header_end = std.mem.indexOf(u8, hdr_buf[0..hdr_total], "\r\n\r\n") orelse return;
    const headers = hdr_buf[0..header_end];
    const body_in_hdr = hdr_buf[header_end + 4 .. hdr_total];

    const first_line_end = std.mem.indexOf(u8, headers, "\r\n") orelse return;
    const first_line = headers[0..first_line_end];
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    const method = parts.next() orelse return;
    const full_path = parts.next() orelse return;
    const path = if (std.mem.indexOf(u8, full_path, "?")) |i| full_path[0..i] else full_path;

    var content_length: usize = 0;
    var header_lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (header_lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const val = std.mem.trim(u8, line["content-length:".len..], " ");
            content_length = std.fmt.parseInt(usize, val, 10) catch 0;
        }
    }

    // Read body (up to 16MB). Reject oversized requests explicitly instead of
    // silently truncating JSON and forwarding a malformed provider request.
    const max_body = 16 * 1024 * 1024;
    if (content_length > max_body) {
        socket.writeResponse(conn_stream, 413, "{\"error\":{\"message\":\"request body exceeds 16 MiB\",\"type\":\"invalid_request_error\"}}");
        return;
    }
    const actual_len = content_length;
    var body: []const u8 = "";
    var body_alloc: ?[]u8 = null;
    defer if (body_alloc) |b| global_allocator.free(b);

    if (actual_len > 0) {
        const body_buf = global_allocator.alloc(u8, actual_len) catch {
            socket.writeResponse(conn_stream, 500, "{\"error\":\"body too large\"}");
            return;
        };
        body_alloc = body_buf;
        const already = @min(body_in_hdr.len, actual_len);
        @memcpy(body_buf[0..already], body_in_hdr[0..already]);
        var filled: usize = already;
        while (filled < actual_len) {
            const n = socket.recv(conn_stream, body_buf[filled..actual_len]) catch break;
            if (n == 0) break;
            filled += n;
        }
        body = body_buf[0..filled];
    }

    // Streaming proxy check
    const is_messages = std.mem.eql(u8, path, "/v1/messages") and std.mem.eql(u8, method, "POST");
    const is_completions = std.mem.eql(u8, path, "/v1/chat/completions") and std.mem.eql(u8, method, "POST");
    const is_responses = std.mem.eql(u8, path, "/v1/responses") and std.mem.eql(u8, method, "POST");

    if (is_messages or is_completions or is_responses) {
        providers.validateClientReasoningEffort(global_allocator, body, is_messages) catch |err| {
            if (err == error.UnsupportedReasoningEffort) {
                socket.writeResponse(conn_stream, 400, "{\"error\":{\"message\":\"Zed-hosted GPT-5.6 supports none, low, medium, high, and xhigh; max/minimal are not available on this upstream route\",\"type\":\"invalid_request_error\"}}");
            } else {
                socket.writeResponse(conn_stream, 400, "{\"error\":{\"message\":\"invalid JSON request body\",\"type\":\"invalid_request_error\"}}");
            }
            return;
        };
    }
    const wants_stream = (is_messages or is_completions or is_responses) and requestWantsStream(body);

    if (wants_stream) {
        const req_model_owned = providers.extractModelFromBody(global_allocator, body) catch null;
        defer if (req_model_owned) |value| global_allocator.free(value);
        const req_model = req_model_owned orelse "unknown";
        const has_thinking = std.mem.indexOf(u8, body, "\"thinking\"") != null or std.mem.indexOf(u8, body, "\"reasoning\"") != null;
        std.debug.print("[req] {s} {s} model={s} thinking={} body={d}bytes (stream)\n", .{ method, path, req_model, has_thinking, body.len });
        stream.handleStreamProxy(conn_stream, body, is_messages, is_responses, &account_mgr, global_allocator);
        return;
    }

    // Non-streaming route
    const response = route(method, path, body) catch |err| {
        std.debug.print("[zed2api] route error: {} for {s} {s}\n", .{ err, method, path });
        socket.writeResponse(conn_stream, 500, "{\"error\":\"internal error\"}");
        return;
    };
    defer if (response.allocated) global_allocator.free(response.body);
    socket.writeResponseWithType(conn_stream, response.status, response.body, response.content_type);
}

/// JSON whitespace and formatting are insignificant. Parsing the boolean
/// avoids routing a valid request to the non-streaming handler merely because
/// a client emitted tabs, newlines, or multiple spaces around `stream`.
fn requestWantsStream(body: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, global_allocator, body, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const stream_value = parsed.value.object.get("stream") orelse return false;
    return stream_value == .bool and stream_value.bool;
}

const Response = struct {
    status: u16,
    body: []const u8,
    content_type: []const u8 = "application/json",
    allocated: bool = false,
};

const ProxyProtocol = enum { openai_chat, openai_responses, anthropic };

fn route(method: []const u8, path: []const u8, body: []const u8) !Response {
    std.debug.print("[req] {s} {s} body={d}bytes\n", .{ method, path, body.len });

    if (std.mem.eql(u8, path, "/")) return .{ .status = 200, .body = web_ui, .content_type = "text/html; charset=utf-8" };
    if (std.mem.eql(u8, path, "/v1/models") and std.mem.eql(u8, method, "GET"))
        return try handleModels();
    if (std.mem.eql(u8, path, "/api/event_logging/batch"))
        return .{ .status = 200, .body = "{\"status\":\"ok\"}" };
    if (std.mem.startsWith(u8, path, "/v1/messages/count_tokens"))
        return .{ .status = 200, .body = "{\"input_tokens\":0}" };
    if (std.mem.eql(u8, path, "/zed/accounts") and std.mem.eql(u8, method, "GET"))
        return try handleListAccounts();
    if (std.mem.eql(u8, path, "/zed/accounts/status") and std.mem.eql(u8, method, "GET"))
        return try handleAccountStatuses();
    if (std.mem.eql(u8, path, "/zed/accounts/health") and std.mem.eql(u8, method, "POST"))
        return try handleAccountHealth(body);
    if (std.mem.eql(u8, path, "/zed/accounts/switch") and std.mem.eql(u8, method, "POST"))
        return handleSwitchAccount(body);
    if (std.mem.eql(u8, path, "/zed/usage") and std.mem.eql(u8, method, "GET"))
        return try handleUsage();
    if (std.mem.eql(u8, path, "/zed/billing") and std.mem.eql(u8, method, "GET"))
        return try handleBilling();
    if (std.mem.eql(u8, path, "/v1/chat/completions") and std.mem.eql(u8, method, "POST"))
        return try handleProxy(body, .openai_chat);
    if (std.mem.eql(u8, path, "/v1/responses") and std.mem.eql(u8, method, "POST"))
        return try handleProxy(body, .openai_responses);
    if (std.mem.eql(u8, path, "/v1/messages") and std.mem.eql(u8, method, "POST"))
        return try handleProxy(body, .anthropic);
    if (std.mem.eql(u8, path, "/zed/login") and std.mem.eql(u8, method, "POST"))
        return try handleLogin(body);
    if (std.mem.eql(u8, path, "/zed/login/status") and std.mem.eql(u8, method, "GET"))
        return handleLoginStatus();
    if (std.mem.eql(u8, method, "OPTIONS"))
        return .{ .status = 200, .body = "" };
    return .{ .status = 404, .body = "{\"error\":\"not found\"}" };
}

// ── Non-streaming proxy with failover ──

fn handleProxy(body: []const u8, protocol: ProxyProtocol) !Response {
    if (account_mgr.list.items.len == 0) return .{ .status = 400, .body = "{\"error\":\"no account configured\"}" };

    var try_order: [64]usize = undefined;
    const count = account_mgr.buildTryOrder(&try_order);

    var last_err: anyerror = error.UpstreamError;
    for (try_order[0..count]) |acc_idx| {
        const acc = &account_mgr.list.items[acc_idx];
        const available = accounts.AccountManager.isAvailable(acc);
        if (!available)
            std.debug.print("[zed2api] account '{s}' is benched (retry in {d}s), trying anyway as last resort\n", .{ acc.name, acc.disabled_until - std.time.timestamp() });

        const result = switch (protocol) {
            .anthropic => zed.proxyMessages(global_allocator, acc, body),
            .openai_chat => zed.proxyChatCompletions(global_allocator, acc, body),
            .openai_responses => zed.proxyResponses(global_allocator, acc, body),
        };

        if (result) |data| {
            accounts.AccountManager.markSuccess(acc, 200);
            if (acc_idx != account_mgr.current) {
                std.debug.print("[zed2api] failover success: switched to '{s}'\n", .{acc.name});
                account_mgr.setCurrent(acc_idx);
            }
            return .{ .status = 200, .body = data, .allocated = true };
        } else |err| {
            last_err = err;
            const kind = failureKind(err);
            accounts.AccountManager.markFailure(acc, kind, statusForError(err));
            std.debug.print("[zed2api] account '{s}' failed: {} (kind={s}, benched {d}s)\n", .{ acc.name, err, @tagName(kind), @max(acc.disabled_until - std.time.timestamp(), 0) });
            // Auth/rate/upstream errors are worth failing over; anything else
            // (e.g. malformed request) will fail identically on every account.
            const should_failover = (err == error.TokenRefreshFailed or err == error.TokenExpired or err == error.UpstreamError or err == error.RateLimited);
            if (!should_failover) break;
        }
    }

    const status: u16 = switch (last_err) {
        error.TokenRefreshFailed => 401,
        error.TokenExpired => 401,
        error.RateLimited => 429,
        error.UpstreamError => 502,
        else => 500,
    };
    const msg = switch (last_err) {
        error.TokenRefreshFailed => "{\"error\":{\"message\":\"All accounts failed: token refresh failed (bad/expired credential or banned account)\",\"type\":\"auth_error\"}}",
        error.TokenExpired => "{\"error\":{\"message\":\"All accounts failed: token expired\",\"type\":\"auth_error\"}}",
        error.RateLimited => "{\"error\":{\"message\":\"All accounts failed: rate limited\",\"type\":\"rate_limit_error\"}}",
        error.UpstreamError => "{\"error\":{\"message\":\"All accounts failed: upstream error\",\"type\":\"upstream_error\"}}",
        else => "{\"error\":{\"message\":\"All accounts failed: internal error\",\"type\":\"server_error\"}}",
    };
    return .{ .status = status, .body = msg };
}

/// Classify a proxy error into a health FailureKind so the scheduler can pick a
/// sensible cooldown.
fn failureKind(err: anyerror) accounts.FailureKind {
    return switch (err) {
        error.TokenRefreshFailed, error.TokenExpired => .auth,
        error.RateLimited => .rate_limit,
        else => .transient,
    };
}

fn statusForError(err: anyerror) u16 {
    return switch (err) {
        error.TokenRefreshFailed, error.TokenExpired => 401,
        error.RateLimited => 429,
        error.UpstreamError => 502,
        else => 0,
    };
}

// ── Account handlers ──

fn handleListAccounts() !Response {
    const now = std.time.timestamp();
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(global_allocator);
    try w.writeAll("{\"accounts\":[");
    for (account_mgr.list.items, 0..) |acc, i| {
        if (i > 0) try w.writeAll(",");
        const healthy = now >= acc.disabled_until;
        const cooldown = if (healthy) @as(i64, 0) else acc.disabled_until - now;
        try w.print("{{\"name\":\"{s}\",\"user_id\":\"{s}\",\"current\":{s},\"healthy\":{s},\"cooldown_s\":{d},\"consecutive_failures\":{d},\"last_status\":{d}}}", .{
            acc.name,                                          acc.user_id,
            if (i == account_mgr.current) "true" else "false", if (healthy) "true" else "false",
            cooldown,                                          acc.consecutive_failures,
            acc.last_status,
        });
    }
    try w.print("],\"current\":\"{s}\"}}", .{
        if (account_mgr.getCurrent()) |c| c.name else "",
    });
    return .{ .status = 200, .body = try buf.toOwnedSlice(global_allocator), .allocated = true };
}

fn writeOptionalInt(w: *std.io.Writer, value: ?i64) !void {
    if (value) |number| {
        try w.print("{d}", .{number});
    } else {
        try w.writeAll("null");
    }
}

fn writeOptionalString(w: *std.io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try std.json.Stringify.encodeJsonString(text, .{}, w);
    } else {
        try w.writeAll("null");
    }
}

/// Check every configured account without exposing credentials or JWTs. A
/// successful LLM-token refresh proves that the account can authenticate;
/// billing data then provides the best non-consuming quota signal available.
fn handleAccountStatuses() !Response {
    const now = std.time.timestamp();
    var output: std.io.Writer.Allocating = .init(global_allocator);
    errdefer output.deinit();
    const w = &output.writer;

    try w.print("{{\"checked_at\":{d},\"accounts\":[", .{now});
    for (account_mgr.list.items, 0..) |*acc, index| {
        if (index > 0) try w.writeAll(",");
        const scheduler_healthy = accounts.AccountManager.isAvailable(acc);
        const cooldown = if (scheduler_healthy) @as(i64, 0) else @max(@as(i64, 0), acc.disabled_until - now);

        try w.writeAll("{\"name\":");
        try std.json.Stringify.encodeJsonString(acc.name, .{}, w);
        try w.writeAll(",\"user_id\":");
        try std.json.Stringify.encodeJsonString(acc.user_id, .{}, w);
        try w.print(",\"current\":{s},\"scheduler_healthy\":{s},\"cooldown_s\":{d},\"last_status\":{d}", .{
            if (index == account_mgr.current) "true" else "false",
            if (scheduler_healthy) "true" else "false",
            cooldown,
            acc.last_status,
        });
        try w.print(",\"model_state\":\"{s}\",\"model_ok\":{s},\"model_checked_at\":{d},\"model_latency_ms\":{d}", .{
            @tagName(acc.last_probe_state),
            if (acc.last_probe_state == .healthy) "true" else "false",
            acc.last_probe_at,
            acc.last_probe_latency_ms,
        });

        const token: ?[]const u8 = zed.getToken(global_allocator, acc) catch null;
        if (token == null) {
            try w.writeAll(",\"check_ok\":false,\"token_ok\":false,\"billing_ok\":false,\"usable\":false,\"quota_state\":\"unavailable\",\"error\":\"llm_token_refresh_failed\"}");
            continue;
        }

        const billing_result = zed.fetchBillingUsage(global_allocator, acc);
        if (billing_result) |billing| {
            defer global_allocator.free(billing);
            const parsed = std.json.parseFromSlice(std.json.Value, global_allocator, billing, .{}) catch {
                try w.writeAll(",\"check_ok\":false,\"token_ok\":true,\"billing_ok\":false,\"usable\":true,\"quota_state\":\"unknown\",\"error\":\"invalid_billing_response\"}");
                continue;
            };
            defer parsed.deinit();

            const summary = account_status.summarize(parsed.value);
            const state = account_status.quotaState(summary);
            try w.print(",\"check_ok\":true,\"token_ok\":true,\"billing_ok\":true,\"usable\":{s},\"quota_state\":\"{s}\",\"plan\":", .{
                if (account_status.isUsable(summary)) "true" else "false",
                state,
            });
            try std.json.Stringify.encodeJsonString(summary.plan, .{}, w);
            try w.writeAll(",\"used\":");
            try writeOptionalInt(w, summary.used);
            try w.writeAll(",\"limit\":");
            try writeOptionalInt(w, summary.limit);
            try w.writeAll(",\"remaining\":");
            try writeOptionalInt(w, account_status.remaining(summary));
            try w.writeAll(",\"subscription_ends_at\":");
            try writeOptionalString(w, summary.subscription_ends_at);
            try w.print(",\"usage_based_billing\":{s},\"overdue\":{s},\"account_too_young\":{s}}}", .{
                if (summary.usage_based_billing) "true" else "false",
                if (summary.overdue) "true" else "false",
                if (summary.account_too_young) "true" else "false",
            });
        } else |_| {
            // The LLM token is valid, so model access may still work even when
            // the optional billing endpoint is temporarily unavailable.
            try w.writeAll(",\"check_ok\":false,\"token_ok\":true,\"billing_ok\":false,\"usable\":true,\"quota_state\":\"unknown\",\"error\":\"billing_check_failed\"}");
        }
    }
    try w.writeAll("]}");
    return .{ .status = 200, .body = try output.toOwnedSlice(), .allocated = true };
}

/// Run a real, account-specific inference probe. This bypasses failover on
/// purpose: a healthy second account must not hide a broken selected account.
fn runAccountHealthProbe(acc: *accounts.Account) void {
    const started_ms = std.time.milliTimestamp();
    const result: anyerror![]const u8 = zed.proxyChatCompletions(global_allocator, acc, HEALTH_PROBE_BODY);
    const latency_ms = @max(@as(i64, 0), std.time.milliTimestamp() - started_ms);

    if (result) |response| {
        const has_text = probeResponseHasText(response);
        global_allocator.free(response);
        if (!has_text) {
            accounts.AccountManager.markProbeFailure(acc, .upstream_error, .transient, 502, latency_ms);
            std.debug.print("[health] account '{s}' probe returned no visible text ({d}ms)\n", .{ acc.name, latency_ms });
            return;
        }
        accounts.AccountManager.markProbeSuccess(acc, latency_ms);
        return;
    } else |err| {
        const state: accounts.ProbeState = switch (err) {
            error.TokenRefreshFailed, error.TokenExpired => .auth_error,
            error.RateLimited => .rate_limited,
            else => .upstream_error,
        };
        accounts.AccountManager.markProbeFailure(acc, state, failureKind(err), statusForError(err), latency_ms);
        std.debug.print("[health] account '{s}' probe failed: {} ({d}ms)\n", .{ acc.name, err, latency_ms });
    }
}

/// A 2xx envelope with an empty choice is not a useful health signal. Require
/// visible assistant text so the probe verifies the complete inference path.
fn probeResponseHasText(response: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, global_allocator, response, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const choices = parsed.value.object.get("choices") orelse return false;
    if (choices != .array or choices.array.items.len == 0) return false;
    const choice = choices.array.items[0];
    if (choice != .object) return false;
    const message = choice.object.get("message") orelse return false;
    if (message != .object) return false;
    const content = message.object.get("content") orelse return false;
    return content == .string and std.mem.trim(u8, content.string, " \t\r\n").len > 0;
}

fn writeAccountHealthResult(w: *std.io.Writer, acc: *const accounts.Account, now: i64) !void {
    const scheduler_healthy = accounts.AccountManager.isAvailable(acc);
    const cooldown = if (scheduler_healthy) @as(i64, 0) else @max(@as(i64, 0), acc.disabled_until - now);

    try w.writeAll("{\"name\":");
    try std.json.Stringify.encodeJsonString(acc.name, .{}, w);
    try w.print(",\"model_ok\":{s},\"model_state\":\"{s}\",\"model_checked_at\":{d},\"model_latency_ms\":{d},\"scheduler_healthy\":{s},\"cooldown_s\":{d},\"last_status\":{d}}}", .{
        if (acc.last_probe_state == .healthy) "true" else "false",
        @tagName(acc.last_probe_state),
        acc.last_probe_at,
        acc.last_probe_latency_ms,
        if (scheduler_healthy) "true" else "false",
        cooldown,
        acc.last_status,
    });
}

/// POST body may be `{}` for all accounts or `{"account":"name"}` for one.
/// The response contains only diagnostics and never returns credentials/JWTs.
fn handleAccountHealth(body: []const u8) !Response {
    var target_owned: ?[]const u8 = null;
    defer if (target_owned) |target| global_allocator.free(target);

    if (body.len > 0) {
        const parsed = std.json.parseFromSlice(std.json.Value, global_allocator, body, .{}) catch
            return .{ .status = 400, .body = "{\"error\":\"invalid json\"}" };
        defer parsed.deinit();
        if (parsed.value != .object)
            return .{ .status = 400, .body = "{\"error\":\"request body must be an object\"}" };
        if (parsed.value.object.get("account")) |account_value| {
            if (account_value != .string)
                return .{ .status = 400, .body = "{\"error\":\"account must be a string\"}" };
            target_owned = try global_allocator.dupe(u8, account_value.string);
        }
    }

    if (target_owned) |target| {
        var found = false;
        for (account_mgr.list.items) |*acc| {
            if (!std.mem.eql(u8, acc.name, target)) continue;
            found = true;
            runAccountHealthProbe(acc);
            break;
        }
        if (!found) return .{ .status = 404, .body = "{\"error\":\"account not found\"}" };
    } else {
        // Sequential checks keep resource use predictable and avoid sending a
        // burst of paid model requests when many accounts are configured.
        for (account_mgr.list.items) |*acc| runAccountHealthProbe(acc);
    }

    const now = std.time.timestamp();
    var output: std.io.Writer.Allocating = .init(global_allocator);
    errdefer output.deinit();
    const w = &output.writer;
    try w.print("{{\"checked_at\":{d},\"probe\":{{\"model\":\"{s}\",\"reasoning_effort\":\"{s}\",\"max_output_tokens\":{d}}},\"accounts\":[", .{
        now,
        HEALTH_PROBE_MODEL,
        HEALTH_PROBE_EFFORT,
        HEALTH_PROBE_MAX_OUTPUT_TOKENS,
    });
    var written: usize = 0;
    for (account_mgr.list.items) |*acc| {
        if (target_owned) |target| {
            if (!std.mem.eql(u8, acc.name, target)) continue;
        }
        if (written > 0) try w.writeAll(",");
        try writeAccountHealthResult(w, acc, now);
        written += 1;
    }
    try w.writeAll("]}");
    return .{ .status = 200, .body = try output.toOwnedSlice(), .allocated = true };
}

fn handleSwitchAccount(body: []const u8) Response {
    const parsed = std.json.parseFromSlice(std.json.Value, global_allocator, body, .{}) catch
        return .{ .status = 400, .body = "{\"error\":\"invalid json\"}" };
    defer parsed.deinit();
    const name = switch (parsed.value.object.get("account") orelse return .{ .status = 400, .body = "{\"error\":\"missing account\"}" }) {
        .string => |s| s,
        else => return .{ .status = 400, .body = "{\"error\":\"bad type\"}" },
    };
    if (account_mgr.switchTo(name))
        return .{ .status = 200, .body = "{\"success\":true}" }
    else
        return .{ .status = 404, .body = "{\"error\":\"not found\"}" };
}

fn handleUsage() !Response {
    const acc = account_mgr.getCurrent() orelse return .{ .status = 400, .body = "{\"error\":\"no account\"}" };
    const jwt = try zed.getToken(global_allocator, acc);
    const claims = try zed.parseJwtClaims(global_allocator, jwt);
    return .{ .status = 200, .body = claims, .allocated = true };
}

fn handleBilling() !Response {
    const acc = account_mgr.getCurrent() orelse return .{ .status = 400, .body = "{\"error\":\"no account\"}" };
    const user_info = zed.fetchBillingUsage(global_allocator, acc) catch {
        return .{ .status = 502, .body = "{\"error\":\"failed to fetch user info\"}" };
    };
    return .{ .status = 200, .body = user_info, .allocated = true };
}

fn handleModels() !Response {
    const now = std.time.timestamp();
    if (cached_models_openai) |cached| {
        if (now - cached_models_time < MODELS_CACHE_TTL) {
            return .{ .status = 200, .body = cached };
        }
    }

    // Fetch from Zed
    const acc = account_mgr.getCurrent() orelse {
        // Fallback to static
        return .{ .status = 200, .body = @embedFile("models.json") };
    };

    const raw = zed.fetchModels(global_allocator, acc) catch {
        // Fallback to cache or static
        if (cached_models_openai) |cached| return .{ .status = 200, .body = cached };
        return .{ .status = 200, .body = @embedFile("models.json") };
    };
    defer global_allocator.free(raw);

    // Convert Zed format to OpenAI format
    const openai = convertZedModelsToOpenAI(global_allocator, raw) catch {
        if (cached_models_openai) |cached| return .{ .status = 200, .body = cached };
        return .{ .status = 200, .body = @embedFile("models.json") };
    };

    // A successful upstream response can still contain none of the aliases
    // this proxy intentionally exposes. Return the stable local catalog in
    // that case instead of caching an empty model list.
    if (std.mem.indexOf(u8, openai, "\"data\":[]") != null) {
        global_allocator.free(openai);
        return .{ .status = 200, .body = @embedFile("models.json") };
    }

    // Update cache
    if (cached_models_openai) |old| global_allocator.free(old);
    cached_models_openai = openai;
    cached_models_time = now;

    std.debug.print("[zed2api] models refreshed ({d} bytes)\n", .{openai.len});
    return .{ .status = 200, .body = openai };
}

/// Models advertised on /v1/models (all requests are normalized onto these).
fn isExposedModel(id: []const u8) bool {
    const exposed = [_][]const u8{ "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "claude-sonnet-5" };
    for (exposed) |m| if (std.mem.eql(u8, id, m)) return true;
    return false;
}

fn convertZedModelsToOpenAI(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const models = switch (parsed.value.object.get("models") orelse return error.InvalidFormat) {
        .array => |a| a,
        else => return error.InvalidFormat,
    };

    var buf: std.io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("{\"object\":\"list\",\"data\":[");
    var first = true;
    var has_bare_gpt56 = false;
    var has_gpt56_sol = false;
    for (models.items) |model| {
        if (model != .object) continue;
        const id = switch (model.object.get("id") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        if (std.mem.eql(u8, id, "gpt-5.6")) has_bare_gpt56 = true;
        if (std.mem.eql(u8, id, "gpt-5.6-sol")) has_gpt56_sol = true;
    }
    // Bare gpt-5.6 is a stable local alias for Sol. Advertise it even though
    // Zed's upstream catalog lists only the concrete Sol/Terra/Luna variants.
    if (has_gpt56_sol and !has_bare_gpt56) {
        try w.writeAll("{\"id\":\"gpt-5.6\",\"object\":\"model\",\"owned_by\":\"open_ai\"}");
        first = false;
    }
    for (models.items) |model| {
        if (model != .object) continue;
        const id = switch (model.object.get("id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const provider = switch (model.object.get("provider") orelse continue) {
            .string => |s| s,
            else => continue,
        };

        // Only expose the 5.6-era models we route to.
        if (!isExposedModel(id)) continue;

        if (!first) try w.writeAll(",");
        first = false;
        try w.print("{{\"id\":\"{s}\",\"object\":\"model\",\"owned_by\":\"{s}\"}}", .{ id, provider });
    }
    // Codex Desktop's models manager requires a top-level "models" catalog
    // (it fails the whole turn with `missing field \`models\`` otherwise).
    // OpenAI-style clients ignore the extra field, so both formats coexist.
    try w.writeAll("],\"models\":");
    try w.writeAll(std.mem.trim(u8, @embedFile("codex_models.json"), " \n\r\t"));
    try w.writeAll("}");
    return try buf.toOwnedSlice();
}

// ── Login ──
var login_status: enum { idle, waiting, success, failed } = .idle;
var login_error_msg: []const u8 = "";
var login_result_name: []const u8 = "";

fn handleLogin(body: []const u8) !Response {
    if (login_status == .waiting) return .{ .status = 409, .body = "{\"error\":\"login already in progress\"}" };

    var account_name: []const u8 = "";
    if (body.len > 0) {
        const parsed = std.json.parseFromSlice(std.json.Value, global_allocator, body, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value.object.get("name")) |n| {
                if (n == .string) account_name = global_allocator.dupe(u8, n.string) catch "";
            }
        }
    }

    const keypair = try global_allocator.create(auth.RsaKeyPair);
    keypair.* = auth.RsaKeyPair.generate(global_allocator) catch |err| {
        global_allocator.destroy(keypair);
        return err;
    };
    const pub_key = keypair.exportPublicKeyB64(global_allocator) catch |err| {
        keypair.deinit();
        global_allocator.destroy(keypair);
        return err;
    };

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    const tcp = try global_allocator.create(std.net.Server);
    tcp.* = addr.listen(.{}) catch |err| {
        global_allocator.free(pub_key);
        keypair.deinit();
        global_allocator.destroy(keypair);
        global_allocator.destroy(tcp);
        return err;
    };
    const port = tcp.listen_address.getPort();
    const url = try std.fmt.allocPrint(global_allocator, "https://zed.dev/native_app_signin?native_app_port={d}&native_app_public_key={s}", .{ port, pub_key });

    login_status = .waiting;
    const thread = std.Thread.spawn(.{}, loginWorker, .{ keypair, tcp, pub_key, account_name }) catch {
        login_status = .failed;
        tcp.deinit();
        global_allocator.destroy(tcp);
        keypair.deinit();
        global_allocator.destroy(keypair);
        global_allocator.free(pub_key);
        global_allocator.free(url);
        return .{ .status = 500, .body = "{\"error\":\"thread spawn failed\"}" };
    };
    thread.detach();
    auth.openBrowserPublic(url);

    var resp_buf: [4096]u8 = undefined;
    const resp = try std.fmt.bufPrint(&resp_buf, "{{\"login_url\":\"{s}\",\"port\":{d}}}", .{ url, port });
    const result = try global_allocator.dupe(u8, resp);
    global_allocator.free(url);
    return .{ .status = 200, .body = result, .allocated = true };
}

fn loginWorker(keypair: *auth.RsaKeyPair, tcp: *std.net.Server, pub_key: []const u8, account_name: []const u8) void {
    defer {
        tcp.deinit();
        global_allocator.destroy(tcp);
        keypair.deinit();
        global_allocator.destroy(keypair);
        global_allocator.free(pub_key);
        if (account_name.len > 0) global_allocator.free(account_name);
    }
    const creds = auth.loginWithServer(global_allocator, keypair, tcp) catch |err| {
        login_status = .failed;
        login_error_msg = @errorName(err);
        return;
    };
    defer global_allocator.free(creds.user_id);
    defer global_allocator.free(creds.access_token);

    const name = if (account_name.len > 0) account_name else creds.user_id;
    accounts.addAccount(global_allocator, name, creds.user_id, creds.access_token) catch |err| {
        login_status = .failed;
        login_error_msg = @errorName(err);
        return;
    };
    account_mgr.deinit();
    account_mgr = accounts.AccountManager.init(global_allocator);
    account_mgr.loadFromFile() catch {};
    // A freshly logged-in account is the one the user wants to use, so make it
    // active (and persist it) instead of keeping whatever was restored on load.
    _ = account_mgr.switchTo(name);
    login_result_name = global_allocator.dupe(u8, name) catch "";
    login_status = .success;
    std.debug.print("[login] success: {s}\n", .{name});
}

fn handleLoginStatus() Response {
    return switch (login_status) {
        .idle => .{ .status = 200, .body = "{\"status\":\"idle\"}" },
        .waiting => .{ .status = 200, .body = "{\"status\":\"waiting\"}" },
        .success => blk: {
            login_status = .idle;
            break :blk .{ .status = 200, .body = "{\"status\":\"success\"}" };
        },
        .failed => blk: {
            login_status = .idle;
            break :blk .{ .status = 200, .body = "{\"status\":\"failed\"}" };
        },
    };
}
