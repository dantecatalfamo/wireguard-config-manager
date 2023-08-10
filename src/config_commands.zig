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
const ValueList = config.ValueList;

pub fn def(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{ .identifier, null });

    try env.put(args[0].identifier, args[1]);
    return args[1];
}

pub fn plus(env: *Environment, args: []const Value) !Value {
    _ = env;
    try checkArgsType(args, .integer);

    var acc: i64 = 0;
    for (args) |arg| {
        acc += arg.integer;
    }
    return Value{ .integer = acc };
}

pub fn minus(env: *Environment, args: []const Value) !Value {
    _ = env;
    try checkArgsType(args, .integer);
    if (args.len == 0) return error.NumArgs;
    if (args.len == 1) return Value{ .integer = -args[0].integer };

    var acc = args[0].integer;
    for (args[1..]) |arg| {
        acc -= arg.integer;
    }
    return Value{ .integer = acc };
}

pub fn mul(env: *Environment, args: []const Value) !Value {
    _ = env;
    try checkArgsType(args, .integer);
    if (args.len == 0) {
        return Value{ .integer = 0 };
    }

    var acc = args[0].integer;
    for (args[1..]) |arg| {
        acc *= arg.integer;
    }
    return Value{ .integer = acc };
}

pub fn divide(env: *Environment, args: []const Value) !Value {
    _ = env;
    try checkArgsType(args, .integer);
    if (args.len == 0) {
        return Value{ .integer = 0 };
    }

    var acc = args[0].integer;
    for (args[1..]) |arg| {
        if (arg.integer == 0) {
            return error.DivisionByZero;
        }
        acc = @divFloor(acc, arg.integer);
    }

    return Value{ .integer = acc };
}

pub fn pow(env: *Environment, args: []const Value) !Value {
    _ = env;
    try checkArgs(args, &.{ .integer, .integer });

    var acc: i64 = args[0].integer;
    for (args[1..]) |arg| {
        acc = std.math.pow(i64, acc, arg.integer);
    }
    return Value{ .integer = acc };
}

pub fn shl(env: *Environment, args: []const Value) !Value {
    _ = env;
    try checkArgs(args, &.{ .integer, .integer });

    if (args[1].integer > std.math.maxInt(u6)) {
        return error.Overflow;
    }
    const out = args[0].integer << @intCast(args[1].integer);
    return Value{ .integer = out };
}

pub fn shr(env: *Environment, args: []const Value) !Value {
    _ = env;
    try checkArgs(args, &.{ .integer, .integer });

    if (args[1].integer > std.math.maxInt(u6)) {
        return error.Overflow;
    }
    const out = args[0].integer >> @intCast(args[1].integer);
    return Value{ .integer = out };
}



pub fn inc(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{ .identifier });

    var stored = env.get(args[0].identifier) orelse return error.NoBindings;
    if (stored != .integer) {
        return error.ArgType;
    }
    var new_val = Value{ .integer = stored.integer + 1 };
    try env.put(args[0].identifier, new_val);
    return new_val;
}

pub fn dec(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{ .identifier });

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
    errdefer strings.deinit();

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
    try checkArgs(args, &.{ null, null });

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
    try checkArgs(args, &.{ null });

    return args[0];
}

pub fn eval_fn(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{ null });

    return eval(env, args[0]);
}

pub fn lambda(env: *Environment, args: []const Value) !Value {
    _ = env;
    try checkArgsVar(args, &.{ .list }, 2);

    for (args[0].list) |arg| {
        if (arg != .identifier) {
            return error.ArgType;
        }
    }
    return Value{ .lambda = Lambda{ .args = args[0].list, .body = args[1..] }};
}

pub fn if_fn (env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{ null, null, null });

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
    try checkArgs(args, &.{ null });

    const writer = std.io.getStdIn().writer();
    if (args.len == 1) {
        try args[0].toString(writer);
    }
    try writer.print("\n", .{});
    return nil;
}

pub fn interface(env: *Environment, args: []const Value) !Value {
    var name: ?[]const u8 = null;
    var address: ?[]const u8 = null;
    var prefix: ?u6 = null;
    var privkey: ?[]const u8 = null;


    if (try plistValue(args, "name")) |nam|  {
        if (nam != .string) return error.ArgType;
        name = nam.string;
    }
    if (try plistValue(args, "address")) |addr| {
        if (addr != .string) return error.ArgType;
        address = addr.string;
    }
    if (try plistValue(args, "prefix")) |pre| {
        if (pre != .integer) return error.ArgType;
        prefix = @intCast(pre.integer);
    }
    if (try plistValue(args, "privkey")) |pk| {
        if (pk != .string) return error.ArgType;
        if (pk.string.len != 44) {
            return error.IncorrectKeyLength;
        }
        privkey = pk.string;
    }

    if (name == null or address == null or prefix == null or privkey == null) {
        return error.MissingKeywords;
    }

    var privkey_decoded: [32]u8 = undefined;
    try std.base64.standard.Decoder.decode(&privkey_decoded, privkey.?);
    var iface = try env.allocator().create(Interface);
    iface.* = try Interface.init(env.allocator(), name.?, privkey_decoded, address.?, prefix.?);

    if (try plistValue(args, "port")) |port| {
        if (port != .integer) return error.ArgType;
        iface.port = @intCast(port.integer);
    }
    if (try plistValue(args, "hostname")) |host| {
        if (host != .string) return error.ArgType;
        iface.hostname = host.string;
    }
    if (try plistValue(args, "preshared")) |psk| {
        if (psk != .string) return error.ArgType;
        if (psk.string.len != 44) {
            std.debug.print("keylen: {d}\n", .{ psk.string.len });
            return error.IncorrectKeyLength;
        }
        var psk_decoded: [32]u8 = undefined;
        try std.base64.standard.Decoder.decode(&psk_decoded, psk.string);
        iface.preshared_key = [_]u8{0} ** 32;
        @memcpy(&iface.preshared_key.?, &psk_decoded);
    }

    return Value{ .interface = iface };
}

pub fn openbsd(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{ .interface });

    var str = std.ArrayList(u8).init(env.allocator());
    try args[0].interface.toOpenBSD(str.writer());
    return Value{ .string = try str.toOwnedSlice() };
}

pub fn conf(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{ .interface });

    var str = std.ArrayList(u8).init(env.allocator());
    try args[0].interface.toConf(str.writer());
    return Value{ .string = try str.toOwnedSlice() };
}

pub fn genPrivkey(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{});

    const kp = try keypair.generateKeyPair();
    return Value{ .string = try env.allocator().dupe(u8, &kp.privateBase64()) };
}

pub fn addPeer(env: *Environment, args: []const Value) !Value {
    _ = env;
    try checkArgs(args, &.{ .interface, .interface });

    try (args[0].interface.addPeer(args[1].interface));
    return t;
}

pub fn trace(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{ null });
    if (args[0] == .nil) {
        env.trace = false;
        return nil;
    }

    env.trace = true;
    env.trace_depth += 1;
    return t;
}

pub fn typeOf(env: *Environment, args: []const Value) !Value {
    _ = env;
    try checkArgs(args, &.{ null });

    const ident = @tagName(args[0]);
    return Value{ .identifier = ident };
}

pub fn map(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{ null, .list });
    if (!args[0].functionIsh()) {
        return error.ArgType;
    }

    var output = ValueList{};

    for (args[1].list) |item| {
        const func = Value{ .list = &.{ args[0], item }};
        const result = try eval(env, func);
        try output.append(env.allocator(), result);
    }

    return Value{ .list = try output.toOwnedSlice(env.allocator()) };
}

pub fn plistGet(env: *Environment, args: []const Value) !Value {
    _ = env;
    try checkArgs(args, &.{ .symbol, .list });

    if (try plistValue(args[1].list, args[0].symbol)) |val| {
        return val;
    }
    return nil;
}

pub fn plistValue(plist: []const Value, key: []const u8) !?Value {
    var iter = try plistIter(plist);
    while (try iter.next()) |pair| {
        if (mem.eql(u8, key, pair.symbol)) {
            return pair.value;
        }
    }
    return null;
}

pub fn plistIter(args: []const Value) !PlistIter {
    if (args.len % 2 != 0) {
        return error.NumArgs;
    }
    return .{
        .args = args,
        .index = 0,
    };
}

pub const PlistIter = struct {
    args: []const Value,
    index: usize,

    pub fn next(self: *PlistIter) !?Pair {
        if (self.index == self.args.len) {
            return null;
        }
        const symbol = self.args[self.index];
        if (symbol != .symbol) {
            return error.ArgType;
        }
        const value = self.args[self.index+1];
        self.index += 2;
        return Pair{
            .symbol = symbol.symbol,
            .value = value,
        };
    }

    pub fn reset(self: *PlistIter) void {
        self.index = 0;
    }
};

pub const Pair = struct {
    symbol: []const u8,
    value: Value,
};

pub fn nth(env: *Environment, args: []const Value) !Value {
    _ = env;
    try checkArgs(args, &.{ .integer, .list });

    if (args[0].integer > args[1].list.len or args[0].integer < 0) {
        return error.OutOfRange;
    }
    return args[1].list[@intCast(args[0].integer)];
}

pub fn arenaCapacity(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{});

    return Value{ .integer = @intCast(env.arena.queryCapacity()) };
}

pub fn first(env: *Environment, args: []const Value) !Value {
    _ = env;
    try checkArgs(args, &.{ .list });

    return args[0].list[0];
}

pub fn rest(env: *Environment, args: []const Value) !Value {
    _ = env;
    try checkArgs(args, &.{ .list });

    if (args[0].list.len == 0) {
        return Value{ .list = &.{} };
    }
    return Value{ .list = args[0].list[1..] };
}

pub fn apply(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{ null, .list });
    if (!args[0].functionIsh()) {
        return error.ArgType;
    }

    var expr = ValueList{};
    try expr.append(env.allocator(), args[0]);
    for (args[1].list) |item| {
        try expr.append(env.allocator(), item);
    }
    return try eval(env, Value{ .list = try expr.toOwnedSlice(env.allocator()) });
}

pub fn times(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{ .integer, null });
    if (!args[1].functionIsh()) {
        return error.ArgType;
    }

    for (0..@intCast(args[0].integer)) |idx| {
        const expr = [_]Value{ args[1], Value{ .integer = @intCast(idx) } };
        _ = try eval(env, Value{ .list = &expr });
    }
    return Value.nil;
}

pub fn length(env: *Environment, args: []const Value) !Value {
    _ = env;
    try checkArgs(args, &.{ .list });

    return Value{ .integer = @intCast(args[0].list.len) };
}

pub fn append(env: *Environment, args: []const Value) !Value {
    try checkArgsVar(args, &.{ .list }, 2);

    var new_list = try ValueList.initCapacity(env.allocator(), args[0].list.len + args[1..].len);
    new_list.appendSliceAssumeCapacity(args[0].list);
    new_list.appendSliceAssumeCapacity(args[1..]);
    return Value{ .list = try new_list.toOwnedSlice(env.allocator()) };
}

pub fn memUsage(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{});

    return Value{ .integer = @intCast(env.counting.count) };
}

pub fn loadFile(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{ .string });

    const allocator = env.arena.child_allocator;
    const file_contents = try fs.cwd().readFileAlloc(allocator, args[0].string, 12 * 1024 * 1024);
    defer allocator.free(file_contents);
    return try env.load(file_contents);
}

pub fn loadString(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{ .string });

    return try env.load(args[0].string);
}


pub fn logAllocs(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{ null });

    if (args[0] == .nil) {
        env.counting.log = false;
        return nil;
    }
    env.counting.log = true;
    return t;
}

pub fn write(env: *Environment, args: []const Value) !Value {
    _ = env;
    try checkArgs(args, &.{ .string, .string });

    try fs.cwd().writeFile(args[0].string, args[1].string);
    return t;
}

pub fn read(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{ .string });

    const contents = try fs.cwd().readFileAlloc(env.allocator(), args[0].string, 12 * 1024 * 1024);
    return Value{ .string = contents };
}

pub fn join(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{ .string, .list });
    try checkArgsType(args[1].list, .string);

    const strings = try env.arena.child_allocator.alloc([]const u8, args[1].list.len);
    defer env.arena.child_allocator.free(strings);

    for (args[1].list, 0..) |val, idx| {
        strings[idx] = val.string;
    }

    return Value{ .string = try mem.join(env.allocator(), args[0].string, strings) };
}

pub fn cwd(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{});

    const path = try std.process.getCwdAlloc(env.allocator());
    return Value{ .string = path };
}

pub fn last(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{ .list });
    _ = env;
    return args[0].list[args[0].list.len-1];
}

pub fn chars(env: *Environment, args: []const Value) !Value {
    try checkArgs(args, &.{ .string });

    var char = try ValueList.initCapacity(env.allocator(), args[0].string.len);
    for (0..args[0].string.len) |idx| {
        const slice = args[0].string[idx..idx+1];
        char.appendAssumeCapacity(Value{ .string = slice });
    }
    return Value{ .list = try char.toOwnedSlice(env.allocator()) };
}

/// Same as checkArgs, except it allows more arguments than there are
/// in `types`, and doesn't check them.
/// Checks that there are at least `min_args` arguments.
pub fn checkArgsVar(args: []const Value, types: []const ?ArgType, min_args: usize) !void {
    if (args.len < min_args) {
        return error.NumArgs;
    }
    try checkArgs(args[0..types.len], types);
}

/// Check that all args are one type.
pub fn checkArgsType(args: []const Value, arg_type: ArgType) !void {
    for (args) |arg| {
        if (arg != arg_type) {
            return error.ArgType;
        }
    }
}

/// Check the number and type of arguments.
/// args is the arguments argument passed to the calling function
/// types if a list of desired types.
///
/// For example `try checkArgs(args, &.{ .string });`
/// means we would like to check if the function was called with a
/// single string argument
/// The types are optional, meaning if you don't care about the type
/// of one of the arguments, pass `null` in that position.
pub fn checkArgs(args: []const Value, types: []const ?ArgType) !void {
    if (args.len != types.len) {
        return error.NumArgs;
    }
    for (args, types) |arg, typ| {
        if (typ == null) {
            continue;
        }
        if (arg != typ.?) {
            return error.ArgType;
        }
    }
}

pub const ArgType = @typeInfo(Value).Union.tag_type.?;
