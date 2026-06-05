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
    vec3 light_dir = normalize(vec3(0.4, 0.7, 1.0));
    float diffuse = max(dot(n, light_dir), 0.0);
    // Base colour = vertex colour x atlas sample. Untextured meshes bind a 1x1
    // white texture, so they fall back to their vertex colour unchanged.
    vec4 base = color * texture(sampler2D(tex, smp), uv);
    frag_color = vec4(base.rgb * (0.3 + 0.7 * diffuse), base.a);
}
@end

@program skinned vs_skin fs_skin
