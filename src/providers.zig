const std = @import("std");

/// Map Claude Code model names to Zed-compatible names.
/// Every Claude request routes to claude-sonnet-5 and every GPT request to a
/// gpt-5.6 variant, so clients that can't pick models still land on 5.6.
pub fn normalizeModelName(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "gpt-5.6-sol")) return "gpt-5.6-sol";
    if (std.mem.startsWith(u8, name, "gpt-5.6-terra")) return "gpt-5.6-terra";
    if (std.mem.startsWith(u8, name, "gpt-5.6-luna")) return "gpt-5.6-luna";
    // Bare "gpt-5.6" is NOT a model Zed serves — upstream maps it to the "gpt-5"
    // family and returns 403 "not included in your plan". Route it to the real
    // gpt-5.6-sol variant so a client that picks "gpt-5.6" doesn't hard-fail.
    if (std.mem.startsWith(u8, name, "gpt-5.6")) return "gpt-5.6-sol";
    if (std.mem.startsWith(u8, name, "gpt-5.5")) return "gpt-5.5";
    if (std.mem.startsWith(u8, name, "gpt-")) return "gpt-5.6-sol";
    if (std.mem.startsWith(u8, name, "claude")) return "claude-sonnet-5";
    return name;
}

test "model normalization preserves the full GPT 5.6 family" {
    // Codex sends the exact model slug selected by the profile. Keeping every
    // 5.6 variant intact is required so the Zed proxy does not silently route
    // Sol, Terra, or Luna to a different upstream model.
    try std.testing.expectEqualStrings("gpt-5.6-sol", normalizeModelName("gpt-5.6-sol"));
    try std.testing.expectEqualStrings("gpt-5.6-terra", normalizeModelName("gpt-5.6-terra"));
    try std.testing.expectEqualStrings("gpt-5.6-luna", normalizeModelName("gpt-5.6-luna"));
    try std.testing.expectEqualStrings("gpt-5.6-sol", normalizeModelName("gpt-5.6"));
    try std.testing.expectEqualStrings("gpt-5.5", normalizeModelName("gpt-5.5"));
}

/// Get Zed provider string for a model
pub fn getProvider(model: []const u8) []const u8 {
    if (std.mem.startsWith(u8, model, "claude")) return "anthropic";
    if (std.mem.startsWith(u8, model, "gpt-")) return "open_ai";
    if (std.mem.startsWith(u8, model, "gemini")) return "google";
    if (std.mem.startsWith(u8, model, "grok")) return "x_ai";
    return "anthropic";
}

pub fn extractModel(root: std.json.Value) []const u8 {
    if (root != .object) return "claude-sonnet-5";
    if (root.object.get("model")) |mv| {
        if (mv == .string) return normalizeModelName(mv.string);
    }
    return "claude-sonnet-5";
}

/// Return an owned model name so callers can use it after the parsed JSON tree
/// is released. Callers must free the returned slice.
pub fn extractModelFromBody(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return allocator.dupe(u8, "claude-sonnet-5");
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, "claude-sonnet-5");
    if (parsed.value.object.get("model")) |mv| {
        if (mv == .string) return allocator.dupe(u8, mv.string);
    }
    return allocator.dupe(u8, "claude-sonnet-5");
}

/// Append the textual parts of an OpenAI/Anthropic content value. This helper
/// intentionally owns no memory; callers decide whether the collected text is
/// used as a system instruction or a regular Responses message.
fn appendContentText(w: *std.io.Writer, content: std.json.Value, wrote_any: *bool) !void {
    switch (content) {
        .string => |text| {
            if (text.len == 0) return;
            if (wrote_any.*) try w.writeAll("\n\n");
            try w.writeAll(text);
            wrote_any.* = true;
        },
        .array => |items| {
            for (items.items) |item| {
                if (item != .object) continue;
                const text = switch (item.object.get("text") orelse continue) {
                    .string => |value| value,
                    else => continue,
                };
                if (text.len == 0) continue;
                if (wrote_any.*) try w.writeAll("\n\n");
                try w.writeAll(text);
                wrote_any.* = true;
            }
        },
        else => {},
    }
}

/// Collect a content value into an owned UTF-8 slice. Returning owned memory
/// for both strings and arrays avoids the old mixed borrowed/owned contract,
/// which leaked array-form Claude Code system prompts.
fn collectContentText(allocator: std.mem.Allocator, content: std.json.Value) !?[]u8 {
    var buf: std.io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    var wrote_any = false;
    try appendContentText(&buf.writer, content, &wrote_any);
    if (!wrote_any) {
        buf.deinit();
        return null;
    }
    return try buf.toOwnedSlice();
}

/// Collect Anthropic's top-level `system` field for conversion to an OpenAI
/// Responses system message. Native Anthropic requests are passed through
/// structurally elsewhere so cache_control metadata is retained.
fn collectAnthropicSystemText(allocator: std.mem.Allocator, parsed: std.json.Value) !?[]u8 {
    const system = parsed.object.get("system") orelse return null;
    return collectContentText(allocator, system);
}

fn isSystemInstructionRole(role: []const u8) bool {
    return std.mem.eql(u8, role, "system") or std.mem.eql(u8, role, "developer");
}

/// Some OpenAI-compatible clients keep system/developer instructions in
/// `messages`. Claude Code 2.1.205 can also append a message-level `system`
/// instruction alongside Anthropic's official top-level `system` blocks.
/// Collect that text so Anthropic routes can move it to the top level instead
/// of forwarding a role the upstream Messages parser rejects.
fn collectMessageSystemText(allocator: std.mem.Allocator, parsed: std.json.Value) !?[]u8 {
    const messages = parsed.object.get("messages") orelse return null;
    if (messages != .array) return null;

    var buf: std.io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    var wrote_any = false;
    for (messages.array.items) |message| {
        if (message != .object) continue;
        const role = switch (message.object.get("role") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        if (!isSystemInstructionRole(role)) continue;
        const content = message.object.get("content") orelse continue;
        try appendContentText(&buf.writer, content, &wrote_any);
    }
    if (!wrote_any) {
        buf.deinit();
        return null;
    }
    return try buf.toOwnedSlice();
}

/// Write an Anthropic `system` value as entries in a system-block array. This
/// preserves official array blocks (including cache_control) while allowing a
/// message-level system string to be appended as one additional text block.
fn writeAnthropicSystemArrayEntries(w: *std.io.Writer, system: std.json.Value, first: *bool) !void {
    switch (system) {
        .string => |text| {
            if (!first.*) try w.writeAll(",");
            first.* = false;
            try w.writeAll("{\"type\":\"text\",\"text\":");
            try std.json.Stringify.encodeJsonString(text, .{}, w);
            try w.writeAll("}");
        },
        .array => |items| {
            for (items.items) |item| {
                if (!first.*) try w.writeAll(",");
                first.* = false;
                try std.json.Stringify.value(item, .{}, w);
            }
        },
        else => {},
    }
}

/// Generate a genuine RFC 4122 version-4 UUID string. The real Zed client
/// sends distinct v4 UUIDs for thread_id/prompt_id; the previous implementation
/// seeded a PRNG with the whole-second timestamp, so two calls in the same
/// second returned the SAME value (thread_id == prompt_id) and the layout was
/// not a valid v4 (wrong version/variant nibbles) — a request fingerprint that
/// does not match a real client. Use the OS CSPRNG and set version/variant bits.
fn fakeUuid(buf: *[36]u8) []const u8 {
    const hex = "0123456789abcdef";
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
    var bi: usize = 0;
    for (buf, 0..) |*c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            c.* = '-';
        } else {
            const nibble: u8 = if ((bi & 1) == 0) (bytes[bi >> 1] >> 4) else (bytes[bi >> 1] & 0x0f);
            c.* = hex[nibble];
            bi += 1;
        }
    }
    return buf;
}

fn writeMessage(w: *std.io.Writer, msg: std.json.Value) !void {
    if (msg != .object) return;
    const role = switch (msg.object.get("role") orelse return) {
        .string => |s| s,
        else => return,
    };
    const content = msg.object.get("content") orelse return;
    try w.print("{{\"role\":\"{s}\",\"content\":", .{role});
    switch (content) {
        .string => {
            try w.writeAll("[{\"type\":\"text\",\"text\":");
            try std.json.Stringify.encodeJsonString(content.string, .{}, w);
            try w.writeAll("}]");
        },
        .array => try std.json.Stringify.value(content, .{}, w),
        else => try w.writeAll("[]"),
    }
    try w.writeAll("}");
}

/// Write Anthropic-native message (passthrough content as-is, including tool_use/tool_result)
fn writeAnthropicMessage(w: *std.io.Writer, msg: std.json.Value) !void {
    if (msg != .object) return;
    const content = msg.object.get("content") orelse return;
    if (content != .string) {
        // Array content is already the official Anthropic representation. Keep
        // tool_use/tool_result/cache_control blocks byte-for-structure intact.
        try std.json.Stringify.value(msg, .{}, w);
        return;
    }

    // Anthropic publicly accepts string shorthand, while Zed's provider parser
    // requires a sequence of content blocks. Canonicalize only that field.
    try w.writeAll("{");
    var first = true;
    var it = msg.object.iterator();
    while (it.next()) |entry| {
        if (!first) try w.writeAll(",");
        first = false;
        try std.json.Stringify.encodeJsonString(entry.key_ptr.*, .{}, w);
        try w.writeAll(":");
        if (std.mem.eql(u8, entry.key_ptr.*, "content")) {
            try w.writeAll("[{\"type\":\"text\",\"text\":");
            try std.json.Stringify.encodeJsonString(content.string, .{}, w);
            try w.writeAll("}]");
        } else {
            try std.json.Stringify.value(entry.value_ptr.*, .{}, w);
        }
    }
    try w.writeAll("}");
}

/// Write message with OpenAI->Anthropic tool support conversion
fn writeMessageWithToolSupport(w: *std.io.Writer, msg: std.json.Value, allocator: std.mem.Allocator) !void {
    if (msg != .object) return;
    const role = switch (msg.object.get("role") orelse return) {
        .string => |s| s,
        else => return,
    };

    // Handle tool call results (OpenAI role=tool -> Anthropic role=user with tool_result)
    if (std.mem.eql(u8, role, "tool")) {
        const tool_call_id = switch (msg.object.get("tool_call_id") orelse return) {
            .string => |s| s,
            else => return,
        };
        const content = msg.object.get("content") orelse return;
        try w.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":");
        try std.json.Stringify.encodeJsonString(tool_call_id, .{}, w);
        try w.writeAll(",\"content\":");
        switch (content) {
            .string => try std.json.Stringify.encodeJsonString(content.string, .{}, w),
            else => try std.json.Stringify.value(content, .{}, w),
        }
        try w.writeAll("}]}");
        return;
    }

    // Handle assistant messages with tool_calls (OpenAI -> Anthropic tool_use)
    if (std.mem.eql(u8, role, "assistant")) {
        const tool_calls = msg.object.get("tool_calls");
        const content = msg.object.get("content");
        if (tool_calls != null and tool_calls.? == .array) {
            try w.writeAll("{\"role\":\"assistant\",\"content\":[");
            var wrote_any = false;
            // Include text content if present
            if (content) |c| {
                switch (c) {
                    .string => |s| {
                        if (s.len > 0) {
                            try w.writeAll("{\"type\":\"text\",\"text\":");
                            try std.json.Stringify.encodeJsonString(s, .{}, w);
                            try w.writeAll("}");
                            wrote_any = true;
                        }
                    },
                    else => {},
                }
            }
            // Convert tool_calls to tool_use blocks
            for (tool_calls.?.array.items) |tc| {
                if (tc != .object) continue;
                if (wrote_any) try w.writeAll(",");
                wrote_any = true;
                try w.writeAll("{\"type\":\"tool_use\"");
                if (tc.object.get("id")) |id| {
                    try w.writeAll(",\"id\":");
                    try std.json.Stringify.value(id, .{}, w);
                }
                if (tc.object.get("function")) |func| {
                    if (func == .object) {
                        if (func.object.get("name")) |n| {
                            try w.writeAll(",\"name\":");
                            try std.json.Stringify.value(n, .{}, w);
                        }
                        if (func.object.get("arguments")) |args| {
                            try w.writeAll(",\"input\":");
                            if (args == .string) {
                                // Parse JSON string arguments into object
                                const parsed_args = std.json.parseFromSlice(std.json.Value, allocator, args.string, .{}) catch {
                                    try w.writeAll("{}");
                                    try w.writeAll("}");
                                    continue;
                                };
                                defer parsed_args.deinit();
                                try std.json.Stringify.value(parsed_args.value, .{}, w);
                            } else {
                                try std.json.Stringify.value(args, .{}, w);
                            }
                        } else {
                            try w.writeAll(",\"input\":{}");
                        }
                    }
                }
                try w.writeAll("}");
            }
            try w.writeAll("]}");
            return;
        }
    }

    // Default: regular message
    try writeMessage(w, msg);
}

/// Build Zed completions payload from client request body.
pub fn buildZedPayload(allocator: std.mem.Allocator, body: []const u8, is_anthropic: bool) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequestBody;

    const model = extractModel(parsed.value);
    const provider = getProvider(model);

    var zed_body: std.io.Writer.Allocating = .init(allocator);
    errdefer zed_body.deinit();
    const w = &zed_body.writer;

    var uuid_buf1: [36]u8 = undefined;
    var uuid_buf2: [36]u8 = undefined;
    try w.print("{{\"thread_id\":\"{s}\",\"prompt_id\":\"{s}\",\"intent\":\"user_prompt\",\"provider\":\"{s}\",\"model\":\"{s}\",\"provider_request\":{{", .{
        fakeUuid(&uuid_buf1), fakeUuid(&uuid_buf2), provider, model,
    });

    if (std.mem.eql(u8, provider, "anthropic")) {
        try buildAnthropicRequest(allocator, w, parsed.value, model, is_anthropic);
    } else if (std.mem.eql(u8, provider, "open_ai")) {
        try buildOpenAIRequest(allocator, w, parsed.value, model, is_anthropic);
    } else if (std.mem.eql(u8, provider, "google")) {
        try buildGoogleRequest(allocator, w, parsed.value, model, is_anthropic);
    } else {
        try buildXAIRequest(allocator, w, parsed.value, model, is_anthropic);
    }

    try w.writeAll("}}");
    return try zed_body.toOwnedSlice();
}

fn buildAnthropicRequest(allocator: std.mem.Allocator, w: *std.io.Writer, parsed: std.json.Value, model: []const u8, is_anthropic: bool) !void {
    try w.print("\"model\":\"{s}\",", .{model});
    if (parsed.object.get("max_tokens")) |mt| {
        switch (mt) {
            .integer => |i| try w.print("\"max_tokens\":{d},", .{i}),
            else => try w.writeAll("\"max_tokens\":8192,"),
        }
    } else try w.writeAll("\"max_tokens\":8192,");

    const message_system_text = try collectMessageSystemText(allocator, parsed);
    defer if (message_system_text) |text| allocator.free(text);

    if (is_anthropic) {
        if (message_system_text) |text| {
            // Claude Code may send both official top-level system blocks and a
            // trailing role=system message. Merge them structurally so cache
            // metadata survives and `messages` remains Anthropic-valid.
            try w.writeAll("\"system\":[");
            var first_system_block = true;
            if (parsed.object.get("system")) |system| {
                try writeAnthropicSystemArrayEntries(w, system, &first_system_block);
            }
            try writeAnthropicSystemArrayEntries(w, .{ .string = text }, &first_system_block);
            try w.writeAll("],");
        } else if (parsed.object.get("system")) |system| {
            // Preserve ordinary native Anthropic requests byte-for-structure,
            // including cache_control metadata and string shorthand.
            try w.writeAll("\"system\":");
            try std.json.Stringify.value(system, .{}, w);
            try w.writeAll(",");
        }
    } else if (message_system_text) |text| {
        try w.writeAll("\"system\":");
        try std.json.Stringify.encodeJsonString(text, .{}, w);
        try w.writeAll(",");
    }
    if (parsed.object.get("temperature")) |temp| {
        try w.writeAll("\"temperature\":");
        try std.json.Stringify.value(temp, .{}, w);
        try w.writeAll(",");
    }
    if (parsed.object.get("thinking")) |thinking| {
        try w.writeAll("\"thinking\":");
        try std.json.Stringify.value(thinking, .{}, w);
        try w.writeAll(",");
    }
    if (is_anthropic) {
        // Sonnet 5 controls adaptive reasoning through Anthropic's native
        // `output_config.effort`. Preserve the whole object so effort and
        // structured-output settings keep their official wire shape.
        if (parsed.object.get("output_config")) |output_config| {
            try w.writeAll("\"output_config\":");
            try std.json.Stringify.value(output_config, .{}, w);
            try w.writeAll(",");
        }
    }
    // Tools support
    if (is_anthropic) {
        // Anthropic native format: tools already in correct format
        if (parsed.object.get("tools")) |tools| {
            try w.writeAll("\"tools\":");
            try std.json.Stringify.value(tools, .{}, w);
            try w.writeAll(",");
        }
        if (parsed.object.get("tool_choice")) |tc| {
            try w.writeAll("\"tool_choice\":");
            try std.json.Stringify.value(tc, .{}, w);
            try w.writeAll(",");
        }
    } else {
        // OpenAI format -> Anthropic format conversion
        if (parsed.object.get("tools")) |tools| {
            if (tools == .array) {
                try w.writeAll("\"tools\":[");
                var first = true;
                for (tools.array.items) |tool| {
                    if (tool != .object) continue;
                    const func = tool.object.get("function") orelse continue;
                    if (func != .object) continue;
                    if (!first) try w.writeAll(",");
                    first = false;
                    try w.writeAll("{\"name\":");
                    if (func.object.get("name")) |n| try std.json.Stringify.value(n, .{}, w) else try w.writeAll("\"\"");
                    if (func.object.get("description")) |d| {
                        try w.writeAll(",\"description\":");
                        try std.json.Stringify.value(d, .{}, w);
                    }
                    if (func.object.get("parameters")) |p| {
                        try w.writeAll(",\"input_schema\":");
                        try std.json.Stringify.value(p, .{}, w);
                    }
                    try w.writeAll("}");
                }
                try w.writeAll("],");
            }
        }
        if (parsed.object.get("tool_choice")) |tc| {
            // OpenAI tool_choice -> Anthropic tool_choice
            if (tc == .string) {
                if (std.mem.eql(u8, tc.string, "auto")) {
                    try w.writeAll("\"tool_choice\":{\"type\":\"auto\"},");
                } else if (std.mem.eql(u8, tc.string, "required")) {
                    try w.writeAll("\"tool_choice\":{\"type\":\"any\"},");
                } else if (std.mem.eql(u8, tc.string, "none")) {
                    // Don't send tool_choice for "none", just omit tools
                }
            } else if (tc == .object) {
                try w.writeAll("\"tool_choice\":");
                try std.json.Stringify.value(tc, .{}, w);
                try w.writeAll(",");
            }
        }
    }
    try w.writeAll("\"messages\":[");
    if (parsed.object.get("messages")) |msgs| {
        if (msgs == .array) {
            var first_message = true;
            for (msgs.array.items) |msg| {
                if (msg == .object) {
                    const role = switch (msg.object.get("role") orelse .null) {
                        .string => |value| value,
                        else => "",
                    };
                    if (isSystemInstructionRole(role)) continue;
                }
                if (!first_message) try w.writeAll(",");
                first_message = false;
                if (is_anthropic) {
                    try writeAnthropicMessage(w, msg);
                } else {
                    try writeMessageWithToolSupport(w, msg, allocator);
                }
            }
        }
    }
    try w.writeAll("]");
}

/// Write one Anthropic-format message as OpenAI Responses `input` item(s).
/// A single Anthropic message may expand into: a message item (text), one or
/// more function_call items (tool_use), and function_call_output items
/// (tool_result). Returns the updated `wrote_any` flag for comma handling.
fn writeAnthropicMsgToResponses(w: *std.io.Writer, role: []const u8, content: std.json.Value, wrote_any_in: bool, allocator: std.mem.Allocator) !bool {
    var wrote_any = wrote_any_in;
    const is_assistant = std.mem.eql(u8, role, "assistant");
    const text_type = if (is_assistant) "output_text" else "input_text";

    switch (content) {
        .string => |s| {
            if (s.len > 0) {
                if (wrote_any) try w.writeAll(",");
                try w.print("{{\"type\":\"message\",\"role\":\"{s}\",\"content\":[{{\"type\":\"{s}\",\"text\":", .{ role, text_type });
                try std.json.Stringify.encodeJsonString(s, .{}, w);
                try w.writeAll("}]}");
                wrote_any = true;
            }
        },
        .array => |arr| {
            // 1) Collect all text blocks into a single message item.
            var text_buf: std.io.Writer.Allocating = .init(allocator);
            defer text_buf.deinit();
            var has_text = false;
            for (arr.items) |blk| {
                if (blk != .object) continue;
                const bt = switch (blk.object.get("type") orelse continue) {
                    .string => |x| x,
                    else => continue,
                };
                if (std.mem.eql(u8, bt, "text")) {
                    if (blk.object.get("text")) |t| {
                        if (t == .string) {
                            try text_buf.writer.writeAll(t.string);
                            has_text = true;
                        }
                    }
                }
            }
            if (has_text) {
                if (wrote_any) try w.writeAll(",");
                try w.print("{{\"type\":\"message\",\"role\":\"{s}\",\"content\":[{{\"type\":\"{s}\",\"text\":", .{ role, text_type });
                try std.json.Stringify.encodeJsonString(text_buf.written(), .{}, w);
                try w.writeAll("}]}");
                wrote_any = true;
            }
            // 2) tool_use blocks -> function_call items.
            for (arr.items) |blk| {
                if (blk != .object) continue;
                const bt = switch (blk.object.get("type") orelse continue) {
                    .string => |x| x,
                    else => continue,
                };
                if (!std.mem.eql(u8, bt, "tool_use")) continue;
                if (wrote_any) try w.writeAll(",");
                wrote_any = true;
                try w.writeAll("{\"type\":\"function_call\"");
                if (blk.object.get("id")) |id| {
                    try w.writeAll(",\"call_id\":");
                    try std.json.Stringify.value(id, .{}, w);
                }
                if (blk.object.get("name")) |nm| {
                    try w.writeAll(",\"name\":");
                    try std.json.Stringify.value(nm, .{}, w);
                }
                // Responses API requires arguments to be a JSON *string*.
                try w.writeAll(",\"arguments\":");
                if (blk.object.get("input")) |inp| {
                    var ab: std.io.Writer.Allocating = .init(allocator);
                    defer ab.deinit();
                    try std.json.Stringify.value(inp, .{}, &ab.writer);
                    try std.json.Stringify.encodeJsonString(ab.written(), .{}, w);
                } else {
                    try w.writeAll("\"{}\"");
                }
                try w.writeAll("}");
            }
            // 3) tool_result blocks -> function_call_output items.
            for (arr.items) |blk| {
                if (blk != .object) continue;
                const bt = switch (blk.object.get("type") orelse continue) {
                    .string => |x| x,
                    else => continue,
                };
                if (!std.mem.eql(u8, bt, "tool_result")) continue;
                if (wrote_any) try w.writeAll(",");
                wrote_any = true;
                try w.writeAll("{\"type\":\"function_call_output\"");
                if (blk.object.get("tool_use_id")) |tid| {
                    try w.writeAll(",\"call_id\":");
                    try std.json.Stringify.value(tid, .{}, w);
                }
                try w.writeAll(",\"output\":");
                if (blk.object.get("content")) |c| {
                    switch (c) {
                        .string => |s| try std.json.Stringify.encodeJsonString(s, .{}, w),
                        .array => |carr| {
                            var ob: std.io.Writer.Allocating = .init(allocator);
                            defer ob.deinit();
                            for (carr.items) |ci| {
                                if (ci == .object) {
                                    if (ci.object.get("text")) |t| {
                                        if (t == .string) try ob.writer.writeAll(t.string);
                                    }
                                }
                            }
                            try std.json.Stringify.encodeJsonString(ob.written(), .{}, w);
                        },
                        else => try w.writeAll("\"\""),
                    }
                } else try w.writeAll("\"\"");
                try w.writeAll("}");
            }
        },
        else => {},
    }
    return wrote_any;
}

/// Convert one OpenAI Chat Completions history message to Responses input.
/// Tool history is not a normal `role=tool` message in Responses: assistant
/// calls and tool results must be represented as function_call and
/// function_call_output items so OpenCode can continue multi-step tool loops.
fn writeOpenAIChatMsgToResponses(w: *std.io.Writer, message: std.json.Value, wrote_any_in: bool, allocator: std.mem.Allocator) !bool {
    if (message != .object) return wrote_any_in;
    const role = switch (message.object.get("role") orelse return wrote_any_in) {
        .string => |value| value,
        else => return wrote_any_in,
    };
    var wrote_any = wrote_any_in;

    if (std.mem.eql(u8, role, "tool")) {
        const call_id = message.object.get("tool_call_id") orelse return wrote_any;
        if (wrote_any) try w.writeAll(",");
        try w.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
        try std.json.Stringify.value(call_id, .{}, w);
        try w.writeAll(",\"output\":");
        if (message.object.get("content")) |content| {
            if (content == .string) {
                try std.json.Stringify.encodeJsonString(content.string, .{}, w);
            } else {
                var output_buf: std.io.Writer.Allocating = .init(allocator);
                defer output_buf.deinit();
                try std.json.Stringify.value(content, .{}, &output_buf.writer);
                try std.json.Stringify.encodeJsonString(output_buf.written(), .{}, w);
            }
        } else {
            try w.writeAll("\"\"");
        }
        try w.writeAll("}");
        return true;
    }

    // Preserve textual content as a typed Responses message. Assistant tool
    // calls commonly carry content=null, so text is optional here.
    if (message.object.get("content")) |content| {
        if (try collectContentText(allocator, content)) |text| {
            defer allocator.free(text);
            if (wrote_any) try w.writeAll(",");
            const text_type = if (std.mem.eql(u8, role, "assistant")) "output_text" else "input_text";
            try w.print("{{\"type\":\"message\",\"role\":\"{s}\",\"content\":[{{\"type\":\"{s}\",\"text\":", .{ role, text_type });
            try std.json.Stringify.encodeJsonString(text, .{}, w);
            try w.writeAll("}]}");
            wrote_any = true;
        }
    }

    if (std.mem.eql(u8, role, "assistant")) {
        if (message.object.get("tool_calls")) |tool_calls| {
            if (tool_calls == .array) {
                for (tool_calls.array.items) |tool_call| {
                    if (tool_call != .object) continue;
                    const function = tool_call.object.get("function") orelse continue;
                    if (function != .object) continue;
                    if (wrote_any) try w.writeAll(",");
                    try w.writeAll("{\"type\":\"function_call\",\"call_id\":");
                    if (tool_call.object.get("id")) |id| {
                        try std.json.Stringify.value(id, .{}, w);
                    } else {
                        try w.writeAll("\"\"");
                    }
                    try w.writeAll(",\"name\":");
                    if (function.object.get("name")) |name| {
                        try std.json.Stringify.value(name, .{}, w);
                    } else {
                        try w.writeAll("\"\"");
                    }
                    try w.writeAll(",\"arguments\":");
                    if (function.object.get("arguments")) |arguments| {
                        if (arguments == .string) {
                            try std.json.Stringify.encodeJsonString(arguments.string, .{}, w);
                        } else {
                            var arguments_buf: std.io.Writer.Allocating = .init(allocator);
                            defer arguments_buf.deinit();
                            try std.json.Stringify.value(arguments, .{}, &arguments_buf.writer);
                            try std.json.Stringify.encodeJsonString(arguments_buf.written(), .{}, w);
                        }
                    } else {
                        try w.writeAll("\"{}\"");
                    }
                    try w.writeAll("}");
                    wrote_any = true;
                }
            }
        }
    }

    return wrote_any;
}

fn namedToolChoice(tool_choice: std.json.Value) ?[]const u8 {
    if (tool_choice != .object) return null;
    const choice_type = switch (tool_choice.object.get("type") orelse .null) {
        .string => |value| value,
        else => "",
    };
    if (std.mem.eql(u8, choice_type, "tool")) {
        return switch (tool_choice.object.get("name") orelse return null) {
            .string => |value| value,
            else => null,
        };
    }
    if (!std.mem.eql(u8, choice_type, "function")) return null;
    if (tool_choice.object.get("name")) |name| {
        if (name == .string) return name.string;
    }
    if (tool_choice.object.get("function")) |function| {
        if (function == .object) {
            return switch (function.object.get("name") orelse return null) {
                .string => |value| value,
                else => null,
            };
        }
    }
    return null;
}

/// Zed accepts a named function choice object but does not enforce it.
/// The caller filters `tools` to the requested name, then `required` preserves
/// the official exact-tool semantics against this older upstream parser.
fn writeZedOpenAIToolChoice(w: *std.io.Writer, tool_choice: std.json.Value) !void {
    if (tool_choice == .string) {
        try std.json.Stringify.value(tool_choice, .{}, w);
        return;
    }
    if (tool_choice != .object) {
        try std.json.Stringify.value(tool_choice, .{}, w);
        return;
    }

    if (namedToolChoice(tool_choice) != null) {
        try w.writeAll("\"required\"");
        return;
    }
    try std.json.Stringify.value(tool_choice, .{}, w);
}

fn supportedZedResponsesToolName(tool: std.json.Value) ?[]const u8 {
    if (tool != .object) return null;
    const tool_type = switch (tool.object.get("type") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    // Zed's hosted Responses parser currently accepts only function/custom
    // declarations. Codex's namespace declaration needs bidirectional call
    // translation, so forwarding it unchanged makes the whole request fail.
    if (!std.mem.eql(u8, tool_type, "function") and !std.mem.eql(u8, tool_type, "custom")) return null;
    return switch (tool.object.get("name") orelse return null) {
        .string => |value| value,
        else => null,
    };
}

fn supportedToolArrayContainsName(tools: ?std.json.Value, name: []const u8) bool {
    const value = tools orelse return false;
    if (value != .array) return false;
    for (value.array.items) |tool| {
        const candidate = supportedZedResponsesToolName(tool) orelse continue;
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn writeSupportedZedResponsesTools(
    w: *std.io.Writer,
    tools: std.json.Value,
    selected_name: ?[]const u8,
    excluded_tools: ?std.json.Value,
    first: *bool,
) !void {
    if (tools != .array) return;
    for (tools.array.items, 0..) |tool, index| {
        const name = supportedZedResponsesToolName(tool) orelse continue;
        if (selected_name) |selected| {
            if (!std.mem.eql(u8, name, selected)) continue;
        }
        if (supportedToolArrayContainsName(excluded_tools, name)) continue;

        // Keep the merged top-level tool list deterministic and avoid an
        // upstream duplicate-name rejection when a client repeats a tool.
        var duplicate = false;
        for (tools.array.items[0..index]) |previous| {
            const previous_name = supportedZedResponsesToolName(previous) orelse continue;
            if (std.mem.eql(u8, previous_name, name)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;

        if (!first.*) try w.writeAll(",");
        first.* = false;
        try std.json.Stringify.value(tool, .{}, w);
    }
}

fn inputHasAdditionalTools(input: ?std.json.Value) bool {
    const value = input orelse return false;
    if (value != .array) return false;
    for (value.array.items) |item| {
        if (item != .object) continue;
        const item_type = switch (item.object.get("type") orelse continue) {
            .string => |candidate| candidate,
            else => continue,
        };
        if (std.mem.eql(u8, item_type, "additional_tools")) return true;
    }
    return false;
}

fn writeMergedResponsesToolsForZed(
    w: *std.io.Writer,
    top_level_tools: ?std.json.Value,
    input: ?std.json.Value,
    selected_name: ?[]const u8,
) !void {
    if (top_level_tools == null and !inputHasAdditionalTools(input)) return;

    try w.writeAll(",\"tools\":[");
    var first = true;
    if (top_level_tools) |tools| {
        try writeSupportedZedResponsesTools(w, tools, selected_name, null, &first);
    }

    const input_value = input orelse {
        try w.writeAll("]");
        return;
    };
    if (input_value == .array) {
        for (input_value.array.items) |item| {
            if (item != .object) continue;
            const item_type = switch (item.object.get("type") orelse continue) {
                .string => |candidate| candidate,
                else => continue,
            };
            if (!std.mem.eql(u8, item_type, "additional_tools")) continue;
            const tools = item.object.get("tools") orelse continue;
            try writeSupportedZedResponsesTools(w, tools, selected_name, top_level_tools, &first);
        }
    }
    try w.writeAll("]");
}

const DEFAULT_GPT56_REASONING_EFFORT = "xhigh";

/// Efforts accepted end-to-end by the current Zed hosted GPT-5.6 route. OpenAI
/// also documents `max`, but Zed's cloud parser currently rejects it. Zed's
/// parser recognizes `minimal`, yet the GPT-5.6 backend fails that request.
/// Neither value is silently rewritten to another effort.
fn isZedHostedGpt56ReasoningEffort(effort: []const u8) bool {
    const supported = [_][]const u8{ "none", "low", "medium", "high", "xhigh" };
    for (supported) |candidate| {
        if (std.mem.eql(u8, effort, candidate)) return true;
    }
    return false;
}

fn isGpt56(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "gpt-5.6");
}

fn isGpt55(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "gpt-5.5");
}

/// Chat Completions uses top-level `reasoning_effort`; Responses uses
/// `reasoning.effort`. Accept both forms because OpenCode and Codex use
/// different official surfaces, then emit the Responses shape upstream.
fn clientReasoningEffort(parsed: std.json.Value) ?[]const u8 {
    if (parsed.object.get("reasoning_effort")) |value| {
        if (value == .string) return value.string;
    }
    if (parsed.object.get("reasoning")) |reasoning| {
        if (reasoning == .object) {
            if (reasoning.object.get("effort")) |value| {
                if (value == .string) return value.string;
            }
        }
    }
    return null;
}

/// Resolve the effective effort without overriding a native client choice.
/// Claude Code is the one intentional exception: its Anthropic endpoint cannot
/// select an OpenAI effort reliably, so GPT-5.6 requests there are pinned to
/// xhigh. GPT-5.5 keeps the historical xhigh policy.
fn effectiveReasoningEffort(parsed: std.json.Value, model: []const u8, is_anthropic: bool) ?[]const u8 {
    if (isGpt56(model)) {
        if (is_anthropic) return DEFAULT_GPT56_REASONING_EFFORT;
        return clientReasoningEffort(parsed) orelse DEFAULT_GPT56_REASONING_EFFORT;
    }
    if (isGpt55(model)) return "xhigh";
    return clientReasoningEffort(parsed);
}

/// Reject unsupported client-selected GPT-5.6 efforts before account failover.
/// Claude Code is excluded because its `/v1/messages` GPT route intentionally
/// ignores client effort fields and always uses xhigh.
pub fn validateClientReasoningEffort(allocator: std.mem.Allocator, body: []const u8, is_anthropic: bool) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequestBody;

    const model = extractModel(parsed.value);
    if (is_anthropic or !isGpt56(model)) return;
    if (clientReasoningEffort(parsed.value)) |effort| {
        if (!isZedHostedGpt56ReasoningEffort(effort)) return error.UnsupportedReasoningEffort;
    }
}

/// Write a Responses `reasoning` object while retaining mode, summary,
/// context, encrypted-content options, and future fields supplied by Codex.
/// Only `effort` is resolved by the policy above. A visible summary is added
/// for active reasoning when the client did not choose a summary policy.
fn writeReasoningObject(w: *std.io.Writer, source: ?std.json.Value, effort: []const u8) !void {
    try w.writeAll("{\"effort\":");
    try std.json.Stringify.encodeJsonString(effort, .{}, w);

    var has_summary = false;
    if (source) |reasoning| {
        if (reasoning == .object) {
            var it = reasoning.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (std.mem.eql(u8, key, "effort")) continue;
                if (std.mem.eql(u8, key, "summary")) has_summary = true;
                try w.writeAll(",");
                try std.json.Stringify.encodeJsonString(key, .{}, w);
                try w.writeAll(":");
                try std.json.Stringify.value(entry.value_ptr.*, .{}, w);
            }
        }
    }

    if (!has_summary and !std.mem.eql(u8, effort, "none")) {
        try w.writeAll(",\"summary\":\"detailed\"");
    }
    try w.writeAll("}");
}

fn requestedOutputBudget(parsed: std.json.Value) ?i64 {
    const keys = [_][]const u8{ "max_output_tokens", "max_completion_tokens", "max_tokens" };
    for (keys) |key| {
        if (parsed.object.get(key)) |value| {
            if (value == .integer) return value.integer;
        }
    }
    return null;
}

fn effortNeedsLargeOutputBudget(effort: []const u8) bool {
    return std.mem.eql(u8, effort, "xhigh") or std.mem.eql(u8, effort, "max");
}

fn writeOutputBudget(w: *std.io.Writer, parsed: std.json.Value, model: []const u8, effort: ?[]const u8) !void {
    const requested = requestedOutputBudget(parsed);
    const needs_floor = if (effort) |value|
        (isGpt56(model) or isGpt55(model)) and effortNeedsLargeOutputBudget(value)
    else
        false;

    if (needs_floor) {
        const budget = if (requested) |value| @max(value, GPT_REASONING_OUTPUT_FLOOR) else GPT_REASONING_OUTPUT_FLOOR;
        try w.print(",\"max_output_tokens\":{d}", .{budget});
    } else if (requested) |value| {
        try w.print(",\"max_output_tokens\":{d}", .{value});
    }
}

fn buildOpenAIRequest(allocator: std.mem.Allocator, w: *std.io.Writer, parsed: std.json.Value, model: []const u8, is_anthropic: bool) !void {
    // Codex already sends OpenAI Responses input. Preserve its request shape
    // instead of trying to reinterpret it as Chat Completions messages.
    if (!is_anthropic and parsed.object.get("input") != null) {
        return buildNativeResponsesRequest(w, parsed, model, is_anthropic);
    }

    try w.print("\"model\":\"{s}\",\"stream\":true,\"input\":[", .{model});
    var wrote_any = false;
    const selected_tool_name = if (parsed.object.get("tool_choice")) |choice| namedToolChoice(choice) else null;

    if (is_anthropic) {
        if (try collectAnthropicSystemText(allocator, parsed)) |sys_text| {
            defer allocator.free(sys_text);
            try w.writeAll("{\"type\":\"message\",\"role\":\"system\",\"content\":[{\"type\":\"input_text\",\"text\":");
            try std.json.Stringify.encodeJsonString(sys_text, .{}, w);
            try w.writeAll("}]}");
            wrote_any = true;
        }
    }

    if (parsed.object.get("messages")) |msgs| {
        if (msgs == .array) for (msgs.array.items) |msg| {
            if (msg != .object) continue;
            if (is_anthropic) {
                const role = switch (msg.object.get("role") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const content = msg.object.get("content") orelse continue;
                wrote_any = try writeAnthropicMsgToResponses(w, role, content, wrote_any, allocator);
            } else {
                wrote_any = try writeOpenAIChatMsgToResponses(w, msg, wrote_any, allocator);
            }
        };
    }
    try w.writeAll("]");

    // Tools -> OpenAI Responses flat function tool format.
    if (parsed.object.get("tools")) |tools| {
        if (tools == .array and tools.array.items.len > 0) {
            try w.writeAll(",\"tools\":[");
            var first = true;
            for (tools.array.items) |tool| {
                if (tool != .object) continue;
                if (is_anthropic) {
                    const nm = tool.object.get("name") orelse continue;
                    if (selected_tool_name) |selected| {
                        if (nm != .string or !std.mem.eql(u8, nm.string, selected)) continue;
                    }
                    if (!first) try w.writeAll(",");
                    first = false;
                    try w.writeAll("{\"type\":\"function\",\"name\":");
                    try std.json.Stringify.value(nm, .{}, w);
                    if (tool.object.get("description")) |d| {
                        try w.writeAll(",\"description\":");
                        try std.json.Stringify.value(d, .{}, w);
                    }
                    try w.writeAll(",\"parameters\":");
                    if (tool.object.get("input_schema")) |s| try std.json.Stringify.value(s, .{}, w) else try w.writeAll("{\"type\":\"object\",\"properties\":{}}");
                    try w.writeAll("}");
                } else {
                    const func = tool.object.get("function") orelse continue;
                    if (func != .object) continue;
                    if (selected_tool_name) |selected| {
                        const function_name = func.object.get("name") orelse continue;
                        if (function_name != .string or !std.mem.eql(u8, function_name.string, selected)) continue;
                    }
                    if (!first) try w.writeAll(",");
                    first = false;
                    try w.writeAll("{\"type\":\"function\",\"name\":");
                    if (func.object.get("name")) |n| try std.json.Stringify.value(n, .{}, w) else try w.writeAll("\"\"");
                    if (func.object.get("description")) |d| {
                        try w.writeAll(",\"description\":");
                        try std.json.Stringify.value(d, .{}, w);
                    }
                    try w.writeAll(",\"parameters\":");
                    if (func.object.get("parameters")) |p| try std.json.Stringify.value(p, .{}, w) else try w.writeAll("{\"type\":\"object\",\"properties\":{}}");
                    try w.writeAll("}");
                }
            }
            try w.writeAll("]");
        }
    }

    // tool_choice mapping.
    if (parsed.object.get("tool_choice")) |tc| {
        if (is_anthropic) {
            if (tc == .object) {
                const ttype = switch (tc.object.get("type") orelse .null) {
                    .string => |s| s,
                    else => "",
                };
                if (std.mem.eql(u8, ttype, "auto")) {
                    try w.writeAll(",\"tool_choice\":\"auto\"");
                } else if (std.mem.eql(u8, ttype, "any")) {
                    try w.writeAll(",\"tool_choice\":\"required\"");
                } else if (std.mem.eql(u8, ttype, "tool")) {
                    try w.writeAll(",\"tool_choice\":\"required\"");
                }
            }
        } else {
            if (tc == .string) {
                try w.writeAll(",\"tool_choice\":");
                try std.json.Stringify.value(tc, .{}, w);
            } else if (tc == .object) {
                try w.writeAll(",\"tool_choice\":");
                try writeZedOpenAIToolChoice(w, tc);
            }
        }
    }

    const effort = effectiveReasoningEffort(parsed, model, is_anthropic);
    if (effort) |value| {
        try w.writeAll(",\"reasoning\":");
        try writeReasoningObject(w, parsed.object.get("reasoning"), value);
    }
    try writeOutputBudget(w, parsed, model, effort);
}

/// High/max reasoning can consume most of a small completion budget before a
/// visible answer is emitted. Keep the existing safety floor only when the
/// effective effort really is xhigh/max; lower client-selected levels retain
/// the exact budget they sent.
const GPT_REASONING_OUTPUT_FLOOR: i64 = 32768;

/// Zed's OpenAI provider currently accepts only the fully typed Responses
/// representation, while the public Responses API also accepts two official
/// shorthands:
///   - top-level `input` as a string;
///   - message items without `type`, with `content` as a string.
/// Canonicalize those forms at the provider boundary. Already-typed Codex
/// items (function_call, function_call_output, reasoning, etc.) pass through
/// unchanged.
fn writeNativeResponsesInput(w: *std.io.Writer, input: std.json.Value) !void {
    switch (input) {
        .string => |text| {
            try w.writeAll("[{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":");
            try std.json.Stringify.encodeJsonString(text, .{}, w);
            try w.writeAll("}]}]");
        },
        .array => |items| {
            try w.writeAll("[");
            var first = true;
            for (items.items) |item| {
                if (item == .object) {
                    const item_type = switch (item.object.get("type") orelse .null) {
                        .string => |value| value,
                        else => "",
                    };
                    // Codex uses this internal input item to carry tool
                    // declarations. Zed expects declarations at top-level.
                    if (std.mem.eql(u8, item_type, "additional_tools")) continue;
                }
                if (!first) try w.writeAll(",");
                first = false;
                if (isResponsesMessageItem(item)) {
                    try writeCanonicalResponsesMessage(w, item);
                } else if (item == .object) {
                    // Codex resends history items (e.g. reasoning) with
                    // explicit nulls ("content":null); Zed's parser rejects
                    // null where it expects an array, so omit those fields.
                    try writeObjectSkippingNulls(w, item);
                } else {
                    try std.json.Stringify.value(item, .{}, w);
                }
            }
            try w.writeAll("]");
        },
        else => try std.json.Stringify.value(input, .{}, w),
    }
}

fn writeObjectSkippingNulls(w: *std.io.Writer, item: std.json.Value) !void {
    try w.writeAll("{");
    var first = true;
    var it = item.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .null) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try std.json.Stringify.encodeJsonString(entry.key_ptr.*, .{}, w);
        try w.writeAll(":");
        try std.json.Stringify.value(entry.value_ptr.*, .{}, w);
    }
    try w.writeAll("}");
}

fn isResponsesMessageItem(item: std.json.Value) bool {
    if (item != .object) return false;
    const role = item.object.get("role") orelse return false;
    if (role != .string) return false;

    const item_type = item.object.get("type") orelse return true;
    return item_type == .string and std.mem.eql(u8, item_type.string, "message");
}

fn writeCanonicalResponsesMessage(w: *std.io.Writer, item: std.json.Value) !void {
    const role = item.object.get("role").?.string;
    const content_type = if (std.mem.eql(u8, role, "assistant")) "output_text" else "input_text";

    try w.writeAll("{\"type\":\"message\"");
    var it = item.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "type")) continue;

        try w.writeAll(",");
        try std.json.Stringify.encodeJsonString(key, .{}, w);
        try w.writeAll(":");
        if (std.mem.eql(u8, key, "role") and
            entry.value_ptr.* == .string and
            std.mem.eql(u8, entry.value_ptr.string, "developer"))
        {
            // Zed's hosted parser predates the Responses developer role. A
            // system message preserves the instruction priority it supports.
            try w.writeAll("\"system\"");
        } else if (std.mem.eql(u8, key, "content") and entry.value_ptr.* == .string) {
            try w.print("[{{\"type\":\"{s}\",\"text\":", .{content_type});
            try std.json.Stringify.encodeJsonString(entry.value_ptr.string, .{}, w);
            try w.writeAll("}]");
        } else {
            try std.json.Stringify.value(entry.value_ptr.*, .{}, w);
        }
    }
    try w.writeAll("}");
}

/// Forward a native OpenAI Responses request from Codex while replacing only
/// the fields the local proxy owns. Keeping the remaining fields intact is
/// important for Codex tool calls, encrypted reasoning continuity and request
/// metadata added by newer clients.
fn buildNativeResponsesRequest(w: *std.io.Writer, parsed: std.json.Value, model: []const u8, is_anthropic: bool) !void {
    try w.writeAll("\"model\":");
    try std.json.Stringify.encodeJsonString(model, .{}, w);
    try w.writeAll(",\"stream\":true");
    const selected_tool_name = if (parsed.object.get("tool_choice")) |choice| namedToolChoice(choice) else null;

    var it = parsed.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "model") or
            std.mem.eql(u8, key, "stream") or
            std.mem.eql(u8, key, "reasoning") or
            std.mem.eql(u8, key, "reasoning_effort") or
            std.mem.eql(u8, key, "max_output_tokens") or
            std.mem.eql(u8, key, "max_completion_tokens") or
            std.mem.eql(u8, key, "max_tokens") or
            std.mem.eql(u8, key, "tools"))
        {
            continue;
        }

        try w.writeAll(",");
        try std.json.Stringify.encodeJsonString(key, .{}, w);
        try w.writeAll(":");
        if (std.mem.eql(u8, key, "input")) {
            try writeNativeResponsesInput(w, entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "tool_choice")) {
            try writeZedOpenAIToolChoice(w, entry.value_ptr.*);
        } else {
            try std.json.Stringify.value(entry.value_ptr.*, .{}, w);
        }
    }

    try writeMergedResponsesToolsForZed(w, parsed.object.get("tools"), parsed.object.get("input"), selected_tool_name);

    const effort = effectiveReasoningEffort(parsed, model, is_anthropic);
    if (effort) |value| {
        try w.writeAll(",\"reasoning\":");
        try writeReasoningObject(w, parsed.object.get("reasoning"), value);
    } else if (parsed.object.get("reasoning")) |reasoning| {
        // Non-GPT routes still receive the native object unchanged.
        try w.writeAll(",\"reasoning\":");
        try std.json.Stringify.value(reasoning, .{}, w);
    }
    try writeOutputBudget(w, parsed, model, effort);
}

test "native Responses keeps the historical GPT 5.5 xhigh policy" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"gpt-5.5","stream":true,"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"ping"}]}],"reasoning":{"effort":"low"},"store":false}
    ;
    const payload = try buildZedPayload(allocator, body, false);
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"model\":\"gpt-5.5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"input\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"effort\":\"xhigh\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"effort\":\"low\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"store\":false") != null);
}

test "native Responses preserves every Zed-hosted GPT 5.6 effort and reasoning field" {
    const allocator = std.testing.allocator;
    const models = [_][]const u8{ "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna" };
    const efforts = [_][]const u8{ "none", "low", "medium", "high", "xhigh" };

    for (models) |model| {
        for (efforts) |effort| {
            try std.testing.expect(isZedHostedGpt56ReasoningEffort(effort));
            const body = try std.fmt.allocPrint(
                allocator,
                "{{\"model\":\"{s}\",\"input\":\"ping\",\"reasoning\":{{\"effort\":\"{s}\",\"summary\":\"concise\",\"context\":\"all_turns\"}},\"max_output_tokens\":1234}}",
                .{ model, effort },
            );
            defer allocator.free(body);
            const payload = try buildZedPayload(allocator, body, false);
            defer allocator.free(payload);

            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
            defer parsed.deinit();
            const request = parsed.value.object.get("provider_request").?.object;
            const reasoning = request.get("reasoning").?.object;
            try std.testing.expectEqualStrings(model, request.get("model").?.string);
            try std.testing.expectEqualStrings(effort, reasoning.get("effort").?.string);
            try std.testing.expectEqualStrings("concise", reasoning.get("summary").?.string);
            try std.testing.expectEqualStrings("all_turns", reasoning.get("context").?.string);
            const expected_budget: i64 = if (effortNeedsLargeOutputBudget(effort)) GPT_REASONING_OUTPUT_FLOOR else 1234;
            try std.testing.expectEqual(expected_budget, request.get("max_output_tokens").?.integer);
        }
    }
}

test "native Responses defaults all GPT 5.6 models to xhigh" {
    const allocator = std.testing.allocator;
    const models = [_][]const u8{ "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna" };

    for (models) |model| {
        const body = try std.fmt.allocPrint(allocator, "{{\"model\":\"{s}\",\"input\":\"ping\"}}", .{model});
        defer allocator.free(body);
        const payload = try buildZedPayload(allocator, body, false);
        defer allocator.free(payload);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
        defer parsed.deinit();
        const request = parsed.value.object.get("provider_request").?.object;
        try std.testing.expectEqualStrings("xhigh", request.get("reasoning").?.object.get("effort").?.string);
        try std.testing.expectEqual(@as(i64, GPT_REASONING_OUTPUT_FLOOR), request.get("max_output_tokens").?.integer);
    }
}

test "native Responses payload canonicalizes official shorthand messages" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"gpt-5.6","stream":true,"input":[{"role":"user","content":"ping"}],"store":false}
    ;
    const payload = try buildZedPayload(allocator, body, false);
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"model\":\"gpt-5.6-sol\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"input\":[{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"ping\"}]}]") != null);
}

test "native Responses payload canonicalizes string input" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"gpt-5.6-sol","stream":true,"input":"ping"}
    ;
    const payload = try buildZedPayload(allocator, body, false);
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"input\":[{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"ping\"}]}]") != null);
}

test "native Responses normalizes Codex additional tools and developer role for Zed" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"gpt-5.6-sol","stream":true,"input":[{"type":"additional_tools","role":"developer","tools":[{"type":"custom","name":"exec","description":"run code","format":{"type":"text"}},{"type":"function","name":"wait","description":"wait","strict":true,"parameters":{"type":"object","properties":{}}},{"type":"namespace","name":"collaboration","description":"agent tools","tools":[{"type":"function","name":"spawn_agent","parameters":{"type":"object"}}]}]},{"type":"message","role":"developer","content":[{"type":"input_text","text":"follow project rules"}]},{"type":"message","role":"user","content":[{"type":"input_text","text":"ping"}]}],"tool_choice":"auto","reasoning":{"effort":"xhigh"}}
    ;
    const payload = try buildZedPayload(allocator, body, false);
    defer allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const request = parsed.value.object.get("provider_request").?.object;
    const input = request.get("input").?.array;
    try std.testing.expectEqual(@as(usize, 2), input.items.len);
    try std.testing.expectEqualStrings("system", input.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("user", input.items[1].object.get("role").?.string);

    const tools = request.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 2), tools.items.len);
    try std.testing.expectEqualStrings("custom", tools.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("exec", tools.items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("function", tools.items[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("wait", tools.items[1].object.get("name").?.string);
}

test "Chat Completions preserves every Zed-hosted GPT 5.6 reasoning_effort" {
    const allocator = std.testing.allocator;
    const models = [_][]const u8{ "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna" };
    const efforts = [_][]const u8{ "none", "low", "medium", "high", "xhigh" };

    for (models) |model| {
        for (efforts) |effort| {
            const body = try std.fmt.allocPrint(
                allocator,
                "{{\"model\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":\"ping\"}}],\"reasoning_effort\":\"{s}\",\"max_completion_tokens\":2048}}",
                .{ model, effort },
            );
            defer allocator.free(body);
            const payload = try buildZedPayload(allocator, body, false);
            defer allocator.free(payload);

            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
            defer parsed.deinit();
            const request = parsed.value.object.get("provider_request").?.object;
            try std.testing.expectEqualStrings(model, request.get("model").?.string);
            try std.testing.expectEqualStrings(effort, request.get("reasoning").?.object.get("effort").?.string);
            const expected_budget: i64 = if (effortNeedsLargeOutputBudget(effort)) GPT_REASONING_OUTPUT_FLOOR else 2048;
            try std.testing.expectEqual(expected_budget, request.get("max_output_tokens").?.integer);
        }
    }
}

test "GPT 5.6 unsupported efforts are rejected instead of downgraded" {
    const allocator = std.testing.allocator;
    const max_body =
        \\{"model":"gpt-5.6-sol","input":"ping","reasoning":{"effort":"max"}}
    ;
    const minimal_body =
        \\{"model":"gpt-5.6-terra","messages":[{"role":"user","content":"ping"}],"reasoning_effort":"minimal"}
    ;

    try std.testing.expectError(error.UnsupportedReasoningEffort, validateClientReasoningEffort(allocator, max_body, false));
    try std.testing.expectError(error.UnsupportedReasoningEffort, validateClientReasoningEffort(allocator, minimal_body, false));
    try validateClientReasoningEffort(allocator, max_body, true); // Claude Messages is forced to xhigh.
}

test "Chat Completions accepts nested effort and defaults missing effort to xhigh" {
    const allocator = std.testing.allocator;
    const nested = try buildZedPayload(
        allocator,
        "{\"model\":\"gpt-5.6-terra\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"reasoning\":{\"effort\":\"low\",\"summary\":\"auto\"}}",
        false,
    );
    defer allocator.free(nested);
    const nested_parsed = try std.json.parseFromSlice(std.json.Value, allocator, nested, .{});
    defer nested_parsed.deinit();
    const nested_reasoning = nested_parsed.value.object.get("provider_request").?.object.get("reasoning").?.object;
    try std.testing.expectEqualStrings("low", nested_reasoning.get("effort").?.string);
    try std.testing.expectEqualStrings("auto", nested_reasoning.get("summary").?.string);

    const defaulted = try buildZedPayload(
        allocator,
        "{\"model\":\"gpt-5.6-luna\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}",
        false,
    );
    defer allocator.free(defaulted);
    const defaulted_parsed = try std.json.parseFromSlice(std.json.Value, allocator, defaulted, .{});
    defer defaulted_parsed.deinit();
    const defaulted_request = defaulted_parsed.value.object.get("provider_request").?.object;
    try std.testing.expectEqualStrings("xhigh", defaulted_request.get("reasoning").?.object.get("effort").?.string);
}

test "Claude Messages forces GPT 5.6 to xhigh" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"gpt-5.6-terra","max_tokens":1024,"reasoning_effort":"low","messages":[{"role":"user","content":"ping"}]}
    ;
    const payload = try buildZedPayload(allocator, body, true);
    defer allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const request = parsed.value.object.get("provider_request").?.object;
    try std.testing.expectEqualStrings("gpt-5.6-terra", request.get("model").?.string);
    try std.testing.expectEqualStrings("xhigh", request.get("reasoning").?.object.get("effort").?.string);
    try std.testing.expectEqual(@as(i64, GPT_REASONING_OUTPUT_FLOOR), request.get("max_output_tokens").?.integer);
}

test "OpenAI Chat tool history becomes Responses function items" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"gpt-5.6-terra","messages":[{"role":"user","content":"run"},{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{\"key\":\"v\"}"}}]},{"role":"tool","tool_call_id":"call_1","content":"done"}]}
    ;
    const payload = try buildZedPayload(allocator, body, false);
    defer allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const request = parsed.value.object.get("provider_request").?.object;
    const input = request.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), input.len);
    try std.testing.expectEqualStrings("message", input[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("function_call", input[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", input[1].object.get("call_id").?.string);
    try std.testing.expectEqualStrings("{\"key\":\"v\"}", input[1].object.get("arguments").?.string);
    try std.testing.expectEqualStrings("function_call_output", input[2].object.get("type").?.string);
    try std.testing.expectEqualStrings("done", input[2].object.get("output").?.string);
}

test "official tool choice is adapted to the Zed parser" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"gpt-5.6-luna","stream":true,"input":"call lookup","tools":[{"type":"function","name":"other","parameters":{"type":"object","properties":{}}},{"type":"function","name":"lookup","parameters":{"type":"object","properties":{}}}],"tool_choice":{"type":"function","name":"lookup"}}
    ;
    const payload = try buildZedPayload(allocator, body, false);
    defer allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const request = parsed.value.object.get("provider_request").?.object;
    try std.testing.expectEqualStrings("required", request.get("tool_choice").?.string);
    const tools = request.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings("lookup", tools[0].object.get("name").?.string);
}

test "native Sonnet 5 preserves official Anthropic system blocks" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"claude-sonnet-5","max_tokens":1024,"output_config":{"effort":"xhigh"},"system":[{"type":"text","text":"system prompt","cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user","content":"ping"}]}
    ;
    const payload = try buildZedPayload(allocator, body, true);
    defer allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const request = parsed.value.object.get("provider_request").?.object;
    try std.testing.expectEqualStrings("claude-sonnet-5", request.get("model").?.string);
    const system = request.get("system").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), system.len);
    try std.testing.expectEqualStrings("ephemeral", system[0].object.get("cache_control").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("xhigh", request.get("output_config").?.object.get("effort").?.string);
    const message_content = request.get("messages").?.array.items[0].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("text", message_content[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("ping", message_content[0].object.get("text").?.string);
    try std.testing.expect(request.get("reasoning") == null);
}

test "native Sonnet 5 merges Claude Code trailing system message" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"claude-sonnet-5","max_tokens":1024,"output_config":{"effort":"xhigh"},"system":[{"type":"text","text":"base system","cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user","content":[{"type":"text","text":"ping"}]},{"role":"system","content":"workspace instructions"}]}
    ;
    const payload = try buildZedPayload(allocator, body, true);
    defer allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const request = parsed.value.object.get("provider_request").?.object;

    const system = request.get("system").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), system.len);
    try std.testing.expectEqualStrings("base system", system[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("ephemeral", system[0].object.get("cache_control").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("workspace instructions", system[1].object.get("text").?.string);

    const messages = request.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("user", messages[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("xhigh", request.get("output_config").?.object.get("effort").?.string);
    try std.testing.expect(request.get("reasoning") == null);
}

test "OpenAI system and developer messages become Anthropic top-level system" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"claude-sonnet-5","messages":[{"role":"system","content":"system"},{"role":"developer","content":"developer"},{"role":"user","content":"ping"}]}
    ;
    const payload = try buildZedPayload(allocator, body, false);
    defer allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const request = parsed.value.object.get("provider_request").?.object;
    try std.testing.expectEqualStrings("system\n\ndeveloper", request.get("system").?.string);
    const messages = request.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("user", messages[0].object.get("role").?.string);
}

test "Zed envelope uses distinct RFC 4122 version-4 UUIDs" {
    const allocator = std.testing.allocator;
    const payload = try buildZedPayload(allocator, "{\"model\":\"gpt-5.6-sol\",\"input\":\"ping\"}", false);
    defer allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const thread_id = parsed.value.object.get("thread_id").?.string;
    const prompt_id = parsed.value.object.get("prompt_id").?.string;

    try std.testing.expectEqual(@as(usize, 36), thread_id.len);
    try std.testing.expectEqual(@as(usize, 36), prompt_id.len);
    try std.testing.expectEqual(@as(u8, '4'), thread_id[14]);
    try std.testing.expectEqual(@as(u8, '4'), prompt_id[14]);
    try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", thread_id[19]) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", prompt_id[19]) != null);
    try std.testing.expect(!std.mem.eql(u8, thread_id, prompt_id));
}

test "non-streaming Responses returns official completed envelope" {
    const allocator = std.testing.allocator;
    const upstream =
        \\{"event":{"type":"response.completed","response":{"id":"resp_1","status":"completed","status_details":null,"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2},"output":[{"type":"message","id":"msg_1","role":"assistant","status":"completed","content":[{"type":"output_text","text":"ok","annotations":[]}]}]}}}
        \\{"status":"stream_ended"}
    ;
    const output = try convertToResponses(allocator, upstream, "gpt-5.6-sol");
    defer allocator.free(output);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("response", parsed.value.object.get("object").?.string);
    try std.testing.expectEqualStrings("gpt-5.6-sol", parsed.value.object.get("model").?.string);
    try std.testing.expectEqualStrings("resp_1", parsed.value.object.get("id").?.string);
    try std.testing.expectEqualStrings("ok", parsed.value.object.get("output").?.array.items[0].object.get("content").?.array.items[0].object.get("text").?.string);
}

fn buildGoogleRequest(allocator: std.mem.Allocator, w: *std.io.Writer, parsed: std.json.Value, model: []const u8, is_anthropic: bool) !void {
    try w.print("\"model\":\"models/{s}\",", .{model});

    if (is_anthropic) {
        if (try collectAnthropicSystemText(allocator, parsed)) |sys_text| {
            defer allocator.free(sys_text);
            try w.writeAll("\"systemInstruction\":{\"parts\":[{\"text\":");
            try std.json.Stringify.encodeJsonString(sys_text, .{}, w);
            try w.writeAll("}]},");
        }
    }

    try w.writeAll("\"generationConfig\":{\"candidateCount\":1,\"stopSequences\":[],\"temperature\":1.0},");

    // Tools support for Google format
    if (is_anthropic) {
        // Anthropic tools -> Google functionDeclarations
        if (parsed.object.get("tools")) |tools| {
            if (tools == .array and tools.array.items.len > 0) {
                try w.writeAll("\"tools\":[{\"functionDeclarations\":[");
                var first = true;
                for (tools.array.items) |tool| {
                    if (tool != .object) continue;
                    if (!first) try w.writeAll(",");
                    first = false;
                    try w.writeAll("{");
                    if (tool.object.get("name")) |n| {
                        try w.writeAll("\"name\":");
                        try std.json.Stringify.value(n, .{}, w);
                    }
                    if (tool.object.get("description")) |d| {
                        try w.writeAll(",\"description\":");
                        try std.json.Stringify.value(d, .{}, w);
                    }
                    if (tool.object.get("input_schema")) |s| {
                        try w.writeAll(",\"parameters\":");
                        try std.json.Stringify.value(s, .{}, w);
                    }
                    try w.writeAll("}");
                }
                try w.writeAll("]}],");
            }
        }
    } else {
        // OpenAI tools -> Google functionDeclarations
        if (parsed.object.get("tools")) |tools| {
            if (tools == .array and tools.array.items.len > 0) {
                try w.writeAll("\"tools\":[{\"functionDeclarations\":[");
                var first = true;
                for (tools.array.items) |tool| {
                    if (tool != .object) continue;
                    const func = tool.object.get("function") orelse continue;
                    if (func != .object) continue;
                    if (!first) try w.writeAll(",");
                    first = false;
                    try w.writeAll("{");
                    if (func.object.get("name")) |n| {
                        try w.writeAll("\"name\":");
                        try std.json.Stringify.value(n, .{}, w);
                    }
                    if (func.object.get("description")) |d| {
                        try w.writeAll(",\"description\":");
                        try std.json.Stringify.value(d, .{}, w);
                    }
                    if (func.object.get("parameters")) |p| {
                        try w.writeAll(",\"parameters\":");
                        try std.json.Stringify.value(p, .{}, w);
                    }
                    try w.writeAll("}");
                }
                try w.writeAll("]}],");
            }
        }
    }

    try w.writeAll("\"contents\":[");

    if (parsed.object.get("messages")) |msgs| {
        if (msgs == .array) for (msgs.array.items, 0..) |msg, i| {
            if (msg != .object) continue;
            const role = switch (msg.object.get("role") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const content = msg.object.get("content") orelse continue;
            if (i > 0) try w.writeAll(",");
            const gemini_role = if (std.mem.eql(u8, role, "assistant")) "model" else role;
            try w.print("{{\"parts\":[", .{});
            switch (content) {
                .string => |s| {
                    try w.writeAll("{\"text\":");
                    try std.json.Stringify.encodeJsonString(s, .{}, w);
                    try w.writeAll("}");
                },
                .array => {
                    for (content.array.items, 0..) |item, ci| {
                        if (ci > 0) try w.writeAll(",");
                        if (item == .object) {
                            const text_val = item.object.get("text") orelse continue;
                            if (text_val != .string) continue;
                            try w.writeAll("{\"text\":");
                            try std.json.Stringify.encodeJsonString(text_val.string, .{}, w);
                            try w.writeAll("}");
                        }
                    }
                },
                else => {},
            }
            try w.print("],\"role\":\"{s}\"}}", .{gemini_role});
        };
    }
    try w.writeAll("]");
}

fn buildXAIRequest(allocator: std.mem.Allocator, w: *std.io.Writer, parsed: std.json.Value, model: []const u8, is_anthropic: bool) !void {
    try w.print("\"model\":\"{s}\",\"stream\":true,", .{model});
    if (parsed.object.get("temperature")) |temp| {
        try w.writeAll("\"temperature\":");
        try std.json.Stringify.value(temp, .{}, w);
        try w.writeAll(",");
    } else {
        try w.writeAll("\"temperature\":1.0,");
    }
    try w.writeAll("\"messages\":[");
    var wrote_any = false;
    if (is_anthropic) {
        if (try collectAnthropicSystemText(allocator, parsed)) |sys_text| {
            defer allocator.free(sys_text);
            try w.writeAll("{\"role\":\"system\",\"content\":");
            try std.json.Stringify.encodeJsonString(sys_text, .{}, w);
            try w.writeAll("}");
            wrote_any = true;
        }
    }
    if (parsed.object.get("messages")) |msgs| {
        if (msgs == .array) for (msgs.array.items) |msg| {
            if (msg != .object) continue;
            const role = switch (msg.object.get("role") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const content = msg.object.get("content") orelse continue;
            if (wrote_any) try w.writeAll(",");
            wrote_any = true;
            try w.print("{{\"role\":\"{s}\",\"content\":", .{role});
            switch (content) {
                .string => try std.json.Stringify.encodeJsonString(content.string, .{}, w),
                .array => {
                    var buf: std.io.Writer.Allocating = .init(allocator);
                    defer buf.deinit();
                    for (content.array.items) |item| {
                        if (item == .object) {
                            const text_val = item.object.get("text") orelse continue;
                            if (text_val == .string) buf.writer.writeAll(text_val.string) catch continue;
                        }
                    }
                    try std.json.Stringify.encodeJsonString(buf.written(), .{}, w);
                },
                else => try w.writeAll("\"\""),
            }
            try w.writeAll("}");
        };
    }
    try w.writeAll("]");
}

// ── Response conversion ──

pub const StreamContent = struct {
    thinking: ?[]const u8,
    text: []const u8,
    tool_calls: ?[]const u8, // JSON array of tool_use blocks
};

pub fn extractContentFromStream(allocator: std.mem.Allocator, response: []const u8) !StreamContent {
    var text_buf: std.io.Writer.Allocating = .init(allocator);
    errdefer text_buf.deinit();
    var think_buf: std.io.Writer.Allocating = .init(allocator);
    errdefer think_buf.deinit();
    var tool_buf: std.io.Writer.Allocating = .init(allocator);
    errdefer tool_buf.deinit();

    // Track tool_use blocks being built from streaming events
    var current_tool_id: ?[]const u8 = null;
    var current_tool_name: ?[]const u8 = null;
    var tool_input_buf: std.io.Writer.Allocating = .init(allocator);
    defer tool_input_buf.deinit();
    var tool_count: usize = 0;

    var lines = std.mem.splitScalar(u8, response, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const p = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer p.deinit();

        const obj = if (p.value.object.get("event")) |event|
            (if (event == .object) event else p.value)
        else
            p.value;

        if (obj.object.get("type")) |et| {
            if (et == .string) {
                if (std.mem.eql(u8, et.string, "response.output_text.delta")) {
                    if (obj.object.get("delta")) |d| {
                        if (d == .string) try text_buf.writer.writeAll(d.string);
                    }
                    continue;
                }
                if (std.mem.eql(u8, et.string, "response.reasoning_summary_text.delta") or
                    std.mem.eql(u8, et.string, "response.reasoning_text.delta"))
                {
                    if (obj.object.get("delta")) |d| {
                        if (d == .string) try think_buf.writer.writeAll(d.string);
                    }
                    continue;
                }
                if (std.mem.eql(u8, et.string, "response.output_item.added")) {
                    const item = obj.object.get("item") orelse continue;
                    if (item != .object) continue;
                    const it_type = switch (item.object.get("type") orelse continue) {
                        .string => |s| s,
                        else => continue,
                    };
                    if (!std.mem.eql(u8, it_type, "function_call")) continue;
                    const id_val = item.object.get("call_id") orelse item.object.get("id");
                    if (id_val) |idv| {
                        if (idv == .string) {
                            if (current_tool_id) |old| allocator.free(old);
                            current_tool_id = allocator.dupe(u8, idv.string) catch null;
                        }
                    }
                    if (item.object.get("name")) |name| {
                        if (name == .string) {
                            if (current_tool_name) |old| allocator.free(old);
                            current_tool_name = allocator.dupe(u8, name.string) catch null;
                        }
                    }
                    tool_input_buf.deinit();
                    tool_input_buf = .init(allocator);
                    continue;
                }
                if (std.mem.eql(u8, et.string, "response.function_call_arguments.delta")) {
                    if (obj.object.get("delta")) |d| {
                        if (d == .string) try tool_input_buf.writer.writeAll(d.string);
                    }
                    continue;
                }
                if (std.mem.eql(u8, et.string, "response.function_call_arguments.done") or
                    std.mem.eql(u8, et.string, "response.output_item.done"))
                {
                    if (current_tool_id != null and current_tool_name != null) {
                        const tw = &tool_buf.writer;
                        if (tool_count > 0) try tw.writeAll(",");
                        try tw.writeAll("{\"id\":");
                        try std.json.Stringify.encodeJsonString(current_tool_id.?, .{}, tw);
                        try tw.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                        try std.json.Stringify.encodeJsonString(current_tool_name.?, .{}, tw);
                        try tw.writeAll(",\"arguments\":");
                        const input_json = tool_input_buf.written();
                        if (input_json.len > 0) {
                            try std.json.Stringify.encodeJsonString(input_json, .{}, tw);
                        } else {
                            try tw.writeAll("\"{}\"");
                        }
                        try tw.writeAll("}}");
                        tool_count += 1;
                        allocator.free(current_tool_id.?);
                        current_tool_id = null;
                        allocator.free(current_tool_name.?);
                        current_tool_name = null;
                        tool_input_buf.deinit();
                        tool_input_buf = .init(allocator);
                    }
                    continue;
                }
                if (std.mem.eql(u8, et.string, "content_block_start")) {
                    const cb = obj.object.get("content_block") orelse continue;
                    if (cb != .object) continue;
                    const cb_type = switch (cb.object.get("type") orelse continue) {
                        .string => |s| s,
                        else => continue,
                    };
                    if (std.mem.eql(u8, cb_type, "tool_use")) {
                        if (cb.object.get("id")) |id| {
                            if (id == .string) {
                                if (current_tool_id) |old| allocator.free(old);
                                current_tool_id = allocator.dupe(u8, id.string) catch null;
                            }
                        }
                        if (cb.object.get("name")) |name| {
                            if (name == .string) {
                                if (current_tool_name) |old| allocator.free(old);
                                current_tool_name = allocator.dupe(u8, name.string) catch null;
                            }
                        }
                        tool_input_buf.deinit();
                        tool_input_buf = .init(allocator);
                    }
                    continue;
                }
                if (std.mem.eql(u8, et.string, "content_block_delta")) {
                    const delta = obj.object.get("delta") orelse continue;
                    if (delta != .object) continue;
                    const dt = switch (delta.object.get("type") orelse continue) {
                        .string => |s| s,
                        else => continue,
                    };
                    if (std.mem.eql(u8, dt, "text_delta")) {
                        if (delta.object.get("text")) |t| {
                            if (t == .string) try text_buf.writer.writeAll(t.string);
                        }
                    } else if (std.mem.eql(u8, dt, "thinking_delta")) {
                        if (delta.object.get("thinking")) |t| {
                            if (t == .string) try think_buf.writer.writeAll(t.string);
                        }
                    } else if (std.mem.eql(u8, dt, "input_json_delta")) {
                        if (delta.object.get("partial_json")) |pj| {
                            if (pj == .string) try tool_input_buf.writer.writeAll(pj.string);
                        }
                    }
                    continue;
                }
                if (std.mem.eql(u8, et.string, "content_block_stop")) {
                    // Finalize tool_use block if we were building one
                    if (current_tool_id != null and current_tool_name != null) {
                        const tw = &tool_buf.writer;
                        if (tool_count > 0) try tw.writeAll(",");
                        try tw.writeAll("{\"id\":");
                        try std.json.Stringify.encodeJsonString(current_tool_id.?, .{}, tw);
                        try tw.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                        try std.json.Stringify.encodeJsonString(current_tool_name.?, .{}, tw);
                        try tw.writeAll(",\"arguments\":");
                        const input_json = tool_input_buf.written();
                        if (input_json.len > 0) {
                            try std.json.Stringify.encodeJsonString(input_json, .{}, tw);
                        } else {
                            try tw.writeAll("\"{}\"");
                        }
                        try tw.writeAll("}}");
                        tool_count += 1;
                        allocator.free(current_tool_id.?);
                        current_tool_id = null;
                        allocator.free(current_tool_name.?);
                        current_tool_name = null;
                        tool_input_buf.deinit();
                        tool_input_buf = .init(allocator);
                    }
                    continue;
                }
            }
        }

        if (obj.object.get("choices")) |choices| {
            if (choices == .array and choices.array.items.len > 0) {
                const choice = choices.array.items[0];
                if (choice == .object) {
                    if (choice.object.get("delta")) |delta| {
                        if (delta == .object) {
                            if (delta.object.get("content")) |c| {
                                if (c == .string) try text_buf.writer.writeAll(c.string);
                            }
                        }
                    }
                }
            }
            continue;
        }

        if (obj.object.get("candidates")) |candidates| {
            if (candidates == .array and candidates.array.items.len > 0) {
                const cand = candidates.array.items[0];
                if (cand == .object) {
                    if (cand.object.get("content")) |content| {
                        if (content == .object) {
                            if (content.object.get("parts")) |parts| {
                                if (parts == .array) for (parts.array.items) |part| {
                                    if (part == .object) {
                                        if (part.object.get("text")) |t| {
                                            if (t == .string) try text_buf.writer.writeAll(t.string);
                                        }
                                    }
                                };
                            }
                        }
                    }
                }
            }
            continue;
        }
    }

    // Cleanup any dangling tool state
    if (current_tool_id) |id| allocator.free(id);
    if (current_tool_name) |name| allocator.free(name);

    const text = try text_buf.toOwnedSlice();
    const think_written = think_buf.written();
    const tool_written = tool_buf.written();

    var thinking: ?[]const u8 = null;
    if (think_written.len > 0) {
        thinking = try allocator.dupe(u8, think_written);
    }
    think_buf.deinit();

    var tool_calls: ?[]const u8 = null;
    if (tool_written.len > 0) {
        // Wrap in array brackets
        const tc = try std.fmt.allocPrint(allocator, "[{s}]", .{tool_written});
        tool_calls = tc;
    }
    tool_buf.deinit();

    return .{ .thinking = thinking, .text = text, .tool_calls = tool_calls };
}

pub fn convertToOpenAI(allocator: std.mem.Allocator, response: []const u8, model: []const u8) ![]const u8 {
    const sc = try extractContentFromStream(allocator, response);
    defer allocator.free(sc.text);
    defer if (sc.thinking) |t| allocator.free(t);
    defer if (sc.tool_calls) |t| allocator.free(t);

    var result: std.io.Writer.Allocating = .init(allocator);
    errdefer result.deinit();
    const w = &result.writer;

    try w.writeAll("{\"id\":\"chatcmpl-zed\",\"object\":\"chat.completion\",\"model\":\"");
    try w.writeAll(model);
    try w.writeAll("\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\"");
    if (sc.thinking) |thinking| {
        try w.writeAll(",\"thinking\":");
        try std.json.Stringify.encodeJsonString(thinking, .{}, w);
    }
    try w.writeAll(",\"content\":");
    if (sc.tool_calls != null and sc.text.len == 0) {
        try w.writeAll("null");
    } else {
        try std.json.Stringify.encodeJsonString(sc.text, .{}, w);
    }
    if (sc.tool_calls) |tc| {
        try w.writeAll(",\"tool_calls\":");
        try w.writeAll(tc);
    }
    const finish_reason = if (sc.tool_calls != null) "tool_calls" else "stop";
    try w.print("}},\"finish_reason\":\"{s}\"}}]}}", .{finish_reason});
    return try result.toOwnedSlice();
}

/// Convert Zed's line-delimited, wrapped Responses stream into the ordinary
/// non-streaming Responses object returned when a client omits `stream` or
/// sends `stream=false`. The completed event already contains the authoritative
/// output and usage; add only standard envelope fields Zed omits.
pub fn convertToResponses(allocator: std.mem.Allocator, response: []const u8, model: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, response, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "data:")) line = std.mem.trim(u8, line[5..], " \t");
        if (line.len == 0 or std.mem.eql(u8, line, "[DONE]") or line[0] != '{') continue;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const event = parsed.value.object.get("event") orelse parsed.value;
        if (event != .object) continue;
        const event_type = switch (event.object.get("type") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        if (!std.mem.eql(u8, event_type, "response.completed")) continue;
        const completed = event.object.get("response") orelse return error.InvalidUpstreamResponse;
        if (completed != .object) return error.InvalidUpstreamResponse;

        var result: std.io.Writer.Allocating = .init(allocator);
        errdefer result.deinit();
        const w = &result.writer;
        try w.writeAll("{\"object\":\"response\",\"created_at\":");
        try w.print("{d}", .{std.time.timestamp()});
        try w.writeAll(",\"model\":");
        try std.json.Stringify.encodeJsonString(model, .{}, w);

        var it = completed.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "object") or std.mem.eql(u8, key, "created_at") or std.mem.eql(u8, key, "model")) continue;
            try w.writeAll(",");
            try std.json.Stringify.encodeJsonString(key, .{}, w);
            try w.writeAll(":");
            try std.json.Stringify.value(entry.value_ptr.*, .{}, w);
        }
        try w.writeAll("}");
        return try result.toOwnedSlice();
    }
    return error.InvalidUpstreamResponse;
}

pub fn convertToAnthropic(allocator: std.mem.Allocator, response: []const u8, model: []const u8) ![]const u8 {
    const sc = try extractContentFromStream(allocator, response);
    defer allocator.free(sc.text);
    defer if (sc.thinking) |t| allocator.free(t);
    defer if (sc.tool_calls) |t| allocator.free(t);

    var result: std.io.Writer.Allocating = .init(allocator);
    errdefer result.deinit();
    const w = &result.writer;

    try w.writeAll("{\"id\":\"msg_zed\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"");
    try w.writeAll(model);
    try w.writeAll("\",\"content\":[");
    var wrote_any = false;
    if (sc.thinking) |thinking| {
        try w.writeAll("{\"type\":\"thinking\",\"thinking\":");
        try std.json.Stringify.encodeJsonString(thinking, .{}, w);
        try w.writeAll("}");
        wrote_any = true;
    }
    if (sc.text.len > 0) {
        if (wrote_any) try w.writeAll(",");
        try w.writeAll("{\"type\":\"text\",\"text\":");
        try std.json.Stringify.encodeJsonString(sc.text, .{}, w);
        try w.writeAll("}");
        wrote_any = true;
    }
    if (sc.tool_calls) |tc| {
        // Convert OpenAI-format tool_calls back to Anthropic tool_use blocks
        const parsed_tc = std.json.parseFromSlice(std.json.Value, allocator, tc, .{}) catch null;
        if (parsed_tc) |ptc| {
            defer ptc.deinit();
            if (ptc.value == .array) {
                for (ptc.value.array.items) |tool_call| {
                    if (tool_call != .object) continue;
                    if (wrote_any) try w.writeAll(",");
                    wrote_any = true;
                    try w.writeAll("{\"type\":\"tool_use\"");
                    if (tool_call.object.get("id")) |id| {
                        try w.writeAll(",\"id\":");
                        try std.json.Stringify.value(id, .{}, w);
                    }
                    if (tool_call.object.get("function")) |func| {
                        if (func == .object) {
                            if (func.object.get("name")) |n| {
                                try w.writeAll(",\"name\":");
                                try std.json.Stringify.value(n, .{}, w);
                            }
                            if (func.object.get("arguments")) |args| {
                                try w.writeAll(",\"input\":");
                                if (args == .string) {
                                    // Parse the JSON string into an object
                                    const parsed_args = std.json.parseFromSlice(std.json.Value, allocator, args.string, .{}) catch {
                                        try w.writeAll("{}");
                                        try w.writeAll("}");
                                        continue;
                                    };
                                    defer parsed_args.deinit();
                                    try std.json.Stringify.value(parsed_args.value, .{}, w);
                                } else {
                                    try std.json.Stringify.value(args, .{}, w);
                                }
                            } else {
                                try w.writeAll(",\"input\":{}");
                            }
                        }
                    }
                    try w.writeAll("}");
                }
            }
        }
    }
    if (!wrote_any) {
        try w.writeAll("{\"type\":\"text\",\"text\":\"\"}");
    }
    const stop_reason = if (sc.tool_calls != null) "tool_use" else "end_turn";
    try w.print("],\"stop_reason\":\"{s}\"}}", .{stop_reason});
    return try result.toOwnedSlice();
}
