// raymarch.glsl — single shader source, cross-compiled to every backend by
// sokol-shdc at build time (do NOT hand-write per-backend variants).
//
// Sphere-traces an SDF/CSG scene supplied as a bounded uniform array of nodes
// (the GPU mirror of core's `SdfScene`). A vertex-less fullscreen triangle (the
// same gl_VertexIndex trick as triangle.glsl's bg_vs) covers the frame; the
// fragment shader reconstructs a camera ray per pixel and marches `mapScene`.
//
// Node packing (3 vec4 per node, MAX_NODES nodes):
//   a = (center.x, center.y, center.z, prim + 8*op + 64*new_object)
//       prim: 0 sphere 1 box 2 round_box 3 cone   op: 0 union 1 smooth-union 2 subtract
//       new_object: 1 starts an independent SDF object ("meshlet"); the scene is N
//       such objects packed back-to-back, composited by nearest hit (not unioned).
//   b = (half.x,   half.y,   half.z,   radius)        radius: sphere r / round_box rounding / cone base r
//   c = (color.r,  color.g,  color.b,  k)             k: smooth-blend factor

@vs raymarch_vs
out vec2 ndc;
void main() {
    float x = float((gl_VertexIndex & 1) << 2) - 1.0; // -1 or 3
    float y = float((gl_VertexIndex & 2) << 1) - 1.0; // -1 or 3
    gl_Position = vec4(x, y, 0.5, 1.0);
    ndc = vec2(x, y); // interpolates to the per-pixel NDC coordinate (-1..1 on-screen)
}
@end

@fs raymarch_fs
#define MAX_NODES 32

#define MAX_POINT_LIGHTS 8

layout(binding=0) uniform rm_params {
    vec4 cam_eye;   // xyz eye,    w = tan(fovy/2)
    vec4 cam_right; // xyz right,  w = aspect
    vec4 cam_up;    // xyz up,     w = node_count
    vec4 cam_fwd;   // xyz forward,w = time
    vec4 scene_min; // xyz scene AABB min (empty-space skip), w = 1 if the backend's
                    // NDC depth is [-1,1] (GL) — selects the gl_FragDepth mapping
    vec4 scene_max; // xyz scene AABB max
    mat4 view_proj; // the frame's view-projection, for hit-point depth output
    // Scene lighting (docs/lights-and-tones.md) — same packing as
    // triangle.glsl's fs_lights; all-zeros-except-exposure=1 = legacy look.
    vec4 sun_dir_int;  // xyz = direction the sun light travels, w = intensity
    vec4 sun_color;    // rgb sun colour, w = has_env
    vec4 ambient_ci;   // rgb ambient tint, w = ambient intensity
    vec4 sky_zenith;   // rgb sky top, w = exposure
    vec4 sky_horizon;  // rgb sky horizon, w = tonemap (0 none, 1 aces)
    vec4 point_pos[MAX_POINT_LIGHTS]; // xyz world position, w = range
    vec4 point_col[MAX_POINT_LIGHTS]; // rgb colour, w = intensity
    vec4 nodes[MAX_NODES * 3];
    mat4 sun_shadow_mvp; // world -> sun clip ([0,1] z); shadow_params.x gates
    vec4 shadow_params;  // x = enabled, y = texel size, z = depth bias
};
// The sun shadow map (mesh casters onto the SDF stone) — 16-bit depth packed
// into RG of an RGBA8 target, NEAREST-sampled.
layout(binding=0) uniform texture2D shadow_tex;
layout(binding=0) uniform sampler shadow_smp;

float shadowDepth(vec2 suv) {
    vec2 enc = texture(sampler2D(shadow_tex, shadow_smp), suv).rg;
    return enc.x + enc.y * (1.0 / 255.0);
}

float meshShadow(vec3 wp) {
    if (shadow_params.x < 0.5) return 1.0;
    vec4 clip = sun_shadow_mvp * vec4(wp, 1.0);
    vec3 sndc = clip.xyz / max(clip.w, 1e-6);
    vec2 suv = sndc.xy * 0.5 + 0.5;
    if (suv.x <= 0.0 || suv.x >= 1.0 || suv.y <= 0.0 || suv.y >= 1.0) return 1.0;
    float d = sndc.z - shadow_params.z;
    float tx = shadow_params.y;
    float lit = 0.0;
    lit += d <= shadowDepth(suv + vec2(-0.5, -0.5) * tx) ? 1.0 : 0.0;
    lit += d <= shadowDepth(suv + vec2(0.5, -0.5) * tx) ? 1.0 : 0.0;
    lit += d <= shadowDepth(suv + vec2(-0.5, 0.5) * tx) ? 1.0 : 0.0;
    lit += d <= shadowDepth(suv + vec2(0.5, 0.5) * tx) ? 1.0 : 0.0;
    return lit * 0.25;
}

in vec2 ndc;
out vec4 frag_color;

float sdBox(vec3 q, vec3 b) {
    vec3 d = abs(q) - b;
    return length(max(d, 0.0)) + min(max(d.x, max(d.y, d.z)), 0.0);
}

// Capped cone along +Z: sharp apex at q.z=+h.z, base radius `r` at q.z=-h.z.
// A drill bit's point. (IQ capped-cone, r1=0 top, r2=r bottom, axis Z.)
float sdConeZ(vec3 p, float ha, float r) {
    vec2 q = vec2(length(p.xy), p.z);
    vec2 k1 = vec2(r, -ha);
    vec2 k2 = vec2(r, 2.0 * ha);
    vec2 ca = vec2(q.x - min(q.x, (q.y < 0.0) ? r : 0.0), abs(q.y) - ha);
    vec2 cb = q - k1 + k2 * clamp(dot(k1 - q, k2) / dot(k2, k2), 0.0, 1.0);
    float s = (cb.x < 0.0 && ca.y < 0.0) ? -1.0 : 1.0;
    return s * sqrt(min(dot(ca, ca), dot(cb, cb)));
}

// Marble flag of the nearest surface, written by mapScene alongside its colour.
float g_marble = 0.0;

// returns vec4(distance, color.rgb). The node buffer is N independent objects
// (each begun by a `new_object` node); we fold within an object, then take the
// NEAREST object — so the wall, the drill, etc. composite as separate solids.
vec4 mapScene(vec3 p) {
    float dTot = 1e9; vec3 colTot = vec3(0.80, 0.80, 0.85); float mTot = 0.0;
    float dSub = 1e9; vec3 colSub = vec3(0.80, 0.80, 0.85); float mSub = 0.0;
    int count = int(cam_up.w);
    for (int i = 0; i < MAX_NODES; i++) {
        if (i >= count) break;
        vec4 a = nodes[i * 3 + 0];
        vec4 b = nodes[i * 3 + 1];
        vec4 c = nodes[i * 3 + 2];
        bool newObj = (mod(a.w, 128.0) >= 64.0) || (i == 0);
        bool nodeMarble = a.w >= 128.0;
        float wm = mod(a.w, 64.0);
        int prim = int(mod(wm, 8.0));
        int op = int(floor(wm / 8.0));
        float k = c.w;
        vec3 q = p - a.xyz;
        float di;
        if (prim == 0) di = length(q) - b.w;
        else if (prim == 1) di = sdBox(q, b.xyz);
        else if (prim == 2) di = sdBox(q, b.xyz) - b.w;
        else di = sdConeZ(q, b.z, b.w);

        float mi = nodeMarble ? 1.0 : 0.0;
        if (newObj) {
            if (dSub < dTot) { dTot = dSub; colTot = colSub; mTot = mSub; } // close the previous object
            dSub = di; colSub = c.rgb; mSub = mi;                            // begin a new object
        } else if (op == 0) {
            if (di < dSub) { dSub = di; colSub = c.rgb; mSub = mi; }
        } else if (op == 1) {
            float h = clamp(0.5 + 0.5 * (di - dSub) / max(k, 1e-5), 0.0, 1.0);
            dSub = mix(di, dSub, h) - k * h * (1.0 - h);
            colSub = mix(c.rgb, colSub, h);
            mSub = mix(mi, mSub, h);
        } else {
            // smooth subtract: smax(dSub, -di, k)
            float h = clamp(0.5 + 0.5 * (di + dSub) / max(k, 1e-5), 0.0, 1.0);
            dSub = -(mix(di, -dSub, h) - k * h * (1.0 - h));
        }
    }
    if (dSub < dTot) { dTot = dSub; colTot = colSub; mTot = mSub; }
    g_marble = mTot;
    return vec4(dTot, colTot);
}

vec3 calcNormal(vec3 p) {
    vec2 e = vec2(0.0015, 0.0);
    return normalize(vec3(
        mapScene(p + e.xyy).x - mapScene(p - e.xyy).x,
        mapScene(p + e.yxy).x - mapScene(p - e.yxy).x,
        mapScene(p + e.yyx).x - mapScene(p - e.yyx).x));
}

// SDF soft shadow (IQ): march from the surface toward the light; the closest
// pass-by distance softens the penumbra. This is the sundial's gnomon shadow —
// no shadow map needed, the field IS the occluder.
float softShadow(vec3 ro, vec3 rd, float maxt) {
    float res = 1.0;
    float t = 0.03;
    for (int i = 0; i < 48; i++) {
        float h = mapScene(ro + rd * t).x;
        if (h < 0.0008) return 0.0;
        res = min(res, 9.0 * h / t);
        t += clamp(h, 0.02, 0.6);
        if (t > maxt) break;
    }
    return clamp(res, 0.0, 1.0);
}

// Tiny value-noise stack for the procedural surfaces/sky below.
float hash13(vec3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}
float vnoise(vec3 p) {
    vec3 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x),
                   mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y),
               mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x),
                   mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}
float fbm(vec3 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { v += a * vnoise(p); p *= 2.03; a *= 0.5; }
    return v;
}

// Procedural marble: noise-warped veins over the node colour, in world space
// (stable — the pattern sticks to the stone).
vec3 marble(vec3 base, vec3 p) {
    float warp = fbm(p * 1.6);
    float vein = sin((p.x + 0.6 * p.y + 0.8 * p.z) * 2.4 + warp * 7.0);
    float m = smoothstep(0.72, 0.98, abs(vein));
    vec3 col = mix(base, base * 0.55 + vec3(0.16, 0.15, 0.16), m); // grey veins
    return col * (0.92 + 0.16 * fbm(p * 0.5 + 11.0));              // tonal patches
}

// Night-sky star field: hashed cells over the ray direction; `amt` fades it
// in/out (the timeline's environment.sky.stars).
vec3 stars(vec3 rd, float amt) {
    if (amt <= 0.0) return vec3(0.0);
    vec3 p = rd * 90.0;
    vec3 id = floor(p);
    float h = hash13(id);
    if (h < 0.992) return vec3(0.0);
    float b = smoothstep(0.35, 0.0, length(fract(p) - 0.5));
    float tw = 0.55 + 0.45 * hash13(id + 7.0);
    return vec3(b * tw * amt * 1.4);
}

vec3 acesTonemap(vec3 x) {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

void main() {
    vec3 ro = cam_eye.xyz;
    float tan_half = cam_eye.w;
    float aspect = cam_right.w;
    vec3 rd = normalize(cam_fwd.xyz
        + ndc.x * tan_half * aspect * cam_right.xyz
        + ndc.y * tan_half * cam_up.xyz);

    // Background: the scene Environment's sky gradient along the view ray when
    // present (the visible sky of an SDF scene), else the legacy backdrop.
    bool has_env = sun_color.w > 0.5;
    vec3 bg = has_env
        ? mix(sky_horizon.rgb, sky_zenith.rgb, clamp(rd.y * 0.85 + 0.12, 0.0, 1.0))
        : mix(vec3(0.015, 0.015, 0.02), vec3(0.07, 0.075, 0.095),
              clamp(ndc.y * 0.5 + 0.5, 0.0, 1.0));
    if (has_env) {
        // A soft halo around the sun direction (the bright disc itself is the
        // scene's emissive sundisc entity), and the fadable night star field.
        if (sun_dir_int.w > 0.0) {
            float sa = max(dot(rd, normalize(-sun_dir_int.xyz)), 0.0);
            bg += sun_color.rgb * sun_dir_int.w * (pow(sa, 96.0) * 0.18 + pow(sa, 8.0) * 0.05);
        }
        bg += stars(rd, cam_fwd.w);
    }
    float exposure = max(sky_zenith.w, 0.0);
    bool tonemap = sky_horizon.w > 0.5;
    bg *= exposure;
    if (tonemap) bg = acesTonemap(bg);

    // Empty-space skip: clip the ray to the scene AABB so we only march where the
    // geometry can be (all SDF nodes live inside these bounds). A ray that misses
    // the box draws background immediately.
    vec3 inv = 1.0 / rd;
    vec3 ta = (scene_min.xyz - ro) * inv;
    vec3 tb = (scene_max.xyz - ro) * inv;
    vec3 tlo = min(ta, tb);
    vec3 thi = max(ta, tb);
    float t_near = max(max(tlo.x, tlo.y), max(tlo.z, 0.0));
    float t_far = min(min(thi.x, thi.y), thi.z);
    if (t_far < t_near) {
        frag_color = vec4(bg, 1.0);
        gl_FragDepth = 1.0;
        return;
    }

    float t = t_near;
    bool hit = false;
    vec3 p = ro;
    for (int i = 0; i < 160; i++) {
        p = ro + rd * t;
        float d = mapScene(p).x;
        if (d < 0.0008) { hit = true; break; }
        t += d;
        if (t > t_far) break;
    }

    if (!hit) {
        frag_color = vec4(bg, 1.0);
        gl_FragDepth = 1.0;
        return;
    }

    // Depth of the hit point, in the backend's NDC convention, so the mesh
    // pass depth-tests against the SDF surface (and vice versa).
    vec4 clip = view_proj * vec4(p, 1.0);
    float ndc_z = clip.z / max(clip.w, 1e-6);
    gl_FragDepth = clamp(scene_min.w > 0.5 ? ndc_z * 0.5 + 0.5 : ndc_z, 0.0, 1.0);

    vec3 base = mapScene(p).yzw;
    if (g_marble > 0.01) base = mix(base, marble(base, p), g_marble);
    vec3 n = calcNormal(p);
    // Key light: the scene's directional sun (with an SDF soft shadow) when
    // present, else the legacy fixed key.
    bool has_sun = sun_dir_int.w > 0.0;
    vec3 l = has_sun ? normalize(-sun_dir_int.xyz) : normalize(vec3(0.4, 0.7, 1.0));
    vec3 key_rgb = has_sun ? sun_color.rgb * sun_dir_int.w : vec3(0.85);
    float diff = max(dot(n, l), 0.0);
    float shadow = 1.0;
    if (has_sun && diff > 0.0) shadow = min(softShadow(p + n * 0.02, l, 40.0), meshShadow(p));
    // Ambient: the data sky × ambient tint/intensity when present (×2 maps
    // intensity 0.5 to full sky radiance), else the legacy hemispheric term.
    vec3 amb = has_env
        ? mix(sky_horizon.rgb, sky_zenith.rgb, clamp(n.y * 0.5 + 0.5, 0.0, 1.0))
              * ambient_ci.rgb * (ambient_ci.w * 2.0)
        : mix(vec3(0.10, 0.10, 0.12), vec3(0.30, 0.33, 0.42), n.y * 0.5 + 0.5);
    // A little Blinn specular for shape readability.
    vec3 v = normalize(ro - p);
    vec3 h = normalize(l + v);
    float spec = pow(max(dot(n, h), 0.0), 32.0) * diff * shadow;
    // Camera-coaxial fill ("headlight"): the surface you're looking at always
    // catches light, so an object viewed from its key-shadowed side still reads.
    // With a scene Environment it follows the ambient level (night stays night).
    float fill = max(dot(n, normalize(v + vec3(0.0, 0.3, 0.0))), 0.0)
        * (has_env ? 0.55 * clamp(ambient_ci.w * 2.0, 0.0, 1.0) : 0.55);
    vec3 col = base * (amb + key_rgb * (diff * shadow) + vec3(fill)) + key_rgb * spec * 0.35;

    // Point lights (lanterns): Lambert with smooth quadratic falloff to zero
    // at range. Unused slots have intensity 0.
    for (int i = 0; i < MAX_POINT_LIGHTS; i++) {
        float pint = point_col[i].w;
        if (pint <= 0.0) continue;
        vec3 lv = point_pos[i].xyz - p;
        float dist = length(lv);
        float rng = max(point_pos[i].w, 1e-3);
        if (dist >= rng) continue;
        float att = 1.0 - dist / rng;
        att *= att;
        float ndl = max(dot(n, lv / max(dist, 1e-4)), 0.0);
        col += base * point_col[i].rgb * (pint * att * ndl);
    }

    col *= exposure;
    if (tonemap) col = acesTonemap(col);
    else col = min(col, vec3(1.0));
    frag_color = vec4(col, 1.0);
}
@end

@program raymarch raymarch_vs raymarch_fs
