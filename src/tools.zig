const std = @import("std");
const jh = @import("json_helper.zig");
const terminal = @import("terminal.zig");

const Value = jh.Value;

const MAX_FILE_SIZE: usize = 1024 * 1024; // 1MB
const MAX_OUTPUT_SIZE: usize = 64 * 1024; // 64KB

/// Execute a tool by name with given parameters
pub fn execute(alloc: std.mem.Allocator, name: []const u8, params: Value) ![]const u8 {
    if (std.mem.eql(u8, name, "read_file")) {
        return readFile(alloc, params);
    } else if (std.mem.eql(u8, name, "write_file")) {
        return writeFile(alloc, params);
    } else if (std.mem.eql(u8, name, "edit_file")) {
        return editFile(alloc, params);
    } else if (std.mem.eql(u8, name, "bash")) {
        return bashTool(alloc, params);
    } else if (std.mem.eql(u8, name, "glob")) {
        return globTool(alloc, params);
    } else if (std.mem.eql(u8, name, "grep")) {
        return grepTool(alloc, params);
    } else if (std.mem.eql(u8, name, "list_directory")) {
        return listDirectory(alloc, params);
    } else {
        return try std.fmt.allocPrint(alloc, "Unknown tool: {s}", .{name});
    }
}

fn readFile(alloc: std.mem.Allocator, params: Value) ![]const u8 {
    const file_path = jh.getString(params, "file_path") orelse
        return try alloc.dupe(u8, "Error: file_path is required");

    terminal.printTool(alloc, "read_file", file_path);

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error opening file: {s}", .{@errorName(err)});
    };
    defer file.close();

    const content = file.readToEndAlloc(alloc, MAX_FILE_SIZE) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error reading file: {s}", .{@errorName(err)});
    };

    const offset: usize = if (jh.getInt(params, "offset")) |o| @intCast(@max(0, o)) else 0;
    const limit_val = jh.getInt(params, "limit");

    if (offset == 0 and limit_val == null) {
        return content;
    }

    // Apply line-based offset and limit
    var lines: std.ArrayList(u8) = .empty;
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 0;
    var count: usize = 0;
    const limit: usize = if (limit_val) |l| @intCast(@max(1, l)) else std.math.maxInt(usize);

    while (line_iter.next()) |line| {
        line_num += 1;
        if (line_num <= offset) continue;
        if (count >= limit) break;
        if (count > 0) try lines.append(alloc, '\n');
        try lines.appendSlice(alloc, line);
        count += 1;
    }

    alloc.free(content);
    return try lines.toOwnedSlice(alloc);
}

fn writeFile(alloc: std.mem.Allocator, params: Value) ![]const u8 {
    const file_path = jh.getString(params, "file_path") orelse
        return try alloc.dupe(u8, "Error: file_path is required");
    const content = jh.getString(params, "content") orelse
        return try alloc.dupe(u8, "Error: content is required");

    terminal.printTool(alloc, "write_file", file_path);

    // Create parent directories if needed
    if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |idx| {
        const dir_path = file_path[0..idx];
        std.fs.cwd().makePath(dir_path) catch {};
    }

    const file = std.fs.cwd().createFile(file_path, .{}) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error creating file: {s}", .{@errorName(err)});
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error writing file: {s}", .{@errorName(err)});
    };

    return try std.fmt.allocPrint(alloc, "File written: {s} ({d} bytes)", .{ file_path, content.len });
}

fn editFile(alloc: std.mem.Allocator, params: Value) ![]const u8 {
    const file_path = jh.getString(params, "file_path") orelse
        return try alloc.dupe(u8, "Error: file_path is required");
    const old_string = jh.getString(params, "old_string") orelse
        return try alloc.dupe(u8, "Error: old_string is required");
    const new_string = jh.getString(params, "new_string") orelse
        return try alloc.dupe(u8, "Error: new_string is required");

    terminal.printTool(alloc, "edit_file", file_path);

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error opening file: {s}", .{@errorName(err)});
    };
    const content = file.readToEndAlloc(alloc, MAX_FILE_SIZE) catch |err| {
        file.close();
        return try std.fmt.allocPrint(alloc, "Error reading file: {s}", .{@errorName(err)});
    };
    file.close();

    // Count occurrences
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < content.len) {
        if (std.mem.indexOf(u8, content[pos..], old_string)) |idx| {
            count += 1;
            pos += idx + old_string.len;
        } else break;
    }

    if (count == 0) {
        return try alloc.dupe(u8, "Error: old_string not found in file");
    }

    // Replace
    var result: std.ArrayList(u8) = .empty;
    pos = 0;
    while (pos < content.len) {
        if (std.mem.indexOf(u8, content[pos..], old_string)) |idx| {
            try result.appendSlice(alloc, content[pos .. pos + idx]);
            try result.appendSlice(alloc, new_string);
            pos += idx + old_string.len;
        } else {
            try result.appendSlice(alloc, content[pos..]);
            break;
        }
    }

    // Write back
    const out_file = std.fs.cwd().createFile(file_path, .{}) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error writing file: {s}", .{@errorName(err)});
    };
    defer out_file.close();
    out_file.writeAll(result.items) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error writing file: {s}", .{@errorName(err)});
    };

    return try std.fmt.allocPrint(alloc, "Replaced {d} occurrence(s) in {s}", .{ count, file_path });
}

fn bashTool(alloc: std.mem.Allocator, params: Value) ![]const u8 {
    const command = jh.getString(params, "command") orelse
        return try alloc.dupe(u8, "Error: command is required");

    terminal.printTool(alloc, "bash", command);

    var child = std.process.Child.init(&[_][]const u8{ "/bin/bash", "-c", command }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        return try std.fmt.allocPrint(alloc, "Error spawning process: {s}", .{@errorName(err)});
    };

    const stdout_data = child.stdout.?.readToEndAlloc(alloc, MAX_OUTPUT_SIZE) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error reading stdout: {s}", .{@errorName(err)});
    };
    const stderr_data = child.stderr.?.readToEndAlloc(alloc, MAX_OUTPUT_SIZE) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error reading stderr: {s}", .{@errorName(err)});
    };
    const term = child.wait() catch |err| {
        return try std.fmt.allocPrint(alloc, "Error waiting for process: {s}", .{@errorName(err)});
    };

    const exit_code: u32 = switch (term) {
        .Exited => |code| code,
        else => 255,
    };

    var result: std.ArrayList(u8) = .empty;
    if (stdout_data.len > 0) {
        try result.appendSlice(alloc, stdout_data);
    }
    if (stderr_data.len > 0) {
        if (result.items.len > 0) try result.appendSlice(alloc, "\n--- stderr ---\n");
        try result.appendSlice(alloc, stderr_data);
    }
    if (exit_code != 0) {
        const exit_msg = try std.fmt.allocPrint(alloc, "\n[exit code: {d}]", .{exit_code});
        try result.appendSlice(alloc, exit_msg);
    }

    if (result.items.len == 0) {
        return try alloc.dupe(u8, "(no output)");
    }

    return try result.toOwnedSlice(alloc);
}

fn globTool(alloc: std.mem.Allocator, params: Value) ![]const u8 {
    const pattern = jh.getString(params, "pattern") orelse
        return try alloc.dupe(u8, "Error: pattern is required");
    const path = jh.getString(params, "path") orelse ".";

    terminal.printTool(alloc, "glob", pattern);

    var results: std.ArrayList(u8) = .empty;

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error opening directory: {s}", .{@errorName(err)});
    };
    defer dir.close();

    var walker = dir.walk(alloc) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error walking directory: {s}", .{@errorName(err)});
    };
    defer walker.deinit();

    var count: usize = 0;
    while (walker.next() catch null) |entry| {
        if (matchGlob(pattern, entry.path)) {
            if (count > 0) try results.append(alloc, '\n');
            if (!std.mem.eql(u8, path, ".")) {
                try results.appendSlice(alloc, path);
                try results.append(alloc, '/');
            }
            try results.appendSlice(alloc, entry.path);
            count += 1;
            if (count >= 1000) {
                try results.appendSlice(alloc, "\n... (truncated at 1000 results)");
                break;
            }
        }
    }

    if (count == 0) {
        return try std.fmt.allocPrint(alloc, "No files matching pattern: {s}", .{pattern});
    }
    return try results.toOwnedSlice(alloc);
}

fn grepTool(alloc: std.mem.Allocator, params: Value) ![]const u8 {
    const pattern = jh.getString(params, "pattern") orelse
        return try alloc.dupe(u8, "Error: pattern is required");
    const path = jh.getString(params, "path") orelse ".";

    terminal.printTool(alloc, "grep", pattern);

    var results: std.ArrayList(u8) = .empty;
    var match_count: usize = 0;

    try searchDir(alloc, path, pattern, &results, &match_count);

    if (match_count == 0) {
        return try std.fmt.allocPrint(alloc, "No matches for: {s}", .{pattern});
    }
    return try results.toOwnedSlice(alloc);
}

fn searchDir(alloc: std.mem.Allocator, path: []const u8, pattern: []const u8, results: *std.ArrayList(u8), count: *usize) !void {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = dir.walk(alloc) catch return;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (count.* >= 500) {
            try results.appendSlice(alloc, "... (truncated at 500 matches)\n");
            return;
        }

        const full_path = if (std.mem.eql(u8, path, "."))
            try alloc.dupe(u8, entry.path)
        else
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ path, entry.path });

        const file = dir.openFile(entry.path, .{}) catch continue;
        defer file.close();

        const content = file.readToEndAlloc(alloc, MAX_FILE_SIZE) catch continue;
        defer alloc.free(content);

        var line_num: usize = 0;
        var line_iter = std.mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            line_num += 1;
            if (std.mem.indexOf(u8, line, pattern) != null) {
                const truncated_line = if (line.len > 200) line[0..200] else line;
                const entry_str = try std.fmt.allocPrint(alloc, "{s}:{d}: {s}\n", .{ full_path, line_num, truncated_line });
                try results.appendSlice(alloc, entry_str);
                count.* += 1;
                if (count.* >= 500) return;
            }
        }
    }
}

fn listDirectory(alloc: std.mem.Allocator, params: Value) ![]const u8 {
    const path = jh.getString(params, "path") orelse ".";

    terminal.printTool(alloc, "list_directory", path);

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        return try std.fmt.allocPrint(alloc, "Error opening directory: {s}", .{@errorName(err)});
    };
    defer dir.close();

    var results: std.ArrayList(u8) = .empty;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        const kind_str: []const u8 = switch (entry.kind) {
            .directory => "dir",
            .file => "file",
            .sym_link => "symlink",
            else => "other",
        };
        const line = try std.fmt.allocPrint(alloc, "{s}\t{s}\n", .{ kind_str, entry.name });
        try results.appendSlice(alloc, line);
    }

    if (results.items.len == 0) {
        return try std.fmt.allocPrint(alloc, "(empty directory: {s})", .{path});
    }
    return try results.toOwnedSlice(alloc);
}

/// Simple glob pattern matching (supports * and ? and **)
fn matchGlob(pattern: []const u8, name: []const u8) bool {
    return matchGlobImpl(pattern, name);
}

fn matchGlobImpl(pattern: []const u8, name: []const u8) bool {
    var pi: usize = 0;
    var ni: usize = 0;
    var star_pi: ?usize = null;
    var star_ni: usize = 0;

    while (ni < name.len) {
        if (pi < pattern.len and pattern[pi] == '*') {
            // Check for **
            if (pi + 1 < pattern.len and pattern[pi + 1] == '*') {
                // ** matches everything including /
                pi += 2;
                if (pi < pattern.len and pattern[pi] == '/') pi += 1;
                while (ni <= name.len) {
                    if (matchGlobImpl(pattern[pi..], name[ni..])) return true;
                    if (ni == name.len) break;
                    ni += 1;
                }
                return false;
            }
            star_pi = pi;
            star_ni = ni;
            pi += 1;
        } else if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == name[ni])) {
            if (pattern[pi] == '?' and name[ni] == '/') {
                if (star_pi) |sp| {
                    pi = sp + 1;
                    star_ni += 1;
                    ni = star_ni;
                } else return false;
            } else {
                pi += 1;
                ni += 1;
            }
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_ni += 1;
            ni = star_ni;
            if (ni < name.len and name[ni - 1] == '/') return false;
        } else {
            return false;
        }
    }

    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

/// Build tool definitions for the API
pub fn getToolDefinitions(alloc: std.mem.Allocator) !Value {
    var tools = jh.array(alloc);

    try tools.append(try makeTool(alloc, "read_file", "Read the contents of a file. Returns file content as text.", &[_]PropDef{
        .{ .name = "file_path", .typ = "string", .desc = "Absolute or relative path to the file", .required = true },
        .{ .name = "offset", .typ = "integer", .desc = "Line number to start reading from (1-based)", .required = false },
        .{ .name = "limit", .typ = "integer", .desc = "Maximum number of lines to read", .required = false },
    }));

    try tools.append(try makeTool(alloc, "write_file", "Create or overwrite a file with the given content.", &[_]PropDef{
        .{ .name = "file_path", .typ = "string", .desc = "Path to the file to write", .required = true },
        .{ .name = "content", .typ = "string", .desc = "Content to write to the file", .required = true },
    }));

    try tools.append(try makeTool(alloc, "edit_file", "Replace occurrences of old_string with new_string in a file.", &[_]PropDef{
        .{ .name = "file_path", .typ = "string", .desc = "Path to the file to edit", .required = true },
        .{ .name = "old_string", .typ = "string", .desc = "The text to search for and replace", .required = true },
        .{ .name = "new_string", .typ = "string", .desc = "The replacement text", .required = true },
    }));

    try tools.append(try makeTool(alloc, "bash", "Execute a bash command and return its output.", &[_]PropDef{
        .{ .name = "command", .typ = "string", .desc = "The bash command to execute", .required = true },
    }));

    try tools.append(try makeTool(alloc, "glob", "Find files matching a glob pattern.", &[_]PropDef{
        .{ .name = "pattern", .typ = "string", .desc = "Glob pattern (e.g. **/*.zig, src/*.txt)", .required = true },
        .{ .name = "path", .typ = "string", .desc = "Directory to search in (default: current directory)", .required = false },
    }));

    try tools.append(try makeTool(alloc, "grep", "Search file contents for a pattern (substring match).", &[_]PropDef{
        .{ .name = "pattern", .typ = "string", .desc = "Text pattern to search for", .required = true },
        .{ .name = "path", .typ = "string", .desc = "Directory to search in (default: current directory)", .required = false },
    }));

    try tools.append(try makeTool(alloc, "list_directory", "List contents of a directory.", &[_]PropDef{
        .{ .name = "path", .typ = "string", .desc = "Directory path (default: current directory)", .required = false },
    }));

    return .{ .array = tools };
}

const PropDef = struct {
    name: []const u8,
    typ: []const u8,
    desc: []const u8,
    required: bool,
};

fn makeTool(alloc: std.mem.Allocator, name: []const u8, description: []const u8, props: []const PropDef) !Value {
    var tool = jh.object(alloc);
    try tool.put("name", jh.string(name));
    try tool.put("description", jh.string(description));

    var schema = jh.object(alloc);
    try schema.put("type", jh.string("object"));

    var properties = jh.object(alloc);
    var required_arr = jh.array(alloc);

    for (props) |p| {
        var prop = jh.object(alloc);
        try prop.put("type", jh.string(p.typ));
        try prop.put("description", jh.string(p.desc));
        try properties.put(p.name, .{ .object = prop });
        if (p.required) {
            try required_arr.append(jh.string(p.name));
        }
    }

    try schema.put("properties", .{ .object = properties });
    try schema.put("required", .{ .array = required_arr });
    try tool.put("input_schema", .{ .object = schema });

    return .{ .object = tool };
}
