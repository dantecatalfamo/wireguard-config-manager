const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

pub const KeyPair = struct {
    public: [32]u8,
    private: [32]u8,

    pub fn publicBase64(self: KeyPair) [44]u8 {
        var buffer: [44]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&buffer, &self.public);
        return buffer;
    }

    pub fn privateBase64(self: KeyPair) [44]u8 {
        var buffer: [44]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&buffer, &self.private);
        return buffer;
    }
};

pub fn generateKeyPair() !KeyPair {
    const keypair = try std.crypto.dh.X25519.KeyPair.create(null);
    return KeyPair{
        .public = keypair.public_key,
        .private = keypair.secret_key,
    };
}

pub fn fromBase64PrivateKey(privkey: [44]u8) !KeyPair {
    var buffer: [32]u8 = undefined;
    try std.base64.standard.Decoder.decode(&buffer, &privkey);
    return try fromPrivateKey(buffer);
}

pub fn fromPrivateKey(privkey: [32]u8) !KeyPair {
    const pubkey = try std.crypto.dh.X25519.recoverPublicKey(privkey);
    return KeyPair{
        .public = pubkey,
        .private = privkey,
    };
}

test "key length" {
    try testing.expectEqual(@as(usize, 44), std.base64.url_safe.Encoder.calcSize(32));
}
