const builtin = @import("builtin");
const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const Io = std.Io;
const log = std.log;
const mem = std.mem;
const os = std.os;
const testing = std.testing;
const unicode = std.unicode;
const zip = std.zip;
const minizign = @import("minizign");
pub const ghattestation = @import("ghattestation.zig");
pub const winapi = @import("winapi.zig");
const ziputil = @import("ziputil.zig");
const assert = std.debug.assert;

fn selfExePath(io: Io, allocator: mem.Allocator) ![]u8 {
    return std.process.executablePathAlloc(io, allocator) catch if (builtin.target.os.tag == .windows) {
        var buf: [os.windows.MAX_PATH:0]u16 = undefined;
        const len = winapi.GetModuleFileNameW(null, &buf, buf.len + 1);
        return try unicode.utf16LeToUtf8Alloc(allocator, buf[0..len]);
    } else {
        return try allocator.dupe(u8, "");
    };
}

pub fn cwdRealPath(allocator: mem.Allocator, io: Io) ![]u8 {
    return Io.Dir.realPathFileAlloc(.cwd(), io, ".", allocator) catch if (builtin.target.os.tag == .windows) {
        var buf: [os.windows.MAX_PATH:0]u16 = undefined;
        const len = winapi.GetCurrentDirectoryW(buf.len + 1, &buf);
        return try unicode.utf16LeToUtf8Alloc(allocator, buf[0..len]);
    } else {
        return try allocator.dupe(u8, ".");
    };
}

pub fn installUnchecked(allocator: mem.Allocator, io: Io, dst_path: []const u8, src: Io.File) !void {
    const dir = Io.Dir.openDir(.cwd(), io, dst_path, .{
        .access_sub_paths = true,
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.DestinationMissing,
        else => |leftover_err| return leftover_err,
    };

    // TODO: seek and seek back stream
    const buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(buffer);
    var src_reader = src.reader(io, buffer);
    const pos = src_reader.logicalPos();
    defer src_reader.seekTo(pos) catch {};

    // delete and create new lock file ".updating"
    dir.deleteFile(io, ".updating") catch {};
    const updating = dir.createFile(io, ".updating", .{
        .exclusive = true,
    }) catch |err| switch (err) {
        error.AccessDenied => return error.DestinationReadOnly,
        error.PathAlreadyExists,
        error.DeviceBusy,
        error.WouldBlock,
        // error.SharingViolation,
        error.FileBusy,
        => {
            return error.DestinationUpdating;
        },
        else => |leftover_err| return leftover_err,
    };
    defer dir.deleteFile(io, ".updating") catch {};
    defer updating.close(io);

    // create list for filenames with capacity and an arena for strings
    const file_count = try ziputil.countNames(&src_reader);
    const FilenamePair = struct { final: []const u8, temp: []const u8, is_dir: bool, permissions: ?u9 = null };
    const FilenamePairList = std.ArrayList(FilenamePair);
    var extracted = try FilenamePairList.initCapacity(allocator, file_count);
    defer extracted.deinit(allocator);
    var backup = try FilenamePairList.initCapacity(allocator, file_count);
    defer backup.deinit(allocator);
    var arena = heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const string_allocator = arena.allocator();

    // validate zip
    var prefix_len: usize = 0;
    try ziputil.check(&src_reader, &prefix_len);

    // resolve (absolute) dest path
    // TODO: avoid RealPath and switch to all relative paths, but that's complicated...
    log.debug("Resolving dst path...", .{});
    const cwd_path = try cwdRealPath(string_allocator, io);
    if (builtin.mode == .Debug and !fs.path.isAbsolute(cwd_path)) {
        // in debug mode, fs.*Absolute calls are checked, so this won't work
        // however we want to support e.g. wine with release builds
        return error.CouldNotGetAbsPath;
    }
    defer string_allocator.free(cwd_path);
    const final_path = try std.fs.path.resolve(string_allocator, &[_][]const u8{
        cwd_path,
        dst_path,
    });
    defer string_allocator.free(final_path);

    // set up temp folders
    log.debug("Set up temp path...", .{});
    dir.deleteTree(io, "._new") catch {};
    dir.createDir(io, "._new", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer dir.deleteTree(io, "._new") catch {};
    // TODO: get rid of new_path by immediately opening the dir and using relative paths?
    const new_path = try std.fs.path.resolve(string_allocator, &[_][]const u8{
        final_path,
        "._new",
    });
    defer string_allocator.free(new_path);
    var new_dir = try Io.Dir.openDir(.cwd(), io, new_path, .{
        .access_sub_paths = true,
        .iterate = true,
        .follow_symlinks = false,
    });
    defer new_dir.close(io);

    log.debug("Set up backup path...", .{});
    dir.createDir(io, "._old", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer dir.deleteDir(io, "._old") catch {};
    // TODO: get rid of backup_path by immediately opening the dir and using relative paths?
    const backup_path = try std.fs.path.resolve(string_allocator, &[_][]const u8{
        final_path,
        "._old",
    });
    defer string_allocator.free(backup_path);

    // collect filenames from zip
    log.debug("Collecting filenames...", .{});
    const exe_path = try selfExePath(io, string_allocator);
    if (exe_path.len == 0)
        log.warn("Could not determine exe path", .{});
    defer string_allocator.free(exe_path);

    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;

    var zip_it = try zip.Iterator.init(&src_reader); // TODO: do we need to seek back?
    var external_attr = try ziputil.readExternalFileAttreibutes(zip_it);
    while (try zip_it.next()) |entry| {
        const filename = filename_buf[0..entry.filename_len];
        if (filename.len == prefix_len) {
            continue; // skip root folder
        }
        try src_reader.seekTo(entry.header_zip_offset + @sizeOf(zip.CentralDirectoryFileHeader));
        try src_reader.interface.readSliceAll(filename);
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
        try extracted.append(allocator, .{
            .final = final_filename,
            .temp = extract_as,
            .is_dir = is_dir,
            .permissions = if (permission_bits == 0) null else permission_bits,
        });

        if (Io.Dir.accessAbsolute(io, final_filename, .{})) {
            const backup_as = try std.fs.path.resolve(string_allocator, &[_][]const u8{
                backup_path,
                filename[prefix_len..],
            });
            // TODO: add support to replace file by dir and vice versa
            try backup.append(allocator, .{
                .final = final_filename,
                .temp = backup_as,
                .is_dir = is_dir,
            });
        } else |_| {}

        external_attr = ziputil.readExternalFileAttreibutes(zip_it) catch |err| switch (err) {
            error.EndOfStream => 0, // done
            else => return err,
        };
    }

    // NOTE: "extracted" directory structure is deleted with deleteTree in deferred block above
    try zip.extract(new_dir, &src_reader, .{});

    errdefer {
        // on error, move back old files
        // TODO: add support to replace file by dir and vice versa
        for (backup.items) |*entry| {
            if (entry.is_dir) {
                // restore dir
                Io.Dir.createDirAbsolute(io, entry.final, .default_dir) catch {};
            } else if (Io.Dir.accessAbsolute(io, entry.temp, .{})) {
                // restore file
                if (Io.Dir.accessAbsolute(io, entry.final, .{})) {
                    Io.Dir.deleteFileAbsolute(io, entry.final) catch {};
                } else |_| {}
                Io.Dir.renameAbsolute(entry.temp, entry.final, io) catch {};
            } else |_| {}
        }
        // on error, delete backup dirs
        // NOTE: this should leave a clean target dir unless restoring backups failed
        var rit = std.mem.reverseIterator(backup.items);
        while (rit.nextPtr()) |entry| {
            if (entry.is_dir) {
                Io.Dir.deleteDirAbsolute(io, entry.temp) catch {};
            }
        }
    }

    // move away old files
    for (backup.items) |*entry| {
        // TODO: add support to replace file by dir and vice versa
        log.debug("Saving {s} -> {s}", .{ entry.final, entry.temp });
        if (entry.is_dir) {
            try Io.Dir.createDirAbsolute(io, entry.temp, .default_dir);
        } else {
            try Io.Dir.renameAbsolute(entry.final, entry.temp, io);
        }
    }

    errdefer {
        // on error, delete incomplete upgrade files
        for (extracted.items) |*entry| {
            if (!entry.is_dir) {
                Io.Dir.deleteFileAbsolute(io, entry.final) catch {};
            }
        }
        // on error, delete incomplete upgrade dirs
        var rit = std.mem.reverseIterator(extracted.items);
        while (rit.nextPtr()) |entry| {
            if (entry.is_dir) {
                Io.Dir.deleteDirAbsolute(io, entry.final) catch {};
            }
        }
    }

    // move in new files
    for (extracted.items) |*entry| {
        log.debug("Updating {s} -> {s}", .{ entry.temp, entry.final });
        if (entry.is_dir) {
            Io.Dir.createDirAbsolute(io, entry.final, .default_dir) catch {}; // may already exist
        } else {
            try Io.Dir.renameAbsolute(entry.temp, entry.final, io);
            if (builtin.target.os.tag != .windows) {
                if (entry.permissions) |permissions| {
                    var f = try Io.Dir.openFile(.cwd(), io, entry.final, .{});
                    defer f.close(io);
                    try f.setPermissions(io, @enumFromInt(permissions));
                }
            }
        }
    }

    // delete backups
    // NOTE: this is not in a defer so it keeps backups if restoring from backup fails
    dir.deleteTree(io, "._old") catch |err| {
        log.warn("Could not delete backup dir {s}: {}", .{ backup_path, err });
    };
}

pub fn validate(
    allocator: mem.Allocator,
    io: Io,
    src: Io.File,
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

    var sig = minizign.Signature.fromFile(allocator, sig_path, io) catch |err| switch (err) {
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
    const pubkey_alt_name = pubkey_name[mem.indexOfNone(u8, pubkey_name, "0") orelse unreachable ..];
    const pubkey_path = try fs.path.join(allocator, &.{ key_dir, pubkey_name });
    defer allocator.free(pubkey_path);
    const pubkey_alt_path = try fs.path.join(allocator, &.{ key_dir, pubkey_alt_name });
    defer allocator.free(pubkey_alt_path);
    var pkbuf: [1]minizign.PublicKey = undefined;
    const pks = minizign.PublicKey.fromFile(allocator, &pkbuf, pubkey_path, io) catch |err| switch (err) {
        error.FileNotFound => minizign.PublicKey.fromFile(allocator, &pkbuf, pubkey_alt_path, io) catch |err2| switch (err2) {
            error.FileNotFound => {
                if (pubkey_name.ptr == pubkey_alt_name.ptr) {
                    log.debug("{s} does not exist in {s}", .{ pubkey_name, key_dir });
                } else {
                    log.debug("Neither {s} nor {s} exists in {s}", .{ pubkey_name, pubkey_alt_name, key_dir });
                }
                return error.PublicKeyNotFound;
            },
            error.AccessDenied => {
                log.warn("No permission to access {s}", .{pubkey_alt_path});
                return error.PublicKeyNotFound;
            },
            else => {
                log.warn("Error reading {s}: {}", .{ pubkey_alt_path, err });
                return error.InvalidPublicKey;
            },
        },
        error.AccessDenied => {
            log.warn("No permission to access {s}", .{pubkey_path});
            return error.PublicKeyNotFound;
        },
        else => {
            log.warn("Error reading {s}: {}", .{ pubkey_name, err });
            return error.InvalidPublicKey;
        },
    };
    var pubkey = pks[0];

    // read and check pub key timestamps early if needed since that is cheaper than everything below
    var not_before: ?u64 = null;
    var not_after: ?u64 = null;
    if (timestamp != null or attestation_repo != null) {
        // minizign does not read pub key's untrusted comment, so we do that here
        assert(pubkey.untrusted_comment == null);
        const comment = (try readUntrustedComment(allocator, io, pubkey_path)) orelse {
            return error.PublicKeyWithoutValidity;
        };
        defer allocator.free(comment);
        not_before = parseNotBefore(comment) orelse return error.PublicKeyWithoutValidity;
        not_after = parseNotAfter(comment) orelse return error.PublicKeyWithoutValidity;
        if (not_before.? > not_after.?) return error.PublicKeyWithoutValidity;
    }

    var reader_buffer: [4096]u8 = undefined; // TODO: allocate in arena?
    var reader = src.readerStreaming(io, &reader_buffer);
    const pos = reader.logicalPos();
    defer _ = reader.seekTo(pos) catch {};
    try pubkey.verifyFile(allocator, io, src, sig, null);

    var actual_timestamp = timestamp;
    if (attestation_repo) |repo| {
        try reader.seekTo(pos);
        const attestation_timestamp: u64 = ghattestation.getTimestamp(allocator, io, repo, &reader) catch |err| dflt: {
            switch (err) {
                //error.ConnectionError => break :dflt 0, // TODO: reimplement with new fetch
                //error.ReadError => break :dflt 0,
                //error.WriteError => break :dflt 0,
                error.ResponseStatusError => break :dflt 0, // FIXME: this would be changed behavior. Is this smart?
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
    io: Io,
    dst_path: []const u8,
    src: Io.File,
    sig_path: []const u8,
    key_dir: []const u8,
    timestamp: ?u64,
    attestation_repo: ?[]const u8,
    prehash: ?bool,
    kill_pid: ?u64,
) !void {
    try validate(
        allocator,
        io,
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
    try installUnchecked(allocator, io, dst_path, src);
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
            os.windows.WaitForSingleObject(h, 50) catch {
                // no need to terminate if the process stopped itself
                if (os.windows.TerminateProcess(h, 0)) {
                    if (os.windows.WaitForSingleObject(h, 3000)) {
                        log.debug("Terminated process {}", .{pid});
                    } else |err| {
                        log.debug("Terminate process {} failed: {}", .{ pid, err });
                    }
                } else |err| {
                    log.warn("Could not terminate process {}: {}", .{ pid, err });
                }
            };
        } else {
            log.warn("Could not open process {} for termination", .{pid});
        }
    } else {
        if (os.linux.kill(@intCast(pid), os.linux.SIG.KILL) != 0) {
            log.warn("Could not kill process {}", .{pid});
        }
    }
}

fn readUntrustedComment(allocator: mem.Allocator, io: Io, path: []const u8) !?[]u8 {
    const file = try Io.Dir.openFile(.cwd(), io, path, .{});
    defer file.close(io);
    const buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(buffer);
    var stream = file.reader(io, buffer);
    var line = try stream.interface.peekDelimiterInclusive('\n');
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
