const std = @import("std");
const posix = std.posix;
const compat = @import("compat.zig");

pub const LogSystem = struct {
    file: ?std.Io.File = null,
    mutex: std.atomic.Mutex = .unlocked,
    current_size: u64 = 0,
    max_size: u64 = 5 * 1024 * 1024, // 5MB
    path: []const u8 = "",
    alloc: std.mem.Allocator = undefined,
    io: std.Io = undefined,

    pub fn init(self: *LogSystem, alloc: std.mem.Allocator, path: []const u8, io: std.Io) !void {
        self.alloc = alloc;
        self.io = io;
        self.path = try alloc.dupe(u8, path);

        const file = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.Io.Dir.createFileAbsolute(io, path, .{ .read = true }),
            else => return err,
        };

        const end_pos = try file.length(io);
        self.current_size = end_pos;
        self.file = file;
    }

    pub fn deinit(self: *LogSystem) void {
        if (self.file) |f| compat.close(f.handle);
        self.file = null;
        if (self.path.len > 0) self.alloc.free(self.path);
    }

    pub fn log(self: *LogSystem, comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        if (self.file == null) {
            std.log.defaultLog(level, scope, format, args);
            return;
        }

        if (self.current_size >= self.max_size) {
            self.rotate() catch |err| {
                std.debug.print("Log rotation failed: {s}\n", .{@errorName(err)});
            };
        }

        const now = compat.milliTimestamp();
        const prefix = "[{d}] [{s}] ({s}): ";
        const scope_name = @tagName(scope);
        const level_name = level.asText();

        const prefix_args = .{
            now,
            level_name,
            scope_name,
        };

        if (self.file) |f| {
            const prefix_len = std.fmt.count(prefix, prefix_args);
            const msg_len = std.fmt.count(format, args);
            const newline_len = 1;
            const total_len = prefix_len + msg_len + newline_len;
            self.current_size += total_len;

            var buf: [4096]u8 = undefined;
            var w = f.writerStreaming(self.io, &buf);
            w.interface.print(prefix ++ format ++ "\n", prefix_args ++ args) catch {};
            w.interface.flush() catch {};
        }
    }

    fn rotate(self: *LogSystem) !void {
        if (self.file) |f| {
            compat.close(f.handle);
            self.file = null;
        }

        const old_path = try std.fmt.allocPrint(self.alloc, "{s}.old", .{self.path});
        defer self.alloc.free(old_path);

        std.Io.Dir.renameAbsolute(self.path, old_path, self.io) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        self.file = try std.Io.Dir.createFileAbsolute(self.io, self.path, .{ .truncate = true, .read = true });
        self.current_size = 0;
    }
};
