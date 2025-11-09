const builtin = @import("builtin");
const std = @import("std");
const fifo = std.fifo;
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const log = std.log;
const mem = std.mem;
const os = std.os;
const testing = std.testing;
const zip = std.zip;
const minizign = @import("minizign");
pub const ghattestation = @import("ghattestation.zig");
const winapi = @import("winapi.zig");
const ziputil = @import("ziputil.zig");
const assert = std.debug.assert;

pub fn installUnchecked(allocator: mem.Allocator, dst_path: []const u8, src: fs.File) !void {
    const dir = fs.cwd().openDir(dst_path, .{
        .access_sub_paths = true,
        .iterate = true,
        .no_follow = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.DestinationMissing,
        else => |leftover_err| return leftover_err,
    };

    const pos = try src.getPos();
    defer src.seekTo(pos) catch {};

    // delete and create new lock file ".updating"
    dir.deleteFile(".updating") catch {};
    const updating = dir.createFile(".updating", .{
        .exclusive = true,
    }) catch |err| switch (err) {
        error.AccessDenied => return error.DestinationReadOnly,
        error.PathAlreadyExists,
        error.DeviceBusy,
        error.WouldBlock,
        error.SharingViolation,
        error.FileBusy,
        => {
            return error.DestinationUpdating;
        },
        else => |leftover_err| return leftover_err,
    };
    defer dir.deleteFile(".updating") catch {};
    defer updating.close();

    // create list for filenames with capacity and an arena for strings
    const file_count = try ziputil.countNames(src);
    const FilenamePair = struct { final: []const u8, temp: []const u8, is_dir: bool, permissions: ?u9 = null };
    const FilenamePairList = std.ArrayList(FilenamePair);
    var extracted = try FilenamePairList.initCapacity(allocator, file_count);
    defer extracted.deinit();
    var backup = try FilenamePairList.initCapacity(allocator, file_count);
    defer backup.deinit();
    var arena = heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const string_allocator = arena.allocator();

    // validate zip
    var prefix_len: usize = 0;
    try ziputil.check(src, &prefix_len);

    // resolve (absolute) dest path
    const cwd_path = try std.fs.cwd().realpathAlloc(string_allocator, ".");
    defer string_allocator.free(cwd_path);
    const final_path = try std.fs.path.resolve(string_allocator, &[_][]const u8{
        cwd_path,
        dst_path,
    });
    defer string_allocator.free(final_path);

    // set up temp folders
    dir.deleteTree("._new") catch {};
    dir.makeDir("._new") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer dir.deleteTree("._new") catch {};
    const new_path = try std.fs.path.resolve(string_allocator, &[_][]const u8{
        final_path,
        "._new",
    });
    defer string_allocator.free(new_path);
    var new_dir = try fs.cwd().openDir(new_path, .{
        .access_sub_paths = true,
        .iterate = true,
        .no_follow = true,
    });
    defer new_dir.close();

    dir.makeDir("._old") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer dir.deleteDir("._old") catch {};
    const backup_path = try std.fs.path.resolve(string_allocator, &[_][]const u8{
        final_path,
        "._old",
    });
    defer string_allocator.free(backup_path);

    // collect filenames from zip
    const exe_path = try std.fs.selfExePathAlloc(string_allocator);
    defer string_allocator.free(exe_path);

    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;

    var stream = src.seekableStream();
    const ZipIterator = zip.Iterator(@TypeOf(stream));

    var zip_it = try ZipIterator.init(stream);
    var external_attr = try ziputil.readExternalFileAttreibutes(zip_it);
    while (try zip_it.next()) |entry| {
        const filename = filename_buf[0..entry.filename_len];
        if (filename.len == prefix_len) {
            continue; // skip root folder
        }
        try stream.seekTo(entry.header_zip_offset + @sizeOf(zip.CentralDirectoryFileHeader));
        {
            const len = try stream.context.reader().readAll(filename);
            assert(len == filename.len);
        }
        const is_dir = filename[filename.len - 1] == '/';
        const extract_as = try std.fs.path.resolve(string_allocator, &[_][]const u8{
            new_path,
            filename,
        });
        var final_filename = try std.fs.path.resolve(string_allocator, &[_][]const u8{
            final_path,
            filename[prefix_len..],
        });
        if (std.mem.eql(u8, final_filename, exe_path)) {
            // append .new instead, if it should update the currently running binary
            string_allocator.free(final_filename);
            final_filename = try std.mem.concat(string_allocator, u8, &[_][]const u8{
                exe_path,
                ".new",
            });
            if (std.ascii.endsWithIgnoreCase(final_filename, ".exe.new")) {
                // change .exe.new to .new.exe
                std.mem.copyForwards(
                    u8,
                    final_filename[final_filename.len - 4 ..],
                    final_filename[final_filename.len - 8 .. final_filename.len - 4],
                );
                std.mem.copyForwards(u8, final_filename[final_filename.len - 8 ..], ".new");
            }
        }

        const permission_bits: u9 = @intCast(external_attr >> 16 & 0x1FF);
        log.debug("Extracting {s} -> {s} mode {o}", .{ filename, extract_as, permission_bits });
        try extracted.append(.{
            .final = final_filename,
            .temp = extract_as,
            .is_dir = is_dir,
            .permissions = if (permission_bits == 0) null else permission_bits,
        });

        if (std.fs.accessAbsolute(final_filename, .{})) {
            const backup_as = try std.fs.path.resolve(string_allocator, &[_][]const u8{
                backup_path,
                filename[prefix_len..],
            });
            // TODO: add support to replace file by dir and vice versa
            try backup.append(.{
                .final = final_filename,
                .temp = backup_as,
                .is_dir = is_dir,
            });
        } else |_| {}

        external_attr = ziputil.readExternalFileAttreibutes(zip_it) catch |err| switch(err) {
            error.EndOfStream => 0, // done
            else => return err,
        };
    }

    // NOTE: "extracted" directory structure is deleted with deleteTree in deferred block above
    try zip.extract(new_dir, src.seekableStream(), .{});

    errdefer {
        // on error, move back old files
        // TODO: add support to replace file by dir and vice versa
        for (backup.items) |*entry| {
            if (entry.is_dir) {
                // restore dir
                std.fs.makeDirAbsolute(entry.final) catch {};
            } else if (std.fs.accessAbsolute(entry.temp, .{})) {
                // restore file
                if (std.fs.accessAbsolute(entry.final, .{})) {
                    std.fs.deleteFileAbsolute(entry.final) catch {};
                } else |_| {}
                std.fs.renameAbsolute(entry.temp, entry.final) catch {};
            } else |_| {}
        }
        // on error, delete backup dirs
        // NOTE: this should leave a clean target dir unless restoring backups failed
        var rit = std.mem.reverseIterator(backup.items);
        while (rit.nextPtr()) |entry| {
            if (entry.is_dir) {
                std.fs.deleteDirAbsolute(entry.temp) catch {};
            }
        }
    }

    // move away old files
    for (backup.items) |*entry| {
        // TODO: add support to replace file by dir and vice versa
        log.debug("Saving {s} -> {s}", .{ entry.final, entry.temp });
        if (entry.is_dir) {
            try std.fs.makeDirAbsolute(entry.temp);
        } else {
            try std.fs.renameAbsolute(entry.final, entry.temp);
        }
    }

    errdefer {
        // on error, delete incomplete upgrade files
        for (extracted.items) |*entry| {
            if (!entry.is_dir) {
                std.fs.deleteFileAbsolute(entry.final) catch {};
            }
        }
        // on error, delete incomplete upgrade dirs
        var rit = std.mem.reverseIterator(extracted.items);
        while (rit.nextPtr()) |entry| {
            if (entry.is_dir) {
                std.fs.deleteDirAbsolute(entry.final) catch {};
            }
        }
    }

    // move in new files
    for (extracted.items) |*entry| {
        log.debug("Updating {s} -> {s}", .{ entry.temp, entry.final });
        if (entry.is_dir) {
            std.fs.makeDirAbsolute(entry.final) catch {}; // may already exist
        } else {
            try std.fs.renameAbsolute(entry.temp, entry.final);
            if (entry.permissions) |permissions| {
                var f = try fs.cwd().openFile(entry.final, .{});
                defer f.close();
                try f.chmod(permissions);
            }
        }
    }

    // delete backups
    // NOTE: this is not in a defer so it keeps backups if restoring from backup fails
    dir.deleteTree("._old") catch |err| {
        log.warn("Could not delete backup dir {s}: {}", .{ backup_path, err });
    };
}

pub fn validate(
    allocator: mem.Allocator,
    src: fs.File,
    sig_path: []const u8,
    key_dir: []const u8,
    timestamp: ?u64,
    attestation_repo: ?[]const u8,
    prehash: ?bool,
) !void {
    if (timestamp) |ts| {
        if (ts == 0) {
            return error.InvalidTimestamp;
        }
    }
    if (attestation_repo) |repo| {
        if (mem.indexOfScalar(u8, repo, '/') == null) {
            return error.InvalidAttestationRepo;
        }
    }

    var sig = minizign.Signature.fromFile(allocator, sig_path) catch |err| switch (err) {
        error.FileNotFound => return error.SigFileNotFound,
        else => return err,
    };
    defer sig.deinit();
    if (prehash) |want_prehashed| {
        if (want_prehashed and try sig.algorithm() != .Prehash) {
            return error.UnsupportedAlgorithm;
        }
    }

    var key_id = sig.key_id;
    mem.reverse(u8, &key_id);
    const hex_key_id = fmt.bytesToHex(key_id, .upper);
    const pubkey_name = try std.fmt.allocPrint(allocator, "{s}.pub", .{hex_key_id});
    defer allocator.free(pubkey_name);
    const pubkey_path = try fs.path.join(allocator, &.{ key_dir, pubkey_name });
    defer allocator.free(pubkey_path);
    var pkbuf: [1]minizign.PublicKey = undefined;
    var pubkey = (minizign.PublicKey.fromFile(allocator, &pkbuf, pubkey_path) catch |err| switch (err) {
        error.FileNotFound => {
            log.debug("{s} does not exist in {s}", .{ pubkey_name, key_dir });
            return error.PublicKeyNotFound;
        },
        error.AccessDenied => {
            log.warn("No permission to access {s}", .{pubkey_path});
            return error.PublicKeyNotFound;
        },
        else => {
            log.warn("Error reading {s}: {}", .{ pubkey_name, err });
            return error.InvalidPublicKey;
        },
    })[0];

    // read and check pub key timestamps early if needed since that is cheaper than everything below
    var not_before: ?u64 = null;
    var not_after: ?u64 = null;
    if (timestamp != null or attestation_repo != null) {
        // minizign does not read pub key's untrusted comment, so we do that here
        assert(pubkey.untrusted_comment == null);
        const comment = (try readUntrustedComment(allocator, pubkey_path)) orelse {
            return error.PublicKeyWithoutValidity;
        };
        defer allocator.free(comment);
        not_before = parseNotBefore(comment) orelse return error.PublicKeyWithoutValidity;
        not_after = parseNotAfter(comment) orelse return error.PublicKeyWithoutValidity;
        if (not_before.? > not_after.?) return error.PublicKeyWithoutValidity;
    }

    const pos = try src.getPos();
    defer _ = src.seekTo(pos) catch {};
    try pubkey.verifyFile(allocator, src, sig, null);

    var actual_timestamp = timestamp;
    if (attestation_repo) |repo| {
        try src.seekTo(pos);
        const attestation_timestamp: u64 = ghattestation.getTimestamp(allocator, repo, src) catch |err| dflt: {
            switch (err) {
                error.ConnectionError => break :dflt 0,
                error.ReadError => break :dflt 0,
                error.WriteError => break :dflt 0,
                else => |leftover_err| return leftover_err,
            }
        };
        if (attestation_timestamp != 0) {
            std.log.info("Fetched timestamp: {}", .{attestation_timestamp});
            actual_timestamp = attestation_timestamp;
        } else if (actual_timestamp) |ts| {
            std.log.warn("Fetch failed, assuming timestamp {}", .{ts});
        } else {
            std.log.warn("Fetch failed, ignoring timestamp. Consider using --timestamp as fall-back.", .{});
        }
    } else if (actual_timestamp) |ts| {
        std.log.info("Assuming timestamp {}", .{ts});
    }
    if (actual_timestamp == null) {
        std.log.debug("No timestamp", .{});
    }

    if (actual_timestamp) |ts| {
        assert(not_after != null and not_before != null);
        if (ts > not_after.?) {
            return error.PublicKeyExpired;
        }
        if (ts < not_before.?) {
            return error.PublicKeyTooNew;
        }
    }
}

pub fn install(
    allocator: mem.Allocator,
    dst_path: []const u8,
    src: fs.File,
    sig_path: []const u8,
    key_dir: []const u8,
    timestamp: ?u64,
    attestation_repo: ?[]const u8,
    prehash: ?bool,
    kill_pid: ?u64,
) !void {
    try validate(
        allocator,
        src,
        sig_path,
        key_dir,
        timestamp,
        attestation_repo,
        prehash,
    );
    if (kill_pid) |pid| {
        tryKill(pid);
    }
    try installUnchecked(allocator, dst_path, src);
}

fn tryKill(pid: u64) void {
    if (builtin.target.os.tag == .windows) {
        const h = winapi.OpenProcess(
            winapi.PROCESS_TERMINATE,
            0,
            @intCast(pid),
        );
        if (@intFromPtr(h) != 0) {
            defer os.windows.CloseHandle(h);
            if (os.windows.TerminateProcess(h, 0)) {
                log.debug("Terminated process {}", .{pid});
            } else |err| {
                log.warn("Could not terminate process {}: {}", .{ pid, err });
            }
        } else {
            log.warn("Could not open process {} for termination", .{pid});
        }
    } else {
        if (os.linux.kill(@intCast(pid), os.linux.SIG.KILL) != 0) {
            log.warn("Could not kill process {}", .{pid});
        }
    }
}

fn readUntrustedComment(allocator: mem.Allocator, path: []const u8) !?[]u8 {
    const file = try fs.cwd().openFile(path, .{});
    defer file.close();
    var reader = io.bufferedReader(file.reader());
    const stream = reader.reader();
    var line = try stream.readUntilDelimiterAlloc(allocator, '\n', 4096);
    defer allocator.free(line);
    const marker = "untrusted comment: ";
    if (mem.startsWith(u8, line, marker)) {
        return try allocator.dupe(u8, line[marker.len..]);
    }
    return null;
}

fn parseIntAfter(comptime T: type, haystack: []const u8, needle: []const u8) ?T {
    const white_space = [_]u8{ ' ', '\n', '\r', '\t' };
    if (mem.indexOf(u8, haystack, needle)) |pos| {
        const start = pos + needle.len;
        if (mem.indexOfAnyPos(u8, haystack, start, &white_space)) |end| {
            return fmt.parseInt(T, haystack[start..end], 10) catch return null;
        } else {
            return fmt.parseInt(T, haystack[start..], 10) catch return null;
        }
    }
    return null;
}

fn parseNotBefore(comment: []const u8) ?u64 {
    return parseIntAfter(u64, comment, "not before ");
}

fn parseNotAfter(comment: []const u8) ?u64 {
    return parseIntAfter(u64, comment, "not after ");
}

test "not before comment" {
    const comment =
        "minisign public key F93AE9DB05595CD3 alias black-sliver not before 1743356631 not after 1774892631";
    try std.testing.expectEqual(1743356631, parseNotBefore(comment));
}

test "not after comment" {
    const comment =
        "minisign public key F93AE9DB05595CD3 alias black-sliver not before 1743356631 not after 1774892631";
    try std.testing.expectEqual(1774892631, parseNotAfter(comment));
}

test {
    std.testing.refAllDecls(@This());
}
