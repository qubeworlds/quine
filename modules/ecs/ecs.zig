//! quine ECS — a small, generic, domain-agnostic Entity Component System.
//!
//! This module is the simulation's foundation and knows nothing about the
//! concrete world built on it (no `Vertex`, `Transform`, camera, or rendering).
//! A concrete world (see `modules/core`) instantiates `Registry` with its own
//! component set.
//!
//!   * an `Entity` is just an id (index + generation),
//!   * a *component* is plain data attached to an entity,
//!   * a *system* is a free function (defined by the caller) that queries
//!     components and mutates them.
//!
//! Storage is sparse-set based and fixed-capacity (no allocator), so a
//! `Registry` is a trivially-copyable value type — handy for deterministic
//! replay and snapshotting.

const entity = @import("entity.zig");
const storage = @import("storage.zig");
const registry = @import("registry.zig");

pub const Entity = entity.Entity;
pub const EntityAllocator = entity.EntityAllocator;
pub const ComponentStorage = storage.ComponentStorage;
pub const Registry = registry.Registry;

/// Default entity capacity for worlds that don't specify their own. Bump this
/// (or pass a larger capacity to `Registry`) when a world outgrows it.
///
/// Sized for a scene of thousands of DISTINCT entities (each its own mesh) —
/// the "8K" target. The registry's storage is fixed-capacity static memory
/// (`[capacity]T` per component), so this just grows the .bss of a `World`
/// value; it never allocates per-tick. Raise again as scenes grow.
pub const default_capacity = 8192;

test {
    // Pull in the registry's generic tests under `zig build test`.
    _ = registry;
}
