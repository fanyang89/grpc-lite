const std = @import("std");
const backend = if (@import("grpc_lite_options").mbedtls) @import("tls_mbedtls.zig") else @import("tls_openssl.zig");
pub const Config = backend.Config;
pub const Session = backend.Session;
pub const Result = backend.Result;
pub const Identity = backend.Identity;

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
        fn run(source: *Session, destination: *Session, received: *usize) !usize {
            var queued: usize = 0;
            while (true) {
                const bytes = source.ciphertext();
                if (bytes.len == 0) break;
                try destination.feedCiphertext(bytes);
                queued += bytes.len;
                source.consumeCiphertext(bytes.len);
            }
            var buffer: [4096]u8 = undefined;
            while (true) {
                switch (try destination.read(&buffer)) {
                    .bytes => |count| {
                        for (buffer[0..count]) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
                        received.* += count;
                    },
                    .want_read => return queued,
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
                    try std.testing.expectEqual(@as(usize, 64 * 1024), try Drain.run(client, server, &received));
                    result = try client.continueWrite();
                },
                else => return error.UnexpectedTlsResult,
            }
        }
    }
    try std.testing.expect(blocked > 0);
    _ = try Drain.run(client, server, &received);
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
