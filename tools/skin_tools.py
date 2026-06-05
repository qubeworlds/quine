#!/usr/bin/env python3
"""skin_tools.py — texture tooling built on the engine's G-buffer probe.

The engine can render a clean screen->{UV,position,normal} map for the skinned
mesh (`QUINE_GBUFFER=uv|pos|normal` + the offscreen QUINE_THUMB path — see
shaders/skinned.glsl and apps/desktop/main.zig). That map is the inverse of the
UV unwrap, sampled per pixel, so it turns "where does this screen pixel live in
the texture" into a lookup — which makes two otherwise-hard jobs easy:

  project   Paint a 2D image onto a model's texture by aligning it in screen
            space (a stencil/decal projector). Align by telling it where the
            eyes are in your image; it finds the eyes on the model from the
            G-buffer and fits a similarity transform.

  transfer  Copy one model's albedo onto another model's UVs by closest-surface-
            point matching (the "transfer maps" / bake bridge between meshes).

Both write the result back into the target .glb's base-colour image.

Deps: numpy, pillow (already used by the offscreen thumbnail workflow). Needs a
built engine binary (zig-out/bin/quine) and Xvfb+Mesa for the headless render,
exactly like the QUINE_THUMB visual-verification path in CLAUDE.md.
"""
from __future__ import annotations
import argparse, io, json, os, struct, subprocess, sys, tempfile
import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINE = os.path.join(ROOT, "zig-out", "bin", "quine")


# ---------------------------------------------------------------- glb helpers
def _read_glb(path):
    data = open(path, "rb").read()
    total = struct.unpack("<III", data[:12])[2]
    off, chunks = 12, []
    while off < total:
        clen, ctype = struct.unpack("<II", data[off:off + 8])
        chunks.append([ctype, bytearray(data[off + 8:off + 8 + clen])])
        off += 8 + clen
    gltf = json.loads(chunks[0][1])
    binc = chunks[1][1] if len(chunks) > 1 else bytearray()
    return gltf, binc


def _write_glb(path, gltf, binc):
    nj = json.dumps(gltf, separators=(",", ":")).encode()
    nj += b" " * ((-len(nj)) % 4)
    nb = bytes(binc) + b"\x00" * ((-len(binc)) % 4)
    out = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(nj) + 8 + len(nb))
    out += struct.pack("<II", len(nj), 0x4E4F534A) + nj
    out += struct.pack("<II", len(nb), 0x004E4942) + nb
    open(path, "wb").write(out)


_CT = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2),
       5125: ("I", 4), 5126: ("f", 4)}
_NC = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def _accessor(gltf, binc, i):
    a = gltf["accessors"][i]; bv = gltf["bufferViews"][a["bufferView"]]
    base = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    fmt, sz = _CT[a["componentType"]]; nc = _NC[a["type"]]; cnt = a["count"]
    stride = bv.get("byteStride") or sz * nc
    out = np.empty((cnt, nc), float)
    for k in range(cnt):
        out[k] = struct.unpack_from("<" + fmt * nc, binc, base + k * stride)
    return out


def _diffuse_index(gltf):
    """bufferView index of the base-colour (Diffuse) image, by name or material."""
    for i, im in enumerate(gltf.get("images", [])):
        if "Diffuse" in (im.get("name") or "") and "bufferView" in im:
            return i, gltf["images"][i]["bufferView"]
    # fall back to the first material's baseColorTexture -> texture -> image
    mats = gltf.get("materials", [])
    if mats:
        bct = mats[0].get("pbrMetallicRoughness", {}).get("baseColorTexture")
        if bct is not None:
            src = gltf["textures"][bct["index"]]["source"]
            return src, gltf["images"][src]["bufferView"]
    raise SystemExit("no base-colour image found in glb")


def read_diffuse(path):
    gltf, binc = _read_glb(path)
    _, bvx = _diffuse_index(gltf)
    bv = gltf["bufferViews"][bvx]; s = bv.get("byteOffset", 0); l = bv["byteLength"]
    return Image.open(io.BytesIO(bytes(binc[s:s + l]))).convert("RGB")


def write_diffuse(path, image, out=None):
    """Replace the base-colour image bytes, rebuilding the BIN buffer + offsets."""
    gltf, binc = _read_glb(path)
    _, bvx = _diffuse_index(gltf)
    png = io.BytesIO(); image.save(png, format="PNG"); png = png.getvalue()
    bvs = gltf["bufferViews"]
    order = sorted(range(len(bvs)), key=lambda i: bvs[i].get("byteOffset", 0))
    nb = bytearray()
    for i in order:
        bv = bvs[i]; s = bv.get("byteOffset", 0); l = bv["byteLength"]
        blob = png if i == bvx else bytes(binc[s:s + l])
        nb += b"\x00" * ((-len(nb)) % 4)
        bv["byteOffset"] = len(nb); bv["byteLength"] = len(blob); nb += blob
    gltf["buffers"][0]["byteLength"] = len(nb) + ((-len(nb)) % 4)
    _write_glb(out or path, gltf, nb)


# ------------------------------------------------------------- G-buffer render
def render_gbuffer(scene_json, channel, size=512, engine=ENGINE):
    """Run the engine offscreen and return the {uv,pos,normal} map as HxWx3 uint8.

    `scene_json` is a path to a scene file framing the target model (its camera
    decides the view). Requires a built engine + Xvfb/Mesa, as in CLAUDE.md.
    """
    with tempfile.NamedTemporaryFile(suffix=".ppm", delete=False) as f:
        ppm = f.name
    env = dict(os.environ, QUINE_GBUFFER=channel, QUINE_THUMB="1",
               QUINE_THUMB_SCENE=scene_json, QUINE_THUMB_OUT=ppm,
               QUINE_THUMB_SIZE=str(size), LIBGL_ALWAYS_SOFTWARE="1",
               GALLIUM_DRIVER="llvmpipe")
    subprocess.run(["xvfb-run", "-a", engine], env=env, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    arr = np.asarray(Image.open(ppm).convert("RGB"))
    os.unlink(ppm)
    return arr


def _detect_model_eyes(uv):
    """Two eyeball centroids (screen px) from the UV map: the eye-island UVs sit
    at low-U / high-V, so they read green against the red/orange face skin."""
    R, G, B = uv[..., 0].astype(int), uv[..., 1].astype(int), uv[..., 2].astype(int)
    H, W = R.shape
    green = (G > 120) & (G > R + 25) & (B < 120)
    ys, xs = np.where(green)
    # keep the central upper cluster (drop stray green at the silhouette/neck)
    keep = (ys > H * 0.45) & (ys < H * 0.75) & (xs > W * 0.25) & (xs < W * 0.75)
    xs, ys = xs[keep], ys[keep]
    if len(xs) < 8:
        raise SystemExit("could not locate eyes in the UV map (is the model skinned/textured?)")
    mx = np.median(xs)
    L = np.array([xs[xs < mx].mean(), ys[xs < mx].mean()])
    R_ = np.array([xs[xs >= mx].mean(), ys[xs >= mx].mean()])
    return (L, R_) if L[0] < R_[0] else (R_, L)


def _similarity(src, dst):
    """2x3 affine mapping the 2 src points to the 2 dst points as a similarity
    (translation + uniform scale + rotation). src/dst are 2x2 arrays."""
    (x0, y0), (x1, y1) = src; (X0, Y0), (X1, Y1) = dst
    dx, dy = x1 - x0, y1 - y0; DX, DY = X1 - X0, Y1 - Y0
    den = dx * dx + dy * dy
    a = (dx * DX + dy * DY) / den; b = (dx * DY - dy * DX) / den
    M = np.array([[a, -b, X0 - a * x0 + b * y0],
                  [b, a, Y0 - b * x0 - a * y0]])
    return M


# ----------------------------------------------------------------- project (#4)
def cmd_project(args):
    scene = args.scene
    glb = args.glb or _glb_from_scene(scene)
    src = Image.open(args.image).convert("RGB"); SW, SH = src.size
    srcA = np.asarray(src)

    uv = render_gbuffer(scene, "uv", args.size)
    H, W, _ = uv.shape
    R, G, B = uv[..., 0].astype(float), uv[..., 1].astype(float), uv[..., 2].astype(float)
    face = (R + G) > 25  # any rendered mesh pixel (black background elsewhere)

    # screen->image alignment: your two eye points -> the model's detected eyes
    img_eyes = np.array(args.image_eyes, float).reshape(2, 2)
    model_eyes = np.array(_detect_model_eyes(uv))
    M = _similarity(np.array(model_eyes), img_eyes)  # screen -> image

    # scatter every face pixel's source colour into its texel (UV is exact here)
    TS = args.tex
    sumc = np.zeros((TS, TS, 3)); cnt = np.zeros((TS, TS))
    sy, sx = np.where(face)
    U = (R[face] / 255 * (TS - 1)).astype(int)
    V = (G[face] / 255 * (TS - 1)).astype(int)
    ix = M[0, 0] * sx + M[0, 1] * sy + M[0, 2]
    iy = M[1, 0] * sx + M[1, 1] * sy + M[1, 2]
    ok = (ix >= 0) & (ix < SW) & (iy >= 0) & (iy < SH)
    col = np.zeros((len(sx), 3)); col[ok] = srcA[iy[ok].astype(int), ix[ok].astype(int)]
    np.add.at(sumc, (V[ok], U[ok]), col[ok]); np.add.at(cnt, (V[ok], U[ok]), 1)
    hit = cnt > 0
    tex = np.zeros((TS, TS, 3)); tex[hit] = sumc[hit] / cnt[hit, None]
    tex, filled = _dilate(tex, hit, args.fill)

    base = np.asarray(read_diffuse(glb).resize((TS, TS))).astype(float)
    alpha = np.asarray(Image.fromarray((filled * 255).astype(np.uint8))
                       .filter(ImageFilter.GaussianBlur(args.feather))).astype(float) / 255
    out = (tex * alpha[..., None] + base * (1 - alpha[..., None])).astype(np.uint8)
    write_diffuse(glb, Image.fromarray(out), args.out)
    print(f"projected {args.image} onto {args.out or glb}  "
          f"(model eyes {model_eyes[0].round().tolist()},{model_eyes[1].round().tolist()}; "
          f"{int(hit.sum())} texels hit)")


def _dilate(img, mask, n):
    m = mask.copy(); out = img.copy()
    for _ in range(n):
        for dx, dy in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)]:
            sh = np.roll(np.roll(out, dy, 0), dx, 1)
            shm = np.roll(np.roll(m, dy, 0), dx, 1)
            f = (~m) & shm; out[f] = sh[f]; m[f] = True
    return out, m


def _glb_from_scene(scene):
    doc = json.load(open(scene))
    for e in doc.get("entities", []):
        g = e.get("geometry", {})
        if g.get("kind") == "gltf" and g.get("source"):
            cand = os.path.join(ROOT, "assets", g["source"])
            if os.path.exists(cand):
                return cand
            # the engine maps rpm.glb -> rpm-head.glb (see build.zig)
            alt = os.path.join(ROOT, "assets", g["source"].replace(".glb", "-head.glb"))
            if os.path.exists(alt):
                return alt
    raise SystemExit("no gltf entity found in scene; pass --glb explicitly")


# ---------------------------------------------------------------- transfer (#2)
def cmd_transfer(args):
    from scipy.spatial import cKDTree
    sg, sb = _read_glb(args.src)
    sp = sg["meshes"][0]["primitives"][0]
    s_pos = _accessor(sg, sb, sp["attributes"]["POSITION"])
    s_uv = _accessor(sg, sb, sp["attributes"]["TEXCOORD_0"])
    s_tex = np.asarray(read_diffuse(args.src)); STH, STW, _ = s_tex.shape

    # dense point cloud on the source surface (barycentric samples per triangle),
    # each carrying its UV, so a closest-point query returns a source texel.
    s_idx = _indices(sg, sb, sp)
    P, UVc = _sample_surface(s_pos, s_uv, s_idx, args.samples)
    tree = cKDTree(P)

    tg, tb = _read_glb(args.dst)
    tp = tg["meshes"][0]["primitives"][0]
    t_pos = _accessor(tg, tb, tp["attributes"]["POSITION"])
    t_uv = _accessor(tg, tb, tp["attributes"]["TEXCOORD_0"])
    t_idx = _indices(tg, tb, tp)

    # rasterize the target UV layout: for each texel, its 3D position, then find
    # the closest source surface point and copy that source texel's colour.
    TS = args.tex
    out = np.asarray(read_diffuse(args.dst).resize((TS, TS))).astype(np.uint8).copy()
    tposmap, tmask = _rasterize_positions(t_uv, t_pos, t_idx, TS)
    vy, vx = np.where(tmask)
    _, nn = tree.query(tposmap[vy, vx])
    su = (UVc[nn, 0] * (STW - 1)).astype(int) % STW
    sv = (UVc[nn, 1] * (STH - 1)).astype(int) % STH
    out[vy, vx] = s_tex[sv, su]
    write_diffuse(args.dst, Image.fromarray(out), args.out)
    print(f"transferred {args.src} -> {args.out or args.dst}  ({int(tmask.sum())} texels)")


def _indices(gltf, binc, prim):
    a = gltf["accessors"][prim["indices"]]; bv = gltf["bufferViews"][a["bufferView"]]
    fmt, sz = _CT[a["componentType"]]
    base = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    return np.array(struct.unpack_from("<" + fmt * a["count"], binc, base)).reshape(-1, 3)


def _sample_surface(pos, uv, idx, per_tri):
    A, B, C = pos[idx[:, 0]], pos[idx[:, 1]], pos[idx[:, 2]]
    Au, Bu, Cu = uv[idx[:, 0]], uv[idx[:, 1]], uv[idx[:, 2]]
    w = np.random.dirichlet((1, 1, 1), size=(len(idx), per_tri))  # ntri x k x 3
    P = (w[..., 0:1] * A[:, None] + w[..., 1:2] * B[:, None] + w[..., 2:3] * C[:, None]).reshape(-1, 3)
    U = (w[..., 0:1] * Au[:, None] + w[..., 1:2] * Bu[:, None] + w[..., 2:3] * Cu[:, None]).reshape(-1, 2)
    return P, U


def _rasterize_positions(uv, pos, idx, TS):
    """Scan-fill each UV triangle, writing the barycentric-interpolated 3D
    position into a TSxTS map (+ a coverage mask)."""
    posmap = np.zeros((TS, TS, 3)); mask = np.zeros((TS, TS), bool)
    P = uv[idx] * (TS - 1)  # ntri x 3 x 2 in texel space
    V = pos[idx]
    for t in range(len(idx)):
        (x0, y0), (x1, y1), (x2, y2) = P[t]
        minx, maxx = int(max(0, np.floor(min(x0, x1, x2)))), int(min(TS - 1, np.ceil(max(x0, x1, x2))))
        miny, maxy = int(max(0, np.floor(min(y0, y1, y2)))), int(min(TS - 1, np.ceil(max(y0, y1, y2))))
        if maxx < minx or maxy < miny:
            continue
        xs, ys = np.meshgrid(np.arange(minx, maxx + 1), np.arange(miny, maxy + 1))
        d = (y1 - y2) * (x0 - x2) + (x2 - x1) * (y0 - y2)
        if abs(d) < 1e-9:
            continue
        a = ((y1 - y2) * (xs - x2) + (x2 - x1) * (ys - y2)) / d
        b = ((y2 - y0) * (xs - x2) + (x0 - x2) * (ys - y2)) / d
        c = 1 - a - b
        inside = (a >= -1e-4) & (b >= -1e-4) & (c >= -1e-4)
        if not inside.any():
            continue
        P3 = a[..., None] * V[t, 0] + b[..., None] * V[t, 1] + c[..., None] * V[t, 2]
        yy, xx = ys[inside], xs[inside]
        posmap[yy, xx] = P3[inside]; mask[yy, xx] = True
    return posmap, mask


# --------------------------------------------------------------------- gbuffer
def cmd_gbuffer(args):
    arr = render_gbuffer(args.scene, args.channel, args.size)
    Image.fromarray(arr).save(args.out)
    print(f"wrote {args.channel} G-buffer -> {args.out}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("project", help="paint a 2D image onto a model's texture (decal projector)")
    p.add_argument("--scene", required=True, help="scene file framing the model (its camera = the view)")
    p.add_argument("--image", required=True, help="source image to project")
    p.add_argument("--image-eyes", nargs=4, type=float, required=True,
                   metavar=("LX", "LY", "RX", "RY"), help="eye centres in the source image (px)")
    p.add_argument("--glb", help="target glb (default: inferred from the scene)")
    p.add_argument("--out", help="output glb (default: overwrite target)")
    p.add_argument("--size", type=int, default=768, help="G-buffer render resolution")
    p.add_argument("--tex", type=int, default=1024, help="texture resolution")
    p.add_argument("--fill", type=int, default=2, help="dilation passes to fill scatter gaps")
    p.add_argument("--feather", type=float, default=3, help="composite edge feather (px)")
    p.set_defaults(func=cmd_project)

    t = sub.add_parser("transfer", help="copy one model's albedo onto another's UVs (closest-point)")
    t.add_argument("--src", required=True, help="source glb (has the texture to copy)")
    t.add_argument("--dst", required=True, help="target glb (receives it on its own UVs)")
    t.add_argument("--out", help="output glb (default: overwrite dst)")
    t.add_argument("--tex", type=int, default=1024, help="texture resolution")
    t.add_argument("--samples", type=int, default=24, help="surface samples per source triangle")
    t.set_defaults(func=cmd_transfer)

    g = sub.add_parser("gbuffer", help="dump a screen->{uv,pos,normal} map")
    g.add_argument("--scene", required=True)
    g.add_argument("--channel", choices=["uv", "pos", "normal"], default="uv")
    g.add_argument("--size", type=int, default=512)
    g.add_argument("--out", default="gbuffer.png")
    g.set_defaults(func=cmd_gbuffer)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
