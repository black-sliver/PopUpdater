const std = @import("std");
const crypto = std.crypto;
const fifo = std.fifo;
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const http = std.http;
const json = std.json;
const log = std.log;
const mem = std.mem;
const testing = std.testing;

fn getHashForFile(file: anytype) ![crypto.hash.sha2.Sha256.digest_length * 2]u8 {
    const pos = try file.getPos();
    defer _ = file.seekTo(pos) catch {}; // seek back
    // assert pos == 0?
    var hash = crypto.hash.sha2.Sha256.init(.{});
    // hash.update(&.{0}); // use this to simulate unknown (error 404)
    var file_fifo = fifo.LinearFifo(u8, .{ .Static = 4096 }).init();
    try file_fifo.pump(file, hash.writer());
    return fmt.bytesToHex(hash.finalResult(), .lower);
}

pub fn getTimestamp(allocator: mem.Allocator, repo: []const u8, file: fs.File) !u64 {
    const hex_sha256 = try getHashForFile(file);
    return getTimestampForHash(allocator, repo, &hex_sha256);
}

const TLogEntry = struct {
    logIndex: []const u8,
    integratedTime: []const u8,
};

const VerificationMaterial = struct {
    tlogEntries: []const TLogEntry,
};

const AttestationBundle = struct {
    verificationMaterial: VerificationMaterial,
};

const Attestation = struct {
    bundle: AttestationBundle,
};

const AttestationsResponse = struct {
    attestations: []const Attestation,
};

fn getTimestampForHash(orig_allocator: mem.Allocator, repo: []const u8, hex_sha256: []const u8) !u64 {
    var arena = heap.ArenaAllocator.init(orig_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const endpoint = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/attestations/sha256:{s}",
        .{ repo, hex_sha256 },
    );
    const uri = try std.Uri.parse(endpoint);

    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    const server_header_buffer: []u8 = try allocator.alloc(u8, 16 * 1024);

    log.debug("Fetching {}", .{uri});

    var req = client.open(.GET, uri, http.Client.RequestOptions{
        .server_header_buffer = server_header_buffer,
        .headers = .{
            .content_type = http.Client.Request.Headers.Value{
                .override = "application/json",
            },
        },
        .extra_headers = &.{
            http.Header{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
        },
    }) catch |err| {
        log.err("Connection error: {}", .{err});
        return error.ConnectionError;
    };
    defer req.deinit();

    req.send() catch |err| {
        log.err("Write error: {}", .{err});
        return error.WriteError;
    };
    req.wait() catch |err| {
        log.err("Read error: {}", .{err});
        return error.ReadError;
    };
    if (req.response.status != .ok) {
        log.err("Unexpected response code: {}", .{req.response.status});
        return error.ResponseStatusError;
    }
    const resp = try req.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(resp);

    const data = json.parseFromSlice(AttestationsResponse, allocator, resp, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.err("Unexpected response data: {}", .{err});
        return error.ResponseContentError;
    };
    defer data.deinit();
    if (data.value.attestations.len < 1 or data.value.attestations[0].bundle.verificationMaterial.tlogEntries.len < 1) {
        log.err("No tlog entries", .{});
        return error.ResponseContentError;
    }
    return fmt.parseInt(
        u64,
        data.value.attestations[0].bundle.verificationMaterial.tlogEntries[0].integratedTime,
        10,
    ) catch |err| {
        log.err("Unexpected timestamp format: {}", .{err});
        return error.ResponseContentError;
    };
}

test "hash for empty file" {
    const bytes = [_]u8{};
    var fake_file = std.io.fixedBufferStream(&bytes);
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &try getHashForFile(&fake_file),
    );
}

test "hash for known file" {
    const bytes = "test";
    var fake_file = std.io.fixedBufferStream(bytes);
    try testing.expectEqualStrings(
        "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
        &try getHashForFile(&fake_file),
    );
}

test "known timestamp for hash" {
    try testing.expectEqual(1743493277, getTimestampForHash(
        testing.allocator,
        "black-sliver/PopTracker",
        "493d9e6538d1780cba39399d46512eaada71e0a06c60b92319296b3401fe8331"
    ));
}
