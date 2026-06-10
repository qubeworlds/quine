// post.glsl — the minimal post chain (docs/lights-and-tones.md): bright-pass
// extract, separable gaussian blur, additive composite. LDR (RGBA8) so it runs
// on the WebGL2/iPad floor — the scene pass tonemaps, bloom blooms what's
// still bright after it. Cross-compiled by sokol-shdc; do NOT hand-write
// per-backend variants.

@vs post_vs
out vec2 uv;
void main() {
    float x = float((gl_VertexIndex & 1) << 2) - 1.0;
    float y = float((gl_VertexIndex & 2) << 1) - 1.0;
    gl_Position = vec4(x, y, 0.5, 1.0);
    uv = vec2(x, y) * 0.5 + 0.5;
}
@end

@fs bright_fs
layout(binding=0) uniform texture2D src;
layout(binding=0) uniform sampler psmp;
layout(binding=0) uniform bright_params {
    vec4 bp; // x = threshold (LDR luminance where bloom starts)
};
in vec2 uv;
out vec4 frag_color;
void main() {
    vec3 c = texture(sampler2D(src, psmp), uv).rgb;
    float l = max(max(c.r, c.g), c.b);
    float w = smoothstep(bp.x, min(bp.x + 0.18, 1.0), l);
    frag_color = vec4(c * w, 1.0);
}
@end

@fs blur_fs
layout(binding=0) uniform texture2D src;
layout(binding=0) uniform sampler psmp;
layout(binding=0) uniform blur_params {
    vec4 dir; // xy = one-texel step along the blur axis (in UV units)
};
in vec2 uv;
out vec4 frag_color;
void main() {
    vec2 d = dir.xy;
    vec3 acc = texture(sampler2D(src, psmp), uv).rgb * 0.227027;
    vec2 o1 = d * 1.3846154;
    vec2 o2 = d * 3.2307692;
    acc += texture(sampler2D(src, psmp), uv + o1).rgb * 0.3162162;
    acc += texture(sampler2D(src, psmp), uv - o1).rgb * 0.3162162;
    acc += texture(sampler2D(src, psmp), uv + o2).rgb * 0.0702703;
    acc += texture(sampler2D(src, psmp), uv - o2).rgb * 0.0702703;
    frag_color = vec4(acc, 1.0);
}
@end

@fs comp_fs
layout(binding=0) uniform texture2D scene_tex;
layout(binding=1) uniform texture2D bloom_tex;
layout(binding=0) uniform sampler psmp;
layout(binding=0) uniform comp_params {
    vec4 cp; // x = bloom intensity
};
in vec2 uv;
out vec4 frag_color;
void main() {
    vec3 s = texture(sampler2D(scene_tex, psmp), uv).rgb;
    vec3 b = texture(sampler2D(bloom_tex, psmp), uv).rgb;
    frag_color = vec4(s + b * cp.x, 1.0);
}
@end

@program bright post_vs bright_fs
@program blur post_vs blur_fs
@program composite post_vs comp_fs
