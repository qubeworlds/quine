// triangle.glsl — single shader source, cross-compiled to every backend
// (Metal on macOS, HLSL on Windows, GLSL on Linux) by sokol-shdc at build time.
// Do NOT hand-write per-backend variants; edit this file and regenerate.
//
// The mesh shader: positions are transformed by a model-view-projection matrix
// supplied by the render layer (built from the camera in the render queue), and
// shaded with simple directional (Lambert) lighting so 3D geometry reads as 3D.
@vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
    mat4 model;
};

in vec3 position;
in vec3 normal;
in vec4 color0;

out vec3 world_normal;
out vec4 color;

void main() {
    gl_Position = mvp * vec4(position, 1.0);
    world_normal = mat3(model) * normal;
    color = color0;
}
@end

@fs fs
// PBR material as a per-draw uniform (metallic-roughness factors). `base_color`
// tints the vertex colour (white vertices => the material drives the colour);
// `pbr` carries metallic/roughness for the BRDF (plumbed now, used next);
// `emissive` adds light. Grid/gizmo bind a white, non-emissive default.
layout(binding=1) uniform fs_params {
    vec4 base_color;   // albedo rgba
    vec4 pbr;          // x = metallic, y = roughness (z,w reserved)
    vec4 emissive;     // rgb emissive (a reserved)
};

in vec3 world_normal;
in vec4 color;
out vec4 frag_color;

void main() {
    vec3 n = normalize(world_normal);
    vec3 light_dir = normalize(vec3(0.4, 0.7, 1.0));
    float diffuse = max(dot(n, light_dir), 0.0);
    float shade = 0.3 + 0.7 * diffuse; // ambient + diffuse (BRDF lands next)
    vec3 albedo = color.rgb * base_color.rgb;
    frag_color = vec4(albedo * shade + emissive.rgb, color.a * base_color.a);
}
@end

@program triangle vs fs
