const std = @import("std");
const jh = @import("json_helper.zig");

/// Read the preferredLanguage from ~/.claude/settings.json.
/// Returns null if the file doesn't exist or has no language setting.
pub fn readPreferredLanguage(alloc: std.mem.Allocator) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;

    // Try settings.json, then settings.local.json
    const paths = [_][]const u8{ "/settings.local.json", "/settings.json" };
    for (&paths) |suffix| {
        const path = std.fmt.allocPrint(alloc, "{s}/.claude{s}", .{ home, suffix }) catch continue;
        defer alloc.free(path);

        if (readLanguageFromFile(alloc, path)) |lang| return lang;
    }
    return null;
}

fn readLanguageFromFile(alloc: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const content = file.readToEndAlloc(alloc, 64 * 1024) catch return null;
    defer alloc.free(content);

    const parsed = jh.parse(alloc, content) catch return null;
    defer parsed.deinit();

    const lang = jh.getString(parsed.value, "preferredLanguage") orelse return null;
    // Dupe so it outlives the parsed JSON
    return alloc.dupe(u8, lang) catch null;
}
