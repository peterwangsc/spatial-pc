#include <metal_stdlib>
using namespace metal;
struct DesktopVertex { float4 position [[position]]; float2 uv; };
vertex DesktopVertex desktopVertex(uint id [[vertex_id]]) {
    float2 uv = float2((id << 1) & 2, id & 2);
    return {float4(uv * float2(2,-2) + float2(-1,1),0,1), uv};
}
struct VideoColorConversion { float4x4 transform; uint4 options; float4 chromaOffset; };
float4 sampleDesktop(float2 uv, texture2d<float> image, texture2d<float> chroma,
                     constant VideoColorConversion &color) {
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    if (!color.options.x) return float4(image.sample(s,uv).rgb,1);
    float y = image.sample(s,uv).r;
    float2 cbcr = chroma.sample(s,uv+color.chromaOffset.xy).rg;
    return float4(saturate((color.transform * float4(y,cbcr,1)).rgb),1);
}
fragment float4 desktopFragment(DesktopVertex in [[stage_in]], texture2d<float> desktop [[texture(0)]],
                                texture2d<float> chroma [[texture(1)]],
                                constant VideoColorConversion &color [[buffer(0)]]) {
    return sampleDesktop(in.uv,desktop,chroma,color);
}
kernel void videoToBGRA(texture2d<float> image [[texture(0)]], texture2d<float> chroma [[texture(1)]],
                        texture2d<half,access::write> output [[texture(2)]],
                        constant VideoColorConversion &color [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    float2 uv = (float2(p)+0.5) / float2(output.get_width(),output.get_height());
    output.write(half4(sampleDesktop(uv,image,chroma,color)),p);
}
