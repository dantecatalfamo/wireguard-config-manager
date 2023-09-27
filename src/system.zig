const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

const interface = @import("interface.zig");
const keypair = @import("keypair.zig");
const sqlite = @import("sqlite.zig");
const add_router = @embedFile("sql/add_router.sql");

pub const System = struct {
    db: sqlite.DB,
    allocator: mem.Allocator,

    pub fn init(path: []const u8, allocator: mem.Allocator) !System {
        const schema = @embedFile("sql/schema.sql");
        const db = try sqlite.open(path);
        try db.exec_multiple(schema);
        return System{
            .db = db,
            .allocator = allocator,
        };
    }

    fn create_tables(self: System) !void {
        const schema = @embedFile("schema.sql");
        try self.db.exec_multiple(schema);
    }

    pub fn close(self: System) !void {
        try self.db.close();
    }

    pub fn addInterface(self: System, name: []const u8, address: []const u8, prefix: u6, privkey: ?[32]u8) !u64 {
        const query = "INSERT INTO interfaces (name, address, prefix, privkey) VALUES (?, ?, ?, ?) RETURNING id";
        const kp = if (privkey) |pk|
            try keypair.fromPrivateKey(pk)
        else
            try keypair.generateKeyPair();

        const pk = kp.privateBase64();

        return try self.db.exec_returning_int(query, .{ name, address, prefix, &pk });
    }

    pub fn getInterface(self: System, id: u64) !Interface {
        const query = "SELECT id, name, comment, privkey, hostname, port, address, prefix, psk FROM interfaces WHERE id = ?";
        const stmt = try self.db.prepare_bind(query, .{ id });
        _ = try stmt.step();
        return  Interface{
            .allocator = self.allocator,
            .id = stmt.uint(0),
            .name = if (stmt.text(1)) |str| try self.allocator.dupe(u8, str) else return error.InvalidInterfaceName,
            .comment = if (stmt.text(2)) |str| try self.allocator.dupe(u8, str) else null,
            .privkey = if (stmt.text(3)) |str| try self.allocator.dupe(u8, str) else return error.InvalidInterfacePrivkey,
            .hostname = if (stmt.text(4)) |str| try self.allocator.dupe(u8, str) else null,
            .port = if (stmt.int(5) != 0) @intCast(stmt.int(5)) else null,
            .address = if (stmt.text(6)) |str| try self.allocator.dupe(u8, str) else return error.InvalidInterfaceAddress,
            .prefix = if (stmt.int(7) != 0) @intCast(stmt.int(7)) else return error.InvalidInterfacePrefix,
            .preshared_key = if (stmt.text(8)) |str| try self.allocator.dupe(u8, str) else null,
        };
    }

    pub fn addRouter(self: System, router_id: u64, client_id: u64) !void {
        const router = try self.getInterface(router_id);
        defer router.deinit();
        const client = try self.getInterface(client_id);
        defer client.deinit();
        const router_to_client = try self.addPeerEntry(router_id, client_id);
        const client_to_router = try self.addPeerEntry(client_id, router_id);
        _ = try self.addAllowedIP(router_to_client, client.address, 32);
        _ = try self.addAllowedIP(client_to_router, router.address, router.prefix);
    }

    pub fn addPeer(self: System, interface1_id: u64, interface2_id: u64) !void {
        const query = "SELECT address FROM interfaces WHERE id = ?";
        const peer1_id = try self.addPeerEntry(interface1_id, interface2_id);
        const interface1_address = try self.db.exec_returning_text(self.allocator, query, .{ interface1_id });
        defer self.allocator.free(interface1_address);
        const peer2_id = try self.addPeerEntry(interface2_id, interface1_id);
        const interface2_address = try self.db.exec_returning_text(self.allocator, query, .{ interface2_id });
        defer self.allocator.free(interface2_address);
        _ = try self.addAllowedIP(peer1_id, interface2_address, 32);
        _ = try self.addAllowedIP(peer2_id, interface1_address, 32);
    }

    pub fn addPeerEntry(self: System, interface_id1: u64, interface_id2: u64) !u64 {
        const query = "INSERT INTO peers (interface1, interface2) VALUES (?, ?) RETURNING id";
        return try self.db.exec_returning_int(query, .{ interface_id1, interface_id2 });
    }

    pub fn addAllowedIP(self: System, peer: u64, address: []const u8, prefix: u6) !u64 {
        const query = "INSERT INTO allowed_ips (peer, address, prefix) VALUES (?, ?, ?) RETURNING id";
        return try self.db.exec_returning_int(query, .{ peer, address, prefix });
    }

    pub fn listInterfaces(system: System, writer: anytype) !void {
        const query = "SELECT i.id, i.name, i.address, i.prefix, i.privkey, count(p.id), i.comment FROM interfaces i LEFT JOIN peers p ON i.id = p.interface1 GROUP BY i.id";
        const stmt = try system.db.prepare_bind(query, .{});
        try writer.print("ID |      Name      |       Address      |                  Public Key                  | Peers | Comment \n", .{});
        try writer.print("---+----------------+--------------------+----------------------------------------------+-------+---------\n", .{});
        while (try stmt.step()) {
            try writer.print(
                "{d: <2} | {?s: <14} | {?s: <15}/{d: <2} | {s} | {d: <5} | {s}\n", .{
                    stmt.uint(0),
                    stmt.text(1),
                    stmt.text(2),
                    stmt.uint(3),
                    try keypair.base64PrivateToPublic(stmt.text(4) orelse ""),
                    stmt.uint(5),

                    stmt.text(6) orelse "",        });
        }
    }

    pub fn listInterface(system: System, writer: anytype, interface_id: u64) !void {
        const details_query = "SELECT id, name, comment, privkey, hostname, address, prefix, port, psk FROM interfaces WHERE id = ?";
        const peers_query = "SELECT i.id, i.name, p.id FROM peers AS p JOIN interfaces AS i ON p.interface2 = i.id WHERE p.interface1 = ?";
        const allowed_ips_query = "SELECT address, prefix FROM allowed_ips WHERE peer = ?";
        const details_stmt = try system.db.prepare_bind(details_query, .{ interface_id });
        const peers_stmt = try system.db.prepare_bind(peers_query, .{ interface_id });
        const allowed_ips_stmt = try system.db.prepare(allowed_ips_query, null);

        if (!try details_stmt.step()) {
            return;
        }

        try writer.print("Interface details\n", .{});
        try writer.print("-----------------\n", .{});
        try writer.print("ID: {d}\n", .{ details_stmt.uint(0) });
        try writer.print("Name: {s}\n", .{ details_stmt.text(1) orelse "" });
        try writer.print("Comment: {s}\n", .{ details_stmt.text(2) orelse "" });
        try writer.print("PubKey: {s}\n", .{ try keypair.base64PrivateToPublic(details_stmt.text(3) orelse "") });
        try writer.print("PrivKey: {s}\n", .{ details_stmt.text(3) orelse "" });
        try writer.print("Hostname: {s}\n", .{ details_stmt.text(4) orelse "" });
        try writer.print("Address: {s}/{d}\n", .{ details_stmt.text(5) orelse "", details_stmt.uint(6) });
        try writer.print("Port: {d}\n", .{ details_stmt.uint(7) });
        try writer.print("PSK: {s}\n", .{ details_stmt.text(8) orelse "" });

        try writer.print("\nPeers\n", .{});
        try writer.print("-----\n", .{});
        try writer.print("ID |      Name      |   Allowed IPs    \n", .{});
        try writer.print("---+----------------+------------------\n", .{});
        while (try peers_stmt.step()) {
            try writer.print("{d: <2} | {s: <14} | ", .{ peers_stmt.uint(0), peers_stmt.text(1) orelse "" });
            try allowed_ips_stmt.reset();
            try allowed_ips_stmt.bind(.{ peers_stmt.int(2) });
            while (try allowed_ips_stmt.step()) {
                try writer.print("{s}/{d} ", .{ allowed_ips_stmt.text(0) orelse "", allowed_ips_stmt.int(1) });
            }
            try writer.print("\n", .{});
        }
        try details_stmt.finalize();
        try peers_stmt.finalize();
        try allowed_ips_stmt.finalize();
    }
};

pub const Interface = struct {
    allocator: mem.Allocator,
    id: ?u64,
    name: []const u8,
    comment: ?[]const u8,
    privkey: []const u8,
    hostname: ?[]const u8 = null,
    port: ?u16 = null,
    address: []const u8,
    prefix: u6,
    preshared_key: ?[]const u8 = null,

    pub fn deinit(self: Interface) void {
        self.allocator.free(self.name);
        if (self.comment) |m| self.allocator.free(m);
        self.allocator.free(self.privkey);
        if (self.hostname) |m| self.allocator.free(m);
        self.allocator.free(self.address);
        if (self.preshared_key) |m| self.allocator.free(m);
    }

    pub fn kp(self: Interface) !keypair.KeyPair {
        var priv: [44]u8 = undefined;
        @memcpy(&priv, self.privkey);
        return try keypair.fromBase64PrivateKey(priv);
    }
};
