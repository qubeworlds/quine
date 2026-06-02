//! The generic ECS registry: an entity allocator plus one component storage per
//! registered component type, with spawn/despawn/get/set/query.
//!
//! `Registry` is parameterised by the **set of component types** it manages and
//! the entity `capacity`. The component set is comptime data, so mapping a
//! component type to its backing storage is a comptime lookup — there is no
//! hand-written, per-component `switch` to keep in sync. Adding a component to
//! a world is a one-line edit to the type list passed here.
//!
//! This file is domain-agnostic: it has no knowledge of any concrete component
//! (Transform, mesh refs, cameras, …) — those are supplied by the caller.

const std = @import("std");
const entity = @import("entity.zig");
const storage = @import("storage.zig");

pub const Entity = entity.Entity;
pub const ComponentStorage = storage.ComponentStorage;

/// Build a registry type for the given `Components` and entity `capacity`.
///
/// Usage:
/// ```zig
/// const Reg = Registry(&.{ Transform, MeshRef }, 256);
/// var reg: Reg = .{};
/// const e = reg.spawn();
/// reg.set(Transform, e, .{});
/// var it = reg.query(&.{ Transform, MeshRef });
/// while (it.next()) |hit| { ... reg.get(Transform, hit) ... }
/// ```
pub fn Registry(comptime Components: []const type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        /// Maximum number of live entities this registry can hold.
        pub const max_entities = capacity;

        entities: entity.EntityAllocator(capacity) = .{},
        stores: Stores = .{},

        /// A generated struct with one `ComponentStorage(C, capacity)` field per
        /// registered component `C`. Field `i` backs `Components[i]`.
        const Stores = StoresType(Components, capacity);

        // --- entities ------------------------------------------------------------

        pub fn spawn(self: *Self) Entity {
            return self.entities.spawn();
        }

        /// Despawn an entity and detach all of its components.
        pub fn despawn(self: *Self, e: Entity) void {
            if (!self.entities.isAlive(e)) return;
            inline for (Components) |C| self.storage(C).remove(e);
            self.entities.despawn(e);
        }

        pub fn isAlive(self: *const Self, e: Entity) bool {
            return self.entities.isAlive(e);
        }

        // --- components ----------------------------------------------------------

        /// Borrow a mutable pointer to `e`'s `T` component, or null if absent or
        /// the handle is stale.
        pub fn get(self: *Self, comptime T: type, e: Entity) ?*T {
            if (!self.entities.isAlive(e)) return null;
            return self.storage(T).get(e);
        }

        /// Attach (or overwrite) `e`'s `T` component.
        pub fn set(self: *Self, comptime T: type, e: Entity, value: T) void {
            if (!self.entities.isAlive(e)) return;
            self.storage(T).set(e, value);
        }

        /// The backing storage for component type `T`. The component-type ->
        /// field mapping is resolved entirely at comptime.
        pub fn storage(self: *Self, comptime T: type) *ComponentStorage(T, capacity) {
            return &@field(self.stores, fieldName(T));
        }

        // --- queries -------------------------------------------------------------

        /// Iterate every live entity that has all of `Comps`.
        pub fn query(self: *Self, comptime Comps: []const type) QueryIter(Comps) {
            return .{ .reg = self };
        }

        fn hasAll(self: *Self, comptime Comps: []const type, e: Entity) bool {
            inline for (Comps) |T| {
                if (!self.storage(T).has[e.index]) return false;
            }
            return true;
        }

        /// Iterator over entities matching a component set. Drives off the first
        /// component's dense array (already packed) and filters by the rest.
        pub fn QueryIter(comptime Comps: []const type) type {
            return struct {
                const Iter = @This();
                reg: *Self,
                i: usize = 0,

                pub fn next(self: *Iter) ?Entity {
                    const driver = self.reg.storage(Comps[0]);
                    while (self.i < driver.len) {
                        const e = driver.owner[self.i];
                        self.i += 1;
                        if (self.reg.hasAll(Comps, e)) return e;
                    }
                    return null;
                }
            };
        }

        /// Comptime: the `Stores` field name backing component type `T`.
        fn fieldName(comptime T: type) []const u8 {
            inline for (Components, 0..) |C, i| {
                if (C == T) return std.fmt.comptimePrint("c{d}", .{i});
            }
            @compileError("unknown component type: " ++ @typeName(T));
        }
    };
}

/// Generate the storage struct: field `c{i}` is `ComponentStorage(Components[i],
/// capacity)`, defaulted to empty so the whole registry is `.{}`-constructible.
fn StoresType(comptime Components: []const type, comptime capacity: usize) type {
    var names: [Components.len][]const u8 = undefined;
    var types: [Components.len]type = undefined;
    var attrs: [Components.len]std.builtin.Type.StructField.Attributes = undefined;
    inline for (Components, 0..) |C, i| {
        const S = ComponentStorage(C, capacity);
        const default: S = .{};
        names[i] = std.fmt.comptimePrint("c{d}", .{i});
        types[i] = S;
        attrs[i] = .{ .default_value_ptr = &default };
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

// =============================================================================
// Tests (generic — uses throwaway component types)
// =============================================================================

const testing = std.testing;

const Position = struct { x: f32 = 0, y: f32 = 0 };
const Velocity = struct { dx: f32 = 0, dy: f32 = 0 };
const TestReg = Registry(&.{ Position, Velocity }, 64);

test "spawn assigns distinct ids; despawn recycles with a bumped generation" {
    var reg: TestReg = .{};
    const e1 = reg.spawn();
    const e2 = reg.spawn();
    try testing.expect(e1.index != e2.index);
    try testing.expect(reg.isAlive(e1));

    reg.despawn(e1);
    try testing.expect(!reg.isAlive(e1));

    // The freed index is reused, but the stale handle no longer validates.
    const e3 = reg.spawn();
    try testing.expectEqual(e1.index, e3.index);
    try testing.expect(e3.generation != e1.generation);
    try testing.expect(!reg.isAlive(e1));
    try testing.expect(reg.isAlive(e3));
}

test "components: set, get, overwrite, remove on despawn" {
    var reg: TestReg = .{};
    const e = reg.spawn();

    try testing.expect(reg.get(Position, e) == null);
    reg.set(Position, e, .{ .x = 1.5 });
    try testing.expectEqual(@as(f32, 1.5), reg.get(Position, e).?.x);

    reg.get(Position, e).?.x = 2.0; // mutate through the borrowed pointer
    try testing.expectEqual(@as(f32, 2.0), reg.get(Position, e).?.x);

    reg.despawn(e);
    try testing.expect(reg.get(Position, e) == null);
}

test "query yields only entities holding every requested component" {
    var reg: TestReg = .{};
    const only_pos = reg.spawn();
    reg.set(Position, only_pos, .{});

    const both = reg.spawn();
    reg.set(Position, both, .{});
    reg.set(Velocity, both, .{});

    var count: usize = 0;
    var matched_both = false;
    var it = reg.query(&.{ Position, Velocity });
    while (it.next()) |e| {
        count += 1;
        if (e.index == both.index) matched_both = true;
        try testing.expect(reg.get(Position, e) != null);
        try testing.expect(reg.get(Velocity, e) != null);
    }
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expect(matched_both);
}

test "swap-remove keeps remaining components intact" {
    var reg: TestReg = .{};
    const a = reg.spawn();
    const b = reg.spawn();
    const c = reg.spawn();
    reg.set(Position, a, .{ .x = 10 });
    reg.set(Position, b, .{ .x = 20 });
    reg.set(Position, c, .{ .x = 30 });

    // Remove the middle one; the last element swaps into its slot.
    reg.despawn(b);

    try testing.expectEqual(@as(f32, 10), reg.get(Position, a).?.x);
    try testing.expectEqual(@as(f32, 30), reg.get(Position, c).?.x);
    try testing.expect(reg.get(Position, b) == null);
}
