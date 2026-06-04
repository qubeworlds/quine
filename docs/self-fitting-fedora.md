# The self-fitting fedora

A hat that measures the head it's placed on and shapes itself to fit — any head,
no per-avatar tuning. This is the first **placement behavior**: geometry that
adapts to context (see `asset-behaviors.md`).

## The problem

A head is **not round, and not even a clean oval**. Measured at the hat's contact
ring, the silhouette is an irregular closed curve — deeper front-to-back than it
is wide, asymmetric, with the **ears and nose poking out** as spikes.

So three naive approaches all fail:

- **One radius (a circle).** Sized to clear the back of the skull it bulges wide
  at the temples; sized to the temples it clips the back. (On this RPM head the
  round fit needed R≈0.115 m while the sides are only ≈0.085 m — visibly too
  wide.)
- **An ellipse.** Closer, but still an approximation — it can't follow a real
  cranium, and a different (unusual) head won't be elliptical at all.
- **Max radius anywhere.** Grabs the **ears** (the widest point in the band is an
  ear tip), making a clown brim.

The fix is to **measure the actual contour** where the band touches and shape the
crown to it — soft felt that adapts, spanning the ears rather than dipping into
them.

## The algorithm

Input: a skinned model + its bind/posed `Pose`, the head joint, and `N` segments.
Output: `N` per-angle radii (the contour), the ring centre, and the seat height —
everything `fedoraContour` needs.

1. **Find the head joint.** Prefer the rig's named `Head` node (RPM/VRM); fall
   back to the topmost skin joint for unnamed rigs (CesiumMan).

2. **Skin the head vertices** dominantly weighted to that joint into the posed
   world frame (the same frame the scene renders in). This is what makes the fit
   pose-correct and deterministic — a pure function of mesh + pose.

3. **Locate the contact ring.** Take the head's centroid and vertical span, then
   seat the ring a fraction of the way up toward the crown:

   ```
   seat_y = centroid.y + seat_lift · (top − centroid.y)      // ~0.62 → forehead
   band   = band_frac · (top − bottom)                        // a thin slice
   ```

   This rides **above the brows and ears**, on the forehead/cranium where a band
   actually rests — not down at the wide cheeks (which swallowed the face when
   the seat was too low).

4. **Centre the ring.** The ring centre `(cx, cz)` is the mean X,Z of the band
   vertices — note it sits **forward** of the head joint, because the face
   protrudes; the hat must seat there, not on the bone.

5. **Sample the silhouette.** For each band vertex, bin by angle
   `atan2(z−cz, x−cx)` into `N` buckets and keep the **max** radius per bucket.
   Max (not a percentile) is right *here* because everything above the seat must
   be enclosed — but the ears/nose are *below* the seat, so they no longer
   pollute it.

6. **Close the gaps, then soften.** Empty buckets are interpolated from their
   circular neighbours; then a 3-tap circular smooth (two passes) rounds off
   spikes so the **felt spans** small dips instead of denting into them.

7. **Build to the contour.** `fedoraContour(radii, …)` lays the crown band
   directly on `radii[s]`, then blends each ring toward the mean radius as it
   rises so the top **closes into a round dome**; the brim extends `brim_width`
   beyond the contour with a snap/droop.

8. **Seat it.** Offset the hat from the head joint by `(cx − jointₓ, seat_y −
   jointᵧ, cz − joint_z)`, added to the parent offset so per-tick parenting
   carries it along as the head moves.

## Why it generalizes

Nothing in the algorithm assumes a shape — it reads the mesh. A round head, an
oval head, or an unusual head all produce their own `radii[]`, and the crown is
built to match. That's the point: **no bespoke hat asset per avatar**. The same
fedora behavior fits them all, measured at placement.

## Determinism

It's a pure function of (mesh, pose, params): no wall-clock, no RNG. The same
head always yields the same hat, so replays and CI are identical — it lives in
the headless core and runs without a GPU.

## Code

- `core.measureHeadContour` — steps 1–6 (`modules/core/anim.zig`).
- `core.fedoraContour` — step 7 (`modules/core/assets.zig`).
- `SceneRuntime.buildFedora` — orchestration + step 8
  (`modules/scene_runtime/scene_runtime.zig`); triggered by a `fedora` entity
  with `fitToJoint` parented to the avatar.

## Tunables

- `seat_lift` (≈0.62) — how high the band rides toward the crown.
- `band_frac` (≈0.10) — contact-ring thickness.
- `crown_fit` (≈1.04) — radial clearance so the band rings the head, not the skin.
- `brim_flare` — brim width as a multiple of the mean contour radius.
- `top_clearance` — headroom between the skull top and the crown dome.
