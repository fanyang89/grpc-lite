const std = @import("std");

const c = @import("wolfssl_bindings");
const queue_capacity = 64 * 1024;
var initialized: std.atomic.Value(u8) = .init(0);
// HTTP/2 permits TLS 1.2 ECDHE AEAD suites and all TLS 1.3 suites below.
const ciphers =
    "TLS13-AES128-GCM-SHA256:TLS13-AES256-GCM-SHA384:TLS13-CHACHA20-POLY1305-SHA256:" ++
    "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:" ++
    "ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:" ++
    "ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305";

/// Certificate chain and unencrypted private key an endpoint presents to its peer.
pub const Identity = struct {
    certificate_chain_pem: []const u8,
    private_key_pem: []const u8,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    ssl: *c.WOLFSSL_CTX,
    client: bool,

    fn create(allocator: std.mem.Allocator, client: bool) !*Config {
        while (true) switch (initialized.load(.acquire)) {
            0 => {
                if (initialized.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) continue;
                if (c.wolfSSL_Init() != c.WOLFSSL_SUCCESS) {
                    initialized.store(0, .release);
                    return error.TlsConfigurationFailed;
                }
                initialized.store(2, .release);
                break;
            },
            1 => std.atomic.spinLoopHint(),
            2 => break,
            else => unreachable,
        };
        const method = (if (client) c.wolfSSLv23_client_method() else c.wolfSSLv23_server_method()) orelse
            return error.TlsConfigurationFailed;
        const ctx = c.wolfSSL_CTX_new(method) orelse return error.TlsConfigurationFailed;
        errdefer c.wolfSSL_CTX_free(ctx);
        if (c.wolfSSL_CTX_SetMinVersion(ctx, c.WOLFSSL_TLSV1_2) != c.WOLFSSL_SUCCESS)
            return error.TlsConfigurationFailed;
        if (c.wolfSSL_CTX_set_cipher_list(ctx, ciphers) != c.WOLFSSL_SUCCESS)
            return error.TlsConfigurationFailed;
        c.wolfSSL_CTX_SetIORecv(ctx, Session.bioRecv);
        c.wolfSSL_CTX_SetIOSend(ctx, Session.bioSend);
        const self = try allocator.create(Config);
        self.* = .{ .allocator = allocator, .ssl = ctx, .client = client };
        return self;
    }

    pub fn createClient(allocator: std.mem.Allocator, ca: []const u8, identity: ?Identity) !*Config {
        const self = try create(allocator, true);
        errdefer self.destroy();
        try self.trust(ca);
        c.wolfSSL_CTX_set_verify(self.ssl, c.WOLFSSL_VERIFY_PEER, null);
        if (identity) |id| try self.useIdentity(id);
        return self;
    }

    pub fn createServer(allocator: std.mem.Allocator, cert: []const u8, key: []const u8, ca: ?[]const u8) !*Config {
        const self = try create(allocator, false);
        errdefer self.destroy();
        try self.useIdentity(.{ .certificate_chain_pem = cert, .private_key_pem = key });
        if (ca) |pem| {
            try self.trust(pem);
            c.wolfSSL_CTX_set_verify(self.ssl, c.WOLFSSL_VERIFY_PEER | c.WOLFSSL_VERIFY_FAIL_IF_NO_PEER_CERT, null);
        } else {
            c.wolfSSL_CTX_set_verify(self.ssl, c.WOLFSSL_VERIFY_NONE, null);
        }
        return self;
    }

    fn trust(self: *Config, pem: []const u8) !void {
        if (pem.len == 0 or c.wolfSSL_CTX_load_verify_buffer(self.ssl, pem.ptr, @intCast(pem.len), c.WOLFSSL_FILETYPE_PEM) != c.WOLFSSL_SUCCESS)
            return error.InvalidCertificate;
    }

    fn useIdentity(self: *Config, identity: Identity) !void {
        if (c.wolfSSL_CTX_use_certificate_chain_buffer(self.ssl, identity.certificate_chain_pem.ptr, @intCast(identity.certificate_chain_pem.len)) != c.WOLFSSL_SUCCESS)
            return error.InvalidCertificate;
        if (c.wolfSSL_CTX_use_PrivateKey_buffer(self.ssl, identity.private_key_pem.ptr, @intCast(identity.private_key_pem.len), c.WOLFSSL_FILETYPE_PEM) != c.WOLFSSL_SUCCESS)
            return error.InvalidPrivateKey;
        if (c.wolfSSL_CTX_check_private_key(self.ssl) != c.WOLFSSL_SUCCESS)
            return error.CertificateKeyMismatch;
    }

    pub fn destroy(self: *Config) void {
        c.wolfSSL_CTX_free(self.ssl);
        self.allocator.destroy(self);
    }
};

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
    ssl: *c.WOLFSSL,
    inbound: ByteQueue = .{},
    outbound: ByteQueue = .{},
    transport_eof: bool = false,
    pending_write: [16 * 1024]u8 = undefined,
    pending_write_length: usize = 0,
    state: enum { handshaking, active, failed } = .handshaking,

    pub fn create(allocator: std.mem.Allocator, config: *const Config, hostname: ?[]const u8) !*Session {
        if (config.client and hostname == null) return error.InvalidServerName;
        const ssl = c.wolfSSL_new(config.ssl) orelse return error.TlsSessionInitializationFailed;
        errdefer c.wolfSSL_free(ssl);
        if (hostname) |name| {
            if (name.len == 0 or name.len > 255 or std.mem.indexOfScalar(u8, name, 0) != null)
                return error.InvalidServerName;
            const z = try allocator.dupeSentinel(u8, name, 0);
            defer allocator.free(z);
            const ip = std.Io.net.IpAddress.parseIp4(name, 0) catch null;
            if (ip != null) {
                if (c.wolfSSL_check_ip_address(ssl, z) != c.WOLFSSL_SUCCESS) return error.InvalidServerName;
            } else {
                if (c.wolfSSL_check_domain_name(ssl, z) != c.WOLFSSL_SUCCESS) return error.InvalidServerName;
                if (c.wolfSSL_UseSNI(ssl, c.WOLFSSL_SNI_HOST_NAME, name.ptr, @intCast(name.len)) != c.WOLFSSL_SUCCESS)
                    return error.InvalidServerName;
            }
        }
        var protocol = [_]u8{ 'h', '2' };
        if (c.wolfSSL_UseALPN(ssl, &protocol, protocol.len, c.WOLFSSL_ALPN_FAILED_ON_MISMATCH) != c.WOLFSSL_SUCCESS)
            return error.TlsConfigurationFailed;
        const self = try allocator.create(Session);
        self.* = .{ .allocator = allocator, .ssl = ssl };
        c.wolfSSL_SetIOReadCtx(ssl, self);
        c.wolfSSL_SetIOWriteCtx(ssl, self);
        return self;
    }

    pub fn destroy(self: *Session) void {
        c.wolfSSL_free(self.ssl);
        std.crypto.secureZero(u8, &self.pending_write);
        self.allocator.destroy(self);
    }

    pub fn feedCiphertext(self: *Session, bytes: []const u8) !void {
        try self.inbound.append(bytes);
    }

    pub fn markTransportEof(self: *Session) void {
        self.transport_eof = true;
    }

    pub fn ciphertext(self: *const Session) []const u8 {
        return self.outbound.readable();
    }

    pub fn consumeCiphertext(self: *Session, count: usize) void {
        self.outbound.consume(count);
    }

    pub fn handshake(self: *Session) Result {
        if (self.state == .active) return .complete;
        if (self.state == .failed) return .{ .failed = c.WOLFSSL_FATAL_ERROR };
        const result = c.wolfSSL_negotiate(self.ssl);
        if (result == c.WOLFSSL_SUCCESS) {
            if (!self.negotiatedHttp2()) {
                self.state = .failed;
                return .alpn_mismatch;
            }
            self.state = .active;
            return .complete;
        }
        return self.classify(result);
    }

    pub fn read(self: *Session, output: []u8) !Result {
        if (self.state != .active) return error.TlsHandshakeIncomplete;
        if (output.len == 0) return .{ .bytes = 0 };
        const n = c.wolfSSL_read(self.ssl, output.ptr, @intCast(@min(output.len, std.math.maxInt(c_int))));
        if (n > 0) return .{ .bytes = @intCast(n) };
        return self.classify(n);
    }

    pub fn beginWrite(self: *Session, input: []const u8) !Result {
        if (self.state != .active) return error.TlsHandshakeIncomplete;
        if (self.pending_write_length != 0) return error.TlsWriteInProgress;
        if (input.len == 0) return .{ .bytes = 0 };
        // wolfSSL requires identical bytes and length when retrying WANT_WRITE.
        self.pending_write_length = @min(input.len, self.pending_write.len);
        @memcpy(self.pending_write[0..self.pending_write_length], input[0..self.pending_write_length]);
        return self.continueWrite();
    }

    pub fn continueWrite(self: *Session) !Result {
        if (self.state != .active) return error.TlsHandshakeIncomplete;
        std.debug.assert(self.pending_write_length != 0);
        const n = c.wolfSSL_write(self.ssl, &self.pending_write, @intCast(self.pending_write_length));
        if (n > 0) {
            self.pending_write_length = 0;
            return .{ .bytes = @intCast(n) };
        }
        return self.classify(n);
    }

    pub fn hasPendingWrite(self: *const Session) bool {
        return self.pending_write_length != 0;
    }

    pub fn closeNotify(self: *Session) !Result {
        if (self.state != .active) return error.TlsHandshakeIncomplete;
        if (self.pending_write_length != 0) return error.TlsWriteInProgress;
        const n = c.wolfSSL_shutdown(self.ssl);
        if (n == c.WOLFSSL_SUCCESS or n == c.WOLFSSL_SHUTDOWN_NOT_DONE) return .complete;
        return self.classify(n);
    }

    pub fn negotiatedHttp2(self: *const Session) bool {
        var name: [*c]u8 = null;
        var len: u16 = 0;
        return c.wolfSSL_ALPN_GetProtocol(self.ssl, &name, &len) == c.WOLFSSL_SUCCESS and
            len == 2 and std.mem.eql(u8, name[0..len], "h2");
    }

    fn classify(self: *Session, ret: c_int) Result {
        const err = c.wolfSSL_get_error(self.ssl, ret);
        return switch (err) {
            c.WOLFSSL_ERROR_WANT_READ => .want_read,
            c.WOLFSSL_ERROR_WANT_WRITE => .want_write,
            c.WOLFSSL_ERROR_ZERO_RETURN => .peer_closed,
            else => result: {
                self.state = .failed;
                if (self.transport_eof) break :result .transport_eof;
                break :result .{ .failed = err };
            },
        };
    }

    fn bioSend(_: ?*c.WOLFSSL, buffer: [*c]u8, length: c_int, context: ?*anyopaque) callconv(.c) c_int {
        const self: *Session = @ptrCast(@alignCast(context.?));
        const count = self.outbound.appendPartial(buffer[0..@intCast(length)]);
        return if (count == 0) c.WOLFSSL_CBIO_ERR_WANT_WRITE else @intCast(count);
    }

    fn bioRecv(_: ?*c.WOLFSSL, buffer: [*c]u8, length: c_int, context: ?*anyopaque) callconv(.c) c_int {
        const self: *Session = @ptrCast(@alignCast(context.?));
        const available = self.inbound.readable();
        if (available.len == 0) return if (self.transport_eof) c.WOLFSSL_CBIO_ERR_CONN_CLOSE else c.WOLFSSL_CBIO_ERR_WANT_READ;
        const count = @min(@as(usize, @intCast(length)), available.len);
        @memcpy(buffer[0..count], available[0..count]);
        self.inbound.consume(count);
        return @intCast(count);
    }
};

const ByteQueue = struct {
    bytes: [queue_capacity]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    pub fn append(self: *ByteQueue, input: []const u8) !void {
        if (input.len > queue_capacity - (self.end - self.start)) return error.TlsBufferFull;
        const count = self.appendPartial(input);
        std.debug.assert(count == input.len);
    }

    pub fn appendPartial(self: *ByteQueue, input: []const u8) usize {
        if (self.start != 0) {
            std.mem.copyForwards(u8, self.bytes[0 .. self.end - self.start], self.bytes[self.start..self.end]);
            self.end -= self.start;
            self.start = 0;
        }
        const count = @min(input.len, queue_capacity - self.end);
        @memcpy(self.bytes[self.end..][0..count], input[0..count]);
        self.end += count;
        return count;
    }

    pub fn readable(self: *const ByteQueue) []const u8 {
        return self.bytes[self.start..self.end];
    }

    pub fn consume(self: *ByteQueue, count: usize) void {
        std.debug.assert(count <= self.end - self.start);
        self.start += count;
        if (self.start == self.end) {
            self.start = 0;
            self.end = 0;
        }
    }
};

test "byte queue compacts consumed input" {
    var queue: ByteQueue = .{};
    try queue.append("first");
    queue.consume(5);
    try queue.append("second");
    try std.testing.expectEqualStrings("second", queue.readable());
}

test "byte queue rejects input beyond its bound" {
    var queue: ByteQueue = .{};
    const input = try std.testing.allocator.alloc(u8, queue_capacity + 1);
    defer std.testing.allocator.free(input);
    try std.testing.expectError(error.TlsBufferFull, queue.append(input));
}

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
                    try std.testing.expectEqual(queue_capacity, client.ciphertext().len);
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

    try std.testing.expectEqual(Result.complete, try client.closeNotify());
    try transferCiphertext(client, server);
    try std.testing.expectEqual(Result.peer_closed, try server.read(&plaintext));
    client.markTransportEof();
    try std.testing.expectEqual(Result.transport_eof, try client.read(&plaintext));
}

test "client rejects a certificate for a different hostname or IP address" {
    const certificate = @embedFile("testdata/localhost-cert.pem");
    const private_key = @embedFile("testdata/localhost-key.pem");
    const client_config = try Config.createClient(std.testing.allocator, certificate, null);
    defer client_config.destroy();
    const server_config = try Config.createServer(std.testing.allocator, certificate, private_key, null);
    defer server_config.destroy();
    for ([_][]const u8{ "wrong.example", "127.0.0.2" }) |hostname| {
        const client = try Session.create(std.testing.allocator, client_config, hostname);
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
}

test "client requires an unambiguous server name" {
    const config = try Config.createClient(std.testing.allocator, @embedFile("testdata/localhost-cert.pem"), null);
    defer config.destroy();
    for ([_]?[]const u8{ null, "", "localhost\x00.attacker.example" }) |hostname|
        try std.testing.expectError(error.InvalidServerName, Session.create(std.testing.allocator, config, hostname));
}

test "concurrent handshakes initialize each AEAD dispatch cache" {
    const Worker = struct {
        client_config: *const Config,
        server_config: *const Config,
        start: *std.atomic.Value(bool),
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            const outcome = runHandshake(self.client_config, self.server_config) catch |err| {
                self.failure = err;
                return;
            };
            if (!outcome.client_complete or !outcome.server_complete)
                self.failure = error.TlsHandshakeFailed;
        }
    };
    const certificate = @embedFile("testdata/localhost-cert.pem");
    const private_key = @embedFile("testdata/localhost-key.pem");
    for ([_][:0]const u8{
        "TLS13-AES128-GCM-SHA256",
        "TLS13-AES256-GCM-SHA384",
        "TLS13-CHACHA20-POLY1305-SHA256",
    }) |cipher| {
        const client_config = try Config.createClient(std.testing.allocator, certificate, null);
        defer client_config.destroy();
        const server_config = try Config.createServer(std.testing.allocator, certificate, private_key, null);
        defer server_config.destroy();
        try std.testing.expectEqual(c.WOLFSSL_SUCCESS, c.wolfSSL_CTX_set_cipher_list(client_config.ssl, cipher));
        try std.testing.expectEqual(c.WOLFSSL_SUCCESS, c.wolfSSL_CTX_set_cipher_list(server_config.ssl, cipher));
        var start: std.atomic.Value(bool) = .init(false);
        var workers: [2]Worker = @splat(.{
            .client_config = client_config,
            .server_config = server_config,
            .start = &start,
        });
        const first = try std.Thread.spawn(.{}, Worker.run, .{&workers[0]});
        const second = std.Thread.spawn(.{}, Worker.run, .{&workers[1]}) catch |err| {
            start.store(true, .release);
            first.join();
            return err;
        };
        start.store(true, .release);
        first.join();
        second.join();
        for (workers) |worker| if (worker.failure) |err| return err;
    }
}

test "TLS 1.2 and TLS 1.3 verify IP SANs and reject corrupted records" {
    const certificate = @embedFile("testdata/localhost-cert.pem");
    const private_key = @embedFile("testdata/localhost-key.pem");
    for ([_]c_int{ c.WOLFSSL_TLSV1_2, c.WOLFSSL_TLSV1_3 }) |version| {
        const client_config = try Config.createClient(std.testing.allocator, certificate, null);
        defer client_config.destroy();
        const server_config = try Config.createServer(std.testing.allocator, certificate, private_key, null);
        defer server_config.destroy();
        const client = try Session.create(std.testing.allocator, client_config, "127.0.0.1");
        defer client.destroy();
        const server = try Session.create(std.testing.allocator, server_config, null);
        defer server.destroy();
        try std.testing.expectEqual(c.WOLFSSL_SUCCESS, c.wolfSSL_SetVersion(client.ssl, version));
        try std.testing.expectEqual(c.WOLFSSL_SUCCESS, c.wolfSSL_SetVersion(server.ssl, version));
        const outcome = try driveHandshake(client, server);
        try std.testing.expect(outcome.client_complete and outcome.server_complete);
        try std.testing.expectEqualStrings(
            if (version == c.WOLFSSL_TLSV1_2) "TLSv1.2" else "TLSv1.3",
            std.mem.span(c.wolfSSL_get_version(client.ssl)),
        );
        var output: [64]u8 = undefined;
        // Consume any post-handshake records before corrupting application data.
        try std.testing.expectEqual(Result.want_read, try client.read(&output));
        try std.testing.expectEqual(Result.want_read, try server.read(&output));
        try std.testing.expectEqual(Result{ .bytes = 5 }, try client.beginWrite("hello"));
        const ciphertext = try std.testing.allocator.dupe(u8, client.ciphertext());
        defer std.testing.allocator.free(ciphertext);
        ciphertext[ciphertext.len - 1] ^= 1;
        try server.feedCiphertext(ciphertext);
        try std.testing.expect((try server.read(&output)) == .failed);
        try std.testing.expectError(error.TlsHandshakeIncomplete, server.read(&output));
    }
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
    return driveHandshake(client, server);
}

fn driveHandshake(client: *Session, server: *Session) !HandshakeOutcome {
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
    const bytes = source.ciphertext();
    try destination.feedCiphertext(bytes);
    source.consumeCiphertext(bytes.len);
}
