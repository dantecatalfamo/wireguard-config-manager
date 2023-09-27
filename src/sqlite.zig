const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub fn open(path: []const u8) !DB {
    return DB{
        .ptr = try open_internal(path),
    };
}

pub const DB = struct {
    ptr: *c.sqlite3,

    pub fn prepare(self: DB, query: []const u8, query_tail: ?*[]const u8) !Stmt {
        var qt: []const u8 = undefined;
        const stmt = try prepare_internal(self.ptr, query, &qt);
        if (query_tail) |_| {
            query_tail.?.* = qt;
        } else if (!query_empty(qt)) {
            return error.CompoundQuery;
        }
        return Stmt{
            .ptr = stmt,
        };
    }

    pub fn prepare_bind(self: DB, query: []const u8, values: anytype) !Stmt {
        var query_tail = query;
        const stmt = try self.prepare(query, &query_tail);
        if (!query_empty(query_tail)) {
            return error.CompoundQuery;
        }
        try stmt.bind(values);
        return stmt;
    }

    pub fn exec_multiple(self: DB, query: []const u8) !void {
        var query_in = query;
        var query_tail = query;
        while (!query_empty(query_tail)) {
            const stmt = try self.prepare(query_in, &query_tail);
            query_in = query_tail;
            while (try stmt.step()) {}
            try stmt.finalize();
        }
    }

    pub fn exec(self: DB, query: []const u8, values: anytype) !void {
        const stmt = try self.prepare_bind(query, values);
        while (try stmt.step()) {}
        try stmt.finalize();
    }

    pub fn exec_returning_int(self: DB, query: []const u8, values: anytype) !u64 {
        var stmt = try self.prepare_bind(query, values);
        _ = try stmt.step();
        const id: u64 = @intCast(stmt.int(0));
        try stmt.finalize();
        return id;
    }

    fn query_empty(query: []const u8) bool {
        for (query) |char| {
            if (!std.ascii.isWhitespace(char)) {
                return false;
            }
        }
        return true;
    }


    pub fn close(self: DB) !void {
        return close_internal(self.ptr);
    }
};

pub const Stmt = struct {
    ptr: *c.sqlite3_stmt,

    pub fn bind(self: Stmt, values: anytype) !void {
        try bind_internal(self.ptr, values);
    }

    pub fn step(self: Stmt) !bool {
        return step_internal(self.ptr);
    }

    pub fn text(self: Stmt, column: u32) ?[]const u8 {
        const val = c.sqlite3_column_text(self.ptr, @intCast(column));
        if (val == null) {
            return null;
        }
        return std.mem.span(val);
    }

    pub fn int(self: Stmt, column: u32) i64 {
        return @intCast(c.sqlite3_column_int64(self.ptr, @intCast(column)));
    }

    pub fn count(self: Stmt) u32 {
        return @intCast(c.sqlite3_column_count(self.ptr));
    }

    pub fn reset(self: Stmt) !void {
        try reset_internal(self.ptr);
    }

    pub fn finalize(self: Stmt) !void {
        try finalize_internal(self.ptr);
    }
};

pub fn open_internal(path: []const u8) !*c.sqlite3 {
    var db: ?*c.sqlite3 = null;
    const ret = c.sqlite3_open_v2(path.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null);
    if (ret != c.SQLITE_OK) {
        std.debug.print("{s}\n", .{ c.sqlite3_errmsg(db) });
        return error.OpenDB;
    }
    return db.?;
}

pub fn prepare_internal(db: *c.sqlite3, query: []const u8, query_tail: *[]const u8) !*c.sqlite3_stmt {
    var tail_ptr: [*c]u8 = undefined;
    var stmt: ?*c.sqlite3_stmt = null;
    const ret = c.sqlite3_prepare_v2(db, query.ptr, @intCast(query.len), &stmt, &tail_ptr);
    if (tail_ptr != null) {
        const remaining_bytes: usize = @intFromPtr(tail_ptr) - @intFromPtr(query.ptr);
        query_tail.* = query[remaining_bytes..];
    }
    if (ret != c.SQLITE_OK) {
        std.debug.print("{s}: \"{s}\"\n", .{ c.sqlite3_errstr(ret), query });
        return error.Prepare;
    }
    return stmt.?;
}

pub fn bind_internal(stmt: *c.sqlite3_stmt, values: anytype) !void {
    inline for (std.meta.fields(@TypeOf(values)), 0..) |field, idx| {
        const value = @field(values, field.name);
        const index = idx + 1;
        const ret = switch (@typeInfo(@TypeOf(value))) {
            .Int, .ComptimeInt => blk: {
                break :blk c.sqlite3_bind_int64(stmt, index, @intCast(value));
            },
            .Array => |arr| blk: {
                if (arr.child != u8) {
                    @compileError("Unsupported array type " ++ @tagName(arr.child));
                }
                break :blk c.sqlite3_bind_text(stmt, index, value.ptr, value.len, c.SQLITE_TRANSIENT);
            },
            .Pointer => |ptr| blk: {
                switch (ptr.size) {
                    .One => {
                        if (@typeInfo(ptr.child) != .Array) {
                            @compileError("Unsupported single pointer child " ++ @tagName(@typeInfo(ptr.child)));
                        }
                        if (@typeInfo(ptr.child).Array.child != u8) {
                            @compileError("Unsupported array pointer child " ++ @tagName(@typeInfo(ptr.child).Array.child));
                        }
                        break :blk c.sqlite3_bind_text(stmt, index, value, value.len, c.SQLITE_TRANSIENT);
                    },
                    .Slice => {
                        if (ptr.child != u8) {
                            @compileError("Unsupported pointer type " ++ @tagName(ptr.size) ++ " " ++ @tagName(@typeInfo(ptr.child)));
                        }
                        break :blk c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), c.SQLITE_TRANSIENT);
                    },
                    else => { @compileError("Unsupported pointer size " ++ @tagName(ptr.size)); },
                }
            },
            else => |ty| {
                @compileError("Unsupported type " ++ @tagName(ty));
            },
        };
        if (ret != c.SQLITE_OK) {
            std.debug.print("{s}\n", .{ c.sqlite3_errstr(ret) });
            return error.Bind;
        }
    }
}

pub fn step_internal(stmt: *c.sqlite3_stmt) !bool {
    switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => return true,
        c.SQLITE_DONE => return false,
        c.SQLITE_CONSTRAINT => return error.ConstraintFailed,
        else => |i| {
            std.debug.print("{d}: {s}\n", .{ i, c.sqlite3_errstr(i) });
            return error.Step;
        }
    }
}

pub fn reset_internal(stmt: *c.sqlite3_stmt) !void {
    switch (c.sqlite3_reset(stmt)) {
        c.SQLITE_OK => {},
        else => |i| {
            std.debug.print("{s}\n", .{ c.sqlite3_errstr(i) });
            return error.Reset;
        }
    }
}

pub fn finalize_internal(stmt: *c.sqlite3_stmt) !void {
    switch (c.sqlite3_finalize(stmt)) {
        c.SQLITE_OK => {},
        else => |i| {
            std.debug.print("{s}\n", .{ c.sqlite3_errstr(i) });
            return error.Finalize;
        }
    }
}

pub fn close_internal(db: *c.sqlite3) !void {
    switch (c.sqlite3_close_v2(db)) {
        c.SQLITE_OK => {},
        else => |i| {
            std.debug.print("{s}\n", .{ c.sqlite3_errstr(i) });
            return error.Close;
        }
    }
}
