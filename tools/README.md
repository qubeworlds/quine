# Texture tools

Utilities for getting an albedo onto a character, built on the engine's
**G-buffer probe** (`QUINE_GBUFFER=uv|pos|normal`, see `shaders/skinned.glsl`
and `apps/desktop/main.zig`). That probe renders a clean screen→{UV, world
position, world normal} map for the skinned mesh — the *inverse* of the UV
unwrap, sampled per pixel — which turns two otherwise-hard jobs into lookups.

The hard fact underneath: mesh→texture is a clean function (every surface point
has a UV), but texture→mesh is partial (atlas gutters), multivalued (mirrored /
tiled UVs) and cut along seams — and between *two different* meshes there's no
pixel↔pixel map at all. These tools sidestep that by going through the rendered
G-buffer (for projection) or through 3D proximity (for transfer).

## Setup

A built engine and headless GL (same as the thumbnail workflow in `CLAUDE.md`):

```sh
zig build                      # produces zig-out/bin/quine
pip install numpy pillow scipy # tool deps
```

## `project` — paint a 2D image onto a model (decal projector)

Aligns an image in screen space and bakes it into the model's base-colour
texture through the UV map. Align by giving the eye positions in your image; it
finds the eyes on the model from the G-buffer and fits a similarity transform.

```sh
python3 tools/skin_tools.py project \
    --scene face.scene.json \         # a scene framing the model (its camera = the view)
    --image face_albedo.png \
    --image-eyes 330 415 520 415 \    # left/right eye centres in the image (px)
    --out assets/rpm-head.glb
```

Single-frontal-view, so it covers what the camera sees; render from the scene's
angle. Re-run with different `--image-eyes` (or scene camera) to refine.

## `transfer` — copy one model's albedo onto another's UVs

For each texel of the target, finds the closest point on the source surface and
copies that source texel — the mesh-to-mesh bridge (both meshes need
`TEXCOORD_0`; the target needs an existing base-colour image to overwrite). Get
the two heads roughly aligned in object space first.

```sh
python3 tools/skin_tools.py transfer \
    --src assets/source-head.glb \    # has the texture to copy
    --dst assets/rpm-head.glb \       # receives it on its own UVs
    --out assets/rpm-head.glb
```

## `gbuffer` — dump the raw probe (debugging / other tools)

```sh
python3 tools/skin_tools.py gbuffer --scene face.scene.json --channel uv --out uv.png
```
