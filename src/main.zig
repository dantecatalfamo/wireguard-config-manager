const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

const keypair = @import("keypair.zig");
const config = @import("config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    var env = try config.defaultEnvironment(allocator);
    defer env.deinit();
    while (true) {
        try stdout.print("> ", .{});
        const input = stdin.readUntilDelimiterAlloc(allocator, '\n', 4096) catch |err| {
            if (err == error.EndOfStream) {
                return;
            }
            return err;
        };
        defer allocator.free(input);
        var tokens = config.tokenIter(allocator, input);
        const result = try config.eval(&env, &tokens);
        try stdout.print("=> ", .{});
        result.debug();
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
