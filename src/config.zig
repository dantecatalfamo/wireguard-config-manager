const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;

const Interface = @import("interface.zig").Interface;
const keypair = @import("keypair.zig");
const cmds = @import("config_commands.zig");

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
        try env.addFunc("def", cmds.def, .normal);
        try env.addFunc("interface", cmds.interface, .normal);
        try env.addFunc("+", cmds.plus, .normal);
        try env.addFunc("-", cmds.minus, .normal);
        try env.addFunc("*", cmds.times, .normal);
        try env.addFunc("/", cmds.divide, .normal);
        try env.addFunc("^", cmds.pow, .normal);
        try env.addFunc("<<", cmds.shl, .normal);
        try env.addFunc(">>", cmds.shr, .normal);
        try env.addFunc("inc", cmds.inc, .normal);
        try env.addFunc("dec", cmds.dec, .normal);
        try env.addFunc("concat", cmds.concat, .normal);
        try env.addFunc("=", cmds.eq, .normal);
        try env.addFunc("list", cmds.list, .normal);
        try env.addFunc("eval", cmds.eval_fn, .normal);
        try env.addFunc("println", cmds.println, .normal);
        try env.addFunc("openbsd", cmds.openbsd, .normal);
        try env.addFunc("conf", cmds.conf, .normal);
        try env.addFunc("gen-privkey", cmds.genPrivkey, .normal);
        try env.addFunc("add-peer", cmds.addPeer, .normal);
        try env.addFunc("trace", cmds.trace, .normal);

        try env.addFunc("if", cmds.if_fn, .special);
        try env.addFunc("quote", cmds.quote, .special);
        try env.addFunc("progn", cmds.progn, .special);
        try env.addFunc("lambda", cmds.lambda, .special);

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

pub const Value = union (enum) {
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

pub const Lambda = struct {
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
