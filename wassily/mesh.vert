#version 450

layout(push_constant) uniform Push {
    mat4 model;
    vec4 tint;
    vec4 params;
    vec4 emissive;
} push;

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

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec2 inUV;
layout(location = 2) in vec3 inColor;
layout(location = 3) in vec3 inLight;

layout(location = 0) out vec2 fragUV;
layout(location = 1) out vec4 fragColor;
layout(location = 2) out vec3 fragWorld;
layout(location = 3) out vec3 fragLight;
layout(location = 4) flat out vec4 fragParams;
layout(location = 5) flat out vec3 fragEmissive;

void main() {
    vec4 world = push.model * vec4(inPosition, 1.0);
    gl_Position = frame.viewProj * world;
    fragWorld = world.xyz;
    fragUV = inUV;
    fragColor = vec4(inColor * push.tint.rgb, push.tint.a);
    fragLight = inLight;
    fragParams = push.params;
    fragEmissive = push.emissive.rgb;
}
