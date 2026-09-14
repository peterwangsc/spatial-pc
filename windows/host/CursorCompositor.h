#pragma once
#include <d3dcompiler.h>
#include <vector>
#include <cstring>
#include <algorithm>
#include <cstdint>

// Composite DXGI's separate pointer on the GPU before video conversion. Desktop
// pixels never leave GPU memory. PointerPosition is the shape's top-left, not hotspot.
class CursorCompositor {
    friend struct CursorCompositorTest;
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<ID3D11Texture2D> background, composed, pointer;
    ComPtr<ID3D11ShaderResourceView> backgroundView, pointerView;
    ComPtr<ID3D11RenderTargetView> target;
    ComPtr<ID3D11VertexShader> vertex;
    ComPtr<ID3D11PixelShader> pixel;
    ComPtr<ID3D11Buffer> constants;
    ComPtr<ID3D11RasterizerState> clippedRasterizer;
    DXGI_OUTDUPL_POINTER_SHAPE_INFO shape{};
    DXGI_OUTDUPL_POINTER_POSITION position{};
    UINT width, height;
    std::vector<BYTE> bytes;
    std::vector<BYTE> uploadedBytes;
    std::vector<uint32_t> texels;
    DXGI_OUTDUPL_POINTER_SHAPE_INFO uploadedShape{};
    UINT textureWidth=0,textureHeight=0;
    uint64_t shapeNotifications=0,shapeUploads=0,textureAllocations=0,duplicateShapes=0,compositedFrames=0;
public:
    CursorCompositor(ID3D11Device* d, ID3D11DeviceContext* c, UINT w, UINT h):device(d),context(c),width(w),height(h) {
        const char* shader=R"(
Texture2D<float4> desktop : register(t0);
Texture2D<uint2> pointerImage : register(t1);
cbuffer Placement : register(b0) { int2 origin; uint2 size; uint kind; uint3 padding; };
float4 vs(uint id : SV_VertexID) : SV_Position {
    float2 uv=float2((id<<1)&2,id&2); return float4(uv*float2(2,-2)+float2(-1,1),0,1);
}
float4 ps(float4 screenPosition : SV_Position) : SV_Target {
    int2 p=int2(screenPosition.xy); float4 bg=desktop.Load(int3(p,0));
    int2 q=p-origin;
    if(any(q<0)||any(q>=int2(size))) return bg;
    uint2 data=pointerImage.Load(int3(q,0));
    uint3 rgb=uint3((data.x>>16)&255,(data.x>>8)&255,data.x&255);
    uint3 base=uint3(round(saturate(bg.rgb)*255));
    if(kind==1) return float4(float3((base&data.y)^rgb)/255,1);
    if(kind==4) return float4(float3((data.x>>24)==255 ? base^rgb : rgb)/255,1);
    float a=float(data.x>>24)/255;
    return float4(lerp(bg.rgb,float3(rgb)/255,a),1);
})";
        ComPtr<ID3DBlob> vs,ps,errors;
        check(D3DCompile(shader,strlen(shader),nullptr,nullptr,nullptr,"vs","vs_5_0",D3DCOMPILE_ENABLE_STRICTNESS,0,&vs,&errors),"CursorVertexCompile");
        HRESULT hr=D3DCompile(shader,strlen(shader),nullptr,nullptr,nullptr,"ps","ps_5_0",D3DCOMPILE_ENABLE_STRICTNESS,0,&ps,&errors);
        if(FAILED(hr)&&errors) std::cerr<<static_cast<const char*>(errors->GetBufferPointer());
        check(hr,"CursorPixelCompile");
        check(device->CreateVertexShader(vs->GetBufferPointer(),vs->GetBufferSize(),nullptr,&vertex),"CursorVertex");
        check(device->CreatePixelShader(ps->GetBufferPointer(),ps->GetBufferSize(),nullptr,&pixel),"CursorPixel");
        D3D11_TEXTURE2D_DESC td{};td.Width=w;td.Height=h;td.MipLevels=1;td.ArraySize=1;td.Format=DXGI_FORMAT_B8G8R8A8_UNORM;td.SampleDesc.Count=1;td.BindFlags=D3D11_BIND_SHADER_RESOURCE;
        check(device->CreateTexture2D(&td,nullptr,&background),"CursorBackground");
        check(device->CreateShaderResourceView(background.Get(),nullptr,&backgroundView),"CursorBackgroundView");
        td.BindFlags=D3D11_BIND_RENDER_TARGET;
        check(device->CreateTexture2D(&td,nullptr,&composed),"CursorComposite");
        check(device->CreateRenderTargetView(composed.Get(),nullptr,&target),"CursorTarget");
        D3D11_BUFFER_DESC bd{};bd.ByteWidth=32;bd.Usage=D3D11_USAGE_DEFAULT;bd.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
        check(device->CreateBuffer(&bd,nullptr,&constants),"CursorConstants");
        D3D11_RASTERIZER_DESC raster{};raster.FillMode=D3D11_FILL_SOLID;raster.CullMode=D3D11_CULL_NONE;
        raster.DepthClipEnable=TRUE;raster.ScissorEnable=TRUE;
        check(device->CreateRasterizerState(&raster,&clippedRasterizer),"CursorScissorState");
    }
    void update(IDXGIOutputDuplication* duplication,const DXGI_OUTDUPL_FRAME_INFO& info) {
        if(info.LastMouseUpdateTime.QuadPart) position=info.PointerPosition;
        if(!info.PointerShapeBufferSize) return;
        bytes.resize(info.PointerShapeBufferSize);UINT required=0;
        check(duplication->GetFramePointerShape(UINT(bytes.size()),bytes.data(),&required,&shape),"PointerShape");
        uploadShape();
    }
private:
    void uploadShape() {
        ++shapeNotifications;
        const UINT h=shape.Type==DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME?shape.Height/2:shape.Height;
        if(!shape.Width||!h||shape.Width>4096||h>4096||size_t(shape.Pitch)*shape.Height>bytes.size()) throw std::runtime_error("Invalid pointer dimensions");
        const bool mono=shape.Type==DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME;
        if(shape.Pitch<(mono?(shape.Width+7)/8:shape.Width*4)) throw std::runtime_error("Invalid pointer pitch");
        if(!mono&&shape.Type!=DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR&&shape.Type!=DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MASKED_COLOR) throw std::runtime_error("Unknown pointer type");
        if(pointer && shape.Type==uploadedShape.Type && shape.Width==uploadedShape.Width &&
           shape.Height==uploadedShape.Height && shape.Pitch==uploadedShape.Pitch && bytes==uploadedBytes) {
            ++duplicateShapes;return;
        }
        texels.assign(size_t(shape.Width)*h*2,0);
        for(UINT y=0;y<h;y++) for(UINT x=0;x<shape.Width;x++) {
            const size_t index=(size_t(y)*shape.Width+x)*2;
            if(mono) {
                const BYTE bit=BYTE(0x80>>(x%8));
                texels[index]=(bytes[size_t(y+h)*shape.Pitch+x/8]&bit)?0xFFFFFF:0;
                texels[index+1]=(bytes[size_t(y)*shape.Pitch+x/8]&bit)?0xFFFFFF:0;
            } else std::memcpy(&texels[index],bytes.data()+size_t(y)*shape.Pitch+x*4,4);
        }
        if(!pointer || textureWidth!=shape.Width || textureHeight!=h) {
            D3D11_TEXTURE2D_DESC td{};td.Width=shape.Width;td.Height=h;td.MipLevels=1;td.ArraySize=1;td.Format=DXGI_FORMAT_R32G32_UINT;td.SampleDesc.Count=1;td.Usage=D3D11_USAGE_DEFAULT;td.BindFlags=D3D11_BIND_SHADER_RESOURCE;
            D3D11_SUBRESOURCE_DATA data{texels.data(),shape.Width*8,0};
            pointerView.Reset();pointer.Reset();
            check(device->CreateTexture2D(&td,&data,&pointer),"CursorTexture");
            check(device->CreateShaderResourceView(pointer.Get(),nullptr,&pointerView),"CursorView");
            textureWidth=shape.Width;textureHeight=h;++textureAllocations;
        } else {
            // Ordered on the same immediate context as draw; the runtime preserves
            // prior GPU reads when the next shape update contends with them.
            context->UpdateSubresource(pointer.Get(),0,nullptr,texels.data(),shape.Width*8,0);
        }
        uploadedShape=shape;uploadedBytes=bytes;++shapeUploads;
    }
public:
    void report() const {
        std::cerr<<"cursor_summary={\"shape_notifications\":"<<shapeNotifications<<",\"shape_uploads\":"<<shapeUploads
            <<",\"texture_allocations\":"<<textureAllocations<<",\"duplicate_shapes\":"<<duplicateShapes
            <<",\"composited_frames\":"<<compositedFrames<<"}\n";
    }
    ID3D11Texture2D* draw(ID3D11Texture2D* source) {
        if(!position.Visible||!pointerView) return source;
        const UINT pointerHeight=shape.Type==1?shape.Height/2:shape.Height;
        const auto left=std::max<int64_t>(0,position.Position.x),top=std::max<int64_t>(0,position.Position.y);
        const auto right=std::min<int64_t>(width,int64_t(position.Position.x)+shape.Width),bottom=std::min<int64_t>(height,int64_t(position.Position.y)+pointerHeight);
        if(left>=right||top>=bottom) return source;
        D3D11_BOX box{0,0,0,width,height,1};context->CopySubresourceRegion(composed.Get(),0,0,0,0,source,0,&box);
        D3D11_BOX pointerBox{UINT(left),UINT(top),0,UINT(right),UINT(bottom),1};
        context->CopySubresourceRegion(background.Get(),0,UINT(left),UINT(top),0,source,0,&pointerBox);
        struct Placement { INT x,y;UINT w,h,kind,pad[3]; } placement{position.Position.x,position.Position.y,shape.Width,pointerHeight,shape.Type,{0,0,0}};
        context->UpdateSubresource(constants.Get(),0,nullptr,&placement,0,0);
        D3D11_VIEWPORT viewport{0,0,float(width),float(height),0,1};context->RSSetViewports(1,&viewport);
        D3D11_RECT clip{LONG(left),LONG(top),LONG(right),LONG(bottom)};
        context->RSSetState(clippedRasterizer.Get());context->RSSetScissorRects(1,&clip);
        context->IASetInputLayout(nullptr);context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        context->VSSetShader(vertex.Get(),nullptr,0);context->PSSetShader(pixel.Get(),nullptr,0);
        ID3D11Buffer* cb=constants.Get();context->PSSetConstantBuffers(0,1,&cb);
        ID3D11ShaderResourceView* views[]={backgroundView.Get(),pointerView.Get()};context->PSSetShaderResources(0,2,views);
        ID3D11RenderTargetView* rt=target.Get();context->OMSetRenderTargets(1,&rt,nullptr);
        context->Draw(3,0);
        ID3D11ShaderResourceView* empty[2]={};context->PSSetShaderResources(0,2,empty);context->OMSetRenderTargets(0,nullptr,nullptr);
        context->RSSetState(nullptr);++compositedFrames;
        return composed.Get();
    }
};
