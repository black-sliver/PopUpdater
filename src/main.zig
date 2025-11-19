const builtin = @import("builtin");
const std = @import("std");
const lib = @import("PopUpdater");
const clap = @import("clap");
const winapi = lib.winapi;
const fs = std.fs;
const heap = std.heap;
const log = std.log;
const mem = std.mem;
const process = std.process;

fn printUsage(stream: anytype, param: anytype) !void {
    var args = try process.argsWithAllocator(heap.page_allocator);
    defer args.deinit();
    const exe_name: [:0]const u8 = args.next() orelse "popupdater";

    try stream.print("Usage: {s} ", .{exe_name});
    try clap.usage(stream, clap.Help, param);
    _ = try stream.write("\n");
}

fn argError(stream: anytype, param: anytype) !void {
    try printUsage(stream, param);
    process.exit(64);
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdOut().writer();

    var arena = heap.ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help            Display this help and exit.
        \\-a, --attested <str>  GitHub repo in the form "owner/repo" to get attestation timestamp.
        \\-t, --timestamp <ts>  Assume this timestamp if no -a is provided or fetch fails.
        \\-k, --kill <pid>      Kill process before replacing files.
        \\-s, --start <str>     Start executable after update (relative to dst).
        \\<dst>                 Path to directory to update.
        \\<src>                 Path to update file (zip).
        \\<sig>                 Path to signature file (minisig).
        \\<keys>                Optional path to folder containing keys, defaults to <dst>/key.
    );

    const parsers = comptime .{
        .str = clap.parsers.string,
        .ts = clap.parsers.int(u64, 10),
        .pid = clap.parsers.int(u64, 10),
        .dst = clap.parsers.string,
        .src = clap.parsers.string,
        .sig = clap.parsers.string,
        .keys = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var args = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return argError(stderr, &params);
    };
    defer args.deinit();

    if (args.args.help != 0) {
        try printUsage(stdout, &params);
        return clap.help(stdout, clap.Help, &params, .{
            .description_on_new_line = false,
            .spacing_between_parameters = 0,
        });
    }
    const dst = args.positionals[0] orelse return argError(stderr, &params);
    const src = args.positionals[1] orelse return argError(stderr, &params);
    const sig = args.positionals[2] orelse return argError(stderr, &params);
    var keys = args.positionals[3] orelse "";
    const auto_keys = (keys.len == 0);

    if (auto_keys) {
        keys = try fs.path.join(allocator, &.{ dst, "key" });
    }
    defer {
        if (auto_keys) {
            allocator.free(keys);
        }
    }

    std.log.info("Attempting to update {s} from {s} with sig {s} checked against {s}/*", .{ dst, src, sig, keys });

    const file = try fs.cwd().openFile(src, .{});

    var exit_code: u8 = 0;

    // NOTE: we only support the new (prehash) format at the moment. TODO: command line switch?
    lib.install(
        allocator,
        dst,
        file,
        sig,
        keys,
        args.args.timestamp,
        args.args.attested,
        true,
        args.args.kill,
    ) catch |err| switch (err) {
        // TODO: pass error code/message to app started with --start
        error.SigFileNotFound => {
            std.log.err("Could not read {s}: {}", .{ sig, err });
            exit_code = 66;
        },
        error.UnsupportedAlgorithm => {
            std.log.err("Unsupported algorithm in {s}", .{sig});
            exit_code = 65;
        },
        error.ResponseStatusError, error.ResponseContentError => {
            std.log.err("Could not find artifact in repo attestations", .{});
            exit_code = 1;
        },
        error.PublicKeyNotFound => {
            std.log.err("Matching public key not found for {s}", .{sig});
            exit_code = 65;
        },
        error.InvalidPublicKey => {
            std.log.err("Public key file for {s} is invalid", .{sig});
            exit_code = 65;
        },
        error.PublicKeyWithoutValidity => {
            std.log.err("Public key does not specify \"not before\" / \"not after\"", .{});
            exit_code = 65;
        },
        error.KeyIdMismatch,
        error.SignatureVerificationFailed,
        error.PublicKeyExpired,
        error.PublicKeyTooNew,
        => {
            std.log.err("Verification failed: {}", .{err});
            exit_code = 1;
        },
        error.DestinationMissing => {
            std.log.err("Destination directory does not exist", .{});
            exit_code = 66;
        },
        error.DestinationUpdating => {
            std.log.err("Destination directory is already being updated", .{});
            exit_code = 1;
        },
        error.InvalidPathSeparator => {
            std.log.err("Invalid path separator. Please use a proper ZIP tool to create the file", .{});
            exit_code = 1;
        },
        else => |leftover_err| return leftover_err,
    };

    try stdout.print("Update OK.\n", .{});

    if (args.args.start) |exe| {
        const exe_path = try fs.path.join(allocator, &.{ dst, exe });
        if (process.can_execv) {
            const argv: [2][]const u8 = .{ exe_path, if (exit_code == 0) "--updated" else "--update-failed" };
            const err = process.execv(allocator, &argv);
            log.err("Could not start program {s}: {}", .{ exe, err });
            process.exit(1);
        } else if (builtin.target.os.tag == .windows) {
            mem.replaceScalar(u8, exe_path, '/', '\\');
            const exe_path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, exe_path);
            defer allocator.free(exe_path_w);
            const exe_args_w = try std.unicode.utf8ToUtf16LeAllocZ(
                allocator,
                if (exit_code == 0) "--updated" else "--update-failed",
            );
            defer allocator.free(exe_args_w);
            const res = winapi.ShellExecuteW(
                null,
                null,
                exe_path_w,
                exe_args_w,
                null,
                1,
            );
            const res_code = @intFromPtr(res);
            if (res_code < 32) {
                const cwd = lib.cwdRealPath(allocator) catch ".";
                defer allocator.free(cwd);
                log.err("Could not start program {s} in {s}: {s}", .{ exe_path, cwd, switch (res_code) {
                    0 => "Out of resources",
                    2 => "File not found",
                    3 => "Path not found",
                    5 => "Access denied",
                    6 => "Invalid handle",
                    8 => "Out of memory",
                    11 => "Bad format",
                    15 => "Invalid drive",
                    32 => "Sharing violation",
                    else => "Other",
                } });
                process.exit(1);
            }
        } else {
            return error.StartProgramNotImplemented;
        }
    }
    if (exit_code != 0) {
        process.exit(exit_code);
    }
}
