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
        // TODO multiple IPs, other interface parameter options
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
        var my_peer = try self.peers.addOne();
        my_peer.* = Peer.init(self.peers.allocator, peer_interface);
        try my_peer.addAllowedIPs(peer_interface.address, 32);

        var their_peer = try peer_interface.peers.addOne();
        their_peer.* = Peer.init(peer_interface.peers.allocator, self);
        try their_peer.addAllowedIPs(self.address, 32);
    }

    pub fn addRouter(self: *Interface, router_interface: *Interface) !void {
        var my_peer = try self.peers.addOne();
        my_peer.* = Peer.init(self.peers.allocator, router_interface);
        try my_peer.addAllowedIPs(router_interface.address, router_interface.prefix);

        var their_peer = try router_interface.peers.addOne();
        their_peer.* = Peer.init(router_interface.peers.allocator, self);
        try their_peer.addAllowedIPs(self.address, 32);
    }

    pub fn addRoutee(self: *Interface, routee_interface: *Interface) !void {
        try routee_interface.addRouter(self);
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
            for (peer.allowed_ips.items) |allowed_ip| {
                try writer.print("wgaip {s}/{d} ", .{ allowed_ip.address, allowed_ip.prefix });
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

    pub fn toConf(self: *Interface, writer: anytype) !void {
        try writer.print("[Interface]\n", .{});
        try writer.print("Address = {s}/{d}\n", .{ self.address, self.prefix });
        try writer.print("PrivateKey = {s}\n", .{ self.keypair.privateBase64() });
        if (self.port) |port| {
            try writer.print("ListenPort = {d}\n", .{ port });
        }
        for (self.peers.items) |peer| {
            try writer.print("\n[Peer]\n", .{});
            try writer.print("# {s}\n", .{ peer.interface.name });
            try writer.print("PublicKey = {s}\n", .{ peer.interface.keypair.publicBase64() });
            if (peer.interface.preshared_key) |psk| {
                var buffer: [44]u8 = undefined;
                try writer.print("PresharedKey = {s}\n", .{ std.base64.standard.Encoder.encode(&buffer, &psk) });
            }
            if (peer.allowed_ips.items.len != 0) {
                try writer.print("AllowedIPs = ", .{});
                for (peer.allowed_ips.items, 0..) |allowed_ip, idx| {
                    try writer.print("{s}/{d}", .{ allowed_ip.address, allowed_ip.prefix });
                    if (idx != peer.allowed_ips.items.len - 1) {
                        try writer.print(", ", .{});
                    }
                }
                try writer.print("\n", .{});
            }
            if (peer.interface.hostname) |host| {
                try writer.print("Endpoint = {s}", .{ host });
                if (peer.interface.port) |port| {
                    try writer.print(":{d}", .{ port });
                }
                try writer.print("\n", .{});
            }
        }
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

    pub fn addAllowedIPs(self: *Peer, address: []const u8, prefix: u6) !void {
        try self.allowed_ips.append(.{
            .address = try self.allowed_ips.allocator.dupe(u8, address),
            .prefix = prefix,
        });
    }

    pub fn deinit(self: Peer) void {
        for (self.allowed_ips.items) |item| {
            self.allowed_ips.allocator.free(item.address);
        }
        self.allowed_ips.deinit();
    }
};

pub const AllowedIPList = std.ArrayList(AllowedIP);

pub const AllowedIP = struct {
    address: []const u8,
    prefix: u6,
};

// test "e" {
//     const stderr = std.io.getStdErr().writer();
//     const k = try kp.generateKeyPair();
//     const k2 = try kp.generateKeyPair();
//     const k3 = try kp.generateKeyPair();

//     var if1 = try Interface.init(testing.allocator, "captain", k.private, "192.168.69.1", 24);
//     if1.port = 1234;
//     if1.hostname = "example.com";
//     defer if1.deinit();
//     var if2 = try Interface.init(testing.allocator, "lappy", k2.private, "192.168.69.2", 24);
//     defer if2.deinit();
//     var if3 = try Interface.init(testing.allocator, "phone", k3.private, "192.168.69.3", 24);
//     defer if3.deinit();

//     try if2.addRouter(&if1);
//     try if3.addRouter(&if1);

//     std.debug.print("\n############\n\n", .{});
//     try if1.toOpenBSD(stderr);
//     try if1.toConf(stderr);

//     std.debug.print("\n############\n\n", .{});
//     try if2.toOpenBSD(stderr);
//     try if2.toConf(stderr);

//     std.debug.print("\n############\n\n", .{});
//     try if3.toOpenBSD(stderr);
//     try if3.toConf(stderr);
// }
