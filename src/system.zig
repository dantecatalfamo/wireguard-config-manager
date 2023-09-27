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

    // TODO Take Interface as thing
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
            .id = @intCast(stmt.int(0)),
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
        const client = try self.getInterface(client_id);
        const router_to_client = try self.addPeer(router_id, client_id);
        const client_to_router = try self.addPeer(client_id, router_id);
        _ = try self.addAllowedIP(router_to_client, client.address, 32);
        _ = try self.addAllowedIP(client_to_router, router.address, router.prefix);
    }

    pub fn addPeer(self: System, interface_id1: u64, interface_id2: u64) !u64 {
        const query = "INSERT INTO peers (interface1, interface2) VALUES (?, ?) RETURNING id";
        return try self.db.exec_returning_int(query, .{ interface_id1, interface_id2 });
    }

    pub fn addAllowedIP(self: System, peer: u64, address: []const u8, prefix: u6) !u64 {
        const query = "INSERT INTO allowed_ips (peer, address, prefix) VALUES (?, ?, ?) RETURNING id";
        return try self.db.exec_returning_int(query, .{ peer, address, prefix });
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
