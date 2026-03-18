const std = @import("std");

/// Input history with file persistence
pub const History = struct {
    entries: std.ArrayList([]const u8),
    alloc: std.mem.Allocator,
    position: usize, // browsing position (entries.len = "current"/new input)
    max_entries: usize,

    pub fn init(alloc: std.mem.Allocator) History {
        return .{
            .entries = .empty,
            .alloc = alloc,
            .position = 0,
            .max_entries = 500,
        };
    }

    /// Add an entry to history
    pub fn add(self: *History, entry: []const u8) void {
        if (entry.len == 0) return;
        // Don't add duplicates of the last entry
        if (self.entries.items.len > 0) {
            if (std.mem.eql(u8, self.entries.items[self.entries.items.len - 1], entry)) {
                self.resetPosition();
                return;
            }
        }
        const duped = self.alloc.dupe(u8, entry) catch return;
        // Evict oldest if at max
        if (self.entries.items.len >= self.max_entries) {
            self.alloc.free(self.entries.items[0]);
            _ = self.entries.orderedRemove(0);
        }
        self.entries.append(self.alloc, duped) catch return;
        self.resetPosition();
    }

    /// Move back in history (up arrow). Returns entry or null if at beginning.
    pub fn prev(self: *History) ?[]const u8 {
        if (self.entries.items.len == 0) return null;
        if (self.position > 0) {
            self.position -= 1;
        }
        return self.entries.items[self.position];
    }

    /// Move forward in history (down arrow). Returns entry or null if at end.
    pub fn next(self: *History) ?[]const u8 {
        if (self.position + 1 < self.entries.items.len) {
            self.position += 1;
            return self.entries.items[self.position];
        }
        self.position = self.entries.items.len;
        return null; // at end = empty/new input
    }

    /// Reset browsing position to end (for new input)
    pub fn resetPosition(self: *History) void {
        self.position = self.entries.items.len;
    }

    /// Load history from file
    pub fn load(self: *History, path: []const u8) void {
        const file = std.fs.openFileAbsolute(path, .{}) catch return;
        defer file.close();
        const content = file.readToEndAlloc(self.alloc, 1024 * 1024) catch return;
        defer self.alloc.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const duped = self.alloc.dupe(u8, line) catch continue;
            if (self.entries.items.len >= self.max_entries) {
                self.alloc.free(self.entries.items[0]);
                _ = self.entries.orderedRemove(0);
            }
            self.entries.append(self.alloc, duped) catch {
                self.alloc.free(duped);
                continue;
            };
        }
        self.resetPosition();
    }

    /// Save history to file
    pub fn save(self: *const History, path: []const u8) void {
        // Ensure parent directory exists (recursive)
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |_| {
            const dir = std.fs.path.dirname(path) orelse return;
            std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return,
            };
        }

        const file = std.fs.createFileAbsolute(path, .{}) catch return;
        defer file.close();
        for (self.entries.items) |entry| {
            _ = file.write(entry) catch return;
            _ = file.write("\n") catch return;
        }
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |entry| {
            self.alloc.free(entry);
        }
        self.entries.deinit(self.alloc);
    }
};
