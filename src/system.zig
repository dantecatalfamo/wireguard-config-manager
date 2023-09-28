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

    pub fn removeInterface(self: System, interface_id: u64) !void {
        const query = "DELETE FROM interfaces WHERE id = ?";
        try self.db.exec(query, .{ interface_id });
    }

    pub fn interfaceIdFromName(self: System, name: []const u8) !u64 {
        const query = "SELECT id FROM interfaces WHERE name = ?";
        return try self.db.exec_returning_int(query, .{ name });
    }

    pub fn getInterface(self: System, id: u64) !Interface {
        const query = "SELECT id, name, comment, privkey, hostname, port, address, prefix, psk FROM interfaces WHERE id = ?";
        const stmt = try self.db.prepare_bind(query, .{ id });
        if (!try stmt.step()) {
            return error.NoInterface;
        }
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
        const query = "SELECT address, prefix FROM interfaces WHERE id = ?";
        const stmt = try self.db.prepare(query, null);

        try stmt.bind(.{ client_id });
        if (!try stmt.step())
            return error.NoRecord;
        const router_to_client = try self.addPeerEntry(router_id, client_id);
        _ = try self.addAllowedIPEntry(router_to_client, stmt.text(0).?, 32);
        try stmt.reset();

        try stmt.bind(.{ router_id });
        if (!try stmt.step())
            return error.NoRecord;
        const client_to_router = try self.addPeerEntry(client_id, router_id);
        _ = try self.addAllowedIPEntry(client_to_router, stmt.text(0).?, @intCast(stmt.uint(1)));
        try stmt.finalize();
    }

    pub fn addPeer(self: System, interface1_id: u64, interface2_id: u64) !void {
        const query = "SELECT address FROM interfaces WHERE id = ?";
        const peer1_id = try self.addPeerEntry(interface1_id, interface2_id);
        const interface1_address = try self.db.exec_returning_text(self.allocator, query, .{ interface1_id });
        defer self.allocator.free(interface1_address);
        const peer2_id = try self.addPeerEntry(interface2_id, interface1_id);
        const interface2_address = try self.db.exec_returning_text(self.allocator, query, .{ interface2_id });
        defer self.allocator.free(interface2_address);
        _ = try self.addAllowedIPEntry(peer1_id, interface2_address, 32);
        _ = try self.addAllowedIPEntry(peer2_id, interface1_address, 32);
    }

    pub fn unPeer(self: System, interface1_id: u64, interface2_id: u64) !void {
        const query = "DELETE FROM peers WHERE interface1 = ? AND interface2 = ?";
        try self.db.exec(query, .{ interface1_id, interface2_id });
        try self.db.exec(query, .{ interface2_id, interface1_id });
    }

    pub fn addPeerEntry(self: System, interface_id1: u64, interface_id2: u64) !u64 {
        const query = "INSERT INTO peers (interface1, interface2) VALUES (?, ?) RETURNING id";
        return try self.db.exec_returning_int(query, .{ interface_id1, interface_id2 });
    }

    pub fn addAllowedIP(self: System, interface1_id: u64, interface2_id: u64, address: []const u8, prefix: u6) !void {
        const peer_query = "SELECT id FROM peers WHERE interface1 = ? AND interface2 = ?";
        const allowed_ip_query = "INSERT INTO allowed_ips (peer, address, prefix) VALUES (?, ?, ?)";
        const peer_id = try self.db.exec_returning_int(peer_query, .{ interface1_id, interface2_id });
        try self.db.exec(allowed_ip_query, .{ peer_id, address, prefix });
    }

    pub fn addAllowedIPEntry(self: System, peer: u64, address: []const u8, prefix: u6) !u64 {
        const query = "INSERT INTO allowed_ips (peer, address, prefix) VALUES (?, ?, ?) RETURNING id";
        return try self.db.exec_returning_int(query, .{ peer, address, prefix });
    }

    pub fn removeAllowedIP(self: System, interface1_id: u64, interface2_id: u64, address: []const u8, prefix: u6) !void {
        const peer_query = "SELECT id FROM peers WHERE interface1 = ? AND interface2 = ?";
        const allowed_ip_query = "DELETE FROM allowed_ips WHERE peer = ? AND address = ? AND prefix = ?";
        const peer_id = try self.db.exec_returning_int(peer_query, .{ interface1_id, interface2_id });
        try self.db.exec(allowed_ip_query, .{ peer_id, address, prefix });
    }

    pub fn setPresharedKey(self: System, interface1_id: u64, interface2_id: u64, psk: ?[]const u8) !void {
        const query = "UPDATE peers SET psk = ? WHERE interface1 = ? AND interface2 = ?";
        if (psk) |k| {
            try self.db.exec(query, .{ k, interface1_id, interface2_id });
            try self.db.exec(query, .{ k, interface2_id, interface1_id });
        } else {
            try self.db.exec(query, .{ null, interface1_id, interface2_id });
            try self.db.exec(query, .{ null, interface2_id, interface1_id });
        }
    }

    pub fn setField(self: System, interface_id: u64, field: Field, value: []const u8) !void {
        switch (field) {
            .name => try self.db.exec("UPDATE interfaces SET name = ? WHERE id = ?", .{ value, interface_id }),
            .comment => try self.db.exec("UPDATE interfaces SET comment = ? WHERE id = ?", .{ value, interface_id }),
            .privkey => {
                if (!try verifyPrivkey(value))
                    return error.InvalidKey;
                try self.db.exec("UPDATE interfaces SET privkey = ? WHERE id = ?", .{ value, interface_id });
            },
            .hostname => try self.db.exec("UPDATE interfaces SET hostname = ? WHERE id = ?", .{ value, interface_id }),
            .port => try self.db.exec("UPDATE interfaces SET port = ? WHERE id = ?", .{ try std.fmt.parseInt(u16, value, 10), interface_id }),
            .address => {
                const addr_pfx = try parseAddrPrefix(value);
                try self.db.exec("UPDATE interfaces SET address = ?, prefix = ? WHERE id = ?", .{ addr_pfx.address, addr_pfx.prefix, interface_id });
            },
            .dns => try self.db.exec("UPDATE interfaces SET dns = ? WHERE id = ?", .{ value, interface_id }),
        }
    }

    pub const Field = enum {
        name,
        comment,
        privkey,
        hostname,
        port,
        address,
        dns,
    };

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
        const details_query = "SELECT id, name, comment, privkey, hostname, address, prefix, port, dns FROM interfaces WHERE id = ?";
        const peers_query = "SELECT i.id, i.name, p.psk, p.id FROM peers AS p JOIN interfaces AS i ON p.interface2 = i.id WHERE p.interface1 = ?";
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
        try writer.print("Public Key: {s}\n", .{ try keypair.base64PrivateToPublic(details_stmt.text(3) orelse "") });
        try writer.print("Private Key: {s}\n", .{ details_stmt.text(3) orelse "" });
        try writer.print("Hostname: {s}\n", .{ details_stmt.text(4) orelse "" });
        try writer.print("Address: {s}/{d}\n", .{ details_stmt.text(5) orelse "", details_stmt.uint(6) });
        if (details_stmt.uint(7) == 0) {
            try writer.print("Port:\n", .{});
        } else {
            try writer.print("Port: {d}\n", .{ details_stmt.uint(7) });
        }
        try writer.print("DNS: {s}\n", .{ details_stmt.text(8) orelse "" });

        try writer.print("\nPeers\n", .{});
        try writer.print("-----\n", .{});
        try writer.print("ID |      Name      |                  Preshared Key               |   Allowed IPs    \n", .{});
        try writer.print("---+----------------+----------------------------------------------+------------------\n", .{});
        while (try peers_stmt.step()) {
            try writer.print("{d: <2} | {s: <14} | {s: <44} | ", .{ peers_stmt.uint(0), peers_stmt.text(1) orelse "", peers_stmt.text(2) orelse "" });
            try allowed_ips_stmt.reset();
            try allowed_ips_stmt.bind(.{ peers_stmt.int(3) });
            while (try allowed_ips_stmt.step()) {
                try writer.print("{s}/{d} ", .{ allowed_ips_stmt.text(0) orelse "", allowed_ips_stmt.int(1) });
            }
            try writer.print("\n", .{});
        }
        try details_stmt.finalize();
        try peers_stmt.finalize();
        try allowed_ips_stmt.finalize();
    }

    pub fn exportConf(system: System, interface_id: u64, writer: std.fs.File.Writer) !void {
        const details_query = "SELECT address, prefix, privkey, port FROM interfaces WHERE id = ?";
        const peers_query = "SELECT i.name, i.comment, i.privkey, i.hostname, i.port, p.id, p.psk FROM peers AS p JOIN interfaces AS i ON p.interface2 = i.id WHERE p.interface1 = ?";
        const allowed_ips_query = "SELECT address, prefix FROM allowed_ips WHERE peer = ?";
        const details_stmt = try system.db.prepare_bind(details_query, .{ interface_id });
        const peers_stmt = try system.db.prepare_bind(peers_query, .{ interface_id });
        const allowed_ips_stmt = try system.db.prepare(allowed_ips_query, null);

        if (!try details_stmt.step())
            return error.NoRecord;

        try writer.print("[Interface]\n", .{});
        try writer.print("Address = {s}/{d}\n", .{ details_stmt.text(0).?, details_stmt.uint(1) });
        try writer.print("PrivateKey = {s}\n", .{ details_stmt.text(2).? });
        if (details_stmt.text(3)) |dns| {
            try writer.print("DNS = {s}\n", .{ dns });
        }
        if (details_stmt.uint(3) != 0)
            try writer.print("ListenPort = {d}\n", .{ details_stmt.uint(3) });

        while (try peers_stmt.step()) {
            try writer.print("\n", .{});
            try writer.print("[Peer]\n", .{});
            try writer.print("# {s}\n", .{ peers_stmt.text(0).? });
            if (peers_stmt.text(1)) |comment| {
                try writer.print("# {s}\n", .{ comment });
            }
            try writer.print("PublicKey = {s}\n", .{ try keypair.base64PrivateToPublic(peers_stmt.text(2).?) });
            if (peers_stmt.text(6)) |psk| {
                try writer.print("PresharedKey = {s}\n", .{ psk });
            }
            if (peers_stmt.text(3)) |hostname| {
                try writer.print("Endpoint = {s}:{d}\n", .{ hostname, peers_stmt.uint(4) });
            }
            try allowed_ips_stmt.reset();
            try allowed_ips_stmt.bind(.{ peers_stmt.uint(5) });
            try writer.print("AllowedIPs = ", .{});
            var first = true;
            while (try allowed_ips_stmt.step()) {
                if (first) {
                    first = false;
                } else {
                    try writer.print(", ", .{});
                }
                try writer.print("{s}/{d}", .{ allowed_ips_stmt.text(0).?, allowed_ips_stmt.uint(1) });
            }
            try writer.print("\n", .{});
        }

        try details_stmt.finalize();
        try peers_stmt.finalize();
        try allowed_ips_stmt.finalize();
    }

    pub fn parseAddrPrefix(str: []const u8) !AddrPrefix {
        var iter = mem.split(u8, str, "/");
        const addr = iter.first();
        const prefix_str = iter.next() orelse "32";
        const prefix = try std.fmt.parseInt(u6, prefix_str, 10);
        return .{
            .address = addr,
            .prefix = prefix
        };
    }

    pub const AddrPrefix = struct {
        address: []const u8,
        prefix: u6,
    };

    pub fn verifyPrivkey(privkey: []const u8) !bool {
        return 32 == try std.base64.standard.Decoder.calcSizeForSlice(privkey);
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
