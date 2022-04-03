
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
    out.light = transpose(lightMatrix) * normalize(float3(1));
    out.uv = in.uv;
    out.position = uniforms.projection * uniforms.view * float4(in.position, 1.0);
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

static float3 tri(float3 x) {
    return abs(x - floor(x) - 0.5);
}

static float surfFunc( float3 p )
{
    float n = dot(tri(p*0.15 + tri(p.yzx*.075)), float3(0.444));
    p = p*1.5773 - n;
    p.yz = float2(p.y + p.z, p.z - p.y) * 0.866;
    p.xz = float2(p.x + p.z, p.z - p.x) * 0.866;
    n += dot(tri(p * 0.225 + tri(p.yzx * 0.1125)), float3(0.222));
    return abs(n - 0.5) * 1.9 + (1.0 - abs(sin(n * 9.0))) * 0.05;
}

fragment float4 fragment_world(WorldVertexOut in [[stage_in]],
                               texture2d<float, access::sample> tex [[texture(0)]])
{
    float surfy = surfFunc(in.worldPos / 50.0);
    float brightness = smoothstep(0.2, 0.3, surfy);
    return float4( (0.5 + 0.25 * brightness) * (0.5 + 0.5 * in.normal), 1.0);
}
