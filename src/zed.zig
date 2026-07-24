const std = @import("std");
const accounts = @import("accounts.zig");
const proxy = @import("proxy.zig");
const providers = @import("providers.zig");

const SYSTEM_ID = proxy.SYSTEM_ID;

// Re-export for server.zig
pub const initProxyPublic = proxy.init;
pub const getProxyHost = proxy.getHost;
pub const getProxyPort = proxy.getPort;
pub const buildZedPayload = providers.buildZedPayload;
pub const extractModelFromBody = providers.extractModelFromBody;

// ── Token management ──

pub fn getToken(allocator: std.mem.Allocator, acc: *accounts.Account) ![]const u8 {
    if (acc.jwt_token) |tok| {
        if (std.time.timestamp() < acc.jwt_exp - 60) return tok;
        allocator.free(tok);
        acc.jwt_token = null;
    }
    return fetchNewToken(allocator, acc);
}

fn fetchNewToken(allocator: std.mem.Allocator, acc: *accounts.Account) ![]const u8 {
    // Route the token request through the configured proxy when one is set,
    // matching the chat/model paths. Going direct here was the root cause of
    // intermittent "Token Refresh" failures in proxied environments.
    proxy.init(allocator);
    const body = if (proxy.getHost() != null)
        try fetchTokenViaProxy(allocator, acc)
    else
        try fetchTokenDirect(allocator, acc);
    defer allocator.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.TokenRefreshFailed;
    defer parsed.deinit();

    if (parsed.value != .object) return error.TokenRefreshFailed;
    const token = switch (parsed.value.object.get("token") orelse return error.NoToken) {
        .string => |s| allocator.dupe(u8, s) catch return error.TokenRefreshFailed,
        else => return error.InvalidToken,
    };

    acc.jwt_exp = parseJwtExp(token) catch 0;
    acc.jwt_token = token;
    std.debug.print("[zed] token refreshed for uid {s}\n", .{acc.user_id});
    return token;
}

/// Fetch an LLM token directly (no proxy). Returns an owned response body.
fn fetchTokenDirect(allocator: std.mem.Allocator, acc: *accounts.Account) ![]const u8 {
    const auth_header = try std.fmt.allocPrint(allocator, "{s} {s}", .{ acc.user_id, acc.credential_json });
    defer allocator.free(auth_header);

    var response_buf: std.io.Writer.Allocating = .init(allocator);
    errdefer response_buf.deinit();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = "https://cloud.zed.dev/client/llm_tokens" },
        .method = .POST,
        .payload = "",
        .response_writer = &response_buf.writer,
        .extra_headers = &.{
            .{ .name = "authorization", .value = auth_header },
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "x-zed-system-id", .value = SYSTEM_ID },
            .{ .name = "user-agent", .value = proxy.USER_AGENT },
        },
    }) catch |err| {
        std.debug.print("[zed] token fetch error: {}\n", .{err});
        response_buf.deinit();
        return error.TokenRefreshFailed;
    };

    if (result.status != .ok) {
        std.debug.print("[zed] token fetch status: {d} body: {s}\n", .{ @intFromEnum(result.status), response_buf.written() });
        response_buf.deinit();
        return error.TokenRefreshFailed;
    }
    return try response_buf.toOwnedSlice();
}

/// Fetch an LLM token via the curl proxy. Returns an owned response body.
fn fetchTokenViaProxy(allocator: std.mem.Allocator, acc: *accounts.Account) ![]const u8 {
    const p_url = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ proxy.getHost().?, proxy.getPort() });
    defer allocator.free(p_url);

    const auth_header = try std.fmt.allocPrint(allocator, "authorization: {s} {s}", .{ acc.user_id, acc.credential_json });
    defer allocator.free(auth_header);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "curl",                                    "-s",
            "-x",                                      p_url,
            "-X",                                      "POST",
            "https://cloud.zed.dev/client/llm_tokens", "-H",
            auth_header,                               "-H",
            "content-type: application/json",          "-H",
            "x-zed-system-id: " ++ SYSTEM_ID,          "-H",
            proxy.USER_AGENT_HEADER,                   "--max-time",
            "15",                                      "-w",
            "\n__HTTP_STATUS__%{http_code}",
        },
        .max_output_bytes = 1024 * 1024,
    }) catch return error.TokenRefreshFailed;
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        std.debug.print("[zed] token fetch (proxy) curl failed: {s}\n", .{result.stderr});
        allocator.free(result.stdout);
        return error.TokenRefreshFailed;
    }

    var response_body = result.stdout;
    var http_status: []const u8 = "unknown";
    if (std.mem.lastIndexOf(u8, result.stdout, "\n__HTTP_STATUS__")) |pos| {
        response_body = result.stdout[0..pos];
        http_status = result.stdout[pos + "\n__HTTP_STATUS__".len ..];
    }

    if (!std.mem.startsWith(u8, http_status, "2")) {
        std.debug.print("[zed] token fetch (proxy) status: {s} body: {s}\n", .{ http_status, response_body[0..@min(response_body.len, 300)] });
        allocator.free(result.stdout);
        return error.TokenRefreshFailed;
    }

    const owned = allocator.dupe(u8, response_body) catch {
        allocator.free(result.stdout);
        return error.TokenRefreshFailed;
    };
    allocator.free(result.stdout);
    return owned;
}

fn parseJwtExp(jwt: []const u8) !i64 {
    var parts = std.mem.splitScalar(u8, jwt, '.');
    _ = parts.next();
    const payload_b64 = parts.next() orelse return error.InvalidJwt;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(payload_b64) catch return error.InvalidJwt;
    const decoded = try std.heap.page_allocator.alloc(u8, decoded_len);
    defer std.heap.page_allocator.free(decoded);
    decoder.decode(decoded, payload_b64) catch return error.InvalidJwt;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, decoded, .{});
    defer parsed.deinit();
    return switch (parsed.value.object.get("exp") orelse return error.NoExp) {
        .integer => |i| i,
        else => error.InvalidExp,
    };
}

pub fn parseJwtClaims(allocator: std.mem.Allocator, jwt: []const u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, jwt, '.');
    _ = parts.next();
    const payload_b64 = parts.next() orelse return error.InvalidJwt;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(payload_b64) catch return error.InvalidJwt;
    const decoded = try allocator.alloc(u8, decoded_len);
    decoder.decode(decoded, payload_b64) catch {
        allocator.free(decoded);
        return error.InvalidJwt;
    };
    return decoded;
}

// ── Proxy endpoints (non-streaming) ──

pub fn proxyChatCompletions(allocator: std.mem.Allocator, acc: *accounts.Account, body: []const u8) ![]const u8 {
    return proxyChatCompletionsInner(allocator, acc, body) catch |err| {
        if (err == error.TokenExpired) {
            if (acc.jwt_token) |tok| {
                allocator.free(tok);
                acc.jwt_token = null;
            }
            std.debug.print("[zed] token expired, refreshing and retrying...\n", .{});
            return proxyChatCompletionsInner(allocator, acc, body);
        }
        return err;
    };
}

fn proxyChatCompletionsInner(allocator: std.mem.Allocator, acc: *accounts.Account, body: []const u8) ![]const u8 {
    const jwt = try getToken(allocator, acc);
    const model_name = try providers.extractModelFromBody(allocator, body);
    defer allocator.free(model_name);
    const model = providers.normalizeModelName(model_name);

    const payload = try providers.buildZedPayload(allocator, body, false);
    defer allocator.free(payload);

    const response = try proxy.sendToZed(allocator, jwt, payload);
    defer allocator.free(response);
    return try providers.convertToOpenAI(allocator, response, model);
}

pub fn proxyResponses(allocator: std.mem.Allocator, acc: *accounts.Account, body: []const u8) ![]const u8 {
    return proxyResponsesInner(allocator, acc, body) catch |err| {
        if (err == error.TokenExpired) {
            if (acc.jwt_token) |tok| {
                allocator.free(tok);
                acc.jwt_token = null;
            }
            std.debug.print("[zed] token expired, refreshing and retrying Responses request...\n", .{});
            return proxyResponsesInner(allocator, acc, body);
        }
        return err;
    };
}

fn proxyResponsesInner(allocator: std.mem.Allocator, acc: *accounts.Account, body: []const u8) ![]const u8 {
    const jwt = try getToken(allocator, acc);
    const model_name = try providers.extractModelFromBody(allocator, body);
    defer allocator.free(model_name);
    const model = providers.normalizeModelName(model_name);

    const payload = try providers.buildZedPayload(allocator, body, false);
    defer allocator.free(payload);

    const response = try proxy.sendToZed(allocator, jwt, payload);
    defer allocator.free(response);
    return try providers.convertToResponses(allocator, response, model);
}

pub fn proxyMessages(allocator: std.mem.Allocator, acc: *accounts.Account, body: []const u8) ![]const u8 {
    return proxyMessagesInner(allocator, acc, body) catch |err| {
        if (err == error.TokenExpired) {
            if (acc.jwt_token) |tok| {
                allocator.free(tok);
                acc.jwt_token = null;
            }
            std.debug.print("[zed] token expired, refreshing and retrying...\n", .{});
            return proxyMessagesInner(allocator, acc, body);
        }
        return err;
    };
}

fn proxyMessagesInner(allocator: std.mem.Allocator, acc: *accounts.Account, body: []const u8) ![]const u8 {
    const jwt = try getToken(allocator, acc);
    const model_name = try providers.extractModelFromBody(allocator, body);
    defer allocator.free(model_name);
    const model = providers.normalizeModelName(model_name);

    const payload = try providers.buildZedPayload(allocator, body, true);
    defer allocator.free(payload);

    const response = try proxy.sendToZed(allocator, jwt, payload);
    defer allocator.free(response);
    return try providers.convertToAnthropic(allocator, response, model);
}

// ── Models ──

pub fn fetchModels(allocator: std.mem.Allocator, acc: *accounts.Account) ![]const u8 {
    const jwt = try getToken(allocator, acc);
    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{jwt});
    defer allocator.free(bearer);

    proxy.init(allocator);

    if (proxy.getHost()) |_| {
        return fetchModelsViaProxy(allocator, bearer);
    } else {
        return fetchModelsDirect(allocator, bearer);
    }
}

fn fetchModelsViaProxy(allocator: std.mem.Allocator, bearer: []const u8) ![]const u8 {
    const p_url = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ proxy.getHost().?, proxy.getPort() });
    defer allocator.free(p_url);

    const auth_header = try std.fmt.allocPrint(allocator, "authorization: {s}", .{bearer});
    defer allocator.free(auth_header);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "curl",                         "-s",
            "-x",                           p_url,
            "https://cloud.zed.dev/models", "-H",
            auth_header,                    "-H",
            proxy.ZED_VERSION_HEADER,       "-H",
            proxy.USER_AGENT_HEADER,        "--max-time",
            "15",
        },
        .max_output_bytes = 1024 * 1024,
    }) catch return error.UpstreamError;
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.UpstreamError;
    }
    if (result.stdout.len == 0 or !std.mem.startsWith(u8, result.stdout, "{")) {
        allocator.free(result.stdout);
        return error.UpstreamError;
    }
    return result.stdout;
}

fn fetchModelsDirect(allocator: std.mem.Allocator, bearer: []const u8) ![]const u8 {
    var response_buf: std.io.Writer.Allocating = .init(allocator);
    errdefer response_buf.deinit();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = "https://cloud.zed.dev/models" },
        .method = .GET,
        .response_writer = &response_buf.writer,
        .extra_headers = &.{
            .{ .name = "authorization", .value = bearer },
            .{ .name = "x-zed-version", .value = proxy.ZED_VERSION },
            .{ .name = "user-agent", .value = proxy.USER_AGENT },
        },
    }) catch return error.UpstreamError;

    if (result.status != .ok) {
        response_buf.deinit();
        return error.UpstreamError;
    }
    return try response_buf.toOwnedSlice();
}

// ── Billing ──

pub fn fetchBillingUsage(allocator: std.mem.Allocator, acc: *accounts.Account) ![]const u8 {
    proxy.init(allocator);
    if (proxy.getHost() != null) return fetchBillingViaProxy(allocator, acc);
    return fetchBillingDirect(allocator, acc);
}

fn fetchBillingViaProxy(allocator: std.mem.Allocator, acc: *accounts.Account) ![]const u8 {
    const p_url = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ proxy.getHost().?, proxy.getPort() });
    defer allocator.free(p_url);

    const auth_header = try std.fmt.allocPrint(allocator, "authorization: {s} {s}", .{ acc.user_id, acc.credential_json });
    defer allocator.free(auth_header);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "curl",                                  "-s",
            "-x",                                    p_url,
            "https://cloud.zed.dev/client/users/me", "-H",
            auth_header,                             "-H",
            "accept: application/json",              "-H",
            "content-type: application/json",        "-H",
            proxy.USER_AGENT_HEADER,                 "--max-time",
            "15",                                    "-w",
            "\n__HTTP_STATUS__%{http_code}",
        },
        .max_output_bytes = 1024 * 1024,
    }) catch return error.BillingFetchFailed;
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.BillingFetchFailed;
    }

    var response_body = result.stdout;
    var http_status: []const u8 = "unknown";
    if (std.mem.lastIndexOf(u8, result.stdout, "\n__HTTP_STATUS__")) |pos| {
        response_body = result.stdout[0..pos];
        http_status = result.stdout[pos + "\n__HTTP_STATUS__".len ..];
    }

    if (!std.mem.startsWith(u8, http_status, "2")) {
        std.debug.print("[zed] users/me (proxy) failed {s}: {s}\n", .{ http_status, response_body[0..@min(response_body.len, 300)] });
        allocator.free(result.stdout);
        return error.BillingFetchFailed;
    }

    const owned = allocator.dupe(u8, response_body) catch {
        allocator.free(result.stdout);
        return error.BillingFetchFailed;
    };
    allocator.free(result.stdout);
    return owned;
}

fn fetchBillingDirect(allocator: std.mem.Allocator, acc: *accounts.Account) ![]const u8 {
    const auth_header = try std.fmt.allocPrint(allocator, "{s} {s}", .{ acc.user_id, acc.credential_json });
    defer allocator.free(auth_header);

    var response_buf: std.io.Writer.Allocating = .init(allocator);
    errdefer response_buf.deinit();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = "https://cloud.zed.dev/client/users/me" },
        .method = .GET,
        .response_writer = &response_buf.writer,
        .extra_headers = &.{
            .{ .name = "authorization", .value = auth_header },
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "user-agent", .value = proxy.USER_AGENT },
        },
    });

    if (result.status != .ok) {
        const err_body = response_buf.written();
        std.debug.print("[zed] users/me failed {}: {s}\n", .{ result.status, err_body });
        response_buf.deinit();
        return error.BillingFetchFailed;
    }
    return try response_buf.toOwnedSlice();
}
