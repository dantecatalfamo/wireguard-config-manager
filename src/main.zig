const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

const keypair = @import("keypair.zig");
const sqlite = @import("sqlite.zig");
const System = @import("system.zig").System;

pub fn main() !void {
    const system = try System.init(":memory:", std.heap.page_allocator);
    defer system.close() catch unreachable;

    const if1 = try system.addInterface("potato", "192.168.10.1", 24, null);
    const if2 = try system.addInterface("banana", "192.168.10.2", 24, null);
    const if3 = try system.addInterface("orange", "192.168.10.3", 24, null);
    const if4 = try system.addInterface("grape",  "192.168.10.4", 24, null);

    try system.addRouter(if1, if2);
    try system.addRouter(if1, if3);
    try system.addRouter(if1, if4);

    try listInterfaces(system);
}

pub fn listInterfaces(system: System) !void {
    const query = "SELECT i.id, i.name, i.address, i.prefix, count(p.id) FROM interfaces i LEFT JOIN peers p ON i.id = p.interface1 GROUP BY i.id";
    const stmt = try system.db.prepare_bind(query, .{});
    std.debug.print("ID |      Name      |    Address      | Peers \n", .{});
    std.debug.print("------------------------------------------------\n", .{});
    while (try stmt.step()) {
        std.debug.print(
            "{d: <2} | {?s: <14} | {?s}/{d} | {d}\n", .{
                @as(u64, @intCast(stmt.int(0))),
                stmt.text(1),
                stmt.text(2),
                stmt.int(3),
                stmt.int(4),
        });
    }
}

test "ref all" {
    testing.refAllDeclsRecursive(@This());
    testing.refAllDecls(sqlite);
}
