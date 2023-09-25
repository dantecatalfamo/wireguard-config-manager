const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

const keypair = @import("keypair.zig");
const sqlite = @import("sqlite.zig");
const schema = @embedFile("schema.sql");

pub fn main() !void {
    const db = try sqlite.open(":memory:");
    defer db.close() catch unreachable;

    try db.exec_noret(schema, .{});

    // const stmt = try db.prepare("SELECT * FROM vv;");
    // while (try stmt.step() != .done) {
    //     std.debug.print("Col 1: {d}, Col 2: {s}\n", .{ stmt.int(0), stmt.text(1) });
    // }
}

test "ref all" {
    testing.refAllDeclsRecursive(@This());
    testing.refAllDecls(sqlite);
}
