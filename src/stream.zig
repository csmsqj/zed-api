const std = @import("std");
const accounts = @import("accounts.zig");
const zed = @import("zed.zig");
const proxy = @import("proxy.zig");
const providers = @import("providers.zig");
const socket = @import("socket.zig");

/// Tracks which Anthropic content block is currently open while converting an
/// OpenAI Responses event stream (reasoning/text/tool come as separate items).
const OaKind = enum { none, text, thinking, tool };

/// State needed while translating an upstream Anthropic/Responses stream to
/// OpenAI Chat Completions chunks for OpenCode and other OpenAI-compatible
/// clients.
const ChatStreamState = struct {
    tool_count: usize = 0,
    active_tool_index: ?usize = null,
    has_tool_use: bool = false,
};

fn writeOpenAIChatChunkPrefix(w: *std.io.Writer, model: []const u8) !void {
    try w.print("data: {{\"id\":\"chatcmpl-zed\",\"object\":\"chat.completion.chunk\",\"created\":{d},\"model\":", .{std.time.timestamp()});
    try std.json.Stringify.encodeJsonString(model, .{}, w);
    try w.writeAll(",\"choices\":[{\"index\":0,\"delta\":");
}

fn sendOpenAIChatField(client_stream: std.net.Stream, model: []const u8, field: []const u8, value: []const u8, allocator: std.mem.Allocator) !void {
    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;
    try writeOpenAIChatChunkPrefix(w, model);
    try w.writeAll("{");
    try std.json.Stringify.encodeJsonString(field, .{}, w);
    try w.writeAll(":");
    try std.json.Stringify.encodeJsonString(value, .{}, w);
    try w.writeAll("},\"finish_reason\":null}]}\n\n");
    try socket.send(client_stream, buf.written());
}

fn sendOpenAIChatDelta(client_stream: std.net.Stream, model: []const u8, delta: std.json.Value, allocator: std.mem.Allocator) !void {
    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;
    try writeOpenAIChatChunkPrefix(w, model);
    try std.json.Stringify.value(delta, .{}, w);
    try w.writeAll(",\"finish_reason\":null}]}\n\n");
    try socket.send(client_stream, buf.written());
}

fn sendOpenAIChatToolStart(client_stream: std.net.Stream, model: []const u8, index: usize, item: std.json.Value, allocator: std.mem.Allocator) !void {
    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;
    try writeOpenAIChatChunkPrefix(w, model);
    try w.print("{{\"tool_calls\":[{{\"index\":{d}", .{index});
    if (item.object.get("call_id") orelse item.object.get("id")) |id| {
        try w.writeAll(",\"id\":");
        try std.json.Stringify.value(id, .{}, w);
    }
    try w.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
    if (item.object.get("name")) |name| {
        try std.json.Stringify.value(name, .{}, w);
    } else {
        try w.writeAll("\"\"");
    }
    try w.writeAll(",\"arguments\":\"\"}}]},\"finish_reason\":null}]}\n\n");
    try socket.send(client_stream, buf.written());
}

fn sendOpenAIChatToolArguments(client_stream: std.net.Stream, model: []const u8, index: usize, arguments: []const u8, allocator: std.mem.Allocator) !void {
    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;
    try writeOpenAIChatChunkPrefix(w, model);
    try w.print("{{\"tool_calls\":[{{\"index\":{d},\"function\":{{\"arguments\":", .{index});
    try std.json.Stringify.encodeJsonString(arguments, .{}, w);
    try w.writeAll("}}]},\"finish_reason\":null}]}\n\n");
    try socket.send(client_stream, buf.written());
}

fn sendOpenAIChatFinish(client_stream: std.net.Stream, model: []const u8, has_tool_use: bool, allocator: std.mem.Allocator) !void {
    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;
    try writeOpenAIChatChunkPrefix(w, model);
    try w.writeAll("{},\"finish_reason\":\"");
    try w.writeAll(if (has_tool_use) "tool_calls" else "stop");
    try w.writeAll("\"}]}\n\ndata: [DONE]\n\n");
    try socket.send(client_stream, buf.written());
}

fn oaCloseBlock(cs: std.net.Stream, block_index: *usize, open_block_idx: *?usize) !void {
    if (open_block_idx.*) |oidx| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "event: content_block_stop\ndata: {{\"type\":\"content_block_stop\",\"index\":{d}}}\n\n", .{oidx}) catch return;
        try socket.send(cs, msg);
        open_block_idx.* = null;
        block_index.* += 1;
    }
}

/// Open a simple text/thinking block (content_block type == field name).
fn oaOpenSimple(cs: std.net.Stream, field: []const u8, block_index: *usize, open_block_idx: *?usize) !void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "event: content_block_start\ndata: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"{s}\",\"{s}\":\"\"}}}}\n\n", .{ block_index.*, field, field }) catch return;
    try socket.send(cs, msg);
    open_block_idx.* = block_index.*;
}

fn oaEnsureSimple(cs: std.net.Stream, want: OaKind, field: []const u8, block_index: *usize, open_block_idx: *?usize, open_kind: *OaKind) !void {
    if (open_kind.* == want) return;
    try oaCloseBlock(cs, block_index, open_block_idx);
    try oaOpenSimple(cs, field, block_index, open_block_idx);
    open_kind.* = want;
}

fn oaEmitDelta(cs: std.net.Stream, delta_type: []const u8, field: []const u8, value: []const u8, block_index: *usize, allocator: std.mem.Allocator) !void {
    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;
    try w.print("event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{{\"type\":\"{s}\",\"{s}\":", .{ block_index.*, delta_type, field });
    try std.json.Stringify.encodeJsonString(value, .{}, w);
    try w.writeAll("}}\n\n");
    try socket.send(cs, buf.written());
}

/// Outcome of a single streaming attempt against one account.
/// `committed` is true once we've sent SSE headers/data to the client, meaning
/// we can no longer fail over (the client already received a 200 + partial
/// body). `kind`/`status` describe the failure for the health scheduler.
const StreamResult = struct {
    ok: bool,
    committed: bool = false,
    /// The upstream accepted the request with HTTP 200 but closed the stream
    /// before emitting a single model event. Zed occasionally produces this
    /// transient empty stream; it is safe to retry only while the client has
    /// not received response headers or SSE data.
    empty_stream: bool = false,
    kind: accounts.FailureKind = .transient,
    status: u16 = 0,
};

/// Number of additional attempts for a transient HTTP-200 empty stream.
/// Three total attempts absorb Zed's occasional empty first response while
/// keeping a permanently broken request bounded and observable.
const EMPTY_STREAM_RETRY_LIMIT: usize = 2;

fn shouldRetryEmptyStream(result: StreamResult, retries_used: usize) bool {
    return result.empty_stream and
        !result.committed and
        retries_used < EMPTY_STREAM_RETRY_LIMIT;
}

/// Handle streaming proxy with account failover
pub fn handleStreamProxy(
    client_stream: std.net.Stream,
    body: []const u8,
    is_anthropic: bool,
    is_responses: bool,
    account_mgr: *accounts.AccountManager,
    allocator: std.mem.Allocator,
) void {
    if (account_mgr.list.items.len == 0) {
        socket.writeResponse(client_stream, 400, "{\"error\":\"no account configured\"}");
        return;
    }

    var try_order: [64]usize = undefined;
    const count = account_mgr.buildTryOrder(&try_order);

    var last: StreamResult = .{ .ok = false, .kind = .transient, .status = 0 };
    for (try_order[0..count]) |acc_idx| {
        const acc = &account_mgr.list.items[acc_idx];
        if (!accounts.AccountManager.isAvailable(acc))
            std.debug.print("[zed2api] stream: account '{s}' benched (retry in {d}s), trying anyway\n", .{ acc.name, acc.disabled_until - std.time.timestamp() });

        var retries_used: usize = 0;
        while (true) {
            const res = doStreamProxy(client_stream, acc, body, is_anthropic, is_responses, allocator);
            last = res;
            if (res.ok) {
                accounts.AccountManager.markSuccess(acc, if (res.status != 0) res.status else 200);
                if (acc_idx != account_mgr.current) {
                    std.debug.print("[zed2api] stream failover: switched to '{s}'\n", .{acc.name});
                    account_mgr.setCurrent(acc_idx);
                }
                return;
            }

            if (shouldRetryEmptyStream(res, retries_used)) {
                retries_used += 1;
                std.debug.print("[zed2api] stream: account '{s}' returned an empty HTTP 200 stream; retry {d}/{d}\n", .{ acc.name, retries_used, EMPTY_STREAM_RETRY_LIMIT });
                // A short delay avoids immediately hitting the same transient
                // upstream worker while adding negligible latency to recovery.
                std.Thread.sleep(250_000_000);
                continue;
            }

            accounts.AccountManager.markFailure(acc, res.kind, res.status);
            std.debug.print("[zed2api] stream: account '{s}' failed (kind={s}, status={d}, benched {d}s)\n", .{ acc.name, @tagName(res.kind), res.status, @max(acc.disabled_until - std.time.timestamp(), 0) });

            // If we already streamed data to the client we cannot retry another
            // account on the same HTTP response.
            if (res.committed) return;
            break;
        }
    }

    const code: u16 = if (last.status != 0) last.status else 502;
    socket.writeResponse(client_stream, code, "{\"error\":{\"message\":\"All accounts failed\",\"type\":\"upstream_error\"}}");
}

fn doStreamProxy(client_stream: std.net.Stream, acc: *accounts.Account, body: []const u8, is_anthropic: bool, is_responses: bool, allocator: std.mem.Allocator) StreamResult {
    const payload = providers.buildZedPayload(allocator, body, is_anthropic) catch |err| {
        std.debug.print("[stream] buildZedPayload failed: {}\n", .{err});
        return .{ .ok = false, .kind = .transient, .status = 0 };
    };
    defer allocator.free(payload);

    const jwt = zed.getToken(allocator, acc) catch |err| {
        std.debug.print("[stream] getToken failed: {}\n", .{err});
        // Token refresh failure = bad/expired credential or banned account.
        return .{ .ok = false, .kind = .auth, .status = 401 };
    };
    const bearer = std.fmt.allocPrint(allocator, "Bearer {s}", .{jwt}) catch return .{ .ok = false, .kind = .transient };
    defer allocator.free(bearer);

    const auth_header = std.fmt.allocPrint(allocator, "authorization: {s}", .{bearer}) catch return .{ .ok = false, .kind = .transient };
    defer allocator.free(auth_header);

    proxy.init(allocator);

    // Write payload to temp file
    var tmp_name_buf: [64]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_name_buf, "zed2api_stream_{d}.json", .{std.time.milliTimestamp()}) catch "zed2api_stream_req.json";
    {
        const f = std.fs.cwd().createFile(tmp_path, .{}) catch return .{ .ok = false, .kind = .transient };
        defer f.close();
        f.writeAll(payload) catch return .{ .ok = false, .kind = .transient };
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const at_path = std.fmt.allocPrint(allocator, "@{s}", .{tmp_path}) catch return .{ .ok = false, .kind = .transient };
    defer allocator.free(at_path);

    const proxy_url = if (proxy.getHost()) |host|
        (std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ host, proxy.getPort() }) catch return .{ .ok = false, .kind = .transient })
    else
        null;
    defer if (proxy_url) |p| allocator.free(p);

    var argv_buf: [26][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "curl";
    argc += 1;
    argv_buf[argc] = "-siN";
    argc += 1;
    argv_buf[argc] = "--suppress-connect-headers";
    argc += 1;
    if (proxy_url) |p| {
        argv_buf[argc] = "-x";
        argc += 1;
        argv_buf[argc] = p;
        argc += 1;
    }
    argv_buf[argc] = "-X";
    argc += 1;
    argv_buf[argc] = "POST";
    argc += 1;
    argv_buf[argc] = "https://cloud.zed.dev/completions";
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = auth_header;
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = "content-type: application/json";
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = proxy.ZED_VERSION_HEADER;
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = proxy.CLIENT_SUPPORTS_STATUS_MESSAGES_HEADER;
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = proxy.CLIENT_SUPPORTS_STREAM_ENDED_HEADER;
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = proxy.USER_AGENT_HEADER;
    argc += 1;
    argv_buf[argc] = "--data-binary";
    argc += 1;
    argv_buf[argc] = at_path;
    argc += 1;
    argv_buf[argc] = "--max-time";
    argc += 1;
    argv_buf[argc] = "300";
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch return .{ .ok = false, .kind = .transient };
    var child_reaped = false;
    defer {
        // Client cancellation, socket write failure, or a local parse error must
        // not leave curl and its upstream connection alive until --max-time.
        if (!child_reaped) {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }
    }

    const stdout = child.stdout orelse {
        return .{ .ok = false, .kind = .transient };
    };

    var line_buf: [65536]u8 = undefined;
    var line_len: usize = 0;
    var block_index: usize = 0;
    var got_any_data = false;
    var headers_sent = false;
    var has_tool_use = false;
    var open_block_idx: ?usize = null;
    var oa_kind: OaKind = .none;
    var chat_state: ChatStreamState = .{};
    var http_headers_done = false;
    var http_status: u16 = 0;
    // Remember whether an upstream error body mentioned the plan, so a 403 for
    // "model not in plan" is treated as model-level (fail over, don't bench)
    // rather than an account ban.
    var saw_plan_error = false;
    // 上游发出 {"status":"stream_ended"} 后置为 true：完整回答已 relay 完毕，
    // 需主动终止 curl 子进程，否则它会为 --max-time(300s) 一直挂着阻塞收尾。
    var ended_by_marker = false;

    const model_owned = providers.extractModelFromBody(allocator, body) catch null;
    defer if (model_owned) |value| allocator.free(value);
    const model = providers.normalizeModelName(model_owned orelse "claude-sonnet-5");

    while (true) {
        var one: [1]u8 = undefined;
        const n = stdout.read(&one) catch break;
        if (n == 0) break;

        if (one[0] == '\n') {
            if (!http_headers_done) {
                // Parse HTTP response headers from curl -i
                const line = line_buf[0..line_len];
                // Trim trailing \r
                const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
                if (trimmed.len == 0) {
                    // Empty line = end of HTTP headers
                    http_headers_done = true;
                    if (http_status != 0 and http_status != 200) {
                        std.debug.print("[stream] upstream HTTP {d}\n", .{http_status});
                    }
                } else if (std.mem.startsWith(u8, trimmed, "HTTP/")) {
                    // Parse status code from "HTTP/1.1 200 OK" or "HTTP/2 200"
                    var parts = std.mem.splitScalar(u8, trimmed, ' ');
                    _ = parts.next(); // skip HTTP/x.x
                    if (parts.next()) |code_str| {
                        http_status = std.fmt.parseInt(u16, code_str, 10) catch 0;
                    }
                }
                line_len = 0;
                continue;
            }

            if (line_len > 0) {
                const line = line_buf[0..line_len];
                // The marker is protocol metadata, not a model event. Detect it
                // structurally before sending SSE headers or counting data.
                if (line[0] == '{' and
                    std.mem.indexOf(u8, line, "\"status\"") != null and
                    std.mem.indexOf(u8, line, "\"stream_ended\"") != null and
                    isStreamEndedMarker(line, allocator))
                {
                    line_len = 0;
                    ended_by_marker = true;
                    break;
                }
                if (line[0] == '{') {
                    // Check if this is an error response (non-200 status)
                    if (http_status != 0 and http_status != 200) {
                        std.debug.print("[stream] upstream error HTTP {d}: {s}\n", .{ http_status, line[0..@min(line.len, 500)] });
                        if (std.mem.indexOf(u8, line, "plan") != null) saw_plan_error = true;
                        line_len = 0;
                        continue;
                    }
                    if (!headers_sent) {
                        headers_sent = true;
                        // This server handles one request per TCP connection and
                        // closes it after the stream. Advertising `close` gives
                        // HTTP/1.1 clients and local proxies an unambiguous body
                        // boundary (there is no Content-Length/chunked framing).
                        const sse_header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: *\r\n\r\n";
                        socket.send(client_stream, sse_header) catch {
                            return .{ .ok = false, .committed = true, .kind = .transient };
                        };
                        if (is_anthropic) {
                            var msg_start_buf: [512]u8 = undefined;
                            const msg_start = std.fmt.bufPrint(&msg_start_buf, "event: message_start\ndata: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_zed\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"{s}\",\"content\":[],\"stop_reason\":null,\"usage\":{{\"input_tokens\":0,\"output_tokens\":0}}}}}}\n\n", .{model}) catch "";
                            socket.send(client_stream, msg_start) catch {};
                        } else if (!is_responses) {
                            sendOpenAIChatField(client_stream, model, "role", "assistant", allocator) catch
                                return .{ .ok = false, .committed = true, .kind = .transient, .status = http_status };
                        }
                    }
                    got_any_data = true;
                    if (is_responses) {
                        passThroughResponsesSSE(client_stream, line, allocator) catch
                            return .{ .ok = false, .committed = true, .kind = .transient, .status = http_status };
                    } else if (!is_anthropic) {
                        convertAndSendOpenAIChatSSE(client_stream, line, model, &chat_state, allocator) catch
                            return .{ .ok = false, .committed = true, .kind = .transient, .status = http_status };
                    } else {
                        convertAndSendSSE(client_stream, line, &block_index, &has_tool_use, &open_block_idx, &oa_kind, allocator) catch
                            return .{ .ok = false, .committed = true, .kind = .transient, .status = http_status };
                    }
                } else {
                    if (http_status != 0 and http_status != 200 and std.mem.indexOf(u8, line, "plan") != null) saw_plan_error = true;
                    std.debug.print("[stream] non-JSON from upstream ({d} bytes): {s}\n", .{ line.len, line[0..@min(line.len, 500)] });
                }
            }
            line_len = 0;
        } else {
            if (line_len < line_buf.len) {
                line_buf[line_len] = one[0];
                line_len += 1;
            }
        }
    }

    if (headers_sent and is_anthropic) {
        if (open_block_idx) |oidx| {
            var cbs_buf: [128]u8 = undefined;
            const cbs = std.fmt.bufPrint(&cbs_buf, "event: content_block_stop\ndata: {{\"type\":\"content_block_stop\",\"index\":{d}}}\n\n", .{oidx}) catch "";
            socket.send(client_stream, cbs) catch {};
            open_block_idx = null;
        }
        const stop_reason = if (has_tool_use) "tool_use" else "end_turn";
        var stop_buf: [256]u8 = undefined;
        const stop_msg = std.fmt.bufPrint(&stop_buf, "event: message_delta\ndata: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n", .{stop_reason}) catch "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n";
        socket.send(client_stream, stop_msg) catch {};
        socket.send(client_stream, "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n") catch {};
    } else if (headers_sent and !is_responses) {
        sendOpenAIChatFinish(client_stream, model, chat_state.has_tool_use, allocator) catch
            return .{ .ok = false, .committed = true, .kind = .transient, .status = http_status };
    }

    // 修复：stream_ended 到达 → 回答已完整 relay 给客户端。但 curl 子进程访问的
    // 上游 HTTP/2 连接被保活、永不发 EOF，子进程会一直挂到 --max-time(300s)，使
    // 下面的 stderr 读取与 child.wait() 阻塞同样时长——连接迟迟不关闭，客户端空等
    // 到自身超时，且服务端线程/curl 进程/上游连接持续泄漏（高并发下耗尽资源、触发
    // 上游风控）。成功路径无需 stderr 诊断，直接终止子进程并回收后返回：
    //   kill() 用 TerminateProcess 立即杀死 curl（不再等 300s）；随后 wait() 走
    //   self.term 已设置的幂等分支执行 cleanupStreams()，关闭 stdout/stderr 管道
    //   避免 fd 泄漏。
    if (ended_by_marker) {
        _ = child.kill() catch {};
        if (child.wait()) |_| {
            child_reaped = true;
        } else |_| {}
        std.debug.print("[stream] done, {d} blocks (stream_ended, curl killed)\n", .{block_index});
        return streamOutcome(got_any_data, headers_sent, http_status, saw_plan_error, line_buf[0..line_len]);
    }

    const stderr_pipe = child.stderr;
    var stderr_buf: [2048]u8 = undefined;
    var stderr_len: usize = 0;
    if (stderr_pipe) |sp| {
        stderr_len = sp.read(&stderr_buf) catch 0;
    }
    const term = child.wait() catch {
        std.debug.print("[stream] done, {d} blocks, headers_sent={}, wait failed\n", .{ block_index, headers_sent });
        return streamOutcome(got_any_data, headers_sent, http_status, saw_plan_error, line_buf[0..line_len]);
    };
    child_reaped = true;
    const exit_code: u32 = switch (term) {
        .Exited => |c| c,
        else => 999,
    };
    if (!got_any_data or exit_code != 0) {
        std.debug.print("[stream] done, {d} blocks, headers_sent={}, curl exit={d}, http={d}, stderr={s}\n", .{ block_index, headers_sent, exit_code, http_status, stderr_buf[0..stderr_len] });
        // If we got no data, print any remaining buffered content for debugging
        if (!got_any_data and line_len > 0) {
            if (http_status != 0 and http_status != 200 and std.mem.indexOf(u8, line_buf[0..line_len], "plan") != null) saw_plan_error = true;
            std.debug.print("[stream] remaining buffer ({d} bytes): {s}\n", .{ line_len, line_buf[0..@min(line_len, 500)] });
        }
    } else {
        std.debug.print("[stream] done, {d} blocks\n", .{block_index});
    }
    return streamOutcome(got_any_data, headers_sent, http_status, saw_plan_error, line_buf[0..line_len]);
}

/// Match only Zed's top-level completion marker. A model is allowed to output
/// the literal text "stream_ended" inside a normal delta; substring matching
/// would truncate such a valid response.
fn isStreamEndedMarker(line: []const u8, allocator: std.mem.Allocator) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const status = parsed.value.object.get("status") orelse return false;
    return status == .string and std.mem.eql(u8, status.string, "stream_ended");
}

test "stream-ended marker is matched structurally" {
    const allocator = std.testing.allocator;
    try std.testing.expect(isStreamEndedMarker("{\"status\":\"stream_ended\"}", allocator));
    try std.testing.expect(!isStreamEndedMarker("{\"event\":{\"type\":\"response.output_text.delta\",\"delta\":\"stream_ended\"}}", allocator));
    try std.testing.expect(!isStreamEndedMarker("{\"status\":\"in_progress\"}", allocator));
}

/// Zed wraps each OpenAI Responses event in an `event` object and emits one
/// JSON object per line. Codex expects standard SSE, so unwrap and frame it
/// without changing the actual Responses event payload.
fn passThroughResponsesSSE(client_stream: std.net.Stream, line: []const u8, allocator: std.mem.Allocator) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;

    const event_value = parsed.value.object.get("event") orelse parsed.value;
    if (event_value != .object) return;
    const event_type = switch (event_value.object.get("type") orelse return) {
        .string => |s| s,
        else => return,
    };

    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try buf.writer.print("event: {s}\ndata: ", .{event_type});
    try std.json.Stringify.value(event_value, .{}, &buf.writer);
    try buf.writer.writeAll("\n\n");
    try socket.send(client_stream, buf.written());
}

/// Translate one upstream event into an OpenAI Chat Completions SSE chunk.
/// GPT models arrive as Responses events, while Sonnet arrives as Anthropic
/// events; both forms are accepted so OpenCode can switch models without
/// changing provider protocol.
fn convertAndSendOpenAIChatSSE(client_stream: std.net.Stream, line: []const u8, model: []const u8, state: *ChatStreamState, allocator: std.mem.Allocator) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;

    const obj = if (parsed.value.object.get("event")) |event|
        (if (event == .object) event else parsed.value)
    else
        parsed.value;
    if (obj != .object) return;

    if (obj.object.get("type")) |event_type_value| {
        if (event_type_value == .string) {
            const event_type = event_type_value.string;

            if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
                if (obj.object.get("delta")) |delta| {
                    if (delta == .string and delta.string.len > 0)
                        try sendOpenAIChatField(client_stream, model, "content", delta.string, allocator);
                }
                return;
            }

            if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta") or
                std.mem.eql(u8, event_type, "response.reasoning_text.delta"))
            {
                if (obj.object.get("delta")) |delta| {
                    if (delta == .string and delta.string.len > 0)
                        try sendOpenAIChatField(client_stream, model, "reasoning_content", delta.string, allocator);
                }
                return;
            }

            if (std.mem.eql(u8, event_type, "response.output_item.added")) {
                const item = obj.object.get("item") orelse return;
                if (item != .object) return;
                const item_type = switch (item.object.get("type") orelse return) {
                    .string => |value| value,
                    else => return,
                };
                if (!std.mem.eql(u8, item_type, "function_call")) return;
                const index = state.tool_count;
                state.tool_count += 1;
                state.active_tool_index = index;
                state.has_tool_use = true;
                try sendOpenAIChatToolStart(client_stream, model, index, item, allocator);
                return;
            }

            if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
                const index = state.active_tool_index orelse return;
                if (obj.object.get("delta")) |delta| {
                    if (delta == .string and delta.string.len > 0)
                        try sendOpenAIChatToolArguments(client_stream, model, index, delta.string, allocator);
                }
                return;
            }

            if (std.mem.eql(u8, event_type, "response.function_call_arguments.done") or
                std.mem.eql(u8, event_type, "response.output_item.done"))
            {
                state.active_tool_index = null;
                return;
            }

            // Native Anthropic stream from Sonnet 5.
            if (std.mem.eql(u8, event_type, "content_block_start")) {
                const content_block = obj.object.get("content_block") orelse return;
                if (content_block != .object) return;
                const block_type = switch (content_block.object.get("type") orelse return) {
                    .string => |value| value,
                    else => return,
                };
                if (!std.mem.eql(u8, block_type, "tool_use")) return;
                const index = state.tool_count;
                state.tool_count += 1;
                state.active_tool_index = index;
                state.has_tool_use = true;
                try sendOpenAIChatToolStart(client_stream, model, index, content_block, allocator);
                return;
            }

            if (std.mem.eql(u8, event_type, "content_block_delta")) {
                const delta = obj.object.get("delta") orelse return;
                if (delta != .object) return;
                const delta_type = switch (delta.object.get("type") orelse return) {
                    .string => |value| value,
                    else => return,
                };
                if (std.mem.eql(u8, delta_type, "text_delta")) {
                    if (delta.object.get("text")) |text| {
                        if (text == .string and text.string.len > 0)
                            try sendOpenAIChatField(client_stream, model, "content", text.string, allocator);
                    }
                } else if (std.mem.eql(u8, delta_type, "thinking_delta")) {
                    if (delta.object.get("thinking")) |thinking| {
                        if (thinking == .string and thinking.string.len > 0)
                            try sendOpenAIChatField(client_stream, model, "reasoning_content", thinking.string, allocator);
                    }
                } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
                    const index = state.active_tool_index orelse return;
                    if (delta.object.get("partial_json")) |partial_json| {
                        if (partial_json == .string and partial_json.string.len > 0)
                            try sendOpenAIChatToolArguments(client_stream, model, index, partial_json.string, allocator);
                    }
                }
                return;
            }

            if (std.mem.eql(u8, event_type, "content_block_stop")) {
                state.active_tool_index = null;
                return;
            }
        }
    }

    // xAI already emits Chat Completions choices; keep its delta object.
    if (obj.object.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0) {
            const choice = choices.array.items[0];
            if (choice == .object) {
                if (choice.object.get("delta")) |delta| {
                    if (delta == .object) {
                        if (delta.object.get("tool_calls") != null) state.has_tool_use = true;
                        try sendOpenAIChatDelta(client_stream, model, delta, allocator);
                    }
                }
            }
        }
        return;
    }

    // Google stream -> ordinary Chat Completions text delta.
    if (obj.object.get("candidates")) |candidates| {
        if (candidates == .array and candidates.array.items.len > 0) {
            const candidate = candidates.array.items[0];
            if (candidate == .object) {
                if (candidate.object.get("content")) |content| {
                    if (content == .object) {
                        if (content.object.get("parts")) |parts| {
                            if (parts == .array) for (parts.array.items) |part| {
                                if (part != .object) continue;
                                if (part.object.get("text")) |text| {
                                    if (text == .string and text.string.len > 0)
                                        try sendOpenAIChatField(client_stream, model, "content", text.string, allocator);
                                }
                            };
                        }
                    }
                }
            }
        }
    }
}

/// Turn the raw streaming state into a StreamResult for the health scheduler.
fn streamOutcome(got_any_data: bool, headers_sent: bool, http_status: u16, saw_plan_error: bool, tail: []const u8) StreamResult {
    if (got_any_data) return .{ .ok = true, .committed = headers_sent, .status = if (http_status == 0) 200 else http_status };

    const plan = saw_plan_error or (http_status == 403 and std.mem.indexOf(u8, tail, "plan") != null);
    const kind: accounts.FailureKind = switch (http_status) {
        401 => .auth,
        403 => if (plan) .transient else .auth, // "not in plan" is model-level
        429 => .rate_limit,
        else => .transient, // 5xx / network / empty
    };
    return .{
        .ok = false,
        .committed = headers_sent,
        .empty_stream = http_status == 200,
        .kind = kind,
        .status = http_status,
    };
}

test "empty HTTP 200 stream is retried only before client commit" {
    const result = streamOutcome(false, false, 200, false, "");
    try std.testing.expect(!result.ok);
    try std.testing.expect(result.empty_stream);
    try std.testing.expect(shouldRetryEmptyStream(result, 0));
    try std.testing.expect(shouldRetryEmptyStream(result, 1));
    try std.testing.expect(!shouldRetryEmptyStream(result, EMPTY_STREAM_RETRY_LIMIT));

    var committed = result;
    committed.committed = true;
    try std.testing.expect(!shouldRetryEmptyStream(committed, 0));
}

test "HTTP error and successful event stream are not empty-stream retries" {
    const upstream_error = streamOutcome(false, false, 502, false, "bad gateway");
    try std.testing.expect(!upstream_error.empty_stream);
    try std.testing.expect(!shouldRetryEmptyStream(upstream_error, 0));

    const success = streamOutcome(true, true, 200, false, "");
    try std.testing.expect(success.ok);
    try std.testing.expect(!success.empty_stream);
    try std.testing.expect(!shouldRetryEmptyStream(success, 0));
}

/// Convert a single Zed streaming JSON line to Anthropic SSE events
fn convertAndSendSSE(client_stream: std.net.Stream, line: []const u8, block_index: *usize, has_tool_use: *bool, open_block_idx: *?usize, oa_kind: *OaKind, allocator: std.mem.Allocator) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return;
    defer parsed.deinit();

    const obj = if (parsed.value.object.get("event")) |event|
        (if (event == .object) event else parsed.value)
    else
        parsed.value;

    if (obj.object.get("type")) |et_val| {
        if (et_val == .string) {
            const event_type = et_val.string;

            if (std.mem.eql(u8, event_type, "message_start")) {
                if (obj.object.get("message")) |msg| {
                    if (msg == .object) {
                        if (msg.object.get("model")) |m| {
                            if (m == .string) std.debug.print("[stream] zed returned model: {s}\n", .{m.string});
                        }
                    }
                }
                return;
            }

            if (std.mem.eql(u8, event_type, "content_block_start")) {
                const cb = obj.object.get("content_block") orelse return;
                if (cb != .object) return;
                const cb_type = switch (cb.object.get("type") orelse return) {
                    .string => |s| s,
                    else => return,
                };
                var buf: std.io.Writer.Allocating = .init(allocator);
                defer buf.deinit();
                const w = &buf.writer;
                if (std.mem.eql(u8, cb_type, "tool_use")) {
                    has_tool_use.* = true;
                    // Pass through tool_use content_block_start with id and name
                    try w.print("event: content_block_start\ndata: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"tool_use\"", .{block_index.*});
                    if (cb.object.get("id")) |id| {
                        try w.writeAll(",\"id\":");
                        try std.json.Stringify.value(id, .{}, w);
                    }
                    if (cb.object.get("name")) |name| {
                        try w.writeAll(",\"name\":");
                        try std.json.Stringify.value(name, .{}, w);
                    }
                    try w.writeAll(",\"input\":{}}}\n\n");
                } else {
                    try w.print("event: content_block_start\ndata: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"{s}\"", .{ block_index.*, cb_type });
                    if (std.mem.eql(u8, cb_type, "thinking")) try w.writeAll(",\"thinking\":\"\"") else try w.writeAll(",\"text\":\"\"");
                    try w.writeAll("}}\n\n");
                }
                try socket.send(client_stream, buf.written());
                open_block_idx.* = block_index.*;
                return;
            }

            if (std.mem.eql(u8, event_type, "content_block_delta")) {
                const delta = obj.object.get("delta") orelse return;
                if (delta != .object) return;
                var buf: std.io.Writer.Allocating = .init(allocator);
                defer buf.deinit();
                const w = &buf.writer;
                try w.print("event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":", .{block_index.*});
                try std.json.Stringify.value(delta, .{}, w);
                try w.writeAll("}\n\n");
                try socket.send(client_stream, buf.written());
                return;
            }

            if (std.mem.eql(u8, event_type, "content_block_stop")) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "event: content_block_stop\ndata: {{\"type\":\"content_block_stop\",\"index\":{d}}}\n\n", .{block_index.*}) catch return;
                try socket.send(client_stream, msg);
                open_block_idx.* = null;
                block_index.* += 1;
                return;
            }

            if (std.mem.eql(u8, event_type, "ping")) {
                try socket.send(client_stream, "event: ping\ndata: {\"type\":\"ping\"}\n\n");
                return;
            }

            if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
                if (obj.object.get("delta")) |d| {
                    if (d == .string and d.string.len > 0) {
                        try oaEnsureSimple(client_stream, .text, "text", block_index, open_block_idx, oa_kind);
                        try oaEmitDelta(client_stream, "text_delta", "text", d.string, block_index, allocator);
                    }
                }
                return;
            }

            // OpenAI reasoning (thinking). summary or raw CoT, depending on model.
            if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta") or
                std.mem.eql(u8, event_type, "response.reasoning_text.delta"))
            {
                if (obj.object.get("delta")) |d| {
                    if (d == .string and d.string.len > 0) {
                        try oaEnsureSimple(client_stream, .thinking, "thinking", block_index, open_block_idx, oa_kind);
                        try oaEmitDelta(client_stream, "thinking_delta", "thinking", d.string, block_index, allocator);
                    }
                }
                return;
            }

            // OpenAI function call start: response.output_item.added with item.type==function_call.
            if (std.mem.eql(u8, event_type, "response.output_item.added")) {
                const item = obj.object.get("item") orelse return;
                if (item != .object) return;
                const it_type = switch (item.object.get("type") orelse return) {
                    .string => |s| s,
                    else => return,
                };
                if (!std.mem.eql(u8, it_type, "function_call")) return;
                has_tool_use.* = true;
                try oaCloseBlock(client_stream, block_index, open_block_idx);
                var buf: std.io.Writer.Allocating = .init(allocator);
                defer buf.deinit();
                const w = &buf.writer;
                try w.print("event: content_block_start\ndata: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"tool_use\"", .{block_index.*});
                if (item.object.get("call_id")) |id| {
                    try w.writeAll(",\"id\":");
                    try std.json.Stringify.value(id, .{}, w);
                } else if (item.object.get("id")) |id| {
                    try w.writeAll(",\"id\":");
                    try std.json.Stringify.value(id, .{}, w);
                }
                if (item.object.get("name")) |name| {
                    try w.writeAll(",\"name\":");
                    try std.json.Stringify.value(name, .{}, w);
                }
                try w.writeAll(",\"input\":{}}}\n\n");
                try socket.send(client_stream, buf.written());
                open_block_idx.* = block_index.*;
                oa_kind.* = .tool;
                return;
            }

            // OpenAI function call argument deltas -> Anthropic input_json_delta.
            if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
                if (obj.object.get("delta")) |d| {
                    if (d == .string and d.string.len > 0 and oa_kind.* == .tool) {
                        try oaEmitDelta(client_stream, "input_json_delta", "partial_json", d.string, block_index, allocator);
                    }
                }
                return;
            }

            // OpenAI item/argument completion -> close current Anthropic block.
            if (std.mem.eql(u8, event_type, "response.function_call_arguments.done") or
                std.mem.eql(u8, event_type, "response.output_item.done"))
            {
                try oaCloseBlock(client_stream, block_index, open_block_idx);
                oa_kind.* = .none;
                return;
            }
        }
    }

    // xAI (Grok)
    if (obj.object.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0) {
            const choice = choices.array.items[0];
            if (choice == .object) {
                if (choice.object.get("delta")) |delta| {
                    if (delta == .object) {
                        if (delta.object.get("content")) |c| {
                            if (c == .string and c.string.len > 0) {
                                try emitTextDelta(client_stream, c.string, block_index, open_block_idx, allocator);
                            }
                        }
                    }
                }
            }
        }
        return;
    }

    // Google (Gemini)
    if (obj.object.get("candidates")) |candidates| {
        if (candidates == .array and candidates.array.items.len > 0) {
            const cand = candidates.array.items[0];
            if (cand == .object) {
                if (cand.object.get("content")) |content| {
                    if (content == .object) {
                        if (content.object.get("parts")) |parts| {
                            if (parts == .array and parts.array.items.len > 0) {
                                const part = parts.array.items[0];
                                if (part == .object) {
                                    if (part.object.get("text")) |t| {
                                        if (t == .string and t.string.len > 0) {
                                            try emitTextDelta(client_stream, t.string, block_index, open_block_idx, allocator);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return;
    }
}

fn emitTextDelta(client_stream: std.net.Stream, text: []const u8, block_index: *usize, open_block_idx: *?usize, allocator: std.mem.Allocator) !void {
    if (block_index.* == 0) {
        try socket.send(client_stream, "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n");
        block_index.* = 1;
        open_block_idx.* = 0;
    }
    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;
    try w.writeAll("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":");
    try std.json.Stringify.encodeJsonString(text, .{}, w);
    try w.writeAll("}}\n\n");
    try socket.send(client_stream, buf.written());
}
