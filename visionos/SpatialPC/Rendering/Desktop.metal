#include <metal_stdlib>
using namespace metal;
struct DesktopVertex { float4 position [[position]]; float2 uv; };
vertex DesktopVertex desktopVertex(uint id [[vertex_id]]) {
    float2 uv = float2((id << 1) & 2, id & 2);
    return {float4(uv * float2(2,-2) + float2(-1,1),0,1), uv};
}
fragment float4 desktopFragment(DesktopVertex in [[stage_in]], texture2d<float> desktop [[texture(0)]]) {
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    return float4(desktop.sample(s,in.uv).rgb,1);
}
