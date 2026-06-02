//! Dense, cache-friendly sparse-set storage for one component type — generic
//! over the component type `T` and the fixed `capacity`. Domain-agnostic.

const Entity = @import("entity.zig").Entity;

/// Storage for one component type `T`.
///
/// `dense` holds the components packed contiguously (great for iteration);
/// `sparse` maps an entity's index to its slot in `dense`; `has` records
/// membership. Removal is O(1) via swap-with-last, with the sparse map fixed
/// up for the moved element.
pub fn ComponentStorage(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        dense: [capacity]T = undefined,
        /// Entity owning `dense[i]` — needed to fix `sparse` on swap-remove.
        owner: [capacity]Entity = undefined,
        /// entity.index -> slot in `dense` (only valid where `has` is true).
        sparse: [capacity]u32 = undefined,
        has: [capacity]bool = [_]bool{false} ** capacity,
        len: usize = 0,

        /// Attach `value` to `e`, or overwrite it if already present.
        pub fn set(self: *Self, e: Entity, value: T) void {
            if (self.has[e.index]) {
                self.dense[self.sparse[e.index]] = value;
                return;
            }
            const slot = self.len;
            self.dense[slot] = value;
            self.owner[slot] = e;
            self.sparse[e.index] = @intCast(slot);
            self.has[e.index] = true;
            self.len += 1;
        }

        pub fn get(self: *Self, e: Entity) ?*T {
            if (!self.has[e.index]) return null;
            return &self.dense[self.sparse[e.index]];
        }

        /// O(1) swap-remove: move the last element into the freed slot and
        /// repoint its sparse entry.
        pub fn remove(self: *Self, e: Entity) void {
            if (!self.has[e.index]) return;
            const slot = self.sparse[e.index];
            const last = self.len - 1;
            self.dense[slot] = self.dense[last];
            self.owner[slot] = self.owner[last];
            self.sparse[self.owner[last].index] = slot;
            self.has[e.index] = false;
            self.len = last;
        }
    };
}
