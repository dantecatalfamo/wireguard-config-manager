const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

const keypair = @import("keypair.zig");
const config = @import("config.zig");
const interface_zig = @import("interface.zig");
const Interface = interface_zig.Interface;
const Environment = config.Environment;
const Lambda = config.Lambda;
const Value = config.Value;
const eval = config.eval;

pub fn def(env: *Environment, args: []const Value) !Value {
    if (args.len != 2)
        return error.NumArgs;

    if (args[0] != .identifier)
        return error.ArgType;

    try env.put(args[0].identifier, args[1]);

    return args[1];
}

pub fn plus(env: *Environment, args: []const Value) !Value {
    _ = env;
    var acc: i64 = 0;
    for (args) |arg| {
        if (arg != .integer) {
            return error.ArgType;
        }
        acc += arg.integer;
    }
    return Value{ .integer = acc };
}

pub fn minus(env: *Environment, args: []const Value) !Value {
    _ = env;
    if (args.len == 0) {
        return error.NumArgs;
    }
    for (args) |arg| {
        if (arg != .integer) {
            return error.ArgType;
        }
    }
    var acc: i64 = if (args.len == 1) 0 else args[0].integer;
    const begin_index: usize = if (args.len == 1) 0 else 1;
    for (args[begin_index..]) |arg| {
        acc -= arg.integer;
    }
    return Value{ .integer = acc };
}

pub fn times(env: *Environment, args: []const Value) !Value {
    _ = env;
    if (args.len == 0) {
        return Value{ .integer = 0 };
    }
    var acc: i64 = if (args[0] == .integer) args[0].integer else return error.ArgType;
    for (args[1..]) |arg| {
        if (arg != .integer) {
            return error.ArgType;
        }
        acc *= arg.integer;
    }
    return Value{ .integer = acc };
}

pub fn divide(env: *Environment, args: []const Value) !Value {
    _ = env;
    if (args.len == 0) {
        return Value{ .integer = 0 };
    }

    var acc: i64 = if (args[0] == .integer) args[0].integer else return error.ArgType;

    for (args[1..]) |arg| {
        if (arg != .integer) {
            return error.ArgType;
        }

        if (arg.integer == 0) {
            return error.DivisionByZero;
        }

        acc = @divFloor(acc, arg.integer);
    }

    return Value{ .integer = acc };
}

pub fn pow(env: *Environment, args: []const Value) !Value {
    _ = env;
    if (args.len < 2) {
        return error.NumArgs;
    }

    for (args) |arg| {
        if (arg != .integer) {
            return error.ArgType;
        }
    }

    var acc: i64 = args[0].integer;
    for (args[1..]) |arg| {
        acc = std.math.pow(i64, acc, arg.integer);
    }
    return Value{ .integer = acc };
}

pub fn shl(env: *Environment, args: []const Value) !Value {
    _ = env;
    if (args.len != 2) {
        return error.NumArgs;
    }
    if (args[0] != .integer and args[1] != .integer) {
        return error.ArgType;
    }
    if (args[1].integer > std.math.maxInt(u6)) {
        return error.Overflow;
    }
    const out = args[0].integer << @intCast(args[1].integer);
    return Value{ .integer = out };
}

pub fn shr(env: *Environment, args: []const Value) !Value {
    _ = env;
    if (args.len != 2) {
        return error.NumArgs;
    }
    if (args[0] != .integer and args[1] != .integer) {
        return error.ArgType;
    }
    if (args[1].integer > std.math.maxInt(u6)) {
        return error.Overflow;
    }
    const out = args[0].integer >> @intCast(args[1].integer);
    return Value{ .integer = out };
}



pub fn inc(env: *Environment, args: []const Value) !Value {
    if (args.len != 1) {
        return error.NumArgs;
    }
    if (args[0] != .identifier) {
        return error.ArgType;
    }
    var stored = env.get(args[0].identifier) orelse return error.NoBindings;
    if (stored != .integer) {
        return error.ArgType;
    }
    var new_val = Value{ .integer = stored.integer + 1 };
    try env.put(args[0].identifier, new_val);
    return new_val;
}

pub fn dec(env: *Environment, args: []const Value) !Value {
    if (args.len != 1) {
        return error.NumArgs;
    }
    if (args[0] != .identifier) {
        return error.ArgType;
    }
    var stored = env.get(args[0].identifier) orelse return error.NoBindings;
    if (stored != .integer) {
        return error.ArgType;
    }
    var new_val = Value{ .integer = stored.integer - 1 };
    try env.put(args[0].identifier, new_val);
    return new_val;
}

pub fn concat(env: *Environment, args: []const Value) !Value {
    var strings = std.ArrayList([]const u8).init(env.allocator());
    for (args) |arg| {
        if (arg == .integer) {
            const int_str = try std.fmt.allocPrint(env.allocator(), "{d}", .{ arg.integer });
            try strings.append(int_str);
            continue;
        }
        if (arg != .string) {
            return error.ArgType;
        }
        try strings.append(arg.string);
    }
    const new_str = try mem.concat(env.allocator(), u8, strings.items);
    return Value{ .string = new_str };
}

pub fn eq(env: *Environment, args: []const Value) !Value {
    _ = env;
    if (args.len < 2) {
        return error.NumArgs;
    }
    const arg1 = args[0];
    for (args[1..]) |arg| {
        if (!eqInternal(arg1, arg)) {
            return nil;
        }
    }
    return t;
}

pub fn progn(env: *Environment, args: []const Value) !Value {
    for (args, 0..) |arg, idx| {
        const val = eval(env, arg);
        if (idx == args.len-1) {
            return val;
        }
    }
    return Value.nil;
}

pub fn eqInternal(lhs: Value, rhs: Value) bool {
    if (!mem.eql(u8, @tagName(lhs), @tagName(rhs))) {
        return false;
    }
    switch(lhs) {
        .nil => return true,
        .integer => return lhs.integer == rhs.integer,
        .function => return lhs.function.impl == rhs.function.impl,
        .string => return mem.eql(u8, lhs.string, rhs.string),
        .identifier => return mem.eql(u8, lhs.identifier, rhs.identifier),
        .symbol => return mem.eql(u8, lhs.symbol, rhs.symbol),
        .interface => return lhs.interface == rhs.interface,
        .list => {
            if (rhs.list.len != rhs.list.len) {
                return false;
            }
            for (0..lhs.list.len) |idx| {
                if (!eqInternal(lhs.list[idx], rhs.list[idx])) {
                    return false;
                }
            }
            return true;
        },
        .lambda => {
            if (rhs.lambda.body.len != rhs.lambda.body.len) {
                return false;
            }
            for (rhs.lambda.body, lhs.lambda.body) |rhb, lhb| {
                if (!eqInternal(rhb, lhb)) {
                    return false;
                }
            }
            // for (0..lhs.lambda.len) |idx| {
            //     if (!eqInternal(lhs.lambda[idx], rhs.lambda[idx])) {
            //         return false;
            //     }
            // }
            return true;
        },
    }
}

pub const t = Value{ .identifier = "t" };
pub const nil = Value.nil;

pub fn list(env: *Environment, args: []const Value) !Value {
    _ = env;
    return Value{ .list = args };
}

pub fn quote(env: *Environment, args: []const Value) !Value {
    _ = env;
    if (args.len != 1) {
        return error.NumArgs;
    }
    return args[0];
}

pub fn eval_fn(env: *Environment, args: []const Value) !Value {
    if (args.len != 1) return error.NumArgs;
    return eval(env, args[0]);
}

pub fn lambda(env: *Environment, args: []const Value) !Value {
    _ = env;
    if (args.len == 0) {
        return error.NumArgs;
    }
    if (args[0] != .list) {
        return error.ArgType;
    }
    for (args[0].list) |arg| {
        if (arg != .identifier) {
            return error.ArgType;
        }
    }
    return Value{ .lambda = Lambda{ .args = args[0].list, .body = args[1..] }};
}

pub fn if_fn (env: *Environment, args: []const Value) !Value {
    if (args.len != 3) {
        return error.NumArgs;
    }
    const condition = args[0];
    const if_true = args[1];
    const if_false = args[2];

    if (try eval(env, condition) != Value.nil) {
        return try eval(env, if_true);
    }
    return try eval(env, if_false);
}

pub fn println(env: *Environment, args: []const Value) !Value {
    _ = env;
    if (args.len > 1) {
        return error.NumArgs;
    }
    const writer = std.io.getStdIn().writer();
    if (args.len == 1) {
        try args[0].toString(writer);
    }
    try writer.print("\n", .{});
    return nil;
}

// keypair: KeyPair,
// name: []const u8,
// port: ?u16 = null,
// hostname: ?[]const u8 = null,
// address: []const u8,
// prefix: u6,
// peers: PeerList,
// preshared_key: ?[32]u8 = null,

pub fn interface(env: *Environment, args: []const Value) !Value {
    var name: ?[]const u8 = null;
    var address: ?[]const u8 = null;
    var prefix: ?u6 = null;
    var privkey: ?[]const u8 = null;

    const pairs = try parsePairs(env, args);
    for (pairs) |pair| {
        if (mem.eql(u8, pair.symbol, "name")) {
            name = pair.value.string;
        } else if (mem.eql(u8, pair.symbol, "address")) {
            address = pair.value.string;
        } else if (mem.eql(u8, pair.symbol, "prefix")) {
            prefix = @intCast(pair.value.integer);
        } else if (mem.eql(u8, pair.symbol, "privkey")) {
            privkey = pair.value.string;
        }
    }
    if (name == null or address == null or prefix == null or privkey == null) {
        return error.MissingKeywords;
    }

    var privkey_decoded: [32]u8 = undefined;
    try std.base64.standard.Decoder.decode(&privkey_decoded, privkey.?);
    var iface = try env.allocator().create(Interface);
    iface.* = try Interface.init(env.allocator(), name.?, privkey_decoded, address.?, prefix.?);
    return Value{ .interface = iface };
}

pub fn openbsd(env: *Environment, args: []const Value) !Value {
    if (args.len != 1) {
        return error.NumArgs;
    }
    if (args[0] != .interface) {
        return error.ArgType;
    }
    var str = std.ArrayList(u8).init(env.allocator());
    try args[0].interface.toOpenBSD(str.writer());
    return Value{ .string = try str.toOwnedSlice() };
}

pub fn conf(env: *Environment, args: []const Value) !Value {
    if (args.len != 1) {
        return error.NumArgs;
    }
    if (args[0] != .interface) {
        return error.ArgType;
    }
    var str = std.ArrayList(u8).init(env.allocator());
    try args[0].interface.toConf(str.writer());
    return Value{ .string = try str.toOwnedSlice() };
}

pub fn genPrivkey(env: *Environment, args: []const Value) !Value {
    if (args.len != 0) {
        return error.NumArgs;
    }
    const kp = try keypair.generateKeyPair();
    return Value{ .string = try env.allocator().dupe(u8, &kp.privateBase64()) };
}

pub fn addPeer(env: *Environment, args: []const Value) !Value {
    if (args.len != 2) {
        return error.NumArgs;
    }
    if (args[0] != .interface or args[1] != .interface) {
        return error.ArgType;
    }
    _ = env;
    try (args[0].interface.addPeer(args[1].interface));
    return t;
}

pub fn trace(env: *Environment, args: []const Value) !Value {
    if (args.len != 1) {
        return error.NumArgs;
    }
    if (args[0] == .nil) {
        env.trace = false;
        return nil;
    }
    env.trace = true;
    env.trace_depth += 1;
    return t;
}

pub fn parsePairs(env: *Environment, args: []const Value) ![]Pair {
    if (args.len % 2 != 0) {
        return error.NumArgs;
    }
    var pairs = std.ArrayList(Pair).init(env.allocator());
    errdefer pairs.deinit();

    for (0..args.len/2) |i| {
        if (args[i*2] != .symbol) {
            return error.ArgType;
        }
        try pairs.append(.{ .symbol = args[i*2].symbol, .value = args[(i*2)+1] });
    }

    return pairs.toOwnedSlice();
}

pub const Pair = struct {
    symbol: []const u8,
    value: Value,
};
