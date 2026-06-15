//! Codec-agnostic image decode: sniff the magic bytes and dispatch to the right
//! decoder (`png.zig` or `jpeg.zig`). Both glTF base-colour atlases and
//! scene-declared `material.texture` assets go through this, so adding a format
//! is one place and the rest of the engine never branches on codec.

const std = @import("std");
const assets = @import("assets.zig");
const png = @import("png.zig");
const jpeg = @import("jpeg.zig");

pub const Error = error{UnknownImageFormat};

/// Decode `bytes` to an allocator-owned RGBA8 `Texture`. Recognises PNG and JPEG.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !assets.Texture {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], &.{ 137, 80, 78, 71, 13, 10, 26, 10 }))
        return png.decode(allocator, bytes);
    if (bytes.len >= 2 and bytes[0] == 0xFF and bytes[1] == 0xD8)
        return jpeg.decode(allocator, bytes);
    return Error.UnknownImageFormat;
}

test "dispatches by magic" {
    // A PNG-signatured-but-empty blob reaches the PNG decoder (its own error), not
    // UnknownImageFormat — proving dispatch picked the PNG codec.
    const png_sig = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10, 0, 0 };
    try std.testing.expectError(error.NoImageData, decode(std.testing.allocator, &png_sig));
    // A JPEG SOI reaches the JPEG decoder (which faults on the truncated stream).
    const jpeg_sig = [_]u8{ 0xFF, 0xD8, 0xFF, 0xD9 };
    try std.testing.expectError(error.Unsupported, decode(std.testing.allocator, &jpeg_sig));
    const junk = [_]u8{ 1, 2, 3, 4 };
    try std.testing.expectError(Error.UnknownImageFormat, decode(std.testing.allocator, &junk));
}
