const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

const keypair = @import("keypair.zig");
const sqlite = @import("sqlite.zig");
const System = @import("system.zig").System;

const config_dir_name = "wireguard-config-manager";
const db_name = "wgcm.db";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();


    const db_path = try setupDbPath(allocator);
    defer allocator.free(db_path);

    const system = try System.init(db_path, allocator);
    defer system.close() catch unreachable;

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

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
            const name = arg_iter.next() orelse usage();
            const addr_pfx = try System.parseAddrPrefix(arg_iter.next() orelse usage());
            _ = system.addInterface(name, addr_pfx.address, addr_pfx.prefix, null) catch |err| switch (err) {
                error.ConstraintFailed => {
                    try stderr.print("New interface conflicts with existing interface\n", .{});
                    os.exit(1);
                },
                else => return err,
            };
        },
        .peer => {
            const if1 = try interfaceId(system, &arg_iter);
            const if2 = try interfaceId(system, &arg_iter);
            checkPeering(if1, if2);
            system.addPeer(if1, if2) catch |err| switch (err) {
                error.ConstraintFailed => {
                    try stderr.print("Interfaces are already peered\n", .{});
                    os.exit(1);
                },
                else => return err,
            };
        },
        .route => {
            const if1 = try interfaceId(system, &arg_iter);
            const if2 = try interfaceId(system, &arg_iter);
            checkPeering(if1, if2);
            system.addRouter(if2, if1) catch |err| switch (err) {
                error.ConstraintFailed => {
                    try stderr.print("Interfaces are already peered\n", .{});
                    os.exit(1);
                },
                else => return err,
            };
        },
        .allow => {
            const if1 = try interfaceId(system, &arg_iter);
            const if2 = try interfaceId(system, &arg_iter);
            checkPeering(if1, if2);
            const addr_pfx = try System.parseAddrPrefix(arg_iter.next() orelse usage());
            system.addAllowedIP(if1, if2, addr_pfx.address, addr_pfx.prefix) catch |err| switch (err) {
                error.ConstraintFailed => {
                    try stderr.print("IP range already allowed\n", .{});
                    os.exit(1);
                },
                else => return err,
            };
        },
        .unallow => {
            const if1 = try interfaceId(system, &arg_iter);
            const if2 = try interfaceId(system, &arg_iter);
            checkPeering(if1, if2);
            const addr_pfx = try System.parseAddrPrefix(arg_iter.next() orelse usage());
            try system.removeAllowedIP(if1, if2, addr_pfx.address, addr_pfx.prefix);
        },
        .unpeer => {
            const if1 = try interfaceId(system, &arg_iter);
            const if2 = try interfaceId(system, &arg_iter);
            checkPeering(if1, if2);
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
        .openbsd => {
            const id = try interfaceId(system, &arg_iter);
            try system.exportOpenBSD(id, stdout);
        },
        .genpsk => {
            const if1 = try interfaceId(system, &arg_iter);
            const if2 = try interfaceId(system, &arg_iter);
            checkPeering(if1, if2);
            const kp = try keypair.generateKeyPair();
            try system.setPresharedKey(if1, if2, &kp.privateBase64());
        },
        .setpsk => {
            const if1 = try interfaceId(system, &arg_iter);
            const if2 = try interfaceId(system, &arg_iter);
            checkPeering(if1, if2);
            if (arg_iter.next()) |key| {
                if (!try System.verifyPrivkey(key))
                    return error.InvalidKey;
                try system.setPresharedKey(if1, if2, key);
            }
        },
        .clearpsk => {
            const if1 = try interfaceId(system, &arg_iter);
            const if2 = try interfaceId(system, &arg_iter);
            checkPeering(if1, if2);
            try system.setPresharedKey(if1, if2, null);
        },
        .set => {
            const id = try interfaceId(system, &arg_iter);
            const field = arg_iter.next() orelse usage();
            const value = arg_iter.next() orelse usage();
            if (std.meta.stringToEnum(System.Field, field)) |f| {
                system.setField(id, f, value) catch |err| switch (err) {
                    error.ConstraintFailed => {
                        try stderr.print("Change conflicts with another interface\n", .{});
                        os.exit(1);
                    },
                    else => return err,
                };
            } else {
                try stderr.print("Invalid field name\n", .{});
                os.exit(1);
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

            const test_psk = try keypair.generateKeyPair();
            try system.setPresharedKey(if1, if2, &test_psk.privateBase64());
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
    openbsd,
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
            \\  openbsd  <name>                           Export the configuration for an interface in OpenBSD hostname.if format to stdout
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
    const arg = iter.next() orelse usage();
    return try std.fmt.parseInt(u64, arg, 10);
}

pub fn interfaceId(system: System, iter: *std.process.ArgIterator) !u64 {
    const name = iter.next() orelse usage();
    return system.interfaceIdFromName(name) catch |err| switch (err) {
        error.NoRecord => {
            std.debug.print("Interface \"{s}\" does not exist\n", .{ name });
            os.exit(1);
        },
        else => return err,
    };
}

pub fn setupDbPath(allocator: mem.Allocator) ![:0]const u8 {
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    const custom_db_path = env.get("WGCM_DB_PATH");
    if (custom_db_path) |custom_path| {
        const dir_name = fs.path.dirname(custom_path) orelse {
            std.debug.print("Invalid custom DB path (WGMC_DB_PATH)\n", .{});
            os.exit(1);
        };
        if (!fs.path.isAbsolute(dir_name)) {
            std.debug.print("Invalid custom DB path (WGMC_DB_PATH): Path must be absolute\n", .{});
            os.exit(1);
        }
        fs.cwd().access(dir_name, .{}) catch {
            std.debug.print("Invalid custom DB path (WGMC_DB_PATH): Directory does not exist\n", .{});
            os.exit(1);
        };
        return try allocator.dupeZ(u8, custom_path);
    }
    const xdg_config = env.get("XDG_CONFIG_HOME");
    if (xdg_config) |config_path| {
        const dir_path = try fs.path.join(allocator, &.{ config_path, config_dir_name });
        defer allocator.free(dir_path);
        try fs.cwd().makePath(dir_path);
        return try fs.path.joinZ(allocator, &.{ dir_path, db_name });
    }
    const home = env.get("HOME");
    if (home) |home_path| {
        const dir_path = try fs.path.join(allocator, &.{ home_path, ".config", config_dir_name });
        defer allocator.free(dir_path);
        try fs.cwd().makePath(dir_path);
        return try fs.path.joinZ(allocator, &.{ dir_path, db_name });
    }
    return error.NoHomeDirectory;
}

pub fn checkPeering(if1: u64, if2: u64) void {
    if (if1 == if2) {
        std.debug.print("You cannot relate interfaces to themselves\n", .{});
        os.exit(1);
    }
}

test "ref all" {
    testing.refAllDeclsRecursive(@This());
    testing.refAllDecls(sqlite);
}
