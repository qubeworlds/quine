#!/usr/bin/env python3
# gen-city.py — a BUILD-TIME content tool (never shipped in any wasm): generate
# the `city` example scene from REAL OpenStreetMap building footprints of Dubai
# Marina / JBR, plus baked facade textures. "Scenes are data" taken literally:
# the skyline is recognisably the real district because every tower is the
# minimum rotated rectangle of its actual footprint at its tagged height.
#
#   python3 tools/gen-city.py             # uses tools/city-osm-cache.json if present
#   python3 tools/gen-city.py --fetch     # refresh the OSM cache from Overpass first
#
# Writes:
#   modules/core/city.scene.json     the scene (committed, published to the CDN)
#   assets/city/*.png                baked facade / ground textures (committed)
#   tools/city-osm-cache.json        the raw Overpass response (committed, so
#                                    regeneration is deterministic and offline)
#
# Data © OpenStreetMap contributors, ODbL — see assets/ATTRIBUTION.md.

import json
import math
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CACHE = os.path.join(HERE, 'city-osm-cache.json')
TEXDIR = os.path.join(ROOT, 'assets', 'city')
SCENE_OUT = os.path.join(ROOT, 'modules', 'core', 'city.scene.json')

# Dubai Marina + JBR (south-west of the Palm). The camera stands on JBR beach.
BBOX = (25.062, 55.118, 25.095, 55.152)  # (s, w, n, e)
BEACH = (25.0762, 55.1338)               # lat/lon of the local origin (inside JBR)

# Coast frame, from the PCA long axis of all footprints: the shoreline runs
# ENE, the Gulf is to the NNW. "along" is coast-parallel, "perp" is seaward.
AX, AZ = 0.877, 0.481    # coast-parallel unit (x = east, z = north)
PX, PZ = -0.481, 0.877   # coast-normal unit, pointing at the sea


def to_xz(along, perp):
    return (along * AX + perp * PX, along * AZ + perp * PZ)


def to_coast(x, z):
    return (x * AX + z * AZ, x * PX + z * PZ)

random.seed(20260704)


def fetch_osm():
    q = f'[out:json][timeout:60];way["building"]({BBOX[0]},{BBOX[1]},{BBOX[2]},{BBOX[3]});out geom;'
    url = 'https://overpass-api.de/api/interpreter?data=' + __import__('urllib.parse', fromlist=['quote']).quote(q)
    print('fetching OSM buildings from Overpass…')
    out = subprocess.run(['curl', '-fsS', '--max-time', '120', '-A', 'quine-city-gen/1.0 (qubeworlds.com)', url],
                         capture_output=True, check=True).stdout
    open(CACHE, 'wb').write(out)
    print(f'  cached {len(out)//1024} KiB -> {CACHE}')


# ---- geometry ----------------------------------------------------------------
def project(lat, lon, lat0, lon0):
    """Equirectangular metres around (lat0, lon0): x = east, z = NORTH."""
    kx = 111320.0 * math.cos(math.radians(lat0))
    kz = 110540.0
    return ((lon - lon0) * kx, (lat - lat0) * kz)


def convex_hull(pts):
    pts = sorted(set(pts))
    if len(pts) <= 2:
        return pts
    def cross(o, a, b):
        return (a[0]-o[0])*(b[1]-o[1]) - (a[1]-o[1])*(b[0]-o[0])
    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0: lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0: upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


def min_rot_rect(pts):
    """Minimum-area rotated rectangle over the convex hull (rotating calipers).
    Returns (cx, cz, half_w, half_d, yaw)."""
    hull = convex_hull(pts)
    if len(hull) < 3:
        xs = [p[0] for p in pts]; zs = [p[1] for p in pts]
        return ((min(xs)+max(xs))/2, (min(zs)+max(zs))/2,
                max(1.0, (max(xs)-min(xs))/2), max(1.0, (max(zs)-min(zs))/2), 0.0)
    best = None
    n = len(hull)
    for i in range(n):
        ex, ez = hull[(i+1) % n][0]-hull[i][0], hull[(i+1) % n][1]-hull[i][1]
        L = math.hypot(ex, ez)
        if L < 1e-9: continue
        ux, uz = ex/L, ez/L               # edge direction
        vx, vz = -uz, ux                  # its normal
        us = [p[0]*ux + p[1]*uz for p in hull]
        vs = [p[0]*vx + p[1]*vz for p in hull]
        area = (max(us)-min(us)) * (max(vs)-min(vs))
        if best is None or area < best[0]:
            cu, cv = (max(us)+min(us))/2, (max(vs)+min(vs))/2
            best = (area,
                    cu*ux + cv*vx, cu*uz + cv*vz,          # center
                    (max(us)-min(us))/2, (max(vs)-min(vs))/2,
                    math.atan2(uz, ux))
    _, cx, cz, hw, hd, ang = best
    return (cx, cz, hw, hd, ang)


def building_height(tags, half_w, half_d):
    try:
        if 'height' in tags:
            return max(4.0, min(340.0, float(str(tags['height']).replace('m', '').strip())))
    except ValueError:
        pass
    try:
        if 'building:levels' in tags:
            return max(4.0, min(340.0, float(tags['building:levels']) * 3.2))
    except ValueError:
        pass
    # untagged: podium-ish for big footprints, low for small
    return 10.0 if half_w * half_d < 250 else 22.0


# ---- facade textures ----------------------------------------------------------
def bake_textures():
    from PIL import Image, ImageDraw
    os.makedirs(TEXDIR, exist_ok=True)
    names = []

    # JBR-style plaster palettes (base, band) and glass-curtain palettes.
    plaster = [((225, 205, 168), (200, 175, 135)),
               ((214, 189, 152), (176, 148, 112)),
               ((201, 176, 146), (222, 202, 170)),
               ((189, 168, 140), (160, 138, 110))]
    row_buckets = [10, 20, 34]  # window rows per texture — matched to floors

    def facade(base, band, rows, cols, glass_ratio, name):
        W = H = 256
        im = Image.new('RGB', (W, H), base)
        d = ImageDraw.Draw(im)
        # horizontal floor bands
        for r in range(rows):
            y0 = int(r * H / rows)
            d.rectangle([0, y0, W, y0 + max(1, H // (rows * 6))], fill=band)
        # window grid
        for r in range(rows):
            for c in range(cols):
                x0 = int((c + 0.18) * W / cols); x1 = int((c + 0.82) * W / cols)
                y0 = int((r + 0.30) * H / rows); y1 = int((r + 0.88) * H / rows)
                v = random.random()
                if v < glass_ratio:
                    col = (96 + int(30*random.random()), 130 + int(30*random.random()), 165 + int(40*random.random()))
                else:
                    col = (70 + int(25*random.random()),) * 3
                d.rectangle([x0, y0, x1, y1], fill=col)
        im.save(os.path.join(TEXDIR, name))
        names.append(name)

    for pi, (base, band) in enumerate(plaster):
        for rows in row_buckets:
            facade(base, band, rows, max(6, rows // 2), 0.55, f'facade_p{pi}_r{rows}.png')
    # glass curtain walls (two tints)
    for gi, tint in enumerate([(120, 158, 190), (105, 140, 150)]):
        for rows in row_buckets[1:]:
            facade(tint, tuple(int(t*0.8) for t in tint), rows, rows // 2, 0.92, f'facade_g{gi}_r{rows}.png')

    # sand: speckled warm noise
    from PIL import Image as I
    im = I.new('RGB', (256, 256))
    px = im.load()
    for y in range(256):
        for x in range(256):
            n = random.random()
            px[x, y] = (int(226 - 18*n), int(206 - 20*n), int(168 - 22*n))
    im.save(os.path.join(TEXDIR, 'sand.png')); names.append('sand.png')
    return names


# ---- scene assembly -----------------------------------------------------------
def main():
    if '--fetch' in sys.argv or not os.path.exists(CACHE):
        fetch_osm()
    data = json.load(open(CACHE))
    lat0, lon0 = BEACH
    tex_names = bake_textures()
    row_buckets = [10, 20, 34]

    towers = []
    for el in data.get('elements', []):
        if el.get('type') != 'way' or 'geometry' not in el:
            continue
        pts = [project(g['lat'], g['lon'], lat0, lon0) for g in el['geometry']]
        if len(pts) < 3:
            continue
        cx, cz, hw, hd, yaw = min_rot_rect(pts)
        if hw < 3 or hd < 3:
            continue
        h = building_height(el.get('tags', {}), hw, hd)
        towers.append((cx, cz, hw, hd, yaw, h))

    # keep the scene inside the entity budget: sort by (tall first, then near
    # the beach), cap the count.
    towers.sort(key=lambda t: (-t[5], math.hypot(t[0], t[1])))
    towers = towers[:820]
    print(f'{len(towers)} towers (of {sum(1 for e in data.get("elements", []) if e.get("type")=="way")} OSM ways)')

    ents = []
    E = ents.append
    # Camera: the photo's framing — standing ON the sand, looking slightly up
    # and obliquely at the JBR beachfront wall so it recedes down-coast.
    # The BEACH origin is actually INSIDE the JBR blocks (Rimal), so the eye
    # must be placed in the coast frame: seaward of the wall's front line.
    wall = []           # tall towers near the origin, excl. Bluewaters island
    front = -1e9        # most-seaward footprint extent of that wall
    for cx, cz, hw, hd, _, h in towers:
        ac, pc = to_coast(cx, cz)
        if abs(ac) < 450 and pc < 900 and h > 90:
            wall.append((ac, pc, h))
            front = max(front, pc + max(hw, hd))
    row = [w for w in wall if w[1] > -250] or wall   # the beachfront row only
    W = sum(w[2] for w in row)
    tac = sum(w[0] * w[2] for w in row) / W
    tpc = sum(w[1] * w[2] for w in row) / W
    tx, tz = to_xz(tac, tpc)
    eac, epc = tac + 240.0, front + 110.0            # on the sand, down-coast
    ex, ez = to_xz(eac, epc)
    target_y, eye_y = 70.0, 3.0
    dist = math.sqrt((tx - ex) ** 2 + (target_y - eye_y) ** 2 + (tz - ez) ** 2)
    # engine orbit: eye = target + d·(cosθ·sinψ, sinθ, cosθ·cosψ)
    yaw = math.atan2(ex - tx, ez - tz)
    pitch = math.asin(max(-0.9, min(0.9, (eye_y - target_y) / dist)))
    E({"name": "camera",
       "camera": {"fovY": 0.85, "near": 0.5, "far": 4200,
                  "controller": {"kind": "orbit", "target": [round(tx, 1), target_y, round(tz, 1)],
                                  "distance": round(dist, 1), "yaw": round(yaw, 3), "pitch": round(pitch, 4)}},
       "post": {"tonemap": "aces", "exposure": 0.92, "bloom_threshold": 1.0, "bloom_intensity": 0.12}})
    E({"name": "sun", "light": {"kind": "directional", "direction": [-0.35, -0.62, 0.42],
                                 "color": [1.0, 0.96, 0.88], "intensity": 1.05,
                                 "castShadows": True, "shadowMapSize": 4096}})
    E({"name": "sky", "environment": {
        "sky": {"zenith": [0.36, 0.52, 0.74], "horizon": [0.83, 0.80, 0.72]},
        "ambient": {"color": [1.0, 0.98, 0.92], "intensity": 0.40},
        "fog": {"color": [0.83, 0.80, 0.72], "density": 0.0011}}})

    # ground: one big sand plane (the whole district floor reads as haze-washed
    # ground at this framing), sea to the south-east of the beach line.
    E({"name": "sand", "geometry": {"kind": "box", "half": [2400, 1, 2400]},
       "transform": {"position": [0, -1, 0]},
       "material": {"color": [0.97, 0.94, 0.86, 1], "roughness": 0.95, "texture": "sand.png"},
       "shadow": {"cast": False}})
    # Sea: a coast-aligned slab whose landward edge sits at the waterline, a
    # little seaward of the eye. Must be rotated into the coast frame or its
    # axis-aligned corners flood the beach.
    waterline = epc + 60.0
    sea_x, sea_z = to_xz(eac, waterline + 1300)
    E({"name": "sea", "geometry": {"kind": "box", "half": [2600, 1, 1300]},
       "transform": {"position": [round(sea_x, 1), -0.2, round(sea_z, 1)],
                      "rotation": [0, round(-math.atan2(AZ, AX), 4), 0]},
       "material": {"color": [0.16, 0.42, 0.52, 1], "roughness": 0.15, "metallic": 0.55},
       "shadow": {"cast": False}})

    # towers — real footprints. Texture: palette by hash, row bucket by floors.
    for i, (cx, cz, hw, hd, yaw, h) in enumerate(towers):
        floors = max(2, h / 3.2)
        rows = min(row_buckets, key=lambda r: abs(r - floors))
        if h > 60 and random.random() < 0.18:
            tex = f'facade_g{random.randrange(2)}_r{max(20, rows)}.png'
        else:
            tex = f'facade_p{random.randrange(4)}_r{rows}.png'
        g = 0.86 + 0.1 * random.random()
        E({"name": f"b{i}", "geometry": {"kind": "box", "half": [round(hw, 2), round(h/2, 2), round(hd, 2)]},
           "transform": {"position": [round(cx, 2), round(h/2, 2), round(cz, 2)],
                          "rotation": [0, round(-yaw, 4), 0]},
           "material": {"color": [g, g, g, 1], "roughness": 0.72, "metallic": 0.06, "texture": tex}})

    # beach foreground: cabana daybeds (posts + canopy + base) + a few palms.
    def cabana(idx, x, z, yaw):
        c, s = math.cos(yaw), math.sin(yaw)
        E({"name": f"cb{idx}", "geometry": {"kind": "box", "half": [1.7, 0.35, 1.4]},
           "transform": {"position": [x, 0.45, z], "rotation": [0, yaw, 0]},
           "material": {"color": [0.52, 0.44, 0.34, 1], "roughness": 0.85}})
        E({"name": f"cbm{idx}", "geometry": {"kind": "box", "half": [1.5, 0.09, 1.2]},
           "transform": {"position": [x, 0.9, z], "rotation": [0, yaw, 0]},
           "material": {"color": [0.82, 0.79, 0.72, 1], "roughness": 0.9}})
        for px_, pz_ in ((-1.5, -1.2), (1.5, -1.2), (-1.5, 1.2), (1.5, 1.2)):
            wx, wz = x + px_*c - pz_*s, z + px_*s + pz_*c
            E({"name": f"cbp{idx}_{px_}_{pz_}", "geometry": {"kind": "cylinder", "radius": 0.07, "height": 2.5},
               "transform": {"position": [wx, 1.25, wz]},
               "material": {"color": [0.35, 0.28, 0.2, 1], "roughness": 0.8}})
        E({"name": f"cbr{idx}", "geometry": {"kind": "box", "half": [1.9, 0.06, 1.6]},
           "transform": {"position": [x, 2.55, z], "rotation": [0, yaw, 0]},
           "material": {"color": [0.9, 0.87, 0.8, 1], "roughness": 0.9, "doubleSided": True}})

    def palm(idx, x, z):
        h = 6 + 3 * random.random()
        E({"name": f"pt{idx}", "geometry": {"kind": "cylinder", "radius": 0.22, "height": h},
           "transform": {"position": [x, h/2, z], "rotation": [0.06*random.random(), 0, 0.05]},
           "material": {"color": [0.45, 0.36, 0.26, 1], "roughness": 0.9}})
        E({"name": f"pl{idx}", "geometry": {"kind": "cone", "radius": 3.1, "height": 0.9},
           "transform": {"position": [x, h + 0.15, z], "rotation": [math.pi, 0, 0]},
           "material": {"color": [0.2, 0.4, 0.18, 1], "roughness": 0.85}})
        E({"name": f"pl2{idx}", "geometry": {"kind": "cone", "radius": 2.1, "height": 0.8},
           "transform": {"position": [x, h + 0.75, z], "rotation": [math.pi, 0, 0.12]},
           "material": {"color": [0.24, 0.46, 0.21, 1], "roughness": 0.85}})

    # Beach set: between the EYE and the wall — two rows of daybeds a short way
    # along the view direction, palms flanking them.
    dxz = math.hypot(tx - ex, tz - ez)
    vx, vz = (tx - ex) / dxz, (tz - ez) / dxz
    px_, pz_ = -vz, vx  # perpendicular, for the row spread
    for k in range(8):
        along = 38 + (k // 4) * 22
        side = ((k % 4) - 1.5) * 16
        cabana(k, ex + along * vx + side * px_ + random.uniform(-2, 2),
               ez + along * vz + side * pz_ + random.uniform(-2, 2),
               math.atan2(vx, vz) + random.uniform(-0.25, 0.25))
    for k in range(6):
        along = 26 + random.uniform(0, 10)
        side = ((k % 6) - 2.5) * 26
        palm(k, ex + along * vx + side * px_, ez + along * vz + side * pz_)

    scene = {
        "schemaVersion": 1,
        "name": "city",
        "comment": "Dubai Marina / JBR from real OSM footprints (© OpenStreetMap contributors, ODbL). Generated by tools/gen-city.py — edit the generator, not this file.",
        # No preferredBackend pin: webgpu verified on Safari 26 (2026-07-04)
        # after the sky-pass bind fix (engine 50cad0d) — textures, fog and the
        # 4096 shadow map all render there. History in docs/TODO.md §0.
        "assets": [{"name": n, "url": n} for n in tex_names],
        "entities": ents,
    }
    json.dump(scene, open(SCENE_OUT, 'w'))
    print(f'{len(ents)} entities -> {SCENE_OUT} ({os.path.getsize(SCENE_OUT)//1024} KiB), {len(tex_names)} textures -> {TEXDIR}')


if __name__ == '__main__':
    main()
