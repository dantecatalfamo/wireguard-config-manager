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

    if (std.os.argv.len == 1) {
        return;
    }

    const operation = mem.span(std.os.argv[1]);

    if (mem.eql(u8, operation, "list")) {
        if (std.os.argv.len == 2) {
            try listInterfaces(system);
        } else {
            const interface_id = try std.fmt.parseInt(u8, mem.span(std.os.argv[2]), 10);
            try listInterface(system, interface_id);
        }
    } else if (mem.eql(u8, operation, "seed")){
        const if1 = try system.addInterface("potato", "192.168.10.1", 24, null);
        const if2 = try system.addInterface("banana", "192.168.10.2", 24, null);
        const if3 = try system.addInterface("orange", "192.168.10.3", 24, null);
        const if4 = try system.addInterface("grape",  "192.168.10.4", 24, null);

        try system.addRouter(if1, if2);
        try system.addRouter(if1, if3);
        try system.addRouter(if1, if4);
    }
}

pub fn listInterfaces(system: System) !void {
    const query = "SELECT i.id, i.name, i.address, i.prefix, i.privkey, count(p.id), i.comment FROM interfaces i LEFT JOIN peers p ON i.id = p.interface1 GROUP BY i.id";
    const stmt = try system.db.prepare_bind(query, .{});
    std.debug.print("ID |      Name      |     Address     |                  Public Key                  | Peers | Comment \n", .{});
    std.debug.print("---+----------------+-----------------+----------------------------------------------+-------+---------\n", .{});
    while (try stmt.step()) {
        var privkey: [44]u8 = undefined;
        @memcpy(&privkey, stmt.text(4).?);
        const kp = try keypair.fromBase64PrivateKey(privkey);
        std.debug.print(
            "{d: <2} | {?s: <14} | {?s}/{d} | {s} | {d: <5} | {s}\n", .{
                @as(u64, @intCast(stmt.int(0))),
                stmt.text(1),
                stmt.text(2),
                stmt.int(3),
                &kp.publicBase64(),
                @as(u64, @intCast(stmt.int(5))),
                stmt.text(6) orelse "",
        });
    }
}

pub fn listInterface(system: System, interface_id: u64) !void {
    const details_query = "SELECT id, name, comment, privkey, hostname, address, prefix, port, prefix, psk FROM interfaces WHERE id = ?";
    const details_stmt = try system.db.prepare_bind(details_query, .{ interface_id });
    _ = try details_stmt.step();
    var privkey: [44]u8 = undefined;
    @memcpy(&privkey, details_stmt.text(3) orelse "");
    const kp = try keypair.fromBase64PrivateKey(privkey);

    std.debug.print("Interface details\n", .{});
    std.debug.print("-----------------\n", .{});
    std.debug.print("ID: {d}\n", .{ @as(u64, @intCast(details_stmt.int(0))) });
    std.debug.print("Name: {s}\n", .{ details_stmt.text(1) orelse "" });
    std.debug.print("Comment: {s}\n", .{ details_stmt.text(2) orelse "" });
    std.debug.print("PubKey: {s}\n", .{ &kp.publicBase64() });
    std.debug.print("PrivKey: {s}\n", .{ &kp.privateBase64() });
    std.debug.print("Hostname: {s}\n", .{ details_stmt.text(4) orelse "" });
    std.debug.print("Address: {s}/{d}\n", .{ details_stmt.text(5) orelse "", @as(u64, @intCast(details_stmt.int(6))) });
    std.debug.print("Port: {d}\n", .{ @as(u64, @intCast(details_stmt.int(7))) });
    std.debug.print("PSK: {s}\n", .{ details_stmt.text(8) orelse "" });

    try details_stmt.finalize();

    std.debug.print("\nPeers\n", .{});
    std.debug.print("-----\n", .{});
    std.debug.print("ID |      Name      |   Allowed IPs    \n", .{});
    std.debug.print("---+----------------+------------------\n", .{});
    const peers_query = "SELECT i.id, i.name, p.id FROM peers AS p JOIN interfaces AS i ON p.interface2 = i.id WHERE p.interface1 = ?";
    const peers_stmt = try system.db.prepare_bind(peers_query, .{ interface_id });
    while (try peers_stmt.step()) {
        std.debug.print("{d: <2} | {s: <14} | ", .{ @as(u64, @intCast(peers_stmt.int(0))), peers_stmt.text(1) orelse "" });
        const allowed_ips_query = "SELECT address, prefix FROM allowed_ips WHERE peer = ?";
        // Should use bind/reset instead of compiling the same query
        const allowed_ips_stmt = try system.db.prepare_bind(allowed_ips_query, .{ peers_stmt.int(2) });
        while (try allowed_ips_stmt.step()) {
            std.debug.print("{s}/{d} ", .{ allowed_ips_stmt.text(0) orelse "", @as(u64, @intCast(allowed_ips_stmt.int(1))) });
        }
        std.debug.print("\n", .{});
        try allowed_ips_stmt.finalize();
    }
    try peers_stmt.finalize();
}

test "ref all" {
    testing.refAllDeclsRecursive(@This());
    testing.refAllDecls(sqlite);
}
