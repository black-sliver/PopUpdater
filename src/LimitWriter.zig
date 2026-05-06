const std = @import("std");
const Io = std.Io;

const Self = @This();

inner: *Io.Writer,
limit: usize,
interface: Io.Writer = .{
    .buffer = &.{},
    .vtable = &.{ .drain = Self.drain },
},

fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) !usize {
    const self: *Self = @fieldParentPtr("interface", w);
    var to_be_written: usize = 0;
    for (data[0 .. data.len - 1]) |el| {
        to_be_written += el.len;
    }
    to_be_written += splat * data[data.len - 1].len;
    if (to_be_written > self.limit) {
        return error.WriteFailed; // limit reached
    }
    const written = self.inner.vtable.drain(self.inner, data, splat) catch |err| {
        return err;
    };
    std.debug.assert(written <= to_be_written and written <= self.limit);
    self.limit -= written;
    return written;
}

test "multiple" {
    var inner: Io.Writer.Discarding = .init(&.{});
    var outer: Self = .{
        .inner = &inner.writer,
        .limit = 10,
    };
    const five_bytes: [5]u8 = @splat(0);
    const one_byte: [1]u8 = @splat(0);
    try std.testing.expectEqual(5, try outer.interface.write(&five_bytes));
    try std.testing.expectEqual(5, try outer.interface.write(&five_bytes));
    try std.testing.expectError(error.WriteFailed, outer.interface.write(&one_byte));
}

test "splatBelow" {
    var inner: Io.Writer.Discarding = .init(&.{});
    var outer: Self = .{
        .inner = &inner.writer,
        .limit = 10,
    };
    const two_bytes: [2]u8 = @splat(0);
    try std.testing.expectEqual(10, try outer.interface.splatBytes(&two_bytes, 5));
}

test "splatAbove" {
    var inner: Io.Writer.Discarding = .init(&.{});
    var outer: Self = .{
        .inner = &inner.writer,
        .limit = 10,
    };
    const two_bytes: [2]u8 = @splat(0);
    const res = outer.interface.splatBytes(&two_bytes, 6);
    try std.testing.expectError(error.WriteFailed, res);
}

test "vecBelow" {
    var inner: Io.Writer.Discarding = .init(&.{});
    var outer: Self = .{
        .inner = &inner.writer,
        .limit = 6,
    };
    const res = try outer.interface.writeVec(&.{&.{1, 2, 3}, &.{4, 5, 6}});
    try std.testing.expectEqual(6, res);
}

test "vecAbove" {
    var inner: Io.Writer.Discarding = .init(&.{});
    var outer: Self = .{
        .inner = &inner.writer,
        .limit = 5,
    };
    const res = outer.interface.writeVec(&.{&.{1, 2, 3}, &.{4, 5, 6}});
    try std.testing.expectError(error.WriteFailed, res);
}
