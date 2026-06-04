# Ready Player Me — character reference & sample asset

A reference for adopting a **standard rigged character** in quine (the "RPM idea"),
and a working sample to test against. Found while trying — and failing — to graft
eyes onto a closed-lid head scan: the clean answer is a character that *already
has* eyes as real geometry on named bones.

## The sample asset

`assets/rpm-half-body.glb` — a Ready Player Me **half-body** avatar (head + torso),
taken from RPM's own MIT-licensed demo repo
[`readyplayerme/visage`](https://github.com/readyplayerme/visage)
(`public/half-body.glb`). 5.9 MB, glTF 2.0 binary.

Inspected contents (`nodes`/`meshes`/extras):

- **41 nodes, 2 meshes, 2 textures.**
- **Eye bones:** node 0 `RightEye`, node 1 `LeftEye` — so an eye's world position
  is just that bone's transform. No socket-measuring, no carving. Gaze = rotate
  these bones (see `core.Gaze`).
- **Meshes:** `Wolf3D_Avatar` (skin/body/face, textured) + `Wolf3D_Avatar_Transparent`
  (hair/glasses transparency). Eyes are **real geometry** in open sockets.
- **72 blendshapes** on `Wolf3D_Avatar`, two standard sets:
  - **ARKit** (Apple `ARFaceAnchor.BlendShapeLocation`): `eyesClosed`,
    `eyeBlinkLeft/Right`, `mouthSmile`, `mouthOpen`, `eyesLookUp/Down`, …
  - **Oculus visemes** (lip-sync): `viseme_sil`, `viseme_PP`, `viseme_FF`, …

## The standard (what to model our own generator on)

Both **half-body and full-body** RPM avatars are **glTF** with:
- a **humanoid skeleton** (`Hips … Head`, `LeftEye`/`RightEye`, hand bones, …),
- a **blendshape facial rig** = **ARKit set + Oculus visemes**,
- **PBR textures** (albedo/normal/…); the face detail lives in the maps.

Docs:
- Morph targets — https://docs.readyplayer.me/ready-player-me/api-reference/avatars/morph-targets
- ARKit blendshapes — https://docs.readyplayer.me/ready-player-me/api-reference/avatars/morph-targets/apple-arkit
- Oculus visemes — https://docs.readyplayer.me/ready-player-me/api-reference/avatars/morph-targets/oculus-ovr-libsync
- Facial animation + bone names — https://docs.readyplayer.me/ready-player-me/integration-guides/unity/setup-for-xr-beta/facial-animations

## What this means for quine

To **use** a conformant character like this, the engine needs two things it
doesn't have yet (both already on the TODO):

1. **PBR textures** (§1) — the face/skin/brows/lips are textures; without sampling
   them a real avatar renders as a flat gray blob.
2. **Morph targets** — load the blendshape vertex-deltas + blend weights per frame
   (the skinned pipeline already does skeletal anim; morphs are the sibling). This
   unlocks **blink + expression + visemes** on any conformant mesh.

What works **today**, untextured: load the glb, read `LeftEye`/`RightEye` bone
positions, and drive **gaze** on them — eye placement straight from the rig, the
thing the closed-lid scan made impossible.

If we build our own avatar generator, **target this same standard** (glTF +
humanoid skeleton + eye bones + ARKit/viseme blendshapes) so our characters
interoperate and we can also import RPM/VRM heads.

## Licensing

The glb is RPM's demo asset, redistributed in their **MIT** `visage` repo, so it's
fine to keep here for **development/reference**. Shipping RPM avatars in a product
is governed by **Ready Player Me's developer terms** — confirm before publishing.
