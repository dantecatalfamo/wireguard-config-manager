const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

const keypair = @import("keypair.zig");
const config = @import("config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){};
    var allocator = gpa.allocator();
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    var env = try config.Environment.init(allocator);
    defer env.deinit();

    var args = std.process.args();
    _ = args.next();
    if (args.next()) |filepath| {
        const contents = try std.fs.cwd().readFileAlloc(allocator, filepath, 1024 * 1024);
        const result = try env.load(contents);
        try result.toString(stdout);
        try stdout.print("\n", .{});
        return;
    }

    var input = std.ArrayList(u8).init(allocator);
    while (true) {
        // try stdout.print("Memory allocated: {d} B\n", .{gpa.total_requested_bytes});
        if (input.items.len != 0) {
            try stdout.print("...> ", .{});
        } else {
            try stdout.print("> ", .{});
        }

        stdin.streamUntilDelimiter(input.writer(), '\n', 4 * 1024 * 1024) catch |err| {
            if (err == error.EndOfStream) {
                try stdout.print("\n", .{});
                return;
            }
            return err;
        };
        const result = env.load(input.items) catch |err| {
            if (err == error.MissingListEnd) {
                try input.append('\n');
                continue;
            }
            try stdout.print("=> Error: {s}\n", .{ @errorName(err) });
            input.clearRetainingCapacity();
            continue;
        };
        try stdout.print("=> ", .{});
        try result.toString(stdout);
        try stdout.print("\n", .{});
        input.clearRetainingCapacity();
    }
}

test "ref all" {
    testing.refAllDeclsRecursive(@This());
    testing.refAllDecls(config);
    testing.refAllDecls(@import("config_commands.zig"));
}
