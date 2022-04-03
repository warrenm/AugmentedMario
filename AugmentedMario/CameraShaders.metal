
#include <metal_stdlib>
using namespace metal;

struct QuadVertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct QuadVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex QuadVertexOut vertex_fullscreen_quad(QuadVertexIn in [[stage_in]]) {
    QuadVertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

fragment float4 fragment_camera_frame(QuadVertexOut in [[stage_in]],
                                      texture2d<float, access::sample> cameraTextureY [[texture(0)]],
                                      texture2d<float, access::sample> cameraTextureCbCr [[texture(1)]])
{
    constexpr sampler colorSampler(filter::linear);
    
    const float4x4 rgbFromYCbCr {
        { 1.0000f,  1.0000f,  1.0000f, 0.0000f },
        { 0.0000f, -0.3441f,  1.7720f, 0.0000f },
        { 1.4020f, -0.7141f,  0.0000f, 0.0000f },
        {-0.7010f,  0.5291f, -0.8860f, 1.0000f }
    };
    
    float4 yCbCr = float4(cameraTextureY.sample(colorSampler, in.texCoord).r,
                          cameraTextureCbCr.sample(colorSampler, in.texCoord).rg, 1.0);

    return rgbFromYCbCr * yCbCr;
}
