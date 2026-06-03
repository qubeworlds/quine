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

out vec3 world_normal;
out vec3 view_dir;
out vec4 color;

void main() {
    vec4 world_pos = model * vec4(position, 1.0);
    gl_Position = mvp * vec4(position, 1.0);
    world_normal = mat3(model) * normal;
    view_dir = eye_pos.xyz - world_pos.xyz;
    color = color0;
}
@end

@fs fs
// PBR material as a per-draw uniform (metallic-roughness factors). `base_color`
// tints the vertex colour (white vertices => the material drives the colour);
// `pbr` carries metallic/roughness; `emissive` adds light. Grid/gizmo bind a
// white default.
layout(binding=1) uniform fs_params {
    vec4 base_color;   // albedo rgba
    vec4 pbr;          // x = metallic, y = roughness, z = preview staging, w = dimples
    vec4 emissive;     // rgb emissive (a reserved)
};

in vec3 world_normal;
in vec3 view_dir;
in vec4 color;
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
    float t = clamp(d.y * 0.5 + 0.5, 0.0, 1.0);
    return mix(vec3(0.20, 0.19, 0.17), vec3(0.55, 0.62, 0.78), t);
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

void main() {
    vec3 n = normalize(world_normal);
    bool preview = pbr.z > 0.5;  // staging: backdrop lights, applies to any body
    bool dimpled = pbr.w > 0.5;  // golf-ball dimples: the sphere material ball only
    if (dimpled) n = dimpleNormal(n);
    vec3 v = normalize(view_dir);
    // Live key light is roughly co-axial with the camera (fine for the editor).
    // For previews that flattens the body and puts a central blob on metals, so
    // the preview keys from the upper-left (3/4) — the highlight rakes across the
    // curve and the far side rolls into the fill + rim.
    vec3 l = preview ? normalize(vec3(0.7, 0.8, -0.25)) : normalize(vec3(0.4, 0.7, 1.0));
    vec3 h = normalize(v + l);

    float n_o_v = max(dot(n, v), 1e-4);
    float n_o_l = max(dot(n, l), 0.0);
    float n_o_h = max(dot(n, h), 0.0);
    float v_o_h = max(dot(v, h), 0.0);

    vec3 albedo = color.rgb * base_color.rgb;
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
    vec3 lit = (kd * diffuse_color + spec) * n_o_l; // white light, unit intensity

    // Ambient from the environment: diffuse irradiance along N + a reflection
    // along R (roughness-aware Fresnel). This is what makes metals look metallic.
    vec3 r = reflect(-v, n);
    vec3 f_amb = f0 + (max(vec3(1.0 - rough), f0) - f0) * pow(1.0 - n_o_v, 5.0);
    vec3 ambient = env(n) * diffuse_color + env(r) * f_amb;

    vec3 col = lit + ambient + emissive.rgb;

    // Preview staging: a soft fill from the opposite side to open up the shadow
    // terminator, and a cool rim to separate the body from the studio backdrop.
    if (preview) {
        // Fill from the side opposite the key (screen-left), to open up the
        // shadow terminator.
        vec3 lf = normalize(vec3(-0.7, 0.15, 0.35));
        col += diffuse_color * max(dot(n, lf), 0.0) * 0.16;
        // Cool rim to separate the body from the backdrop.
        float rim = pow(clamp(1.0 - n_o_v, 0.0, 1.0), 3.0);
        col += vec3(0.45, 0.55, 0.75) * rim * 0.22;
        // Studio softboxes the surface reflects: a hot key box (upper-right) and a
        // cooler fill box (left). On a polished metal the reflection is sharp and
        // bright — the "shine" a flat gradient env can't provide; rough / dielectric
        // surfaces only catch a soft glint. Tinted by the Fresnel reflectance, so
        // gold throws a golden highlight and chrome a white one.
        float gloss = 1.0 - rough;
        vec3 key_r = normalize(vec3(0.7, 0.8, -0.25));
        vec3 fill_r = normalize(vec3(-0.7, 0.2, 0.4));
        float sk = pow(max(dot(r, key_r), 0.0), mix(8.0, 220.0, gloss));
        float sf = pow(max(dot(r, fill_r), 0.0), mix(6.0, 90.0, gloss));
        col += (vec3(1.7, 1.65, 1.5) * sk + vec3(0.5, 0.55, 0.7) * sf) * f_amb;
    }

    frag_color = vec4(min(col, vec3(1.0)), color.a * base_color.a);
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
in vec2 uv;
out vec4 frag_color;
void main() {
    float vert = smoothstep(-0.1, 0.8, uv.y);
    vec3 col = mix(vec3(0.015, 0.015, 0.02), vec3(0.07, 0.075, 0.095), vert);
    float d = distance(uv, vec2(0.5, 0.56));
    col += vec3(0.05, 0.055, 0.075) * smoothstep(0.7, 0.0, d);
    frag_color = vec4(col, 1.0);
}
@end

@program triangle vs fs
@program bg bg_vs bg_fs
