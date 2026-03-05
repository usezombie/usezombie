//! AES-256-GCM secret storage helpers.
//! KEK: 32-byte hex from ENCRYPTION_MASTER_KEY env var.
//! Storage format: BYTEA columns (nonce, ciphertext, tag).

const std = @import("std");
const pg = @import("pg");
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
    NotFound,
};

pub const EncryptedBlob = struct {
    nonce: [NONCE_LEN]u8,
    ciphertext: []u8,
    tag: [TAG_LEN]u8,

    pub fn deinit(self: EncryptedBlob, alloc: std.mem.Allocator) void {
        alloc.free(self.ciphertext);
    }
};

/// Load the 32-byte master key from ENCRYPTION_MASTER_KEY env var (64 hex chars).
pub fn loadKek(alloc: std.mem.Allocator) ![KEY_LEN]u8 {
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

/// Backward-compatible alias.
pub fn loadMasterKey(alloc: std.mem.Allocator) ![KEY_LEN]u8 {
    return loadKek(alloc);
}

/// Encrypt plaintext to raw binary components (nonce + ciphertext + tag).
pub fn encrypt(
    alloc: std.mem.Allocator,
    plaintext: []const u8,
    key: *const [KEY_LEN]u8,
) !EncryptedBlob {
    var nonce: [NONCE_LEN]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    const ciphertext = try alloc.alloc(u8, plaintext.len);
    errdefer alloc.free(ciphertext);

    var tag: [TAG_LEN]u8 = undefined;
    AesGcm.encrypt(ciphertext, &tag, plaintext, "", nonce, key.*);

    return .{
        .nonce = nonce,
        .ciphertext = ciphertext,
        .tag = tag,
    };
}

/// Decrypt raw binary components into plaintext.
/// Caller owns returned slice.
pub fn decrypt(
    alloc: std.mem.Allocator,
    nonce: *const [NONCE_LEN]u8,
    ciphertext: []const u8,
    tag: *const [TAG_LEN]u8,
    key: *const [KEY_LEN]u8,
) ![]u8 {
    const plaintext = try alloc.alloc(u8, ciphertext.len);
    errdefer alloc.free(plaintext);

    AesGcm.decrypt(plaintext, ciphertext, tag.*, "", nonce.*, key.*) catch
        return SecretError.DecryptFailed;

    return plaintext;
}

/// Store encrypted secret in vault.secrets with envelope encryption.
pub fn store(
    alloc: std.mem.Allocator,
    conn: *pg.Conn,
    workspace_id: []const u8,
    key_name: []const u8,
    plaintext: []const u8,
    kek: [KEY_LEN]u8,
) !void {
    var dek: [KEY_LEN]u8 = undefined;
    std.crypto.random.bytes(&dek);

    const wrapped_dek = try encrypt(alloc, dek[0..], &kek);
    defer wrapped_dek.deinit(alloc);

    const encrypted_payload = try encrypt(alloc, plaintext, &dek);
    defer encrypted_payload.deinit(alloc);

    const now_ms = std.time.milliTimestamp();

    var result = try conn.query(
        \\INSERT INTO vault.secrets
        \\  (workspace_id, key_name, kek_version, encrypted_dek, dek_nonce, dek_tag, nonce, ciphertext, tag, created_at, updated_at)
        \\VALUES ($1, $2, 1, $3, $4, $5, $6, $7, $8, $9, $9)
        \\ON CONFLICT (workspace_id, key_name) DO UPDATE
        \\SET encrypted_dek = EXCLUDED.encrypted_dek,
        \\    dek_nonce = EXCLUDED.dek_nonce,
        \\    dek_tag = EXCLUDED.dek_tag,
        \\    nonce = EXCLUDED.nonce,
        \\    ciphertext = EXCLUDED.ciphertext,
        \\    tag = EXCLUDED.tag,
        \\    updated_at = EXCLUDED.updated_at
    , .{
        workspace_id,
        key_name,
        wrapped_dek.ciphertext,
        wrapped_dek.nonce[0..],
        wrapped_dek.tag[0..],
        encrypted_payload.nonce[0..],
        encrypted_payload.ciphertext,
        encrypted_payload.tag[0..],
        now_ms,
    });
    result.deinit();
}

fn toFixed(comptime N: usize, bytes: []const u8) ![N]u8 {
    if (bytes.len != N) return SecretError.InvalidEnvelope;

    var out: [N]u8 = undefined;
    @memcpy(out[0..], bytes);
    return out;
}

/// Load and decrypt a secret from vault.secrets.
pub fn load(
    alloc: std.mem.Allocator,
    conn: *pg.Conn,
    workspace_id: []const u8,
    key_name: []const u8,
    kek: [KEY_LEN]u8,
) ![]u8 {
    var result = try conn.query(
        \\SELECT encrypted_dek, dek_nonce, dek_tag, nonce, ciphertext, tag
        \\FROM vault.secrets
        \\WHERE workspace_id = $1 AND key_name = $2
    , .{ workspace_id, key_name });
    defer result.deinit();

    const row = try result.next() orelse return SecretError.NotFound;

    const encrypted_dek = try row.get([]u8, 0);
    const dek_nonce_slice = try row.get([]u8, 1);
    const dek_tag_slice = try row.get([]u8, 2);
    const payload_nonce_slice = try row.get([]u8, 3);
    const payload_ciphertext = try row.get([]u8, 4);
    const payload_tag_slice = try row.get([]u8, 5);

    const dek_nonce = try toFixed(NONCE_LEN, dek_nonce_slice);
    const dek_tag = try toFixed(TAG_LEN, dek_tag_slice);
    const payload_nonce = try toFixed(NONCE_LEN, payload_nonce_slice);
    const payload_tag = try toFixed(TAG_LEN, payload_tag_slice);

    const dek_plain = try decrypt(alloc, &dek_nonce, encrypted_dek, &dek_tag, &kek);
    defer alloc.free(dek_plain);

    const dek = try toFixed(KEY_LEN, dek_plain);
    return decrypt(alloc, &payload_nonce, payload_ciphertext, &payload_tag, &dek);
}

test "encrypt/decrypt round-trip with raw bytes" {
    const alloc = std.testing.allocator;

    var key: [KEY_LEN]u8 = undefined;
    std.crypto.random.bytes(&key);

    const plaintext = "super-secret-api-key-12345";
    const blob = try encrypt(alloc, plaintext, &key);
    defer blob.deinit(alloc);

    const recovered = try decrypt(alloc, &blob.nonce, blob.ciphertext, &blob.tag, &key);
    defer alloc.free(recovered);

    try std.testing.expectEqualStrings(plaintext, recovered);
}

test "decrypt fails when tag is tampered" {
    const alloc = std.testing.allocator;

    var key: [KEY_LEN]u8 = undefined;
    std.crypto.random.bytes(&key);

    const blob = try encrypt(alloc, "hello", &key);
    defer blob.deinit(alloc);

    var bad_tag = blob.tag;
    bad_tag[0] ^= 0x01;

    try std.testing.expectError(
        SecretError.DecryptFailed,
        decrypt(alloc, &blob.nonce, blob.ciphertext, &bad_tag, &key),
    );
}
