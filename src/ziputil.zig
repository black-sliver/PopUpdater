const std = @import("std");
const ascii = std.ascii;
const log = std.log;
const mem = std.mem;
const testing = std.testing;
const zip = std.zip;
const Io = std.Io;
pub const StringList = std.ArrayList([]u8);

fn isValidFilename(filename: []const u8) bool {
    if (mem.startsWith(u8, filename, ".."))
        return false;
    if (mem.containsAtLeastScalar(u8, filename, 1, '\''))
        return false;
    if (mem.containsAtLeastScalar(u8, filename, 1, ':'))
        return false;
    return true;
}

pub fn countNames(
    reader: *Io.File.Reader,
) !usize {
    var res: usize = 0;
    var zip_it = try zip.Iterator.init(reader);
    while (try zip_it.next()) |_| {
        res += 1;
    }
    return res;
}

pub fn check(
    reader: *Io.File.Reader,
    prefix_len_out: ?*usize,
) !void {
    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
    var prefix_buf: [std.fs.max_path_bytes]u8 = undefined;

    var prefix: []const u8 = prefix_buf[0..0];

    var zip_it = try zip.Iterator.init(reader);
    var first = true;
    while (try zip_it.next()) |entry| {
        if (entry.compression_method != .deflate and entry.compression_method != .store)
            return error.UnsupportedZip;
        if (filename_buf.len < entry.filename_len)
            return error.ZipInsufficientBuffer;

        const filename = filename_buf[0..entry.filename_len];
        try reader.seekTo(entry.header_zip_offset + @sizeOf(zip.CentralDirectoryFileHeader));
        try reader.interface.readSliceAll(filename); // TODO: convert EOF into ZipBadFileOffset
        // log.debug("Checking entry {s}", .{filename}); // TODO: verbosity level
        if (!isValidFilename(filename)) {
            return error.InvalidName;
        }
        if (mem.containsAtLeastScalar(u8, filename, 1, '\'')) {
            return error.InvalidPathSeparator;
        }
        if (first) {
            first = false;
            std.mem.copyForwards(u8, &prefix_buf, filename);
            prefix = prefix_buf[0..filename.len];
            if (std.mem.indexOfScalarPos(u8, prefix, 1, '/')) |p| {
                prefix = prefix[0 .. p + 1];
            }
        } else {
            if (std.mem.indexOfDiff(u8, filename, prefix)) |p| {
                prefix = prefix[0..p];
            }
        }
    }
    log.debug("Common prefix: {s}", .{prefix});
    if (prefix_len_out) |prefix_len| {
        prefix_len.* = prefix.len;
    }
}

/// gets the external file attributes fields of a zip64
/// IMPORTANT: this has to be run on a ZipIterator BEFORE calling next()
/// TODO: either reimplement all of zig's zip to avoid reading it twice or switch to an external lib
pub fn readExternalFileAttreibutes(
    it: anytype,
) !u32 {
    const self = it;
    const header_zip_offset = self.cd_zip_offset + self.cd_record_offset;
    try self.input.seekTo(header_zip_offset);
    const header = try self.input.interface.takeStruct(zip.CentralDirectoryFileHeader, .little);
    if (!std.mem.eql(u8, &header.signature, &zip.central_file_header_sig))
        return error.ZipBadCdOffset;

    return header.external_file_attributes;
}
