const std = @import("std");
const c = @import("openssl_bindings");

const queue_capacity = 64 * 1024;
const protocols = "\x02h2";
const tls12_suites = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305";
const tls13_suites = "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256";

pub const Identity = struct {
    certificate_chain_pem: []const u8,
    private_key_pem: []const u8,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    ctx: *c.SSL_CTX,
    client: bool,

    fn init(allocator: std.mem.Allocator, client: bool) !*Config {
        const ctx = c.SSL_CTX_new(c.TLS_method()) orelse return error.TlsConfigurationFailed;
        errdefer c.SSL_CTX_free(ctx);
        if (c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_2_VERSION) != 1 or
            c.SSL_CTX_set_cipher_list(ctx, tls12_suites) != 1 or
            c.SSL_CTX_set_ciphersuites(ctx, tls13_suites) != 1) return error.TlsConfigurationFailed;
        _ = c.SSL_CTX_set_options(ctx, c.GRPC_SSL_NO_RENEGOTIATION);
        const self = try allocator.create(Config);
        self.* = .{ .allocator = allocator, .ctx = ctx, .client = client };
        return self;
    }

    pub fn createClient(allocator: std.mem.Allocator, ca_pem: []const u8, identity: ?Identity) !*Config {
        const self = try init(allocator, true);
        errdefer self.destroy();
        try self.certificates(ca_pem, true);
        c.SSL_CTX_set_verify(self.ctx, c.SSL_VERIFY_PEER, null);
        if (c.SSL_CTX_set_alpn_protos(self.ctx, protocols, protocols.len) != 0) return error.TlsConfigurationFailed;
        if (identity) |id| try self.useIdentity(id);
        return self;
    }

    pub fn createServer(allocator: std.mem.Allocator, chain: []const u8, key: []const u8, ca: ?[]const u8) !*Config {
        const self = try init(allocator, false);
        errdefer self.destroy();
        try self.useIdentity(.{ .certificate_chain_pem = chain, .private_key_pem = key });
        if (ca) |pem| {
            try self.certificates(pem, true);
            c.SSL_CTX_set_verify(self.ctx, c.SSL_VERIFY_PEER | c.SSL_VERIFY_FAIL_IF_NO_PEER_CERT, null);
        }
        c.SSL_CTX_set_alpn_select_cb(self.ctx, selectH2, null);
        return self;
    }

    // Parse every block: do not accept a valid first certificate followed by an invalid CA.
    fn certificates(self: *Config, pem: []const u8, trust: bool) !void {
        const end = "-----END CERTIFICATE-----";
        var rest = std.mem.trim(u8, pem, " \t\r\n");
        var first = true;
        while (rest.len != 0) {
            if (!std.mem.startsWith(u8, rest, "-----BEGIN CERTIFICATE-----")) return error.InvalidCertificate;
            const length = (std.mem.indexOf(u8, rest, end) orelse return error.InvalidCertificate) + end.len;
            const bio = c.BIO_new_mem_buf(rest.ptr, std.math.cast(c_int, length) orelse return error.InvalidCertificate) orelse return error.OutOfMemory;
            defer _ = c.BIO_free(bio);
            const cert = c.PEM_read_bio_X509(bio, null, noPassword, null) orelse return error.InvalidCertificate;
            defer c.X509_free(cert);
            if (trust) {
                if (c.X509_STORE_add_cert(c.SSL_CTX_get_cert_store(self.ctx), cert) != 1) return error.InvalidCertificate;
            } else if (first) {
                if (c.SSL_CTX_use_certificate(self.ctx, cert) != 1) return error.InvalidCertificate;
            } else if (c.SSL_CTX_add1_chain_cert(self.ctx, cert) != 1) return error.InvalidCertificate;
            rest = std.mem.trim(u8, rest[length..], " \t\r\n");
            first = false;
        }
        if (first) return error.InvalidCertificate;
    }

    fn useIdentity(self: *Config, identity: Identity) !void {
        try self.certificates(identity.certificate_chain_pem, false);
        const pem = identity.private_key_pem;
        const bio = c.BIO_new_mem_buf(pem.ptr, std.math.cast(c_int, pem.len) orelse return error.InvalidPrivateKey) orelse return error.OutOfMemory;
        defer _ = c.BIO_free(bio);
        const key = c.PEM_read_bio_PrivateKey(bio, null, noPassword, null) orelse return error.InvalidPrivateKey;
        defer c.EVP_PKEY_free(key);
        if (c.SSL_CTX_use_PrivateKey(self.ctx, key) != 1 or c.SSL_CTX_check_private_key(self.ctx) != 1)
            return error.CertificateKeyMismatch;
    }

    pub fn destroy(self: *Config) void {
        c.SSL_CTX_free(self.ctx);
        self.allocator.destroy(self);
    }
};

fn noPassword(_: [*c]u8, _: c_int, _: c_int, _: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

fn selectH2(_: ?*c.SSL, out: [*c][*c]const u8, len: [*c]u8, input: [*c]const u8, size: c_uint, _: ?*anyopaque) callconv(.c) c_int {
    var selected: [*c]u8 = null;
    if (c.SSL_select_next_proto(&selected, len, protocols, protocols.len, input, size) != c.OPENSSL_NPN_NEGOTIATED)
        return c.SSL_TLSEXT_ERR_ALERT_FATAL;
    out.* = selected;
    return c.SSL_TLSEXT_ERR_OK;
}

pub const Result = union(enum) {
    complete,
    bytes: usize,
    want_read,
    want_write,
    peer_closed,
    transport_eof,
    failed: c_int,
    alpn_mismatch,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    ssl: *c.SSL,
    network: *c.BIO,
    pending: [16 * 1024]u8 = undefined,
    pending_len: usize = 0,
    state: enum { handshaking, active, failed } = .handshaking,

    pub fn create(allocator: std.mem.Allocator, config: *const Config, hostname: ?[]const u8) !*Session {
        const ssl = c.SSL_new(config.ctx) orelse return error.TlsSessionInitializationFailed;
        errdefer c.SSL_free(ssl);
        if (config.client) {
            const name = hostname orelse return error.InvalidServerName;
            if (name.len == 0 or name.len > 255 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidServerName;
            const z = try allocator.dupeSentinel(u8, name, 0);
            defer allocator.free(z);
            if (std.Io.net.IpAddress.parseIp4(name, 0)) |_| {
                if (c.X509_VERIFY_PARAM_set1_ip_asc(c.SSL_get0_param(ssl), z.ptr) != 1) return error.InvalidServerName;
            } else |_| {
                if (c.SSL_set1_host(ssl, z.ptr) != 1 or c.SSL_set_tlsext_host_name(ssl, z.ptr) != 1) return error.InvalidServerName;
            }
            c.SSL_set_connect_state(ssl);
        } else c.SSL_set_accept_state(ssl);
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        var internal: ?*c.BIO = null;
        var network: ?*c.BIO = null;
        if (c.BIO_new_bio_pair(&internal, queue_capacity, &network, queue_capacity) != 1) return error.TlsSessionInitializationFailed;
        c.SSL_set_bio(ssl, internal, internal);
        self.* = .{ .allocator = allocator, .ssl = ssl, .network = network.? };
        return self;
    }

    pub fn destroy(self: *Session) void {
        c.SSL_free(self.ssl);
        _ = c.BIO_free(self.network);
        self.allocator.destroy(self);
    }

    pub fn feedCiphertext(self: *Session, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (bytes.len > c.BIO_ctrl_get_write_guarantee(self.network)) return error.TlsBufferFull;
        if (c.BIO_write(self.network, bytes.ptr, @intCast(bytes.len)) != bytes.len) return error.TlsConnectionFailed;
    }

    pub fn markTransportEof(self: *Session) void {
        _ = c.BIO_shutdown_wr(self.network);
    }

    pub fn ciphertext(self: *const Session) []const u8 {
        var ptr: [*c]u8 = null;
        const n = c.BIO_nread0(self.network, &ptr);
        return if (n > 0) ptr[0..@intCast(n)] else &.{};
    }

    pub fn consumeCiphertext(self: *Session, count: usize) void {
        if (count == 0) return;
        var ptr: [*c]u8 = null;
        const consumed = c.BIO_nread(self.network, &ptr, @intCast(count));
        std.debug.assert(consumed == count);
    }

    fn classify(self: *Session, rc: c_int) Result {
        const err = c.SSL_get_error(self.ssl, rc);
        return switch (err) {
            c.SSL_ERROR_WANT_READ => .want_read,
            c.SSL_ERROR_WANT_WRITE => .want_write,
            c.SSL_ERROR_ZERO_RETURN => .peer_closed,
            else => blk: {
                self.state = .failed;
                if (err == c.SSL_ERROR_SSL and c.ERR_GET_REASON(c.ERR_peek_last_error()) == c.SSL_R_UNEXPECTED_EOF_WHILE_READING) break :blk .transport_eof;
                break :blk .{ .failed = err };
            },
        };
    }

    pub fn handshake(self: *Session) Result {
        if (self.state == .active) return .complete;
        if (self.state == .failed) return .{ .failed = c.SSL_ERROR_SSL };
        c.ERR_clear_error();
        const rc = c.SSL_do_handshake(self.ssl);
        if (rc != 1) return self.classify(rc);
        if (!self.negotiatedHttp2()) {
            self.state = .failed;
            return .alpn_mismatch;
        }
        self.state = .active;
        return .complete;
    }

    pub fn negotiatedHttp2(self: *const Session) bool {
        var ptr: [*c]const u8 = null;
        var len: c_uint = 0;
        c.SSL_get0_alpn_selected(self.ssl, &ptr, &len);
        return len == 2 and std.mem.eql(u8, ptr[0..2], "h2");
    }

    pub fn read(self: *Session, output: []u8) !Result {
        if (self.state != .active) return error.TlsHandshakeIncomplete;
        if (output.len == 0) return .{ .bytes = 0 };
        c.ERR_clear_error();
        const rc = c.SSL_read(self.ssl, output.ptr, @intCast(@min(output.len, std.math.maxInt(c_int))));
        return if (rc > 0) .{ .bytes = @intCast(rc) } else self.classify(rc);
    }

    pub fn beginWrite(self: *Session, input: []const u8) !Result {
        if (self.state != .active) return error.TlsHandshakeIncomplete;
        if (self.hasPendingWrite()) return error.TlsWriteInProgress;
        if (input.len == 0) return .{ .bytes = 0 };
        self.pending_len = @min(input.len, self.pending.len);
        @memcpy(self.pending[0..self.pending_len], input[0..self.pending_len]);
        return self.continueWrite();
    }

    pub fn continueWrite(self: *Session) !Result {
        if (self.state != .active) return error.TlsHandshakeIncomplete;
        std.debug.assert(self.hasPendingWrite());
        c.ERR_clear_error();
        const rc = c.SSL_write(self.ssl, &self.pending, @intCast(self.pending_len));
        if (rc <= 0) return self.classify(rc);
        self.pending_len = 0;
        return .{ .bytes = @intCast(rc) };
    }

    pub fn hasPendingWrite(self: *const Session) bool {
        return self.pending_len != 0;
    }

    pub fn closeNotify(self: *Session) !Result {
        if (self.state != .active) return error.TlsHandshakeIncomplete;
        if (self.hasPendingWrite()) return error.TlsWriteInProgress;
        c.ERR_clear_error();
        const rc = c.SSL_shutdown(self.ssl);
        // Zero means our alert was sent; the transport need not await the peer's alert.
        return if (rc >= 0) .complete else self.classify(rc);
    }
};

test "client and server negotiate h2 and exchange plaintext" {
    const certificate = @embedFile("testdata/localhost-cert.pem");
    const private_key = @embedFile("testdata/localhost-key.pem");

    const client_config = try Config.createClient(std.testing.allocator, certificate, null);
    defer client_config.destroy();
    const server_config = try Config.createServer(std.testing.allocator, certificate, private_key, null);
    defer server_config.destroy();

    const client = try Session.create(std.testing.allocator, client_config, "localhost");
    defer client.destroy();
    const server = try Session.create(std.testing.allocator, server_config, null);
    defer server.destroy();

    var client_complete = false;
    var server_complete = false;
    for (0..32) |_| {
        if (!client_complete) client_complete = try handshakeStep(client);
        try transferCiphertext(client, server);
        if (!server_complete) server_complete = try handshakeStep(server);
        try transferCiphertext(server, client);
        if (client_complete and server_complete) break;
    }
    try std.testing.expect(client_complete);
    try std.testing.expect(server_complete);
    try std.testing.expect(client.negotiatedHttp2());
    try std.testing.expect(server.negotiatedHttp2());

    const message = "hello over TLS";
    const write_result = try client.beginWrite(message);
    try std.testing.expectEqual(message.len, switch (write_result) {
        .bytes => |count| count,
        else => return error.UnexpectedTlsResult,
    });
    try transferCiphertext(client, server);
    var plaintext: [64]u8 = undefined;
    const read_result = try server.read(&plaintext);
    const read_length = switch (read_result) {
        .bytes => |count| count,
        else => return error.UnexpectedTlsResult,
    };
    try std.testing.expectEqualStrings(message, plaintext[0..read_length]);

    // A full ciphertext batch may end mid-record; retry must not duplicate plaintext.
    const Drain = struct {
        fn run(source: *Session, destination: *Session, received: *usize) !void {
            try transferCiphertext(source, destination);
            var buffer: [4096]u8 = undefined;
            while (true) {
                switch (try destination.read(&buffer)) {
                    .bytes => |count| {
                        for (buffer[0..count]) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
                        received.* += count;
                    },
                    .want_read => return,
                    else => return error.UnexpectedTlsResult,
                }
            }
        }
    };
    const payload: [8 * 1024]u8 = @splat(0x5a);
    var received: usize = 0;
    var blocked: usize = 0;
    for (0..10) |_| {
        var result = try client.beginWrite(&payload);
        while (true) {
            switch (result) {
                .bytes => |count| {
                    try std.testing.expectEqual(payload.len, count);
                    break;
                },
                .want_write => {
                    blocked += 1;
                    try std.testing.expect(client.hasPendingWrite());
                    try std.testing.expectError(error.TlsWriteInProgress, client.beginWrite("overlap"));
                    try std.testing.expectError(error.TlsWriteInProgress, client.closeNotify());
                    try std.testing.expectEqual(queue_capacity, c.BIO_ctrl_pending(client.network));
                    try Drain.run(client, server, &received);
                    result = try client.continueWrite();
                },
                else => return error.UnexpectedTlsResult,
            }
        }
    }
    try std.testing.expect(blocked > 0);
    try Drain.run(client, server, &received);
    try std.testing.expectEqual(10 * payload.len, received);
    try std.testing.expect(!client.hasPendingWrite());
    try std.testing.expectEqual(@as(usize, 0), client.ciphertext().len);
}

test "client rejects a certificate for a different hostname" {
    const certificate = @embedFile("testdata/localhost-cert.pem");
    const private_key = @embedFile("testdata/localhost-key.pem");
    const client_config = try Config.createClient(std.testing.allocator, certificate, null);
    defer client_config.destroy();
    const server_config = try Config.createServer(std.testing.allocator, certificate, private_key, null);
    defer server_config.destroy();
    const client = try Session.create(std.testing.allocator, client_config, "wrong.example");
    defer client.destroy();
    const server = try Session.create(std.testing.allocator, server_config, null);
    defer server.destroy();

    var rejected = false;
    for (0..32) |_| {
        switch (client.handshake()) {
            .failed => rejected = true,
            .complete => return error.UnexpectedTlsResult,
            else => {},
        }
        try transferCiphertext(client, server);
        if (rejected) break;
        _ = server.handshake();
        try transferCiphertext(server, client);
    }
    try std.testing.expect(rejected);
}

test "server rejects empty or malformed client trust roots" {
    const certificate = @embedFile("testdata/localhost-cert.pem");
    const private_key = @embedFile("testdata/localhost-key.pem");
    for ([_][]const u8{ "", "not a PEM certificate" }) |ca| {
        try std.testing.expectError(error.InvalidCertificate, Config.createServer(
            std.testing.allocator,
            certificate,
            private_key,
            ca,
        ));
    }
}

test "server rejects untrusted and expired client certificates" {
    const certificate = @embedFile("testdata/localhost-cert.pem");
    const private_key = @embedFile("testdata/localhost-key.pem");
    const ca = @embedFile("testdata/mtls/ca.pem");
    const server_config = try Config.createServer(std.testing.allocator, certificate, private_key, ca);
    defer server_config.destroy();
    const identities = [_]Identity{
        .{ .certificate_chain_pem = certificate, .private_key_pem = private_key },
        .{ .certificate_chain_pem = @embedFile("testdata/mtls/expired-client.pem"), .private_key_pem = @embedFile("testdata/mtls/client-key.pem") },
    };
    for (identities) |identity| {
        const client_config = try Config.createClient(std.testing.allocator, certificate, identity);
        defer client_config.destroy();
        const outcome = try runHandshake(client_config, server_config);
        try std.testing.expect(outcome.server_failed);
        try std.testing.expect(!outcome.server_complete);
    }
}

test "server requiring a client certificate accepts the client identity" {
    const certificate = @embedFile("testdata/localhost-cert.pem");
    const private_key = @embedFile("testdata/localhost-key.pem");
    const client_config = try Config.createClient(std.testing.allocator, certificate, .{
        .certificate_chain_pem = certificate,
        .private_key_pem = private_key,
    });
    defer client_config.destroy();
    const server_config = try Config.createServer(std.testing.allocator, certificate, private_key, certificate);
    defer server_config.destroy();

    const outcome = try runHandshake(client_config, server_config);
    try std.testing.expect(outcome.client_complete);
    try std.testing.expect(outcome.server_complete);
}

test "server requiring a client certificate rejects a client without identity" {
    const certificate = @embedFile("testdata/localhost-cert.pem");
    const private_key = @embedFile("testdata/localhost-key.pem");
    const client_config = try Config.createClient(std.testing.allocator, certificate, null);
    defer client_config.destroy();
    const server_config = try Config.createServer(std.testing.allocator, certificate, private_key, certificate);
    defer server_config.destroy();

    const outcome = try runHandshake(client_config, server_config);
    try std.testing.expect(outcome.server_failed);
    try std.testing.expect(!outcome.server_complete);
}

test "client rejects an identity whose key does not match the certificate" {
    const certificate = @embedFile("testdata/localhost-cert.pem");
    const unrelated_key =
        \\-----BEGIN PRIVATE KEY-----
        \\MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgo2eSqzM+SZ7QF+x5
        \\4ET3NEJAMz3nbj3e7XzbgSdPHAuhRANCAATSA4imS1m6RqWAI52SWlDnuDuuJ2Ne
        \\D4ql0rjUXF0xwzcTgNr3RgywHrRn4UQ4QiAXctwXTzD9fZxXtyKtTR0X
        \\-----END PRIVATE KEY-----
    ;
    try std.testing.expectError(error.CertificateKeyMismatch, Config.createClient(
        std.testing.allocator,
        certificate,
        .{ .certificate_chain_pem = certificate, .private_key_pem = unrelated_key },
    ));
}

const HandshakeOutcome = struct {
    client_complete: bool = false,
    server_complete: bool = false,
    server_failed: bool = false,
};

/// Drives both handshakes until both complete or either side fails.
fn runHandshake(client_config: *const Config, server_config: *const Config) !HandshakeOutcome {
    const client = try Session.create(std.testing.allocator, client_config, "localhost");
    defer client.destroy();
    const server = try Session.create(std.testing.allocator, server_config, null);
    defer server.destroy();

    var outcome: HandshakeOutcome = .{};
    for (0..32) |_| {
        if (!outcome.client_complete) switch (client.handshake()) {
            .complete => outcome.client_complete = true,
            .want_read, .want_write => {},
            else => return outcome,
        };
        try transferCiphertext(client, server);
        if (!outcome.server_complete) switch (server.handshake()) {
            .complete => outcome.server_complete = true,
            .want_read, .want_write => {},
            else => {
                outcome.server_failed = true;
                return outcome;
            },
        };
        try transferCiphertext(server, client);
        if (outcome.client_complete and outcome.server_complete) break;
    }
    return outcome;
}

fn handshakeStep(session: *Session) !bool {
    return switch (session.handshake()) {
        .complete => true,
        .want_read, .want_write => false,
        else => error.TlsHandshakeFailed,
    };
}

fn transferCiphertext(source: *Session, destination: *Session) !void {
    while (true) {
        const bytes = source.ciphertext();
        if (bytes.len == 0) return;
        try destination.feedCiphertext(bytes);
        source.consumeCiphertext(bytes.len);
    }
}
