// triangle.glsl — single shader source, cross-compiled to every backend
// (Metal on macOS, HLSL on Windows, GLSL on Linux) by sokol-shdc at build time.
// Do NOT hand-write per-backend variants; edit this file and regenerate.
//
// The mesh shader: positions are transformed by a model-view-projection matrix
// supplied by the render layer, and shaded with a metallic-roughness PBR BRDF
// (Cook-Torrance specular + Lambert diffuse) from a per-draw material uniform.
@vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
    mat4 model;
    vec4 eye_pos; // world-space camera position (xyz)
};

in vec3 position;
in vec3 normal;
in vec4 color0;
in vec2 texcoord0;

out vec3 world_normal;
out vec3 view_dir;
out vec3 frag_local_pos;
out vec4 color;
out vec2 uv;
out vec3 world_pos;

void main() {
    vec4 wp = model * vec4(position, 1.0);
    gl_Position = mvp * vec4(position, 1.0);
    world_normal = mat3(model) * normal;
    view_dir = eye_pos.xyz - wp.xyz;
    frag_local_pos = position; // object space — surface finishes tile here so they
                               // stick to the body as it moves/animates
    color = color0;
    uv = texcoord0;       // UV unwrap (0 for untextured procedural meshes)
    world_pos = wp.xyz;   // for the G-buffer position probe
}
@end

@fs fs
// PBR material as a per-draw uniform (metallic-roughness factors). `base_color`
// tints the vertex colour (white vertices => the material drives the colour);
// `pbr` carries metallic/roughness; `emissive` adds light. Grid/gizmo bind a
// white default.
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;
layout(binding=1) uniform fs_params {
    vec4 base_color;   // albedo rgba
    vec4 pbr;          // x = metallic, y = roughness, z = preview staging, w = dimples
    vec4 emissive;     // rgb emissive; .w = G-buffer probe (0 lit, 1 uv, 2 pos, 3 normal)
};

// Scene lighting (docs/lights-and-tones.md), applied once per pipeline. All
// zeros except exposure=1 selects the legacy path (fixed key light, hardcoded
// env gradient, no tonemap) so lightless scenes render exactly as before.
#define MAX_POINT_LIGHTS 8
layout(binding=2) uniform fs_lights {
    vec4 sun_dir_int;  // xyz = direction the sun light travels, w = intensity (0 = legacy key)
    vec4 sun_color;    // rgb sun colour, w = has_env (scene sky/ambient data present)
    vec4 ambient_ci;   // rgb ambient tint, w = ambient intensity
    vec4 sky_zenith;   // rgb sky top, w = exposure
    vec4 sky_horizon;  // rgb sky horizon, w = tonemap (0 none, 1 aces)
    vec4 point_pos[MAX_POINT_LIGHTS]; // xyz world position, w = range
    vec4 point_col[MAX_POINT_LIGHTS]; // rgb colour, w = intensity (0 = unused slot)
    mat4 sun_shadow_mvp; // world -> sun clip ([0,1] z), both write + read side
    vec4 shadow_params;  // x = enabled, y = shadow-map texel size, z = depth bias
};
// The sun shadow map: 16-bit depth packed into RG of an RGBA8 target (works
// on the WebGL2 floor — no depth-texture sampling needed). NEAREST sampler:
// packed channels must not be filtered.
layout(binding=1) uniform texture2D shadow_tex;
layout(binding=1) uniform sampler shadow_smp;

float shadowDepth(vec2 uv) {
    vec2 enc = texture(sampler2D(shadow_tex, shadow_smp), uv).rg;
    return enc.x + enc.y * (1.0 / 255.0);
}

// 0 = fully shadowed, 1 = lit. 4-tap PCF around the projected point.
float sunShadow(vec3 wp) {
    if (shadow_params.x < 0.5) return 1.0;
    vec4 clip = sun_shadow_mvp * vec4(wp, 1.0);
    vec3 ndc = clip.xyz / max(clip.w, 1e-6);
    vec2 uv = ndc.xy * 0.5 + 0.5;
    if (uv.x <= 0.0 || uv.x >= 1.0 || uv.y <= 0.0 || uv.y >= 1.0) return 1.0;
    float d = ndc.z - shadow_params.z; // receiver depth, biased
    float tx = shadow_params.y;
    float lit = 0.0;
    lit += d <= shadowDepth(uv + vec2(-0.5, -0.5) * tx) ? 1.0 : 0.0;
    lit += d <= shadowDepth(uv + vec2(0.5, -0.5) * tx) ? 1.0 : 0.0;
    lit += d <= shadowDepth(uv + vec2(-0.5, 0.5) * tx) ? 1.0 : 0.0;
    lit += d <= shadowDepth(uv + vec2(0.5, 0.5) * tx) ? 1.0 : 0.0;
    return lit * 0.25;
}

in vec3 world_normal;
in vec3 view_dir;
in vec3 frag_local_pos;
in vec4 color;
in vec2 uv;
in vec3 world_pos;
out vec4 frag_color;

const float PI = 3.14159265359;

// GGX/Trowbridge-Reitz normal distribution.
float d_ggx(float n_o_h, float a) {
    float a2 = a * a;
    float d = (n_o_h * n_o_h) * (a2 - 1.0) + 1.0;
    return a2 / max(PI * d * d, 1e-7);
}

// Smith height-correlated visibility (G / (4 NoV NoL)), Schlick-GGX form.
float v_smith(float n_o_v, float n_o_l, float a) {
    float k = (a * a) * 0.5;
    float gv = n_o_v / (n_o_v * (1.0 - k) + k);
    float gl = n_o_l / (n_o_l * (1.0 - k) + k);
    return (gv * gl) / max(4.0 * n_o_v * n_o_l, 1e-4);
}

vec3 f_schlick(float v_o_h, vec3 f0) {
    return f0 + (1.0 - f0) * pow(clamp(1.0 - v_o_h, 0.0, 1.0), 5.0);
}

// Cheap procedural environment: a ground→sky vertical gradient. Sampled along
// the normal (ambient irradiance) and the reflection vector (ambient specular),
// it gives metals something to reflect so they read as metal — a stand-in until
// real image-based lighting.
vec3 env(vec3 d) {
    vec3 dir = normalize(d);
    float t = clamp(dir.y * 0.5 + 0.5, 0.0, 1.0);
    vec3 col = mix(vec3(0.20, 0.19, 0.17), vec3(0.55, 0.62, 0.78), t);
    // Two studio softboxes baked into the environment (not gated to previews), so
    // polished metals reflect bright highlights and read as metal in a live scene,
    // not just in catalogue thumbnails. Sharp lobes keep them as highlights rather
    // than washing the diffuse ambient.
    col += vec3(1.5, 1.45, 1.32) * pow(max(dot(dir, normalize(vec3(0.7, 0.8, -0.25))), 0.0), 32.0);
    col += vec3(0.40, 0.46, 0.60) * pow(max(dot(dir, normalize(vec3(-0.7, 0.2, 0.4))), 0.0), 16.0);
    return col;
}

// Data-driven sky: the scene Environment's two-stop vertical gradient, used
// for both the ambient irradiance and the ambient specular when present.
vec3 skyGrad(vec3 d) {
    float t = clamp(normalize(d).y * 0.5 + 0.5, 0.0, 1.0);
    return mix(sky_horizon.rgb, sky_zenith.rgb, t);
}

// ACES filmic tonemap (Narkowicz fit) — the `post.tonemap:"aces"` operator.
vec3 acesTonemap(vec3 x) {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

// Basketball seams: darken thin bands along three orthogonal great circles of
// the body's object space, so a plain orange sphere reads as a seamed ball
// instead of a fruit. Returns an albedo multiplier (≈0 on a seam, 1 elsewhere).
float basketballSeam(vec3 p) {
    vec3 d = normalize(p);
    float w = 0.05;
    float seam = min(min(abs(d.x), abs(d.y)), abs(d.z)); // distance to nearest plane
    // also a curved seam offset so it's not a perfect beach-ball
    float curved = abs(abs(d.x) - abs(d.z));
    float m = min(seam, curved);
    return mix(0.12, 1.0, smoothstep(0.0, w, m));
}

// Golf-ball dimples for the material-preview sphere. `dimple(dir)` is a height
// field over the sphere — a hex-offset lat/long grid of round wells, 1 at a
// dimple centre, 0 between them. The preview is a unit sphere at the origin, so
// the surface direction is just the normal. Perturbing the normal by the field's
// gradient adds the self-shading that makes the preview read as a 3D body
// (and samples the BRDF across many angles at once). Preview-only — gated by the
// pbr.z flag the renderer sets, so live geometry is never touched.
float dimple(vec3 d) {
    float lat = asin(clamp(d.y, -1.0, 1.0));         // -PI/2..PI/2
    float lon = atan(d.z, d.x);                      // -PI..PI
    const float ROWS = 11.0;
    const float COLS = 22.0;
    float fy = (lat / PI + 0.5) * ROWS;
    float row = floor(fy);
    float fx = (lon / (2.0 * PI) + 0.5) * COLS + 0.5 * mod(row, 2.0); // hex offset
    vec2 cell = vec2(fract(fx) - 0.5, fract(fy) - 0.5);
    return 1.0 - smoothstep(0.0, 0.42, length(cell)); // 1 at dimple centre -> 0
}

vec3 dimpleNormal(vec3 n) {
    vec3 up = abs(n.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    vec3 t = normalize(cross(up, n));
    vec3 b = cross(n, t);
    float e = 0.02;
    float h0 = dimple(n);
    float ht = dimple(normalize(n + t * e));
    float hb = dimple(normalize(n + b * e));
    // Dimples are concave: indent along the gradient (push the normal toward the
    // well centre at the rim, giving each dimple a lit edge and a shaded floor).
    vec3 grad = (ht - h0) * t + (hb - h0) * b;
    return normalize(n + grad * 22.0);
}

// Surface dimples for arbitrary shapes (the golf-ball fedora): the sphere's
// lat/long mapping smears on a hat, so tile the dimples in object space with
// triplanar projection — pick the plane facing away from the dominant normal
// axis and lay a hex grid of wells in it. Independent of the shape's topology.
float dimpleSurface(vec3 p, vec3 n) {
    vec3 an = abs(n);
    vec2 uv = (an.y >= an.x && an.y >= an.z) ? p.xz : (an.x >= an.z ? p.zy : p.xy);
    const float spacing = 0.12;
    vec2 q = uv / spacing;
    float row = floor(q.y);
    q.x += 0.5 * mod(row, 2.0); // hex offset alternate rows
    vec2 f = vec2(fract(q.x) - 0.5, fract(q.y) - 0.5);
    return 1.0 - smoothstep(0.0, 0.44, length(f)); // 1 at a well centre -> 0
}

vec3 dimpleSurfaceNormal(vec3 n, vec3 p) {
    vec3 up = abs(n.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    vec3 t = normalize(cross(up, n));
    vec3 b = cross(n, t);
    float e = 0.012;
    float h0 = dimpleSurface(p, n);
    float ht = dimpleSurface(p + t * e, n);
    float hb = dimpleSurface(p + b * e, n);
    vec3 grad = (ht - h0) * t + (hb - h0) * b;
    return normalize(n + grad * 1.4);
}

void main() {
    // G-buffer probe (emissive.w): output the UV / world position / world normal
    // instead of shading, so offscreen tooling can read this map back. Matches
    // the skinned shader's channels.
    int probe = int(emissive.w + 0.5);
    if (probe == 1) { frag_color = vec4(uv, 0.0, 1.0); return; }
    if (probe == 2) { frag_color = vec4(world_pos * 0.5 + 0.5, 1.0); return; }
    if (probe == 3) { frag_color = vec4(normalize(world_normal) * 0.5 + 0.5, 1.0); return; }

    vec3 n = normalize(world_normal);
    bool preview = pbr.z > 0.5;  // staging: backdrop lights, applies to any body
    // Surface finish (pbr.w): 1 = spherical dimples (the material ball),
    // 2 = surface/triplanar dimples (the golf-ball hat), 3 = basketball seams.
    int surf = int(pbr.w + 0.5);
    if (surf == 2) n = dimpleSurfaceNormal(n, frag_local_pos);
    else if (surf == 1) n = dimpleNormal(n);
    vec3 v = normalize(view_dir);
    // Live key light is roughly co-axial with the camera (fine for the editor).
    // For previews that flattens the body and puts a central blob on metals, so
    // the preview keys from the upper-left (3/4) — the highlight rakes across the
    // curve and the far side rolls into the fill + rim.
    // Key light: the scene's directional sun when present (colour × intensity),
    // else the legacy camera-ish fixed key (white, unit intensity).
    bool has_sun = sun_dir_int.w > 0.0 && !preview;
    bool has_env = sun_color.w > 0.5 && !preview;
    vec3 l = preview ? normalize(vec3(0.7, 0.8, -0.25))
           : (has_sun ? normalize(-sun_dir_int.xyz) : normalize(vec3(0.4, 0.7, 1.0)));
    vec3 key_rgb = has_sun ? sun_color.rgb * sun_dir_int.w : vec3(1.0);
    vec3 h = normalize(v + l);

    float n_o_v = max(dot(n, v), 1e-4);
    float n_o_l = max(dot(n, l), 0.0);
    float n_o_h = max(dot(n, h), 0.0);
    float v_o_h = max(dot(v, h), 0.0);

    // Base colour = vertex colour x material x texture atlas. Untextured meshes
    // bind a 1x1 white texture, so they fall back to vertex x material unchanged.
    vec4 tex_s = texture(sampler2D(tex, smp), uv);
    vec3 albedo = color.rgb * base_color.rgb * tex_s.rgb;
    if (surf == 3) albedo *= basketballSeam(frag_local_pos); // black seams
    float metallic = clamp(pbr.x, 0.0, 1.0);
    float rough = clamp(pbr.y, 0.045, 1.0);
    float a = rough * rough;

    // Dielectrics reflect ~4%; metals tint the specular with their albedo and
    // have no diffuse.
    vec3 f0 = mix(vec3(0.04), albedo, metallic);
    vec3 diffuse_color = albedo * (1.0 - metallic);

    // Direct: Cook-Torrance specular + Lambert diffuse from the key light.
    float d = d_ggx(n_o_h, a);
    float vis = v_smith(n_o_v, n_o_l, a);
    vec3 f = f_schlick(v_o_h, f0);
    vec3 spec = d * vis * f;
    vec3 kd = (vec3(1.0) - f) * (1.0 - metallic);
    float shadow = has_sun ? sunShadow(world_pos) : 1.0;
    vec3 lit = (kd * diffuse_color + spec) * (n_o_l * shadow) * key_rgb;

    // Ambient from the environment: diffuse irradiance along N + a reflection
    // along R (roughness-aware Fresnel). This is what makes metals look metallic.
    vec3 r = reflect(-v, n);
    // Grazing reflectance (f90): dielectrics brighten toward white, but metals
    // keep their tint — else gold/brass desaturate to a white/lavender wash at
    // grazing, which a dimpled surface (many micro-angles) makes severe.
    vec3 f90 = mix(vec3(1.0 - rough), f0, metallic);
    vec3 f_amb = f0 + (max(f90, f0) - f0) * pow(1.0 - n_o_v, 5.0);
    // Ambient: the data sky gradient × ambient tint/intensity when the scene
    // carries an Environment (×2 maps intensity 0.5 to full sky radiance),
    // else the legacy hardcoded env.
    vec3 amb_k = ambient_ci.rgb * (ambient_ci.w * 2.0);
    vec3 amb_n = has_env ? skyGrad(n) * amb_k : env(n);
    vec3 amb_r = has_env ? skyGrad(r) * amb_k : env(r);
    vec3 ambient = amb_n * diffuse_color + amb_r * f_amb;

    vec3 col = lit + ambient + emissive.rgb;

    // Point lights: Lambert + a small Blinn lobe, smooth quadratic falloff to
    // zero at `range`. Unused slots have intensity 0.
    for (int i = 0; i < MAX_POINT_LIGHTS; i++) {
        float pint = point_col[i].w;
        if (pint <= 0.0) continue;
        vec3 lv = point_pos[i].xyz - world_pos;
        float dist = length(lv);
        float rng = max(point_pos[i].w, 1e-3);
        if (dist >= rng) continue;
        vec3 pl = lv / max(dist, 1e-4);
        float att = 1.0 - dist / rng;
        att *= att;
        float ndl = max(dot(n, pl), 0.0);
        float pspec = pow(max(dot(n, normalize(v + pl)), 0.0), 48.0);
        col += (diffuse_color + f0 * pspec * 2.0) * point_col[i].rgb * (pint * att * ndl);
    }

    // Camera-coaxial fill ("headlight"): the surface you're looking at always
    // catches some light, so a body viewed from its key-shadowed side still reads
    // (e.g. the drill scene's front face / its rubble). With a scene Environment
    // the fill follows the ambient level, so night stays night.
    float fill = max(dot(n, normalize(v + vec3(0.0, 0.3, 0.0))), 0.0);
    col += diffuse_color * fill * (has_env ? 0.35 * clamp(ambient_ci.w * 2.0, 0.0, 1.0) : 0.35);

    // Preview staging: a soft fill from the opposite side to open up the shadow
    // terminator, and a cool rim to separate the body from the studio backdrop.
    if (preview) {
        // Fill from the side opposite the key (screen-left), to open up the
        // shadow terminator.
        vec3 lf = normalize(vec3(-0.7, 0.15, 0.35));
        col += diffuse_color * max(dot(n, lf), 0.0) * 0.16;
        // Cool rim to separate the body from the backdrop. (The studio softboxes
        // a metal reflects are baked into env() now, so they apply in-scene too.)
        float rim = pow(clamp(1.0 - n_o_v, 0.0, 1.0), 3.0);
        col += vec3(0.45, 0.55, 0.75) * rim * 0.22;
    }

    // Tones: pre-tonemap exposure, then the selected operator. The legacy
    // block carries exposure=1 / tonemap=0, so old scenes are bit-identical.
    col *= max(sky_zenith.w, 0.0);
    if (sky_horizon.w > 0.5) col = acesTonemap(col);
    else col = min(col, vec3(1.0));
    frag_color = vec4(col, color.a * base_color.a * tex_s.a);
}
@end

// Studio backdrop for the material preview: a vertical gradient with a soft glow
// behind the body, so the sphere sits in a lit scene instead of a black void.
// Drawn as a vertex-less fullscreen triangle, behind everything.
@vs bg_vs
out vec2 uv;
void main() {
    float x = float((gl_VertexIndex & 1) << 2) - 1.0;
    float y = float((gl_VertexIndex & 2) << 1) - 1.0;
    gl_Position = vec4(x, y, 0.999999, 1.0);
    uv = vec2(x, y) * 0.5 + 0.5;
}
@end

@fs bg_fs
// bg_params.zenith.w = 1 selects the scene-Environment sky gradient (colours
// arrive pre-exposed/tonemapped); 0 keeps the legacy studio backdrop.
layout(binding=0) uniform bg_params {
    vec4 bg_zenith;
    vec4 bg_horizon;
};
in vec2 uv;
out vec4 frag_color;
void main() {
    if (bg_zenith.w > 0.5) {
        frag_color = vec4(mix(bg_horizon.rgb, bg_zenith.rgb, clamp(uv.y, 0.0, 1.0)), 1.0);
        return;
    }
    float vert = smoothstep(-0.1, 0.8, uv.y);
    vec3 col = mix(vec3(0.015, 0.015, 0.02), vec3(0.07, 0.075, 0.095), vert);
    float d = distance(uv, vec2(0.5, 0.56));
    col += vec3(0.05, 0.055, 0.075) * smoothstep(0.7, 0.0, d);
    frag_color = vec4(col, 1.0);
}
@end

// Sun shadow-map writer: rasterize casters from the sun, pack the [0,1]
// ortho-clip depth into RG of an RGBA8 target.
@vs shadow_vs
layout(binding=0) uniform shadow_vs_params {
    mat4 light_mvp;
};
in vec3 position;
out float lz;
void main() {
    vec4 clip = light_mvp * vec4(position, 1.0);
    gl_Position = clip;
    lz = clip.z; // [0,1] by construction (orthoZeroToOne)
}
@end

@fs shadow_fs
in float lz;
out vec4 frag_color;
void main() {
    float d = clamp(lz, 0.0, 1.0);
    float hi = floor(d * 255.0) / 255.0;
    float lo = fract(d * 255.0);
    frag_color = vec4(hi, lo, 0.0, 1.0);
}
@end

@program triangle vs fs
@program bg bg_vs bg_fs
@program shadow shadow_vs shadow_fs
