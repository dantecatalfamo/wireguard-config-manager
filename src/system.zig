const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const json = std.json;
const testing = std.testing;

const keypair = @import("keypair.zig");
const sqlite = @import("sqlite.zig");
const pragmas = @embedFile("sql/pragmas.sql");
const schema = @embedFile("sql/schema.sql");
const current_schema_version = 2;

pub const System = struct {
    db: sqlite.DB,
    allocator: mem.Allocator,

    pub fn init(path: [:0]const u8, allocator: mem.Allocator) !System {
        const db = try sqlite.open(path);
        try db.exec_multiple(pragmas);
        const system = System{
            .db = db,
            .allocator = allocator,
        };
        while (try system.migrate()) {}
        return system;
    }

    pub fn migrate(self: System) !bool {
        const schema_version = try self.getVersion();
        switch (schema_version) {
            0 => {
                self.db.exec_multiple(schema) catch |err| switch (err) {
                    // The first schema version didn't set the version
                    // number, so the tables will conflict.
                    // Set the correct schema version and begin
                    // migrating
                    error.Prepare => {
                        try self.setVersion(1);
                        return true;
                    },
                    else => return err,
                };
                try self.setVersion(current_schema_version);
            },
            1 => {
                const migration_2 = @embedFile("sql/migrations/02-remaining_config_fields.sql");
                try self.db.exec_multiple(migration_2);
                try self.setVersion(2);
            },
            current_schema_version => {
                return false;
            },
            current_schema_version+1...std.math.maxInt(u32) => {
                return error.SchemaTooNew;
            },
        }
        return true;
    }

    pub fn close(self: System) !void {
        try self.db.close();
    }

    pub fn getVersion(self: System) !u32 {
        return try self.db.getUserVersion();
    }

    pub fn setVersion(self: System, version: u32) !void {
        try self.db.setUserVersion(version);
    }

    pub fn addInterface(self: System, name: []const u8, address: []const u8, prefix: u6, privkey: ?[32]u8) !u64 {
        const query = "INSERT INTO interfaces (name, address, prefix, privkey) VALUES (?, ?, ?, ?) RETURNING id";
        // Make sure we can parse the IP
        _ = std.net.Address.parseIp(address, 0) catch {
            return error.InvalidIP;
        };
        const kp = if (privkey) |pk|
            try keypair.fromPrivateKey(pk)
        else
            try keypair.generateKeyPair();

        const pk = kp.privateBase64();

        return try self.db.exec_returning_int(query, .{ name, address, prefix, &pk });
    }

    pub fn removeInterface(self: System, interface_id: u64) !void {
        const query = "DELETE FROM interfaces WHERE id = ?";
        try self.db.exec(query, .{ interface_id });
    }

    pub fn interfaceIdFromName(self: System, name: []const u8) !u64 {
        const query = "SELECT id FROM interfaces WHERE name = ?";
        return try self.db.exec_returning_int(query, .{ name });
    }

    pub fn addRouter(self: System, router_id: u64, client_id: u64) !void {
        const query = "SELECT address, prefix FROM interfaces WHERE id = ?";
        const stmt = try self.db.prepare(query, null);

        try stmt.bind(.{ client_id });
        if (!try stmt.step())
            return error.NoRecord;
        const router_to_client = try self.addPeerEntry(router_id, client_id);
        _ = try self.addAllowedIPEntry(router_to_client, stmt.text(0).?, 32);
        try stmt.reset();

        try stmt.bind(.{ router_id });
        if (!try stmt.step())
            return error.NoRecord;
        const client_to_router = try self.addPeerEntry(client_id, router_id);
        _ = try self.addAllowedIPEntry(client_to_router, stmt.text(0).?, @intCast(stmt.uint(1)));
        try stmt.finalize();
    }

    pub fn addPeer(self: System, interface1_id: u64, interface2_id: u64) !void {
        const query = "SELECT address FROM interfaces WHERE id = ?";
        const peer1_id = try self.addPeerEntry(interface1_id, interface2_id);
        const interface1_address = try self.db.exec_returning_text(self.allocator, query, .{ interface1_id });
        defer self.allocator.free(interface1_address);
        const peer2_id = try self.addPeerEntry(interface2_id, interface1_id);
        const interface2_address = try self.db.exec_returning_text(self.allocator, query, .{ interface2_id });
        defer self.allocator.free(interface2_address);
        _ = try self.addAllowedIPEntry(peer1_id, interface2_address, 32);
        _ = try self.addAllowedIPEntry(peer2_id, interface1_address, 32);
    }

    pub fn unPeer(self: System, interface1_id: u64, interface2_id: u64) !void {
        const query = "DELETE FROM peers WHERE interface1 = ? AND interface2 = ?";
        try self.db.exec(query, .{ interface1_id, interface2_id });
        try self.db.exec(query, .{ interface2_id, interface1_id });
    }

    pub fn addPeerEntry(self: System, interface_id1: u64, interface_id2: u64) !u64 {
        const query = "INSERT INTO peers (interface1, interface2) VALUES (?, ?) RETURNING id";
        return try self.db.exec_returning_int(query, .{ interface_id1, interface_id2 });
    }

    pub fn addAllowedIP(self: System, interface1_id: u64, interface2_id: u64, address: []const u8, prefix: u6) !void {
        const peer_query = "SELECT id FROM peers WHERE interface1 = ? AND interface2 = ?";
        const allowed_ip_query = "INSERT INTO allowed_ips (peer, address, prefix) VALUES (?, ?, ?)";
        const peer_id = try self.db.exec_returning_int(peer_query, .{ interface1_id, interface2_id });
        try self.db.exec(allowed_ip_query, .{ peer_id, address, prefix });
    }

    pub fn addAllowedIPEntry(self: System, peer: u64, address: []const u8, prefix: u6) !u64 {
        const query = "INSERT INTO allowed_ips (peer, address, prefix) VALUES (?, ?, ?) RETURNING id";
        return try self.db.exec_returning_int(query, .{ peer, address, prefix });
    }

    pub fn removeAllowedIP(self: System, interface1_id: u64, interface2_id: u64, address: []const u8, prefix: u6) !void {
        const peer_query = "SELECT id FROM peers WHERE interface1 = ? AND interface2 = ?";
        const allowed_ip_query = "DELETE FROM allowed_ips WHERE peer = ? AND address = ? AND prefix = ?";
        const peer_id = try self.db.exec_returning_int(peer_query, .{ interface1_id, interface2_id });
        try self.db.exec(allowed_ip_query, .{ peer_id, address, prefix });
    }

    pub fn setPresharedKey(self: System, interface1_id: u64, interface2_id: u64, psk: ?[]const u8) !void {
        const query = "UPDATE peers SET psk = ? WHERE interface1 = ? AND interface2 = ?";
        if (psk) |k| {
            if (!try verifyPrivkey(k)) {
                return error.InvalidKey;
            }
            try self.db.exec(query, .{ k, interface1_id, interface2_id });
            try self.db.exec(query, .{ k, interface2_id, interface1_id });
        } else {
            try self.db.exec(query, .{ null, interface1_id, interface2_id });
            try self.db.exec(query, .{ null, interface2_id, interface1_id });
        }
    }

    pub fn setKeepAlive(self: System, interface1_id: u64, interface2_id: u64, keep_alive: u32) !void {
        const query = "UPDATE peers SET keep_alive = ? WHERE interface1 = ? AND interface2 = ?";
        if (keep_alive == 0) {
            try self.db.exec(query, .{ null, interface1_id, interface2_id });
            try self.db.exec(query, .{ null, interface2_id, interface1_id });
        } else {
            try self.db.exec(query, .{ keep_alive, interface1_id, interface2_id });
            try self.db.exec(query, .{ keep_alive, interface2_id, interface1_id });
        }
    }

    pub fn setField(self: System, interface_id: u64, field: Field, value: ?[]const u8) !void {
        switch (field) {
            .name => {
                if (value) |val| {
                    try self.db.exec("UPDATE interfaces SET name = ? WHERE id = ?", .{ val, interface_id });
                } else {
                    return error.ConstraintFailed;
                }
            },
            .comment => {
                if (value) |val| {
                    try self.db.exec("UPDATE interfaces SET comment = ? WHERE id = ?", .{ val, interface_id });
                } else {
                    try self.db.exec("UPDATE interfaces SET comment = ? WHERE id = ?", .{ null, interface_id });
                }
            },
            .privkey => {
                if (value) |val| {
                    if (!try verifyPrivkey(val))
                        return error.InvalidKey;
                    try self.db.exec("UPDATE interfaces SET privkey = ? WHERE id = ?", .{ val, interface_id });
                } else {
                    return error.ConstraintFailed;
                }
            },
            .hostname => {
                if (value) |val| {
                    try self.db.exec("UPDATE interfaces SET hostname = ? WHERE id = ?", .{ val, interface_id });
                } else {
                    try self.db.exec("UPDATE interfaces SET hostname = ? WHERE id = ?", .{ null, interface_id });
                }
            },
            .port => {
                if (value) |val| {
                    try self.db.exec("UPDATE interfaces SET port = ? WHERE id = ?", .{ try std.fmt.parseInt(u16, val, 10), interface_id });
                } else {
                    try self.db.exec("UPDATE interfaces SET port = ? WHERE id = ?", .{ null, interface_id });
                }
            },
            .address => {
                if (value) |val| {
                    const addr_pfx = try parseAddrPrefix(val);
                    try self.db.exec("BEGIN TRANSACTION", .{});
                    try self.db.exec(
                        "UPDATE allowed_ips SET address = ? WHERE address = (SELECT address FROM interfaces WHERE id = ?)",
                        .{ addr_pfx.address, interface_id }
                    );
                    try self.db.exec("UPDATE interfaces SET address = ?, prefix = ? WHERE id = ?", .{ addr_pfx.address, addr_pfx.prefix, interface_id });
                    try self.db.exec("COMMIT TRANSACTION", .{});
                } else {
                    return error.ConstraintFailed;
                }
            },
            .dns => {
                if (value) |val| {
                    try self.db.exec("UPDATE interfaces SET dns = ? WHERE id = ?", .{ val, interface_id });
                } else {
                    try self.db.exec("UPDATE interfaces SET dns = ? WHERE id = ?", .{ null, interface_id });
                }

            },
            .table => {
                if (value) |val| {
                    if (mem.eql(u8, val, "off") or mem.eql(u8, val, "auto")) {
                        try self.db.exec("UPDATE interfaces SET routing_table = ? WHERE id = ?", .{ val, interface_id });
                    } else {
                        const num = try std.fmt.parseInt(u32, val, 10);
                        try self.db.exec("UPDATE interfaces SET routing_table = ? WHERE id = ?", .{ num, interface_id });
                    }
                } else {
                    try self.db.exec("UPDATE interfaces SET routing_table = ? WHERE id = ?", .{ null, interface_id });
                }
            },
            .mtu => {
                if (value) |val| {
                    try self.db.exec("UPDATE interfaces SET mtu = ? WHERE id = ?", .{ try std.fmt.parseInt(u32, val, 10), interface_id });
                } else {
                    try self.db.exec("UPDATE interfaces SET mtu = ? WHERE id = ?", .{ null, interface_id });
                }
            },
            .pre_up => {
                if (value) |val| {
                    try self.db.exec("UPDATE interfaces SET pre_up = ? WHERE id = ?", .{ val, interface_id });
                } else {
                    try self.db.exec("UPDATE interfaces SET pre_up = ? WHERE id = ?", .{ null, interface_id });
                }
            },
            .post_up => {
                if (value) |val| {
                    try self.db.exec("UPDATE interfaces SET post_up = ? WHERE id = ?", .{ val, interface_id });
                } else {
                    try self.db.exec("UPDATE interfaces SET post_up = ? WHERE id = ?", .{ null, interface_id });
                }
            },
            .pre_down => {
                if (value) |val| {
                    try self.db.exec("UPDATE interfaces SET pre_down = ? WHERE id = ?", .{ val, interface_id });
                } else {
                    try self.db.exec("UPDATE interfaces SET pre_down = ? WHERE id = ?", .{ null, interface_id });
                }
            },
            .post_down => {
                if (value) |val| {
                    try self.db.exec("UPDATE interfaces SET post_down = ? WHERE id = ?", .{ val, interface_id });
                } else {
                    try self.db.exec("UPDATE interfaces SET post_down = ? WHERE id = ?", .{ null, interface_id });
                }
            },
        }
    }

    pub const Field = enum {
        name,
        comment,
        privkey,
        hostname,
        port,
        address,
        dns,
        table,
        mtu,
        pre_up,
        post_up,
        pre_down,
        post_down,
    };

    pub fn listInterfaces(system: System, output_type: OutputType, writer: anytype) !void {
        const query = "SELECT i.name, i.address, i.prefix, i.privkey, count(p.id), i.comment FROM interfaces i LEFT JOIN peers p ON i.id = p.interface1 GROUP BY i.id ORDER BY aton(i.address)";
        const stmt = try system.db.prepare_bind(query, .{});
        switch (output_type) {
            .table => {
                try writer.print("         Name          |       Address      |                  Public Key                  | Peers | Comment \n", .{});
                try writer.print("-----------------------+--------------------+----------------------------------------------+-------+---------\n", .{});
            },
            .json => {
                try writer.print("[", .{});
            }
        }
        var first = true;
        while (try stmt.step()) {
            switch (output_type) {
                .table => {
                    try writer.print(
                        "{?s: <22} | {?s: <15}/{d: <2} | {s} | {d: <5} | {s}\n", .{
                            stmt.text(0),
                            stmt.text(1),
                            stmt.uint(2),
                            try keypair.base64PrivateToPublic(stmt.text(3) orelse ""),
                            stmt.uint(4),
                            stmt.text(5) orelse "",        });
                },
                .json => {
                    if (first) {
                        first = false;
                    } else {
                        try writer.print(",\n", .{});
                    }
                    const obj = .{
                        .name = stmt.text(0),
                        .address = stmt.text(1),
                        .prefix = stmt.uint(2),
                        .pubkey = try keypair.base64PrivateToPublic(stmt.text(3) orelse ""),
                        .peers = stmt.uint(4),
                        .comment = stmt.text(5) orelse "",
                    };
                    try std.json.stringify(obj, .{}, writer);
                }
            }
        }
        if (output_type == .json) {
            try writer.print("]\n", .{});
        }
    }

    pub fn listNames(self: System, writer: anytype) !void {
        const query = "SELECT name FROM interfaces ORDER BY name";
        const stmt = try self.db.prepare(query, null);
        while (try stmt.step()) {
            try writer.print("{s}\n", .{ stmt.text(0) orelse "" });
        }
    }

    pub fn listInterface(system: System, interface_id: u64, output_type: OutputType, writer: anytype) !void {
        const details_query = "SELECT id, name, comment, privkey, hostname, address, prefix, port, dns, routing_table, mtu, pre_up, post_up, pre_down, post_down FROM interfaces WHERE id = ?";
        const peers_query = "SELECT i.id, i.name, p.psk, p.id, p.keep_alive FROM peers AS p JOIN interfaces AS i ON p.interface2 = i.id WHERE p.interface1 = ? ORDER BY aton(i.address)";
        const allowed_ips_query = "SELECT address, prefix FROM allowed_ips WHERE peer = ? ORDER BY aton(address)";
        const details_stmt = try system.db.prepare_bind(details_query, .{ interface_id });
        const peers_stmt = try system.db.prepare_bind(peers_query, .{ interface_id });
        const allowed_ips_stmt = try system.db.prepare(allowed_ips_query, null);

        if (!try details_stmt.step()) {
            return;
        }

        const name = details_stmt.text(1);
        const comment = details_stmt.text(2);
        const privkey = details_stmt.text(3);
        const pubkey = if (privkey) |priv|
            &(try keypair.base64PrivateToPublic(priv))
        else
            null;
        const hostname = details_stmt.text(4);
        const address = details_stmt.text(5);
        const prefix = details_stmt.uint(6);
        const port = details_stmt.uint(7);
        const dns = details_stmt.text(8);
        const routing_table = details_stmt.text(9);
        const mtu = details_stmt.uint(10);
        const pre_up = details_stmt.text(11);
        const post_up = details_stmt.text(12);
        const pre_down = details_stmt.text(13);
        const post_down = details_stmt.text(14);

        switch (output_type) {
            .table => {
                try writer.print("Interface details\n", .{});
                try writer.print("-----------------\n", .{});
                try writer.print("Name: {s}\n", .{ name orelse "" });
                try writer.print("Comment: {s}\n", .{ comment orelse "" });
                try writer.print("Public Key: {s}\n", .{ pubkey orelse "" });
                try writer.print("Private Key: {s}\n", .{ privkey orelse "" });
                try writer.print("Hostname: {s}\n", .{ hostname orelse "" });
                try writer.print("Address: {s}/{d}\n", .{ address orelse "", prefix });
                if (port == 0) {
                    try writer.print("Port:\n", .{});
                } else {
                    try writer.print("Port: {d}\n", .{ port });
                }
                try writer.print("DNS: {s}\n", .{ dns orelse "" });
                try writer.print("Table: {s}\n", .{ routing_table orelse "" });
                if (mtu == 0) {
                    try writer.print("MTU:\n", .{});
                } else {
                    try writer.print("MTU: {d}\n", .{ mtu });
                }
                try writer.print("Pre  Up: {s}\n", .{ pre_up orelse "" });
                try writer.print("Post Up: {s}\n", .{ post_up orelse "" });
                try writer.print("Pre  Down: {s}\n", .{ pre_down orelse "" });
                try writer.print("Post Down: {s}\n", .{ post_down orelse "" });

                try writer.print("\nPeers\n", .{});
                try writer.print("-----\n", .{});
                try writer.print("         Name          |                  Preshared Key               | Keep Alive |   Allowed IPs    \n", .{});
                try writer.print("-----------------------+----------------------------------------------+------------+------------------\n", .{});
            },
            .json => {
                try writer.print("{{\"name\":", .{});
                try json.stringify(name, .{}, writer);
                try writer.print(",\"comment\":", .{});
                try json.stringify(comment, .{}, writer);
                try writer.print(",\"pubkey\":", .{});
                try json.stringify(pubkey, .{}, writer);
                try writer.print(",\"privkey\":", .{});
                try json.stringify(privkey, .{}, writer);
                try writer.print(",\"hostname\":", .{});
                try json.stringify(hostname, .{}, writer);
                try writer.print(",\"address\":", .{});
                try json.stringify(address, .{}, writer);
                try writer.print(",\"prefix\":", .{});
                try json.stringify(prefix, .{}, writer);
                try writer.print(",\"port\":", .{});
                try json.stringify(if (port == 0) null else port, .{}, writer);
                try writer.print(",\"dns\":", .{});
                try json.stringify(dns, .{}, writer);

                try writer.print(",\"table\":", .{});
                if (mem.eql(u8, routing_table orelse "", "off") or mem.eql(u8, routing_table orelse "", "auto")) {
                    try json.stringify(routing_table, .{}, writer);
                } else if (routing_table) |rtab| {
                    try json.stringify(try std.fmt.parseInt(u32, rtab, 10), .{}, writer);
                } else {
                    try json.stringify(null, .{}, writer);
                }
                try writer.print(",\"mtu\":", .{});
                try json.stringify(if (mtu == 0) null else mtu, .{}, writer);
                try writer.print(",\"pre_up\":", .{});
                try json.stringify(pre_up, .{}, writer);
                try writer.print(",\"post_up\":", .{});
                try json.stringify(post_up, .{}, writer);
                try writer.print(",\"pre_down\":", .{});
                try json.stringify(pre_down, .{}, writer);
                try writer.print(",\"post_down\":", .{});
                try json.stringify(post_down, .{}, writer);
                try writer.print(",\"peers\":[", .{});
            }
        }

        var first_peer = true;
        while (try peers_stmt.step()) {
            const peer_name = peers_stmt.text(1);
            const peer_psk = peers_stmt.text(2);
            const peer_id = peers_stmt.uint(3);
            const peer_keep_alive = peers_stmt.uint(4);
            switch (output_type) {
                .table => {
                    if (peer_keep_alive == 0) {
                        try writer.print("{s: <22} | {s: <44} |            | ", .{ peer_name orelse "", peer_psk orelse "" });
                    } else {
                        try writer.print("{s: <22} | {s: <44} | {d: >10} | ", .{ peer_name orelse "", peer_psk orelse "", peer_keep_alive });
                    }
                },
                .json => {
                    if (first_peer) {
                        first_peer = false;
                    } else {
                        try writer.print(",", .{});
                    }
                    try writer.print("{{\"name\":", .{});
                    try json.stringify(peer_name, .{}, writer);
                    try writer.print(",\"psk\":", .{});
                    try json.stringify(peer_psk, .{}, writer);
                    try writer.print(",\"keep_alive\":", .{});
                    try json.stringify(if (peer_keep_alive == 0) null else peer_keep_alive, .{}, writer);
                    try writer.print(",\"allowed_ips\":[", .{});
                }
            }
            try allowed_ips_stmt.reset();
            try allowed_ips_stmt.bind(.{ peer_id });
            var first_ip = true;
            while (try allowed_ips_stmt.step()) {
                const allowed_ip = allowed_ips_stmt.text(0);
                const allowed_prefix = allowed_ips_stmt.uint(1);
                switch (output_type) {
                    .table => {
                        if (first_ip) {
                            first_ip = false;
                        } else {
                            try writer.print(", ", .{});
                        }
                        try writer.print("{s: <15}/{d: <2}", .{ allowed_ip orelse "", allowed_prefix });
                    },
                    .json => {
                        if (first_ip) {
                            first_ip = false;
                        } else {
                            try writer.print(",", .{});
                        }
                        try writer.print("{{\"address\":", .{});
                        try json.stringify(allowed_ip, .{}, writer);
                        try writer.print(",\"prefix\":", .{});
                        try json.stringify(allowed_prefix, .{}, writer);
                        try writer.print("}}", .{});
                    }
                }
            }
            switch (output_type) {
                .table => try writer.print("\n", .{}),
                .json => try writer.print("]}}", .{}),
            }
        }

        switch (output_type) {
            .json => try writer.print("]}}\n", .{}),
            else => {}
        }

        try details_stmt.finalize();
        try peers_stmt.finalize();
        try allowed_ips_stmt.finalize();
    }

    pub fn jsonDump(self: System, writer: anytype) !void {
        const query = "SELECT id FROM interfaces";
        const stmt = try self.db.prepare(query, null);
        try writer.print("[\n", .{});
        var first = true;
        while (try stmt.step()) {
            if (first) {
                first = false;
            } else {
                try writer.print(",", .{});
            }
            const id = stmt.uint(0);
            try listInterface(self, id, .json, writer);
        }
        try writer.print("]\n", .{});
        try stmt.finalize();
    }

    pub fn exportConf(system: System, interface_id: u64, writer: anytype) !void {
        const details_query = "SELECT address, prefix, privkey, dns, port, routing_table, mtu, pre_up, post_up, pre_down, post_down FROM interfaces WHERE id = ?";
        const peers_query = "SELECT i.name, i.comment, i.privkey, i.hostname, i.port, p.id, p.psk, p.keep_alive FROM peers AS p JOIN interfaces AS i ON p.interface2 = i.id WHERE p.interface1 = ?";
        const allowed_ips_query = "SELECT address, prefix FROM allowed_ips WHERE peer = ?";
        const details_stmt = try system.db.prepare_bind(details_query, .{ interface_id });
        const peers_stmt = try system.db.prepare_bind(peers_query, .{ interface_id });
        const allowed_ips_stmt = try system.db.prepare(allowed_ips_query, null);

        if (!try details_stmt.step())
            return error.NoRecord;

        const address = details_stmt.text(0);
        const prefix = details_stmt.uint(1);
        const privkey = details_stmt.text(2);
        const dns = details_stmt.text(3);
        const port = details_stmt.uint(4);
        const routing_table = details_stmt.text(5);
        const mtu = details_stmt.uint(6);
        const pre_up = details_stmt.text(7);
        const post_up = details_stmt.text(8);
        const pre_down = details_stmt.text(9);
        const post_down = details_stmt.text(10);

        try writer.print("[Interface]\n", .{});
        try writer.print("Address = {s}/{d}\n", .{ address orelse "", prefix });
        try writer.print("PrivateKey = {s}\n", .{ privkey orelse "" });
        if (dns) |dns_ok| {
            try writer.print("DNS = {s}\n", .{ dns_ok });
        }
        if (port != 0)
            try writer.print("ListenPort = {d}\n", .{ port });
        if (routing_table) |rt|
            try writer.print("Table = {s}\n", .{ rt });
        if (mtu != 0)
            try writer.print("MTU = {d}\n", .{ mtu });
        if (pre_up) |val|
            try writer.print("PreUp = {s}\n", .{ val });
        if (post_up) |val|
            try writer.print("PostUp = {s}\n", .{ val });
        if (pre_down) |val|
            try writer.print("PreDown = {s}\n", .{ val });
        if (post_down) |val|
            try writer.print("PostDown = {s}\n", .{ val });

        while (try peers_stmt.step()) {
            const peer_name = peers_stmt.text(0);
            const peer_comment = peers_stmt.text(1);
            const peer_privkey = peers_stmt.text(2);
            const peer_pubkey = if (peer_privkey) |pk| &(try keypair.base64PrivateToPublic(pk)) else "";
            const peer_hostname = peers_stmt.text(3);
            const peer_port = peers_stmt.uint(4);
            const peer_id = peers_stmt.uint(5);
            const peer_psk = peers_stmt.text(6);
            const peer_keepalive = peers_stmt.uint(7);

            try writer.print("\n", .{});
            try writer.print("[Peer]\n", .{});
            try writer.print("# {s}\n", .{ peer_name orelse "" });
            if (peer_comment) |comment| {
                try writer.print("# {s}\n", .{ comment });
            }
            try writer.print("PublicKey = {s}\n", .{ peer_pubkey });
            if (peer_psk) |psk| {
                try writer.print("PresharedKey = {s}\n", .{ psk });
            }
            if (peer_hostname) |hostname| {
                try writer.print("Endpoint = {s}:{d}\n", .{ hostname, peer_port });
            }
            if (peer_keepalive != 0) {
                try writer.print("PersistentKeepalive = {d}\n", .{ peer_keepalive });
            }
            try allowed_ips_stmt.reset();
            try allowed_ips_stmt.bind(.{ peer_id });
            try writer.print("AllowedIPs = ", .{});
            var first = true;
            while (try allowed_ips_stmt.step()) {
                const allowed_address = allowed_ips_stmt.text(0);
                const allowed_prefix = allowed_ips_stmt.uint(1);
                if (first) {
                    first = false;
                } else {
                    try writer.print(", ", .{});
                }
                try writer.print("{s}/{d}", .{ allowed_address orelse "", allowed_prefix });
            }
            try writer.print("\n", .{});
        }

        try details_stmt.finalize();
        try peers_stmt.finalize();
        try allowed_ips_stmt.finalize();
    }

    pub fn exportOpenBSD(system: System, interface_id: u64, writer: anytype) !void {
        const details_query = "SELECT address, prefix, privkey, dns, port, routing_table, mtu, pre_up, post_up, pre_down, post_down FROM interfaces WHERE id = ?";
        const peers_query = "SELECT i.name, i.comment, i.privkey, i.hostname, i.port, p.id, p.psk, p.keep_alive FROM peers AS p JOIN interfaces AS i ON p.interface2 = i.id WHERE p.interface1 = ? ORDER BY aton(i.address)";
        const allowed_ips_query = "SELECT address, prefix FROM allowed_ips WHERE peer = ?";
        const details_stmt = try system.db.prepare_bind(details_query, .{ interface_id });
        const peers_stmt = try system.db.prepare_bind(peers_query, .{ interface_id });
        const allowed_ips_stmt = try system.db.prepare(allowed_ips_query, null);

        if (!try details_stmt.step())
            return error.NoRecord;

        const address = details_stmt.text(0);
        const prefix = details_stmt.uint(1);
        const privkey = details_stmt.text(2);
        // const dns = details_stmt.text(3);
        const port = details_stmt.uint(4);
        const routing_table = details_stmt.text(5);
        const mtu = details_stmt.uint(6);
        const pre_up = details_stmt.text(7);
        const post_up = details_stmt.text(8);
        const pre_down = details_stmt.text(9);
        const post_down = details_stmt.text(10);


        if (pre_up) |val|
            try writer.print("!{s}\n", .{ val });
        try writer.print("inet {s}/{d}\n", .{ address orelse "", prefix });
        try writer.print("wgkey {s}\n", .{ privkey orelse "" });
        if (port != 0)
            try writer.print("wgport {d}\n", .{ port });
        if (routing_table) |rt| {
            try writer.print("wgrtable {d}\n", .{ rt });
        }
        if (mtu != 0)
            try writer.print("mtu {d}\n", .{ mtu });

        while (try peers_stmt.step()) {
            const peer_name = peers_stmt.text(0);
            const peer_comment = peers_stmt.text(1);
            const peer_privkey = peers_stmt.text(2);
            const peer_pubkey = if (peer_privkey) |pk| &(try keypair.base64PrivateToPublic(pk)) else "";
            const peer_hostname = peers_stmt.text(3);
            const peer_port = peers_stmt.uint(4);
            const peer_id = peers_stmt.uint(5);
            const peer_psk = peers_stmt.text(6);
            const peer_keepalive = peers_stmt.uint(7);

            try writer.print("wgpeer {s}", .{ peer_pubkey });
            try allowed_ips_stmt.reset();
            try allowed_ips_stmt.bind(.{ peer_id });
            while (try allowed_ips_stmt.step()) {
                const allowed_address = allowed_ips_stmt.text(0);
                const allowed_prefix = allowed_ips_stmt.uint(1);
                try writer.print(" wgaip {s}/{d}", .{ allowed_address orelse "", allowed_prefix });
            }
            if (peer_psk) |psk| {
                try writer.print(" wgpsk {s}", .{ psk });
            }
            if (peer_hostname) |hostname| {
                try writer.print(" wgendpoint {s} {d}", .{ hostname, peer_port });
            }
            if (peer_keepalive != 0)
                try writer.print(" wgpka {d}", .{ peer_keepalive });

            try writer.print(" # {s}", .{ peer_name orelse "" });
            if (peer_comment) |comment| {
                try writer.print(": {s}", .{ comment });
            }
            try writer.print("\n", .{});
        }

        if (post_up) |val|
            try writer.print("!{s}\n", .{ val });
        if (pre_down) |val|
            try writer.print("# PreDown = {s}\n", .{ val });
        if (post_down) |val|
            try writer.print("# PodtDown = {s}\n", .{ val });

        try details_stmt.finalize();
        try peers_stmt.finalize();
        try allowed_ips_stmt.finalize();
    }


    pub fn dump(self: System, dir: []const u8) !void {
        const query = "SELECT id, name FROM interfaces";
        try fs.cwd().makePath(dir);
        const stmt = try self.db.prepare(query, null);
        while (try stmt.step()) {
            const id = stmt.uint(0);
            const name = stmt.text(1).?;
            const conf_name = try std.fmt.allocPrint(self.allocator, "{s}.conf", .{ name });
            defer self.allocator.free(conf_name);
            const path = try fs.path.join(self.allocator, &.{ dir, conf_name });
            defer self.allocator.free(path);
            const file = try fs.cwd().createFile(path, .{});
            defer file.close();
            try self.exportConf(id, file.writer());
        }
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

    pub fn verifyPrivkey(privkey: []const u8) !bool {
        const keylen = try std.base64.standard.Decoder.calcSizeForSlice(privkey);
        return 32 == keylen;
    }

    pub const OutputType = enum {
        table,
        json,
    };
};
