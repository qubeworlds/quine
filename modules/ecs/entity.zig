//! Entity identity for the generic ECS — a generational index and its allocator.
//!
//! This file is domain-agnostic: it knows nothing about components, the
//! simulation, or rendering. It is the bottom of the ECS and can be reused by
//! any world built on top of it.

const std = @import("std");

/// A handle to an entity. `index` locates its storage slot; `generation`
/// guards against stale handles: when a slot is recycled its generation is
/// bumped, so an old `Entity` value no longer validates. This is the standard
/// "generational index" — the single most important detail to get right.
pub const Entity = struct {
    index: u32,
    generation: u32,
};

/// Allocates and recycles entity ids over a fixed `capacity` (no allocator, so
/// the whole thing stays a plain value type). Recycled slots get a bumped
/// generation so previously-handed-out handles to the same index become
/// invalid.
pub fn EntityAllocator(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        generations: [capacity]u32 = [_]u32{0} ** capacity,
        alive: [capacity]bool = [_]bool{false} ** capacity,
        /// Stack of free (previously-used) indices available for reuse.
        free: [capacity]u32 = undefined,
        free_len: usize = 0,
        /// Lowest index never yet handed out — used once the free stack is empty.
        high: u32 = 0,

        pub fn spawn(self: *Self) Entity {
            var idx: u32 = undefined;
            if (self.free_len > 0) {
                self.free_len -= 1;
                idx = self.free[self.free_len];
            } else {
                std.debug.assert(self.high < capacity);
                idx = self.high;
                self.high += 1;
            }
            self.alive[idx] = true;
            return .{ .index = idx, .generation = self.generations[idx] };
        }

        pub fn despawn(self: *Self, e: Entity) void {
            if (!self.isAlive(e)) return;
            self.alive[e.index] = false;
            self.generations[e.index] += 1; // invalidate any outstanding handle
            self.free[self.free_len] = e.index;
            self.free_len += 1;
        }

        pub fn isAlive(self: *const Self, e: Entity) bool {
            return e.index < capacity and
                self.alive[e.index] and
                self.generations[e.index] == e.generation;
        }
    };
}
