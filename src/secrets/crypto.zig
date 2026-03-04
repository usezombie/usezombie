//! AES-256-GCM secrets at rest.
//! Key: 32-byte hex from ENCRYPTION_MASTER_KEY env var.
//! Envelope: 12-byte nonce || ciphertext || 16-byte tag, base64url-encoded.

const std = @import("std");
const log = std.log.scoped(.secrets);

const AesGcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const KEY_LEN = AesGcm.key_length; // 32
const NONCE_LEN = AesGcm.nonce_length; // 12
const TAG_LEN = AesGcm.tag_length; // 16

pub const SecretError = error{
    MissingMasterKey,
    InvalidKeyHex,
    InvalidEnvelope,
    DecryptFailed,
};

/// Load the 32-byte master key from ENCRYPTION_MASTER_KEY env var (64 hex chars).
pub fn loadMasterKey(alloc: std.mem.Allocator) ![KEY_LEN]u8 {
    const hex = std.process.getEnvVarOwned(alloc, "ENCRYPTION_MASTER_KEY") catch {
        log.err("ENCRYPTION_MASTER_KEY not set", .{});
        return SecretError.MissingMasterKey;
    };
    defer alloc.free(hex);

    if (hex.len != KEY_LEN * 2) return SecretError.InvalidKeyHex;
    var key: [KEY_LEN]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key, hex);
    return key;
}

/// Encrypt plaintext → base64url(nonce || ciphertext || tag).
/// Caller owns returned slice.
pub fn encrypt(
    alloc: std.mem.Allocator,
    plaintext: []const u8,
    key: *const [KEY_LEN]u8,
) ![]const u8 {
    var nonce: [NONCE_LEN]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    const ct_len = plaintext.len;
    const buf = try alloc.alloc(u8, NONCE_LEN + ct_len + TAG_LEN);
    defer alloc.free(buf);

    const ct = buf[NONCE_LEN .. NONCE_LEN + ct_len];
    const tag = buf[NONCE_LEN + ct_len ..][0..TAG_LEN];
    @memcpy(buf[0..NONCE_LEN], &nonce);

    AesGcm.encrypt(ct, tag, plaintext, "", nonce, key.*);

    return std.base64.url_safe_no_pad.Encoder.encode(
        try alloc.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(buf.len)),
        buf,
    );
}

/// Decrypt base64url(nonce || ciphertext || tag) → plaintext.
/// Caller owns returned slice.
pub fn decrypt(
    alloc: std.mem.Allocator,
    envelope: []const u8,
    key: *const [KEY_LEN]u8,
) ![]u8 {
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(envelope) catch
        return SecretError.InvalidEnvelope;

    if (decoded_len < NONCE_LEN + TAG_LEN) return SecretError.InvalidEnvelope;

    const decoded = try alloc.alloc(u8, decoded_len);
    defer alloc.free(decoded);

    std.base64.url_safe_no_pad.Decoder.decode(decoded, envelope) catch
        return SecretError.InvalidEnvelope;

    const nonce = decoded[0..NONCE_LEN];
    const ct_len = decoded_len - NONCE_LEN - TAG_LEN;
    const ct = decoded[NONCE_LEN .. NONCE_LEN + ct_len];
    const tag = decoded[NONCE_LEN + ct_len ..][0..TAG_LEN];

    const plaintext = try alloc.alloc(u8, ct_len);
    errdefer alloc.free(plaintext);

    AesGcm.decrypt(plaintext, ct, tag.*, "", nonce.*, key.*) catch
        return SecretError.DecryptFailed;

    return plaintext;
}

test "encrypt/decrypt round-trip" {
    const alloc = std.testing.allocator;
    var key: [KEY_LEN]u8 = undefined;
    std.crypto.random.bytes(&key);

    const plaintext = "super-secret-api-key-12345";
    const envelope = try encrypt(alloc, plaintext, &key);
    defer alloc.free(envelope);

    const recovered = try decrypt(alloc, envelope, &key);
    defer alloc.free(recovered);

    try std.testing.expectEqualStrings(plaintext, recovered);
}
