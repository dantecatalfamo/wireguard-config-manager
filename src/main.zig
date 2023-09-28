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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const system = try System.init("/tmp/wgbank_test.db", allocator);
    defer system.close() catch unreachable;

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();
    _ = stderr;

    var arg_iter = try std.process.argsWithAllocator(allocator);
    defer arg_iter.deinit();

    _ = arg_iter.skip();

    const operation = arg_iter.next() orelse usage();

    if (mem.eql(u8, operation, "list")) {
        if (arg_iter.next()) |id| {
            const interface_id = try std.fmt.parseInt(u8, id, 10);
            try system.listInterface(stdout, interface_id);
        } else {
            try system.listInterfaces(stdout);
        }
    } else if (mem.eql(u8, operation, "add")) {
        const name = arg_iter.next() orelse return error.MissingArg;
        const addr_pfx = try parseAddrPrefix(arg_iter.next() orelse return error.MissingArg);
        const id = try system.addInterface(name, addr_pfx.address, addr_pfx.prefix, null);
        try stdout.print("{d}\n", .{ id });
    } else if (mem.eql(u8, operation, "peer")) {
        const if1 = try argInt(&arg_iter);
        const if2 = try argInt(&arg_iter);
        try system.addPeer(if1, if2);
    } else if (mem.eql(u8, operation, "route")) {
        const if1 = try argInt(&arg_iter);
        const if2 = try argInt(&arg_iter);
        try system.addRouter(if2, if1);
    } else if (mem.eql(u8, operation, "allow")) {
        const if1 = try argInt(&arg_iter);
        const if2 = try argInt(&arg_iter);
        const addr_pdx = try parseAddrPrefix(arg_iter.next() orelse return error.MissingArg);
        try system.addAllowedIP(if1, if2, addr_pdx.address, addr_pdx.prefix);
    } else if (mem.eql(u8, operation, "unallow")) {
        const if1 = try argInt(&arg_iter);
        const if2 = try argInt(&arg_iter);
        const addr_pdx = try parseAddrPrefix(arg_iter.next() orelse return error.MissingArg);
        try system.removeAllowedIP(if1, if2, addr_pdx.address, addr_pdx.prefix);
    } else if (mem.eql(u8, operation, "unpeer")) {
        const if1 = try argInt(&arg_iter);
        const if2 = try argInt(&arg_iter);
        try system.unPeer(if1, if2);
    } else if (mem.eql(u8, operation, "remove")) {
        const id = try argInt(&arg_iter);
        try system.removeInterface(id);
    } else if (mem.eql(u8, operation, "config")) {
        const id = try argInt(&arg_iter);
        try system.exportConf(id, stdout);
    } else if (mem.eql(u8, operation, "genpsk")) {
        const if1 = try argInt(&arg_iter);
        const if2 = try argInt(&arg_iter);
        const kp = try keypair.generateKeyPair();
        try system.setPresharedKey(if1, if2, &kp.privateBase64());
    } else if (mem.eql(u8, operation, "clearpsk")) {
        const if1 = try argInt(&arg_iter);
        const if2 = try argInt(&arg_iter);
        try system.setPresharedKey(if1, if2, null);
    } else if (mem.eql(u8, operation, "set")) {
        const id = try argInt(&arg_iter);
        const field = arg_iter.next() orelse usage();
        const value = arg_iter.next() orelse usage();
        try system.setField(id, field, value);
    } else if (mem.eql(u8, operation, "seed")) {
        const if1 = try system.addInterface("potato", "192.168.10.1", 24, null);
        const if2 = try system.addInterface("banana", "192.168.10.2", 24, null);
        const if3 = try system.addInterface("orange", "192.168.10.3", 24, null);
        const if4 = try system.addInterface("grape",  "192.168.10.4", 24, null);

        try system.addRouter(if1, if2);
        try system.addRouter(if1, if3);
        try system.addRouter(if1, if4);

        try system.setPresharedKey(if1, if2, "DEADBEEF");
        try system.addPeer(if2, if3);
    }
}

pub fn usage() noreturn {
    std.io.getStdErr().writer().writeAll(
            \\usage: wgbank <option> [args]
            \\options:
            \\  list                                  List all interfaces
            \\  list     <if>                         Display detailed view of an interface
            \\  add      <name> <ip[/prefix]>         Add a new interface with name and IP/subnet
            \\  peer     <if1> <if2>                  Peer two interfaces
            \\  unpeer   <if1> <if2>                  Remove the connection between two interfaces
            \\  route    <if> <router_if>             Peer two interfaces, where <if> accepts the entire subnet from <router_if>
            \\  allow    <if> <peer_if> <ip[/prefix]> Allow an IP or subnet into <if> from <peer_if>
            \\  unallow  <if> <peer_if> <ip[/prefix]> Unallow an IP or subnet into <if> from <peer_if>
            \\  remove   <if>                         Remove an interface
            \\  config   <if>                         Export the configuration an interface in wg-quick format
            \\  genpsk   <if1> <if2>                  Generate a preshared key between two interfaces
            \\  clearpsk <if1> <if2>                  Remove the preshared key between two interfaces
            \\  set      <if> <field> <value>         Set a value for a field on an interface
            \\fields:
            \\  name
            \\  comment
            \\  privkey
            \\  hostname
            \\  address  (ip/prefix)
            \\  port
            \\  dns
            \\
    ) catch unreachable;
    std.os.exit(1);
}

pub fn argInt(iter: *std.process.ArgIterator) !u64 {
    const arg = iter.next() orelse return error.MissingArg;
    return try std.fmt.parseInt(u64, arg, 10);
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

test "ref all" {
    testing.refAllDeclsRecursive(@This());
    testing.refAllDecls(sqlite);
}
