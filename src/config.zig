const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;

const Interface = @import("interface.zig").Interface;

const Environment = struct {
    arena: std.heap.ArenaAllocator,
    bindings: Bindings,

    pub fn deinit(self: *Environment) void {
        self.bindings.deinit();
        self.arena.deinit();
        self.arena.child_allocator.destroy(self);
    }

    pub fn allocator(self: *Environment) mem.Allocator {
        return self.arena.allocator();
    }
};

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
    nil,

    pub fn toString(self: Value, writer: anytype) !void {
        switch (self) {
            .interface => |iface| try writer.print("#<Interface address=\"{s}\" prefix={d} privkey=\"{s}\">",
                                                  .{iface.address, iface.prefix, iface.keypair.privateBase64()}),
            .string => |str| try writer.print("\"{s}\"", .{str}),
            .integer => |int| try writer.print("{d}", .{int}),
            .identifier => |ident| try writer.print("'{s}", .{ident}),
            .function => |func| try writer.print("#<Function @{x}>", .{ @intFromPtr(func) }),
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
            .nil => try writer.print("nil", .{}),
        }
    }
};

pub fn defaultEnvironment(allocator: mem.Allocator) !*Environment {
    var env = try allocator.create(Environment);
    env.* = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .bindings = Bindings.init(allocator),
    };
    try env.bindings.put("def", Value{ .function = def });
    try env.bindings.put("interface", Value{ .function = interface });
    try env.bindings.put("+", Value{ .function = plus });
    try env.bindings.put("-", Value{ .function = minus });
    try env.bindings.put("*", Value{ .function = times });
    try env.bindings.put("/", Value{ .function = divide });
    try env.bindings.put("inc", Value{ .function = inc });
    try env.bindings.put("concat", Value{ .function = concat });
    try env.bindings.put("t", Value{ .identifier = "t"});
    try env.bindings.put("nil", Value.nil);
    try env.bindings.put("eq", Value{ .function = eq });
    try env.bindings.put("list", Value{ .function = list });

    return env;
}

const Function = *const fn (environment: *Environment, args: []const Value) anyerror!Value;

pub fn eval(env: *Environment, iter: *TokenIter) !Value {
    const token = try iter.next() orelse return Value.nil;

    switch (token) {
        .quote => {
            const next = try iter.next() orelse return error.EndOfStream;
            if (next != .value) {
                return error.QuotedListNotSupported;
            }
            if (next.value != .identifier) {
                return error.InvalidQuotedItem;
            }
            return next.value;
        },
        .list_begin => {
            const func = blk: {
                const tok = try iter.next() orelse return error.EndOfStream;
                if (tok == .list_end) {
                    return Value.nil;
                } else if (tok == .list_begin) {
                    return error.UnexpectedList;
                }
                break :blk tok.value;
            };
            if (func != .identifier) {
                return error.NotAnIdentifier;
            }
            const func_impl = blk: {
                const env_val = env.bindings.get(func.identifier) orelse return error.NoBinding;
                if (env_val != .function) {
                    return error.NotAFunction;
                }
                break :blk env_val.function;
            };
            var func_args = std.ArrayList(Value).init(env.allocator());

            while (true) {
                const peeked = try iter.peek() orelse return error.EndOfStream;
                if (peeked == .list_end) {
                    _ = try iter.next();
                    break;
                }
                try func_args.append(try eval(env, iter));
            }
            return try func_impl(env, try func_args.toOwnedSlice());
        },
        .value => |val| {
            if (val == .identifier) {
                return env.bindings.get(val.identifier) orelse return error.NoBinding;
            }
            return val;
        },
        .list_end => return error.UnexpectedListEnd,
    }
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

    try env.bindings.put(args[0].identifier, args[1]);

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
    var acc: i64 = 0;
    for (args) |arg| {
        if (arg != .integer) {
            return error.ArgType;
        }
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

fn inc(env: *Environment, args: []const Value) !Value {
    if (args.len != 1) {
        return error.NumArgs;
    }
    if (args[0] != .identifier) {
        return error.ArgType;
    }
    var stored = env.bindings.get(args[0].identifier) orelse return error.NoBindings;
    if (stored != .integer) {
        return error.ArgType;
    }
    var new_val = Value{ .integer = stored.integer + 1 };
    try env.bindings.put(args[0].identifier, new_val);
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

pub fn eqInternal(lhs: Value, rhs: Value) bool {
    if (!mem.eql(u8, @tagName(lhs), @tagName(rhs))) {
        return false;
    }
    switch(lhs) {
        .nil => return true,
        .integer => return lhs.integer == rhs.integer,
        .function => return lhs.function == rhs.function,
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
    }
}

pub const t = Value{ .identifier = "t" };
pub const nil = Value.nil;

fn list(env: *Environment, args: []const Value) !Value {
    _ = env;
    return Value{ .list = args };
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
