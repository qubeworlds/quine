# World coordinate convention

The single, engine-wide coordinate convention. **Everything** — the camera, the
`Transform` basis, the physics world, and the procedural character rig (head /
eyes / nose / gaze) — uses this one frame. There is no second convention; a part
that disagrees is a bug.

## Handedness

- **Right-handed** coordinate system.

## Axes

| Axis | Direction |
|------|-----------|
| **+X** | right |
| **+Y** | up |
| **−Z** | forward |
| **+Z** | backward |

## Canonical direction vectors

| Name | Vector |
|------|--------|
| Right   | ( 1,  0,  0) |
| Left    | (−1,  0,  0) |
| Up      | ( 0,  1,  0) |
| Down    | ( 0, −1,  0) |
| Forward | ( 0,  0, −1) |
| Back    | ( 0,  0,  1) |

This matches the glTF / OpenGL eye-space convention: a camera looks down its
local **−Z**, with **+Y** up and **+X** right.

## What this means in code

- `components.Transform.forward()` returns the local **−Z** axis; `right()`
  returns local **+X**, and up is local **+Y**. The view matrix
  (`render_queue.viewFromTransform`) looks down the transform's local −Z.
- An entity's **front** is its local **−Z**. A character therefore *faces the
  direction it moves*: its face, eyes and nose are on its forward (−Z) side.
- The procedural rig (`core.eye`, `core.nose`, the `kind:"face"` composite and
  the fitted `eyes`/`nose` parts) is built and seated **−Z-front**, and the gaze
  rest axis is **−Z** (`Gaze.target`/`dir` default to `(0,0,−1)`; the gaze cone
  in `systems.clampToCone` opens around −Z; `scene_runtime.rotZTo` maps the rest
  axis **−Z** onto a look direction).

## Authoring & camera note

Because a face points along **−Z (forward)**, a camera that should see the face
sits *in front of it* — on the −Z side, looking back toward +Z (an orbit camera
at `yaw = π`). A camera at `yaw = 0` sits on the +Z (back) side and sees the back
of the head. Scene cameras that frame a character's face are authored
accordingly (see `modules/core/face-tex.scene.json`).

## History

Earlier the procedural rig was authored **+Z-front** (opposite the camera /
`Transform` convention), so a rigged actor's face pointed *away* from its
forward axis and mounting it on a skeleton needed a bespoke 180° "face-mount"
flip. The rig was flipped to −Z-front so the whole engine shares one convention;
downstream scene cameras and any tuned defaults were re-authored to suit.
