#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <chrono>
#include <cstdlib>
#include <stdexcept>
#include <iostream>
using Microsoft::WRL::ComPtr;
void require(HRESULT value) { if(FAILED(value)) throw std::runtime_error("Motion workload D3D failure"); }
LRESULT CALLBACK windowProc(HWND window,UINT message,WPARAM w,LPARAM l) {
    if(message==WM_CLOSE) { DestroyWindow(window); return 0; }
    if(message==WM_DESTROY) { PostQuitMessage(0); return 0; }
    if(message==WM_KEYDOWN&&w==VK_ESCAPE) { DestroyWindow(window); return 0; }
    return DefWindowProc(window,message,w,l);
}
int WINAPI wWinMain(HINSTANCE instance,HINSTANCE,PWSTR command,int) {
    try {
        const int seconds=std::max(1,std::min(180,_wtoi(command)));
        WNDCLASS wc{};wc.lpfnWndProc=windowProc;wc.hInstance=instance;wc.lpszClassName=L"SpatialPCPerformanceWorkload";
        RegisterClass(&wc);
        HWND window=CreateWindowEx(WS_EX_TOPMOST,wc.lpszClassName,L"Spatial PC performance test - Escape to close",WS_POPUP,0,0,GetSystemMetrics(SM_CXSCREEN),GetSystemMetrics(SM_CYSCREEN),nullptr,nullptr,instance,nullptr);
        if(!window)return 1;
        ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;ComPtr<IDXGISwapChain> swap;
        DXGI_SWAP_CHAIN_DESC desc{};desc.BufferDesc.Width=GetSystemMetrics(SM_CXSCREEN);desc.BufferDesc.Height=GetSystemMetrics(SM_CYSCREEN);
        desc.BufferDesc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.SampleDesc.Count=1;desc.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.BufferCount=2;desc.OutputWindow=window;desc.Windowed=TRUE;desc.SwapEffect=DXGI_SWAP_EFFECT_FLIP_DISCARD;
        D3D_FEATURE_LEVEL level;require(D3D11CreateDeviceAndSwapChain(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&desc,&swap,&device,&level,&context));
        ComPtr<ID3D11Texture2D> back;require(swap->GetBuffer(0,IID_PPV_ARGS(&back)));ComPtr<ID3D11RenderTargetView> target;require(device->CreateRenderTargetView(back.Get(),nullptr,&target));
        const char* source=R"(
cbuffer Time:register(b0) { float seconds; float width; float height; float spare; };
float4 vs(uint id:SV_VertexID):SV_Position { float2 uv=float2((id<<1)&2,id&2);return float4(uv*float2(2,-2)+float2(-1,1),0,1); }
float4 ps(float4 position:SV_Position):SV_Target {
 float t=max(0,seconds-3);float2 p=position.xy;float2 uv=p/float2(width,height);
 float grid=fmod(floor((p.x+t*175)/32)+floor((p.y+t*85)/32),2);
 float3 color=lerp(float3(.04,.08,.12),float3(.35,.45,.55),grid);
 float x=fmod(t*500,width);if(abs(p.x-x)<50)color=float3(.9,.15,.05);
 float y=fmod(t*170,height);if(abs(p.y-y)<24)color=float3(.1,.9,.3);
 if(p.y<70)color=float3(frac(t*.4),.3,.7);
 return float4(color,1);
})";
        ComPtr<ID3DBlob> vb,pb,errors;require(D3DCompile(source,strlen(source),nullptr,nullptr,nullptr,"vs","vs_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&vb,&errors));
        require(D3DCompile(source,strlen(source),nullptr,nullptr,nullptr,"ps","ps_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&pb,&errors));
        ComPtr<ID3D11VertexShader> vs;ComPtr<ID3D11PixelShader> ps;require(device->CreateVertexShader(vb->GetBufferPointer(),vb->GetBufferSize(),nullptr,&vs));require(device->CreatePixelShader(pb->GetBufferPointer(),pb->GetBufferSize(),nullptr,&ps));
        D3D11_BUFFER_DESC bd{};bd.ByteWidth=16;bd.Usage=D3D11_USAGE_DEFAULT;bd.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
        ComPtr<ID3D11Buffer> constants;require(device->CreateBuffer(&bd,nullptr,&constants));
        ShowWindow(window,SW_SHOW);SetForegroundWindow(window);
        auto start=std::chrono::steady_clock::now();bool done=false;UINT frame=0;
        while(!done&&std::chrono::steady_clock::now()-start<std::chrono::seconds(seconds)) {
            MSG message;while(PeekMessage(&message,nullptr,0,0,PM_REMOVE)) { if(message.message==WM_QUIT)done=true;TranslateMessage(&message);DispatchMessage(&message); }
            float values[4]={std::chrono::duration<float>(std::chrono::steady_clock::now()-start).count(),float(desc.BufferDesc.Width),float(desc.BufferDesc.Height),0};context->UpdateSubresource(constants.Get(),0,nullptr,values,0,0);
            ID3D11RenderTargetView* rt=target.Get();context->OMSetRenderTargets(1,&rt,nullptr);
            D3D11_VIEWPORT viewport{0,0,float(desc.BufferDesc.Width),float(desc.BufferDesc.Height),0,1};context->RSSetViewports(1,&viewport);
            context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);context->VSSetShader(vs.Get(),nullptr,0);context->PSSetShader(ps.Get(),nullptr,0);
            ID3D11Buffer* cb=constants.Get();context->PSSetConstantBuffers(0,1,&cb);context->Draw(3,0);require(swap->Present(1,0));++frame;
        }
        std::cerr<<"motion_frames="<<frame<<" elapsed_s="<<std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count()<<'\n';
        DestroyWindow(window);return 0;
    }catch(...){return 1;}
}
