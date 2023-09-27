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
    const system = try System.init("/tmp/wgbank_test.db", std.heap.page_allocator);
    defer system.close() catch unreachable;

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    if (std.os.argv.len == 1) {
        try stderr.print("No argumets provided\n", .{});
        os.exit(1);
    }

    const operation = mem.span(std.os.argv[1]);

    if (mem.eql(u8, operation, "list")) {
        if (std.os.argv.len == 2) {
            try system.listInterfaces(stdout);
        } else {
            const interface_id = try std.fmt.parseInt(u8, mem.span(std.os.argv[2]), 10);
            try system.listInterface(stdout, interface_id);
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

test "ref all" {
    testing.refAllDeclsRecursive(@This());
    testing.refAllDecls(sqlite);
}
