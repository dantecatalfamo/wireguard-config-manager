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

    const command = std.meta.stringToEnum(Command, arg_iter.next() orelse usage()) orelse usage();

    switch (command) {
        .list => {
            if (arg_iter.next()) |name| {
                const id = try system.interfaceIdFromName(name);
                try system.listInterface(stdout, id);
            } else {
                try system.listInterfaces(stdout);
            }
        },
        .add => {
            const name = arg_iter.next() orelse return error.MissingArg;
            const addr_pfx = try System.parseAddrPrefix(arg_iter.next() orelse return error.MissingArg);
            const id = try system.addInterface(name, addr_pfx.address, addr_pfx.prefix, null);
            try stdout.print("{d}\n", .{ id });
        },
        .peer => {
            const if1 = try interfaceId(system, &arg_iter);
            const if2 = try interfaceId(system, &arg_iter);
            try system.addPeer(if1, if2);
        },
        .route => {
            const if1 = try interfaceId(system, &arg_iter);
            const if2 = try interfaceId(system, &arg_iter);
            try system.addRouter(if2, if1);
        },
        .allow => {
            const if1 = try interfaceId(system, &arg_iter);
            const if2 = try interfaceId(system, &arg_iter);
            const addr_pfx = try System.parseAddrPrefix(arg_iter.next() orelse return error.MissingArg);
            try system.addAllowedIP(if1, if2, addr_pfx.address, addr_pfx.prefix);
        },
        .unallow => {
            const if1 = try interfaceId(system, &arg_iter);
            const if2 = try interfaceId(system, &arg_iter);
            const addr_pfx = try System.parseAddrPrefix(arg_iter.next() orelse return error.MissingArg);
            try system.removeAllowedIP(if1, if2, addr_pfx.address, addr_pfx.prefix);
        },
        .unpeer => {
            const if1 = try interfaceId(system, &arg_iter);
            const if2 = try interfaceId(system, &arg_iter);
            try system.unPeer(if1, if2);
        },
        .remove => {
            const id = try interfaceId(system, &arg_iter);
            try system.removeInterface(id);
        },
        .@"export" => {
            const id = try interfaceId(system, &arg_iter);
            try system.exportConf(id, stdout);
        },
        .genpsk => {
            const if1 = try interfaceId(system, &arg_iter);
            const if2 = try interfaceId(system, &arg_iter);
            const kp = try keypair.generateKeyPair();
            try system.setPresharedKey(if1, if2, &kp.privateBase64());
        },
        .setpsk => {
            const if1 = try interfaceId(system, &arg_iter);
            const if2 = try interfaceId(system, &arg_iter);
            if (arg_iter.next()) |key| {
                if (!try System.verifyPrivkey(key))
                    return error.InvalidKey;
                try system.setPresharedKey(if1, if2, key);
            }
        },
        .clearpsk => {
            const if1 = try interfaceId(system, &arg_iter);
            const if2 = try interfaceId(system, &arg_iter);
            try system.setPresharedKey(if1, if2, null);
        },
        .set => {
            const id = try interfaceId(system, &arg_iter);
            const field = arg_iter.next() orelse usage();
            const value = arg_iter.next() orelse usage();
            if (std.meta.stringToEnum(System.Field, field)) |f| {
                try system.setField(id, f, value);
            } else {
                return error.InvalidFieldName;
            }
        },
        .dump => {
            const dir = arg_iter.next() orelse usage();
            try system.dump(dir);
        },
        .seed => {
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
}

pub const Command = enum {
    list,
    add,
    peer,
    unpeer,
    route,
    allow,
    unallow,
    remove,
    @"export",
    genpsk,
    clearpsk,
    setpsk,
    set,
    dump,
    seed,
};

pub fn usage() noreturn {
    std.io.getStdErr().writer().writeAll(
            \\usage: wgcm <command> [args]
            \\commands:
            \\  list                                      List all interfaces
            \\  list     <name>                           Display detailed view of an interface
            \\  add      <name> <ip[/prefix]>             Add a new interface with name and IP/subnet
            \\  peer     <name1> <name2>                  Peer two interfaces
            \\  unpeer   <name1> <name2>                  Remove the connection between two interfaces
            \\  route    <name> <router_name>             Peer two interfaces, where <name> accepts the entire subnet from <router_if>
            \\  allow    <name> <peer_name> <ip[/prefix]> Allow an IP or subnet into <name> from <peer_name>
            \\  unallow  <name> <peer_name> <ip[/prefix]> Unallow an IP or subnet into <name> from <peer_name>
            \\  remove   <name>                           Remove an interface
            \\  export   <name>                           Export the configuration for an interface in wg-quick format to stdout
            \\  genpsk   <name1> <name2>                  Generate a preshared key between two interfaces
            \\  clearpsk <name1> <name2>                  Remove the preshared key between two interfaces
            \\  set      <name> <field> <value>           Set a value for a field on an interface
            \\  dump     <directory>                      Export all configuration files to a directory
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

pub fn interfaceId(system: System, iter: *std.process.ArgIterator) !u64 {
    return try system.interfaceIdFromName(iter.next() orelse usage());
}

test "ref all" {
    testing.refAllDeclsRecursive(@This());
    testing.refAllDecls(sqlite);
}
