#include <metal_stdlib>
using namespace metal;
kernel void syntheticPattern(texture2d<half, access::write> output [[texture(0)]],
                             constant float &time [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if(p.x >= output.get_width() || p.y >= output.get_height()) return;
    float2 uv = float2(p) / float2(output.get_width(), output.get_height());
    bool grid = p.x % 64 < 1 || p.y % 64 < 1;
    float cursor = fract(time * 0.16);
    bool sweep = abs(uv.x-cursor)<0.004;
    half3 color = half3(0.035 + uv.x*0.065, 0.055 + uv.y*0.08, 0.10 + uv.x*0.15);
    if(grid) color += half3(0.13);
    if(uv.y > 0.84) color = half3((p.x/2)%2 ? 0.9 : 0.04);
    if(uv.y < 0.08) color=half3(uv.x, 0.5+0.5*sin(time),1-uv.x);
    if(sweep) color=half3(0.25,0.95,0.8);
    output.write(half4(color,1),p);
}
