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
    vec4 pbr;          // x = metallic, y = roughness (z,w reserved)
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

void main() {
    vec3 n = normalize(world_normal);
    vec3 v = normalize(view_dir);
    vec3 l = normalize(vec3(0.4, 0.7, 1.0)); // key directional light
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
    frag_color = vec4(min(col, vec3(1.0)), color.a * base_color.a);
}
@end

@program triangle vs fs
