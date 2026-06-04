// raymarch.glsl — single shader source, cross-compiled to every backend by
// sokol-shdc at build time (do NOT hand-write per-backend variants).
//
// Sphere-traces an SDF/CSG scene supplied as a bounded uniform array of nodes
// (the GPU mirror of core's `SdfScene`). A vertex-less fullscreen triangle (the
// same gl_VertexIndex trick as triangle.glsl's bg_vs) covers the frame; the
// fragment shader reconstructs a camera ray per pixel and marches `mapScene`.
//
// Node packing (3 vec4 per node, MAX_NODES nodes):
//   a = (center.x, center.y, center.z, prim + 8*op)   prim:0 sphere 1 box 2 round_box
//   b = (half.x,   half.y,   half.z,   radius)        radius: sphere r / round_box rounding
//   c = (color.r,  color.g,  color.b,  k)             k: smooth-blend factor
// op: 0 union, 1 smooth-union, 2 subtract.

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

layout(binding=0) uniform rm_params {
    vec4 cam_eye;   // xyz eye,    w = tan(fovy/2)
    vec4 cam_right; // xyz right,  w = aspect
    vec4 cam_up;    // xyz up,     w = node_count
    vec4 cam_fwd;   // xyz forward,w = time
    vec4 scene_min; // xyz scene AABB min (empty-space skip)
    vec4 scene_max; // xyz scene AABB max
    vec4 nodes[MAX_NODES * 3];
};

in vec2 ndc;
out vec4 frag_color;

float sdBox(vec3 q, vec3 b) {
    vec3 d = abs(q) - b;
    return length(max(d, 0.0)) + min(max(d.x, max(d.y, d.z)), 0.0);
}

// returns vec4(distance, color.rgb)
vec4 mapScene(vec3 p) {
    float d = 1e9;
    vec3 col = vec3(0.80, 0.80, 0.85);
    int count = int(cam_up.w);
    for (int i = 0; i < MAX_NODES; i++) {
        if (i >= count) break;
        vec4 a = nodes[i * 3 + 0];
        vec4 b = nodes[i * 3 + 1];
        vec4 c = nodes[i * 3 + 2];
        int prim = int(mod(a.w, 8.0));
        int op = int(floor(a.w / 8.0));
        float k = c.w;
        vec3 q = p - a.xyz;
        float di;
        if (prim == 0) di = length(q) - b.w;
        else if (prim == 1) di = sdBox(q, b.xyz);
        else di = sdBox(q, b.xyz) - b.w;

        if (op == 0) {
            if (di < d) { d = di; col = c.rgb; }
        } else if (op == 1) {
            float h = clamp(0.5 + 0.5 * (di - d) / max(k, 1e-5), 0.0, 1.0);
            d = mix(di, d, h) - k * h * (1.0 - h);
            col = mix(c.rgb, col, h);
        } else {
            // smooth subtract: smax(d, -di, k) = -smin(-d, di, k)
            float h = clamp(0.5 + 0.5 * (di + d) / max(k, 1e-5), 0.0, 1.0);
            float sm = mix(di, -d, h) - k * h * (1.0 - h);
            d = -sm;
        }
    }
    return vec4(d, col);
}

vec3 calcNormal(vec3 p) {
    vec2 e = vec2(0.0015, 0.0);
    return normalize(vec3(
        mapScene(p + e.xyy).x - mapScene(p - e.xyy).x,
        mapScene(p + e.yxy).x - mapScene(p - e.yxy).x,
        mapScene(p + e.yyx).x - mapScene(p - e.yyx).x));
}

void main() {
    vec3 ro = cam_eye.xyz;
    float tan_half = cam_eye.w;
    float aspect = cam_right.w;
    vec3 rd = normalize(cam_fwd.xyz
        + ndc.x * tan_half * aspect * cam_right.xyz
        + ndc.y * tan_half * cam_up.xyz);

    // Background: the same vertical gradient as the preview backdrop.
    vec3 bg = mix(vec3(0.015, 0.015, 0.02), vec3(0.07, 0.075, 0.095),
                  clamp(ndc.y * 0.5 + 0.5, 0.0, 1.0));

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
        return;
    }

    vec3 base = mapScene(p).yzw;
    vec3 n = calcNormal(p);
    vec3 l = normalize(vec3(0.4, 0.7, 1.0));
    float diff = max(dot(n, l), 0.0);
    // Cheap hemispheric ambient (sky above, ground below) so unlit faces read.
    vec3 amb = mix(vec3(0.10, 0.10, 0.12), vec3(0.30, 0.33, 0.42), n.y * 0.5 + 0.5);
    // A little Blinn specular for shape readability.
    vec3 v = normalize(ro - p);
    vec3 h = normalize(l + v);
    float spec = pow(max(dot(n, h), 0.0), 32.0) * diff;
    vec3 col = base * (amb + diff * 0.9) + vec3(spec * 0.35);

    frag_color = vec4(min(col, vec3(1.0)), 1.0);
}
@end

@program raymarch raymarch_vs raymarch_fs
