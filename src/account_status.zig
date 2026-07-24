const std = @import("std");

/// A deliberately small, credential-free view of Zed's `/client/users/me`
/// response. String slices borrow from the parsed JSON and must be consumed
/// before that parsed value is released.
pub const BillingSummary = struct {
    plan: []const u8 = "unknown",
    used: ?i64 = null,
    limit: ?i64 = null,
    subscription_ends_at: ?[]const u8 = null,
    usage_based_billing: bool = false,
    overdue: bool = false,
    account_too_young: bool = false,
};

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn intField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        else => null,
    };
}

fn boolField(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return false;
    return switch (value) {
        .bool => |flag| flag,
        else => false,
    };
}

pub fn summarize(root: std.json.Value) BillingSummary {
    var result: BillingSummary = .{};
    if (root != .object) return result;

    const plan_value = root.object.get("plan") orelse return result;
    if (plan_value != .object) return result;
    const plan = plan_value.object;

    // Zed currently exposes several generations of plan identifiers. Prefer
    // the newest one while keeping older accounts readable.
    result.plan = stringField(plan, "plan_v3") orelse
        stringField(plan, "plan_v2") orelse
        stringField(plan, "plan") orelse
        "unknown";
    result.overdue = boolField(plan, "has_overdue_invoices");
    result.account_too_young = boolField(plan, "is_account_too_young");
    result.usage_based_billing = boolField(plan, "is_usage_based_billing_enabled");

    if (plan.get("subscription_period")) |period_value| {
        if (period_value == .object) {
            result.subscription_ends_at = stringField(period_value.object, "ended_at");
        }
    }

    const usage_value = plan.get("usage") orelse return result;
    if (usage_value != .object) return result;
    const requests_value = usage_value.object.get("model_requests") orelse return result;
    if (requests_value != .object) return result;
    const requests = requests_value.object;
    result.used = intField(requests, "used");

    if (requests.get("limit")) |limit_value| {
        switch (limit_value) {
            .integer => |number| result.limit = number,
            .object => |limit_object| result.limit = intField(limit_object, "limited"),
            else => {},
        }
    }
    return result;
}

/// A zero/missing numeric limit is treated as unmetered/undisclosed. Zed's
/// current student response is `{ "limited": 0 }` while model requests work,
/// so interpreting zero as exhaustion would produce a false alarm.
pub fn quotaState(summary: BillingSummary) []const u8 {
    if (summary.account_too_young) return "restricted";
    if (summary.limit) |limit| {
        if (limit > 0) {
            if ((summary.used orelse 0) >= limit) return "exhausted";
            return "available";
        }
    }
    return "unmetered";
}

pub fn remaining(summary: BillingSummary) ?i64 {
    const limit = summary.limit orelse return null;
    if (limit <= 0) return null;
    return @max(@as(i64, 0), limit - (summary.used orelse 0));
}

pub fn isUsable(summary: BillingSummary) bool {
    const state = quotaState(summary);
    return !std.mem.eql(u8, state, "exhausted") and !std.mem.eql(u8, state, "restricted");
}

test "limited plan exposes remaining quota" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"plan":{"plan_v3":"zed_pro","subscription_period":{"ended_at":"2026-08-20T00:00:00Z"},"usage":{"model_requests":{"used":12,"limit":{"limited":50}}}}}
    , .{});
    defer parsed.deinit();

    const summary = summarize(parsed.value);
    try std.testing.expectEqualStrings("zed_pro", summary.plan);
    try std.testing.expectEqual(@as(?i64, 12), summary.used);
    try std.testing.expectEqual(@as(?i64, 50), summary.limit);
    try std.testing.expectEqual(@as(?i64, 38), remaining(summary));
    try std.testing.expectEqualStrings("available", quotaState(summary));
    try std.testing.expect(isUsable(summary));
}

test "exhausted plan is not usable" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"plan":{"usage":{"model_requests":{"used":50,"limit":{"limited":50}}}}}
    , .{});
    defer parsed.deinit();

    const summary = summarize(parsed.value);
    try std.testing.expectEqualStrings("exhausted", quotaState(summary));
    try std.testing.expectEqual(@as(?i64, 0), remaining(summary));
    try std.testing.expect(!isUsable(summary));
}

test "zero limit is unmetered instead of a false exhaustion" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"plan":{"plan_v3":"zed_student","usage":{"model_requests":{"used":0,"limit":{"limited":0}}}}}
    , .{});
    defer parsed.deinit();

    const summary = summarize(parsed.value);
    try std.testing.expectEqualStrings("unmetered", quotaState(summary));
    try std.testing.expectEqual(@as(?i64, null), remaining(summary));
    try std.testing.expect(isUsable(summary));
}
