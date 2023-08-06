const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;

const Interface = @import("interface.zig").Interface;
const keypair = @import("keypair.zig");

pub const Environment = struct {
    arena: std.heap.ArenaAllocator,
    bindings: BindingList,
    trace: bool = false,
    trace_depth: u32 = 0,

    pub fn init(inner_allocator: mem.Allocator) !*Environment {
        var env = try inner_allocator.create(Environment);
        env.* = .{
            .arena = std.heap.ArenaAllocator.init(inner_allocator),
            .bindings = BindingList.init(inner_allocator),
        };
        try env.pushBindings();
        try env.addFunc("def", def, .normal);
        try env.addFunc("interface", interface, .normal);
        try env.addFunc("+", plus, .normal);
        try env.addFunc("-", minus, .normal);
        try env.addFunc("*", times, .normal);
        try env.addFunc("/", divide, .normal);
        try env.addFunc("^", pow, .normal);
        try env.addFunc("<<", shl, .normal);
        try env.addFunc(">>", shr, .normal);
        try env.addFunc("inc", inc, .normal);
        try env.addFunc("dec", dec, .normal);
        try env.addFunc("concat", concat, .normal);
        try env.addFunc("=", eq, .normal);
        try env.addFunc("list", list, .normal);
        try env.addFunc("eval", eval_fn, .normal);
        try env.addFunc("println", println, .normal);
        try env.addFunc("openbsd", openbsd, .normal);
        try env.addFunc("conf", conf, .normal);
        try env.addFunc("gen-privkey", genPrivkey, .normal);
        try env.addFunc("add-peer", addPeer, .normal);
        try env.addFunc("trace", trace, .normal);

        try env.addFunc("if", if_fn, .special);
        try env.addFunc("quote", quote, .special);
        try env.addFunc("progn", progn, .special);
        try env.addFunc("lambda", lambda, .special);

        try env.put("t", Value{ .identifier = "t"});
        try env.put("nil", Value.nil);

        return env;
    }

    pub fn addFunc(self: *Environment, name: []const u8, function: *const fn (environment: *Environment, args: []const Value) anyerror!Value, func_type: FunctionType) !void {
        try self.put(name, Value{ .function = .{ .impl = function, .special = func_type == .special }});
    }

    pub const FunctionType = enum {
        normal,
        special,
    };

    pub fn load(self: *Environment, input: []const u8) !Value {
        var iter = tokenIter(self.allocator(), input);
        var last_eval: ?Value = null;
        while (try iter.peek() != null) {
            var parsed = try parser(self, &iter);
            last_eval = try eval(self, parsed);
        }
        return if (last_eval != null) last_eval.? else Value.nil;
    }


    pub fn get(self: *Environment, key: []const u8) ?Value {
        var n = self.bindings.items.len;
        while (n > 0) : (n -= 1) {
            return self.bindings.items[n-1].get(key) orelse continue;
        }
        return null;
    }

    pub fn put(self: *Environment, key: []const u8, value: Value) !void {
        try self.bindings.items[self.bindings.items.len-1].put(key, value);
    }

    pub fn deinit(self: *Environment) void {
        self.bindings.deinit();
        self.arena.deinit();
        self.arena.child_allocator.destroy(self);
    }

    pub fn allocator(self: *Environment) mem.Allocator {
        return self.arena.allocator();
    }

    pub fn pushBindings(self: *Environment) !void {
        try self.bindings.append(Bindings.init(self.allocator()));
    }

    pub fn popBindings(self: *Environment) void {
        _ = self.bindings.pop();
    }
};

const BindingList = std.ArrayList(Bindings);
const Bindings = std.StringHashMap(Value);
const ValueList = std.ArrayList(Value);

const Value = union (enum) {
    interface: *Interface,
    string: []const u8,
    integer: i64,
    identifier: []const u8,
    function: Function,
    symbol: []const u8,
    list: []const Value,
    lambda: Lambda,
    nil,

    pub fn toString(self: Value, writer: anytype) !void {
        switch (self) {
            .interface => |iface| try writer.print("#<Interface address=\"{s}\" prefix={d} privkey=\"{s}\">",
                                                  .{iface.address, iface.prefix, iface.keypair.privateBase64()}),
            .string => |str| try writer.print("\"{s}\"", .{str}),
            .integer => |int| try writer.print("{d}", .{int}),
            .identifier => |ident| try writer.print("{s}", .{ident}),
            .function => |func| try writer.print("#<Function @{x}>", .{ @intFromPtr(func.impl) }),
            .symbol => |sym| try writer.print(":{s}", .{sym}),
            .list => |lst| {
                try writer.print("(", .{});
                for (lst, 0..) |item, idx| {
                    try item.toString(writer);
                    if (idx != lst.len-1) {
                        try writer.print(" ", .{});
                    }
                }
                try writer.print(")", .{});
            },
            .lambda => |lmb| {
                try writer.print("(lambda ", .{});
                try (Value{ .list = lmb.args }).toString(writer);
                try writer.print(" ", .{});
                for (lmb.body, 0..) |item, idx| {
                    try item.toString(writer);
                    if (idx != lmb.body.len-1) {
                        try writer.print(" ", .{});
                    }
                }
                try writer.print(")", .{});
            },
            .nil => try writer.print("nil", .{}),
        }
    }
};

const Lambda = struct {
    args: []const Value,
    body: []const Value,
};

const Function = struct {
    impl: *const fn (environment: *Environment, args: []const Value) anyerror!Value,
    special: bool = false,
};

pub fn eval(env: *Environment, value: Value) !Value {
    switch (value) {
        .identifier => |ident| return {
            return env.get(ident) orelse return error.NoBinding;
        },
        .lambda => return value,
        .list => |lst| {
            if (lst.len == 0) return error.MissingFunction;
            const func_ident = try eval(env, lst[0]);
            if (env.trace) {
                std.debug.print("Trace ", .{});
                for (env.trace_depth) |_| {
                    std.debug.print("  ", .{});
                }
                std.debug.print("\x1b[1;32m->\x1b[0m ", .{});
                env.trace_depth += 1;
                try lst[0].toString(std.io.getStdErr().writer());
                std.debug.print(": ", .{});
                for (lst[1..], 0..) |arg, idx| {
                    try arg.toString(std.io.getStdErr().writer());
                    if (idx != lst.len-1) {
                        std.debug.print(" ", .{});
                    }
                }
                std.debug.print("\n", .{});
            }
            if (func_ident == .lambda) {
                const lmb = func_ident.lambda;
                if (lst[1..].len != lmb.args.len) {
                    return error.NumArgs;
                }

                var lmb_args_values = ValueList.init(env.allocator());
                for (lst[1..]) |arg| {
                    try lmb_args_values.append(try eval(env, arg));
                }
                try env.pushBindings();
                defer env.popBindings();

                for (lmb.args, lmb_args_values.items) |arg_ident, arg_val| {
                    try env.put(arg_ident.identifier, arg_val);
                }
                for (lmb.body, 0..) |item, idx| {
                    const ret = try eval(env, item);
                    if (lmb.body.len-1 == idx) {
                        if (env.trace) {
                            env.trace_depth -= 1;
                            std.debug.print("Trace ", .{});
                            for (env.trace_depth) |_| {
                                std.debug.print("  ", .{});
                            }
                            std.debug.print("\x1b[1;31m<-\x1b[0m ", .{});
                            try lst[0].toString(std.io.getStdErr().writer());
                            std.debug.print(": ", .{});
                            try ret.toString(std.io.getStdErr().writer());
                            std.debug.print("\n", .{});
                        }
                        return ret;
                    }
                }
            }
            const func = blk: {
                const val = func_ident;
                if (val != .function) return error.NotAFunction;
                break :blk val.function;
            };
            const args = blk: {
                if (func.special) {
                    break :blk lst[1..];
                }
                var evaled = ValueList.init(env.allocator());
                for (lst[1..]) |item| {
                    try evaled.append(try eval(env, item));
                }
                break :blk try evaled.toOwnedSlice();
            };
            const ret = try func.impl(env, args);
            if (env.trace) {
                env.trace_depth -= 1;
                std.debug.print("Trace ", .{});
                for (env.trace_depth) |_| {
                    std.debug.print("  ", .{});
                }
                std.debug.print("\x1b[1;31m<-\x1b[0m ", .{});
                try lst[0].toString(std.io.getStdErr().writer());
                std.debug.print(": ", .{});
                try ret.toString(std.io.getStdErr().writer());
                std.debug.print("\n", .{});
            }
            return ret;
        },
        else => return value,
    }
}

pub fn parser(env: *Environment, iter: *TokenIter) !Value {
    while (try iter.next()) |token| {
        switch (token) {
            .list_begin => {
                var lst = ValueList.init(env.allocator());
                errdefer lst.deinit();
                while (try iter.peek()) |peeked| {
                    switch (peeked) {
                        .list_begin, .value, .quote => try lst.append(try parser(env, iter)),
                        .list_end => {
                            _ = try iter.next();
                            return Value{ .list = try lst.toOwnedSlice() };
                        },
                    }
                }
                return error.MissingListEnd;
            },
            .list_end => return error.UnectedListEnd,
            .value => return token.value,
            .quote => {
                var lst = ValueList.init(env.allocator());
                try lst.append(Value{ .identifier = "quote" });
                try lst.append(try parser(env, iter));
                return Value{ .list = try lst.toOwnedSlice() };
            },
        }
    }
    return Value.nil;
}

test "parser" {
    const test_str = "(a (g) (b (\"hello\" 1 2 3 :e q)) g 'quoted '(quoted list))";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var env = Environment.init(arena.allocator);
    var iter = tokenIter(arena.allocator(), test_str);
    const value = try parser(env, &iter);
    try value.toString(std.io.getStdOut().writer());
}

pub fn tokenIter(allocator: mem.Allocator, input: []const u8) TokenIter {
    return .{
        .allocator = allocator,
        .input = input,
        .index = 0,
    };
}

pub const TokenIter = struct {
    allocator: mem.Allocator,
    input: []const u8,
    index: usize,

    pub fn next(self: *TokenIter) !?Token {
        while (self.index < self.input.len and std.ascii.isWhitespace(self.input[self.index])) : (self.index += 1) {}

        if (self.index == self.input.len) {
            return null;
        }

        const char = self.input[self.index];
        if (char == '\'') {
            self.index += 1;
            return Token.quote;
        }
        if (char == '(') {
            self.index += 1;
            return Token.list_begin;
        }
        if (char == ')') {
            self.index += 1;
            return Token.list_end;
        }
        if (std.ascii.isDigit(char)) {
            var end = self.index;
            while (end < self.input.len and std.ascii.isDigit(self.input[end])) : (end += 1) {}
            const int = try std.fmt.parseInt(i64, self.input[self.index..end], 10);
            self.index += end-self.index;
            return Token{
                .value = Value{
                    .integer = int,
                }
            };
        }
        if (char == '"') {
            if (mem.indexOfPos(u8, self.input, self.index+1, "\"")) |end| {
                const val = Value{
                    .string = try self.allocator.dupe(u8, self.input[self.index+1..end]),
                };
                self.index += end - self.index+1;
                return Token{ .value = val };
            }
            return error.UnclosedQuote;
        }
        if (char == ':') {
            var end = self.index;
            if (self.index + 1 >= self.input.len)
                return error.NoSymbol;

            end += 1;
            while (end < self.input.len and std.ascii.isAlphabetic(self.input[end]) or end == '-') : (end += 1) {}
            var symbol = try self.allocator.dupe(u8, self.input[self.index+1..end]);
            self.index += end - self.index;
            return Token{
                .value = Value { .symbol = symbol },
            };
        }
        if (std.ascii.isPrint(char)) {
            var end = self.index;
            while (end < self.input.len and std.ascii.isPrint(self.input[end]) and !std.ascii.isWhitespace(self.input[end]) and self.input[end] != ')') : (end += 1) {}
            const ident = try self.allocator.dupe(u8, self.input[self.index..end]);
            self.index += end - self.index;
            return Token{
                .value = Value{ .identifier = ident }
            };
        }
        return error.InvalidInput;
    }

    pub fn peek(self: *TokenIter) !?Token {
        const begin_index = self.index;
        const token = try self.next();
        self.index = begin_index;
        return token;
    }
};

pub const Token = union (enum) {
    list_begin,
    list_end,
    quote,
    value: Value,
};

fn def(env: *Environment, args: []const Value) !Value {
    if (args.len != 2)
        return error.NumArgs;

    if (args[0] != .identifier)
        return error.ArgType;

    try env.put(args[0].identifier, args[1]);

    return args[1];
}

fn plus(env: *Environment, args: []const Value) !Value {
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

fn minus(env: *Environment, args: []const Value) !Value {
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

fn times(env: *Environment, args: []const Value) !Value {
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

fn divide(env: *Environment, args: []const Value) !Value {
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

fn pow(env: *Environment, args: []const Value) !Value {
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

fn shl(env: *Environment, args: []const Value) !Value {
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

fn shr(env: *Environment, args: []const Value) !Value {
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



fn inc(env: *Environment, args: []const Value) !Value {
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

fn dec(env: *Environment, args: []const Value) !Value {
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

fn concat(env: *Environment, args: []const Value) !Value {
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

fn eq(env: *Environment, args: []const Value) !Value {
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

fn progn(env: *Environment, args: []const Value) !Value {
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

fn list(env: *Environment, args: []const Value) !Value {
    _ = env;
    return Value{ .list = args };
}

fn quote(env: *Environment, args: []const Value) !Value {
    _ = env;
    if (args.len != 1) {
        return error.NumArgs;
    }
    return args[0];
}

fn eval_fn(env: *Environment, args: []const Value) !Value {
    if (args.len != 1) return error.NumArgs;
    return eval(env, args[0]);
}

fn lambda(env: *Environment, args: []const Value) !Value {
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

fn if_fn (env: *Environment, args: []const Value) !Value {
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

fn println(env: *Environment, args: []const Value) !Value {
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

fn interface(env: *Environment, args: []const Value) !Value {
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

fn openbsd(env: *Environment, args: []const Value) !Value {
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

fn conf(env: *Environment, args: []const Value) !Value {
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

fn genPrivkey(env: *Environment, args: []const Value) !Value {
    if (args.len != 0) {
        return error.NumArgs;
    }
    const kp = try keypair.generateKeyPair();
    return Value{ .string = try env.allocator().dupe(u8, &kp.privateBase64()) };
}

fn addPeer(env: *Environment, args: []const Value) !Value {
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

fn trace(env: *Environment, args: []const Value) !Value {
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
