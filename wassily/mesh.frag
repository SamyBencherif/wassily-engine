#version 450

layout(set = 0, binding = 0) uniform sampler2D tex;

layout(location = 0) in vec2 fragUV;
layout(location = 1) in vec4 fragColor;
layout(location = 2) in vec3 fragWorld;
layout(location = 3) in vec3 fragLight;
layout(location = 4) flat in vec4 fragParams;
layout(location = 5) flat in vec3 fragEmissive;

layout(location = 0) out vec4 outColor;

struct BoxLight {
    vec4 center;
    vec4 halfSize;
    vec4 color;
};

layout(set = 1, binding = 0) uniform Frame {
    mat4 viewProj;
    ivec4 lightCount;
    BoxLight lights[8];
} frame;

void main() {
    vec4 texel = texture(tex, fragUV);
    float alpha = texel.a * fragColor.a;
    if (alpha < fragParams.x) {
        discard;
    }
    vec3 base = texel.rgb * fragColor.rgb;

    // Filter: the blend state multiplies the framebuffer by this.
    if (fragParams.y > 0.5) {
        outColor = vec4(base, 1.0);
        return;
    }

    // Box lights act as decals: projected onto whatever surface lies inside the box.
    vec3 light = vec3(0.0);
    for (int i = 0; i < frame.lightCount.x; i++) {
        BoxLight l = frame.lights[i];
        vec3 d = abs(fragWorld - l.center.xyz) / l.halfSize.xyz;
        vec3 falloff = 1.0 - smoothstep(0.0, 1.0, d);
        light += l.color.rgb * falloff.x * falloff.y * falloff.z;
    }

    outColor = vec4(base * (fragLight + light) + light * 0.15 + fragEmissive, alpha);
}
