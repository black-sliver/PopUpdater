const std = @import("std");
const crypto = std.crypto;
const fmt = std.fmt;
const heap = std.heap;
const http = std.http;
const json = std.json;
const log = std.log;
const mem = std.mem;
const testing = std.testing;
const Io = std.Io;
const LimitWriter = @import("LimitWriter.zig");

fn getHashForFile(reader: anytype) ![crypto.hash.sha2.Sha256.digest_length * 2]u8 {
    // FIXME: do we need seek back with the new Io stuff?
    const pos = reader.logicalPos();
    defer _ = reader.seekTo(pos) catch {}; // seek back
    // assert pos == 0?
    var writer: Io.Writer.Hashing(crypto.hash.sha2.Sha256) = .initHasher(.init(.{}), &.{});
    _ = try reader.interface.streamRemaining(&writer.writer);
    try writer.writer.flush();
    return fmt.bytesToHex(writer.hasher.finalResult(), .lower);
}

pub fn getTimestamp(allocator: mem.Allocator, io: Io, repo: []const u8, file: *Io.File.Reader) !u64 {
    const hex_sha256 = try getHashForFile(file);
    return getTimestampForHash(allocator, io, repo, &hex_sha256);
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

fn getTimestampForHash(orig_allocator: mem.Allocator, io: Io, repo: []const u8, hex_sha256: []const u8) !u64 {
    var arena = heap.ArenaAllocator.init(orig_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const endpoint = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/attestations/sha256:{s}",
        .{ repo, hex_sha256 },
    );
    const uri = try std.Uri.parse(endpoint);

    var client = http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    log.debug("Fetching {}", .{uri});
    var unlimited_response_data_writer: Io.Writer.Allocating = .init(allocator);
    defer unlimited_response_data_writer.deinit();
    var limited_response_data_writer: LimitWriter = .{
        .inner = &unlimited_response_data_writer.writer,
        .limit = 1024 * 1024,
    };
    // TODO: translate fetch errors into our own?
    const res = try client.fetch(.{
        .location = .{ .uri = uri },
        .headers = .{
            .content_type = http.Client.Request.Headers.Value{
                .override = "application/json",
            },
        },
        .extra_headers = &.{
            http.Header{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
        },
        .response_writer = &limited_response_data_writer.interface,
        // TODO: redirect handling?
    });
    if (res.status != .ok) {
        log.err("Unexpected response code: {}", .{res.status});
        return error.ResponseStatusError;
    }
    const response_data = unlimited_response_data_writer.written();
    const data = json.parseFromSlice(AttestationsResponse, allocator, response_data, .{
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

const FakeFile = struct {
    interface: *Io.Reader,

    fn logicalPos(_: *FakeFile) usize {
        return 0;
    }
    fn seekTo(_: *FakeFile, _: usize) !usize {
        return 0;
    }
};

test "hash for empty file" {
    var reader = Io.Reader.fixed(&.{});
    var fake_file: FakeFile = .{ .interface = &reader };
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &try getHashForFile(&fake_file),
    );
}

test "hash for known file" {
    const bytes = "test";
    var reader = Io.Reader.fixed(bytes);
    var fake_file: FakeFile = .{ .interface = &reader };
    try testing.expectEqualStrings(
        "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
        &try getHashForFile(&fake_file),
    );
}

test "known timestamp for hash" {
    try testing.expectEqual(
        1743493277,
        getTimestampForHash(
            testing.allocator,
            testing.io,
            "black-sliver/PopTracker",
            "493d9e6538d1780cba39399d46512eaada71e0a06c60b92319296b3401fe8331",
        ),
    );
}
