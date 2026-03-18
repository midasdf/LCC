const std = @import("std");
const terminal = @import("terminal.zig");

/// Streaming Markdown renderer.
/// Buffers text line-by-line, applies ANSI formatting on newlines.
pub const MarkdownRenderer = struct {
    line_buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    in_code_block: bool,
    enabled: bool,

    pub fn init(alloc: std.mem.Allocator) MarkdownRenderer {
        return .{
            .line_buf = .empty,
            .alloc = alloc,
            .in_code_block = false,
            .enabled = true,
        };
    }

    /// Feed streaming text into the renderer
    pub fn feed(self: *MarkdownRenderer, text: []const u8) void {
        if (!self.enabled) {
            terminal.printStr(text);
            return;
        }

        for (text) |c| {
            if (c == '\n') {
                self.flushLine();
                terminal.printStr("\n");
            } else {
                self.line_buf.append(self.alloc, c) catch {
                    // Fallback: flush what we have and print rest directly
                    self.flushLine();
                    terminal.printStr(text);
                    return;
                };
            }
        }
    }

    /// Flush any remaining buffered text
    pub fn flush(self: *MarkdownRenderer) void {
        if (self.line_buf.items.len > 0) {
            self.flushLine();
        }
    }

    /// Reset state between turns
    pub fn reset(self: *MarkdownRenderer) void {
        self.line_buf.clearRetainingCapacity();
        self.in_code_block = false;
    }

    fn flushLine(self: *MarkdownRenderer) void {
        const line = self.line_buf.items;
        defer self.line_buf.clearRetainingCapacity();

        if (line.len == 0) return;

        // Code block toggle: ```
        if (std.mem.startsWith(u8, line, "```")) {
            if (self.in_code_block) {
                // End code block
                self.in_code_block = false;
                terminal.printStr(terminal.Color.dim ++ "```" ++ terminal.Color.reset);
            } else {
                // Start code block (optionally with language)
                self.in_code_block = true;
                terminal.printStr(terminal.Color.dim ++ "```");
                if (line.len > 3) {
                    terminal.printStr(terminal.Color.cyan);
                    terminal.printStr(line[3..]);
                }
                terminal.printStr(terminal.Color.reset);
            }
            return;
        }

        // Inside code block: colored output
        if (self.in_code_block) {
            terminal.printStr(terminal.Color.yellow);
            terminal.printStr(line);
            terminal.printStr(terminal.Color.reset);
            return;
        }

        // Headers: # ## ### etc.
        if (line[0] == '#') {
            var level: usize = 0;
            while (level < line.len and line[level] == '#') : (level += 1) {}
            if (level <= 6 and level < line.len and line[level] == ' ') {
                terminal.printStr(terminal.Color.bold ++ terminal.Color.cyan);
                terminal.printStr(line);
                terminal.printStr(terminal.Color.reset);
                return;
            }
        }

        // Horizontal rule: --- or ***
        if (line.len >= 3) {
            const is_hr = (line[0] == '-' or line[0] == '*') and blk: {
                for (line) |c| {
                    if (c != line[0] and c != ' ') break :blk false;
                }
                break :blk true;
            };
            if (is_hr) {
                terminal.printStr(terminal.Color.dim ++ "────────────────────────────────" ++ terminal.Color.reset);
                return;
            }
        }

        // Bullet points: - or *
        if (line.len >= 2 and (line[0] == '-' or line[0] == '*') and line[1] == ' ') {
            terminal.printStr(terminal.Color.cyan);
            var bullet: [1]u8 = .{line[0]};
            terminal.printStr(&bullet);
            terminal.printStr(" " ++ terminal.Color.reset);
            renderInline(line[2..]);
            return;
        }

        // Numbered list: 1. 2. etc.
        if (line.len >= 3 and std.ascii.isDigit(line[0])) {
            var j: usize = 0;
            while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) {}
            if (j < line.len and line[j] == '.' and j + 1 < line.len and line[j + 1] == ' ') {
                terminal.printStr(terminal.Color.cyan);
                terminal.printStr(line[0 .. j + 1]);
                terminal.printStr(terminal.Color.reset);
                renderInline(line[j + 1 ..]);
                return;
            }
        }

        // Blockquote: >
        if (line.len >= 2 and line[0] == '>' and line[1] == ' ') {
            terminal.printStr(terminal.Color.dim ++ terminal.Color.green ++ "  " ++ terminal.Color.reset);
            terminal.printStr(terminal.Color.green);
            renderInline(line[2..]);
            terminal.printStr(terminal.Color.reset);
            return;
        }

        // Regular line with inline formatting
        renderInline(line);
    }

    /// Render inline markdown: **bold**, `code`, *italic*
    fn renderInline(text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            // Bold: **text**
            if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
                if (std.mem.indexOf(u8, text[i + 2 ..], "**")) |end| {
                    terminal.printStr(terminal.Color.bold);
                    terminal.printStr(text[i + 2 ..][0..end]);
                    terminal.printStr(terminal.Color.reset);
                    i += end + 4;
                    continue;
                }
            }
            // Inline code: `text`
            if (text[i] == '`') {
                if (std.mem.indexOf(u8, text[i + 1 ..], "`")) |end| {
                    terminal.printStr(terminal.Color.yellow);
                    terminal.printStr(text[i + 1 ..][0..end]);
                    terminal.printStr(terminal.Color.reset);
                    i += end + 2;
                    continue;
                }
            }
            // Italic: *text* (single asterisk, not at start of bold)
            if (text[i] == '*' and (i + 1 >= text.len or text[i + 1] != '*')) {
                if (std.mem.indexOf(u8, text[i + 1 ..], "*")) |end| {
                    if (end > 0) {
                        terminal.printStr(terminal.Color.dim);
                        terminal.printStr(text[i + 1 ..][0..end]);
                        terminal.printStr(terminal.Color.reset);
                        i += end + 2;
                        continue;
                    }
                }
            }
            // Regular character
            var buf: [1]u8 = .{text[i]};
            terminal.printStr(&buf);
            i += 1;
        }
    }
};
