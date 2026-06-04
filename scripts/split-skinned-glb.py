#!/usr/bin/env python3
"""Split a skinned glTF (.glb) mesh into parts by which bones drive it.

A merged avatar (e.g. Ready Player Me) is one skinned mesh: head, torso, hands
and outfit all share a vertex buffer, a skin and a texture atlas, separated only
by which joints weight each vertex. This tool carves that single mesh into two
files along a set of joint-name prefixes:

  --extract PREFIX...   bones whose vertices go to the EXTRACT file
                        (everything else stays in the KEEP file)

A triangle is assigned to EXTRACT when a majority of its 3 vertices are
dominantly weighted to an extract bone; otherwise it stays in KEEP. Only the
index buffer is rewritten — vertices, skin, morph targets and textures are left
untouched and shared by both outputs, so the split is lossless and reversible
(re-running with the complementary prefixes reproduces the other half).

Example — peel the floating hands off a half-body avatar, keeping head+torso:

  scripts/split-skinned-glb.py assets/rpm-half-body.glb \\
      --keep-out assets/rpm-head.glb \\
      --extract-out assets/rpm-hands.glb \\
      --extract LeftHand RightHand

Only the first primitive of meshes[0] is split (the merged avatar body); other
meshes (e.g. a transparent eyelash layer) are carried through unchanged.
"""
import argparse
import copy
import json
import struct
import sys

GLB_MAGIC = 0x46546C67
CHUNK_JSON = 0x4E4F534A
CHUNK_BIN = 0x004E4942
COMP_FMT = {5120: "b", 5121: "B", 5122: "h", 5123: "H", 5125: "I", 5126: "f"}
COMP_SIZE = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def read_glb(path):
    d = open(path, "rb").read()
    if struct.unpack_from("<I", d, 0)[0] != GLB_MAGIC:
        sys.exit(f"{path}: not a .glb")
    off = 12
    jlen, jtyp = struct.unpack_from("<II", d, off)
    assert jtyp == CHUNK_JSON, "first chunk must be JSON"
    js = json.loads(d[off + 8 : off + 8 + jlen])
    off += 8 + jlen
    blen, btyp = struct.unpack_from("<II", d, off)
    assert btyp == CHUNK_BIN, "second chunk must be BIN"
    binc = d[off + 8 : off + 8 + blen]
    return js, binc


def accessor_view(js, binc, ai):
    a = js["accessors"][ai]
    bv = js["bufferViews"][a["bufferView"]]
    base = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    ncomp = NCOMP[a["type"]]
    elem = COMP_SIZE[a["componentType"]] * ncomp
    stride = bv.get("byteStride") or elem
    return base, stride, a["componentType"], a["count"], ncomp


def dominant_is_extract(js, binc, prim, extract_prefixes):
    """Boolean per vertex: is its highest-weighted joint an extract bone?"""
    skin = js["skins"][0]
    names = [js["nodes"][j].get("name", "") for j in skin["joints"]]
    extract = [
        any(n.startswith(p) for p in extract_prefixes) for n in names
    ]
    jb, js_, jc, jn, _ = accessor_view(js, binc, prim["attributes"]["JOINTS_0"])
    wb, ws, _, _, _ = accessor_view(js, binc, prim["attributes"]["WEIGHTS_0"])
    jfmt = COMP_FMT[jc]
    flags = bytearray(jn)
    for i in range(jn):
        joints = struct.unpack_from("<4" + jfmt, binc, jb + i * js_)
        weights = struct.unpack_from("<4f", binc, wb + i * ws)
        dom = joints[max(range(4), key=lambda k: weights[k])]
        flags[i] = 1 if extract[dom] else 0
    return flags


def read_indices(binc, base, comp, count):
    return list(struct.unpack_from("<%d%s" % (count, COMP_FMT[comp]), binc, base))


def write_glb(js, binc, new_indices, prim_path, path):
    """Clone the glb with meshes[m].primitives[p].indices replaced by a fresh
    UINT32 accessor over `new_indices` appended to the binary chunk."""
    j = copy.deepcopy(js)
    buf = bytearray(binc)
    while len(buf) % 4:
        buf.append(0)
    off = len(buf)
    payload = struct.pack("<%dI" % len(new_indices), *new_indices)
    buf += payload
    while len(buf) % 4:
        buf.append(0)
    j["bufferViews"].append({"buffer": 0, "byteOffset": off, "byteLength": len(payload)})
    j["accessors"].append(
        {"bufferView": len(j["bufferViews"]) - 1, "componentType": 5125,
         "count": len(new_indices), "type": "SCALAR"}
    )
    m, p = prim_path
    j["meshes"][m]["primitives"][p]["indices"] = len(j["accessors"]) - 1
    if j.get("buffers"):
        j["buffers"][0]["byteLength"] = len(buf)
    jb = json.dumps(j, separators=(",", ":")).encode()
    while len(jb) % 4:
        jb += b" "
    total = 12 + 8 + len(jb) + 8 + len(buf)
    out = struct.pack("<III", GLB_MAGIC, 2, total)
    out += struct.pack("<II", len(jb), CHUNK_JSON) + jb
    out += struct.pack("<II", len(buf), CHUNK_BIN) + bytes(buf)
    open(path, "wb").write(out)
    return total


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src", help="source .glb (a merged skinned avatar)")
    ap.add_argument("--extract", nargs="+", required=True, metavar="PREFIX",
                    help="joint-name prefixes whose triangles are peeled off")
    ap.add_argument("--keep-out", required=True, help="output .glb for the kept part")
    ap.add_argument("--extract-out", required=True, help="output .glb for the extracted part")
    args = ap.parse_args()

    js, binc = read_glb(args.src)
    prim = js["meshes"][0]["primitives"][0]
    flags = dominant_is_extract(js, binc, prim, args.extract)

    ib, _, ic, icnt, _ = accessor_view(js, binc, prim["indices"])
    idx = read_indices(binc, ib, ic, icnt)
    keep, extract = [], []
    for t in range(icnt // 3):
        tri = idx[t * 3 : t * 3 + 3]
        votes = flags[tri[0]] + flags[tri[1]] + flags[tri[2]]
        (extract if votes >= 2 else keep).extend(tri)

    print(f"vertices {len(flags)}  extract-verts {sum(flags)}  "
          f"triangles {icnt // 3}  keep {len(keep)//3}  extract {len(extract)//3}")
    kb = write_glb(js, binc, keep, (0, 0), args.keep_out)
    eb = write_glb(js, binc, extract, (0, 0), args.extract_out)
    print(f"wrote {args.keep_out} ({kb} B) and {args.extract_out} ({eb} B)")


if __name__ == "__main__":
    main()
