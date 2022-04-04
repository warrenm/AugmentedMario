
#include <metal_stdlib>
using namespace metal;

struct MarioVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float3 color    [[attribute(2)]];
    float2 uv       [[attribute(3)]];
};

struct MarioVertexOut {
    float4 position [[position]];
    float3 normal;
    float3 color;
    float3 light;
    float2 uv;
};

struct MarioUniforms {
    float4x4 model;
    float4x4 view;
    float4x4 projection;
};

vertex MarioVertexOut vertex_mario(MarioVertexIn in [[stage_in]],
                                   constant MarioUniforms &uniforms [[buffer(1)]])
{
    float3x3 lightMatrix {
        uniforms.view[0].xyz,
        uniforms.view[1].xyz,
        uniforms.view[2].xyz
    };

    MarioVertexOut out;
    out.color = in.color;
    out.normal = in.normal;
    out.light = transpose(lightMatrix) * normalize(float3(-1, 1, 0.2));
    out.uv = in.uv;
    out.position = uniforms.projection * uniforms.view * uniforms.model * float4(in.position, 1.0);
    return out;
}

fragment float4 fragment_mario(MarioVertexOut in [[stage_in]],
                               texture2d<float, access::sample> marioTex [[texture(0)]])
{
    constexpr sampler nearestSampler(coord::normalized, filter::nearest);
    float light = 0.5 + 0.5 * saturate(dot(in.normal, in.light));
    float4 texColor = marioTex.sample(nearestSampler, in.uv);
    float3 mainColor = mix(in.color, texColor.rgb, texColor.a);
    return float4(mainColor * light, 1.0);
}

struct WorldUniforms {
    float4x4 model;
    float4x4 view;
    float4x4 projection;
};

struct WorldVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
};

struct WorldVertexOut {
    float4 position [[position]];
    float3 normal;
    float3 worldPos;
};

vertex WorldVertexOut vertex_world(WorldVertexIn in [[stage_in]],
                                   constant WorldUniforms &uniforms [[buffer(1)]])
{
    float3x3 normalMatrix {
        uniforms.model[0].xyz,
        uniforms.model[1].xyz,
        uniforms.model[2].xyz
    };

    WorldVertexOut out;
    out.normal = transpose(normalMatrix) * in.normal; // originally inverse()
    float4 worldPos4 = uniforms.model * float4(in.position, 1.0);
    out.worldPos = worldPos4.xyz;
    out.position = uniforms.projection * uniforms.view * worldPos4;
    return out;
}

fragment float4 fragment_world(WorldVertexOut in [[stage_in]],
                               texture2d<float, access::sample> tex [[texture(0)]])
{
    float3 planeColor { 1.0, 1.0, 1.0 };
    float planeOpacity = 0.0;
    return float4(planeColor * planeOpacity, planeOpacity);
}
