const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

pub const kp = @import("keypair.zig");
pub const KeyPair = kp.KeyPair;

pub const Interface = struct {
    keypair: KeyPair,
    name: []const u8,
    port: ?u16 = null,
    hostname: ?[]const u8 = null,
    address: []const u8,
    prefix: u6,
    peers: PeerList,
    preshared_key: ?[32]u8 = null,

    pub fn init(allocator: mem.Allocator, name: []const u8, privkey: [32]u8, address: []const u8, prefix: u6) !Interface {
        return Interface{
            .keypair = try kp.fromPrivateKey(privkey),
            .name = try allocator.dupe(u8, name),
            .peers = PeerList.init(allocator),
            .address = try allocator.dupe(u8, address),
            .prefix = prefix,
        };
    }

    pub fn deinit(self: *Interface) void {
        self.peers.allocator.free(self.name);
        self.peers.allocator.free(self.address);
        for (self.peers.items) |peer| {
            peer.deinit();
        }
        self.peers.deinit();
    }

    pub fn addPeer(self: *Interface, peer_interface: *Interface) !void {
        var peer = try self.peers.addOne();
        peer.* = Peer.init(self.peers.allocator, peer_interface);
    }

    pub fn toOpenBSD(self: *Interface, writer: anytype) !void {
        if (mem.indexOf(u8, self.address, ":")) |_| {
            try writer.print("inet6 {s}/{d}\n", .{ self.address, self.prefix });
        } else {
            try writer.print("inet {s}/{d}\n", .{ self.address, self.prefix });
        }
        try writer.print("wgkey {s}\n", .{ self.keypair.privateBase64() });
        if (self.port) |wgport| {
            try writer.print("wgport {d}\n", .{ wgport });
        }
        for (self.peers.items) |peer| {
            const peer_if: *Interface = peer.interface;
            try writer.print("wgpeer {s} ", .{ peer_if.keypair.publicBase64() });
            try writer.print("wgaip {s}/32 ", .{ peer_if.address });
            for (peer.allowed_ips.items) |allowed_ip| {
                try writer.print("wgaip {s} ", .{ allowed_ip });
            }
            if (peer_if.preshared_key) |wgpsk| {
                var buffer: [44]u8 = undefined;
                try writer.print("wgpsk {s} ", .{ std.base64.standard.Encoder.encode(&buffer, &wgpsk) });
            }
            if (peer_if.hostname) |hostname| {
                try writer.print("wgendpoint {s} ", .{ hostname });
                if (peer_if.port) |port| {
                    try writer.print("{d} ", .{ port });
                }
            }
            try writer.print("# {s}\n", .{ peer_if.name });
        }
        try writer.print("up\n", .{});
    }
};

pub const PeerList = std.ArrayList(Peer);

pub const Peer = struct {
    interface: *Interface,
    allowed_ips: AllowedIPList,

    pub fn init(allocator: mem.Allocator, interface: *Interface) Peer {
        return .{
            .interface = interface,
            .allowed_ips = AllowedIPList.init(allocator),
        };
    }

    pub fn addAllowedIPs(self: *Peer, range: []const u8) !void {
        try self.allowed_ips.append(self.allowed_ips.allocator.dupe(u8, range));
    }

    pub fn deinit(self: Peer) void {
        for (self.allowed_ips.items) |item| {
            self.allowed_ips.allocator.free(item);
        }
        self.allowed_ips.deinit();
    }
};

/// List of strings in the format of "allowed_ip/prefix"
pub const AllowedIPList = std.ArrayList(AllowedIP);

/// String in the format of "allowed_ip/prefix"
pub const AllowedIP = []const u8;

test "e" {
    const k = try kp.generateKeyPair();
    const k2 = try kp.generateKeyPair();
    var if1 = try Interface.init(testing.allocator, "captain", k.private, "192.168.69.1", 24);
    defer if1.deinit();
    var if2 = try Interface.init(testing.allocator, "lappy", k2.private, "192.168.69.2", 24);
    defer if2.deinit();
    var if3 = try Interface.init(testing.allocator, "phone", k2.private, "192.168.69.3", 24);
    defer if3.deinit();

    try if1.addPeer(&if2);
    try if1.addPeer(&if3);
    std.debug.print("\n", .{});
    try if1.toOpenBSD(std.io.getStdErr().writer());
}
