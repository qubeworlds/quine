// skinned.glsl — skeletal (linear-blend) skinning, cross-compiled to every
// backend by sokol-shdc. Up to four joint influences per vertex; the joint
// matrix palette is supplied as a uniform array.
@vs vs_skin
layout(binding=0) uniform vs_params {
    mat4 mvp;
    mat4 model;
};
layout(binding=1) uniform skin_params {
    mat4 joints[64];
};

in vec3 position;
in vec3 normal;
in vec4 color0;
in vec4 joint_index;
in vec4 joint_weight;
in vec2 texcoord0;

out vec3 world_normal;
out vec4 color;
out vec2 uv;
out vec3 world_pos;

void main() {
    mat4 skin =
        joint_weight.x * joints[int(joint_index.x)] +
        joint_weight.y * joints[int(joint_index.y)] +
        joint_weight.z * joints[int(joint_index.z)] +
        joint_weight.w * joints[int(joint_index.w)];

    vec4 skinned = skin * vec4(position, 1.0);
    gl_Position = mvp * skinned;
    world_normal = mat3(model) * mat3(skin) * normal;
    world_pos = (model * skinned).xyz; // post-skin world position (G-buffer)
    color = color0;
    uv = texcoord0;
}
@end

@fs fs_skin
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;
// G-buffer probe: dbg.x selects the output channel — 0 = normal lit shading,
// 1 = UV (texcoord as colour), 2 = world position (scaled+biased into 0..1 by
// dbg.y/dbg.z), 3 = world normal. The render layer drives this so offscreen
// tooling can read screen->UV / position / normal back out of a frame. Binding
// is 2 because the vertex stage already uses uniform blocks 0 and 1.
layout(binding=2) uniform fs_skin_params {
    vec4 dbg;
};

// Scene lighting — same packing as triangle.glsl's fs_lights (all zeros except
// exposure=1 = the legacy fixed-key path, bit-identical for lightless scenes).
#define MAX_POINT_LIGHTS 8
layout(binding=3) uniform fs_lights {
    vec4 sun_dir_int;  // xyz = direction the sun light travels, w = intensity
    vec4 sun_color;    // rgb sun colour, w = has_env
    vec4 ambient_ci;   // rgb ambient tint, w = ambient intensity
    vec4 sky_zenith;   // rgb sky top, w = exposure
    vec4 sky_horizon;  // rgb sky horizon, w = tonemap (0 none, 1 aces)
    vec4 point_pos[MAX_POINT_LIGHTS]; // xyz world position, w = range
    vec4 point_col[MAX_POINT_LIGHTS]; // rgb colour, w = intensity
};

vec3 acesTonemap(vec3 x) {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

in vec3 world_normal;
in vec4 color;
in vec2 uv;
in vec3 world_pos;
out vec4 frag_color;

void main() {
    int mode = int(dbg.x + 0.5);
    if (mode == 1) { frag_color = vec4(uv, 0.0, 1.0); return; }
    if (mode == 2) { frag_color = vec4(world_pos * dbg.y + dbg.z, 1.0); return; }
    if (mode == 3) { frag_color = vec4(normalize(world_normal) * 0.5 + 0.5, 1.0); return; }

    vec3 n = normalize(world_normal);
    // Base colour = vertex colour x atlas sample. Untextured meshes bind a 1x1
    // white texture, so they fall back to their vertex colour unchanged.
    vec4 base = color * texture(sampler2D(tex, smp), uv);

    bool has_sun = sun_dir_int.w > 0.0;
    bool has_env = sun_color.w > 0.5;
    vec3 l = has_sun ? normalize(-sun_dir_int.xyz) : normalize(vec3(0.4, 0.7, 1.0));
    float diffuse = max(dot(n, l), 0.0);
    vec3 col;
    if (!has_sun && !has_env) {
        col = base.rgb * (0.3 + 0.7 * diffuse); // legacy, bit-identical
    } else {
        vec3 key_rgb = has_sun ? sun_color.rgb * sun_dir_int.w : vec3(1.0);
        vec3 amb = has_env
            ? mix(sky_horizon.rgb, sky_zenith.rgb, clamp(n.y * 0.5 + 0.5, 0.0, 1.0))
                  * ambient_ci.rgb * (ambient_ci.w * 2.0)
            : vec3(0.3);
        col = base.rgb * (amb + key_rgb * (diffuse * 0.85));
        for (int i = 0; i < MAX_POINT_LIGHTS; i++) {
            float pint = point_col[i].w;
            if (pint <= 0.0) continue;
            vec3 lv = point_pos[i].xyz - world_pos;
            float dist = length(lv);
            float rng = max(point_pos[i].w, 1e-3);
            if (dist >= rng) continue;
            float att = 1.0 - dist / rng;
            att *= att;
            float ndl = max(dot(n, lv / max(dist, 1e-4)), 0.0);
            col += base.rgb * point_col[i].rgb * (pint * att * ndl);
        }
    }
    col *= max(sky_zenith.w, 0.0);
    if (sky_horizon.w > 0.5) col = acesTonemap(col);
    else col = min(col, vec3(1.0));
    frag_color = vec4(col, base.a);
}
@end

@program skinned vs_skin fs_skin
