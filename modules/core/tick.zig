//! World-tick gate — the multiplayer-safety rule for inbound state frames.
//!
//! Frames arrive tagged with the world tick they belong to, possibly out of
//! order or late (network jitter, reconnects, multiple senders). The gate keeps
//! the newest tick it has accepted and rejects anything not strictly newer, so a
//! delayed or reordered update can never clobber newer state. Pure integer logic
//! with no allocation or wall-clock — testable headlessly, same on every host.

/// Accept/reject inbound frames by their world tick. Monotonic: once a tick is
/// accepted, every tick `<=` it is "too late" and dropped (counted for HUD/diag).
pub const TickGate = struct {
    /// Newest tick accepted so far.
    last: u64 = 0,
    /// Count of frames rejected as too late.
    dropped: u32 = 0,

    /// Return true and advance if `tick` is strictly newer than the last
    /// accepted; otherwise count a drop and return false.
    pub fn accept(self: *TickGate, tick: u64) bool {
        if (tick <= self.last) {
            self.dropped +%= 1;
            return false;
        }
        self.last = tick;
        return true;
    }
};

const std = @import("std");

test "TickGate accepts strictly increasing ticks" {
    var g: TickGate = .{};
    try std.testing.expect(g.accept(1));
    try std.testing.expect(g.accept(2));
    try std.testing.expect(g.accept(100));
    try std.testing.expectEqual(@as(u64, 100), g.last);
    try std.testing.expectEqual(@as(u32, 0), g.dropped);
}

test "TickGate drops stale, late, and duplicate ticks" {
    var g: TickGate = .{};
    try std.testing.expect(g.accept(10));
    try std.testing.expect(!g.accept(10)); // duplicate
    try std.testing.expect(!g.accept(5)); //  late / reordered
    try std.testing.expect(!g.accept(0)); //  stale
    try std.testing.expectEqual(@as(u64, 10), g.last); // unchanged by drops
    try std.testing.expectEqual(@as(u32, 3), g.dropped);
    try std.testing.expect(g.accept(11)); // newer again -> accepted
    try std.testing.expectEqual(@as(u32, 3), g.dropped);
}
