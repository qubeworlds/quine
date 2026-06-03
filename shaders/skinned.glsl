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

void main() {
    mat4 skin =
        joint_weight.x * joints[int(joint_index.x)] +
        joint_weight.y * joints[int(joint_index.y)] +
        joint_weight.z * joints[int(joint_index.z)] +
        joint_weight.w * joints[int(joint_index.w)];

    vec4 skinned = skin * vec4(position, 1.0);
    gl_Position = mvp * skinned;
    world_normal = mat3(model) * mat3(skin) * normal;
    color = color0;
    uv = texcoord0;
}
@end

@fs fs_skin
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;

in vec3 world_normal;
in vec4 color;
in vec2 uv;
out vec4 frag_color;

void main() {
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
