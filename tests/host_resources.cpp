#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <mfapi.h>
#include <mfidl.h>
#include <wrl/client.h>
#include <map>
#include <set>
#include <vector>
#include <iostream>
#include <thread>
#include <stdexcept>
using Microsoft::WRL::ComPtr;
void check(HRESULT hr, const char* where) { if (FAILED(hr)) throw std::runtime_error(where); }
#include "../windows/host/VideoSurfaces.h"
#include "../windows/host/FramePacer.h"
void expect(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
int main() {
    try {
        check(CoInitializeEx(nullptr, COINIT_MULTITHREADED), "COM"); check(MFStartup(MF_VERSION), "MF");
        ComPtr<ID3D11Device> device; ComPtr<ID3D11DeviceContext> context; D3D_FEATURE_LEVEL feature;
        check(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_VIDEO_SUPPORT,nullptr,0,D3D11_SDK_VERSION,&device,&feature,&context), "Device");
        ComPtr<ID3D11VideoDevice> video; check(device.As(&video), "Video");
        D3D11_VIDEO_PROCESSOR_CONTENT_DESC content{}; content.InputFrameFormat=D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
        content.InputWidth=content.OutputWidth=1920;content.InputHeight=content.OutputHeight=1080;
        content.InputFrameRate=content.OutputFrameRate={60,1};
        ComPtr<ID3D11VideoProcessorEnumerator> enumerator; check(video->CreateVideoProcessorEnumerator(&content,&enumerator), "Enumerator");
        ComPtr<IMFDXGIDeviceManager> manager;UINT token=0;check(MFCreateDXGIDeviceManager(&token,&manager), "Manager");check(manager->ResetDevice(device.Get(),token), "Reset");
        ComPtr<IMFMediaType> type;check(MFCreateMediaType(&type), "Type");type->SetGUID(MF_MT_MAJOR_TYPE,MFMediaType_Video);type->SetGUID(MF_MT_SUBTYPE,MFVideoFormat_NV12);
        MFSetAttributeSize(type.Get(),MF_MT_FRAME_SIZE,1920,1080);MFSetAttributeRatio(type.Get(),MF_MT_FRAME_RATE,60,1);type->SetUINT32(MF_MT_INTERLACE_MODE,MFVideoInterlace_Progressive);
        VideoSurfaces pool(device.Get(),video.Get(),enumerator.Get(),manager.Get(),type.Get(),1920,1080,true);
        std::vector<ComPtr<IMFSample>> held; std::set<ID3D11Texture2D*> textures;
        for (int i=0;i<8;++i) {
            ComPtr<IMFSample> sample;ComPtr<ID3D11VideoProcessorOutputView> view;expect(pool.acquire(sample,view), "Pool allocates within limit");
            ComPtr<IMFMediaBuffer> buffer;check(sample->GetBufferByIndex(0,&buffer), "Buffer");DWORD length=0;buffer->GetCurrentLength(&length);expect(length>=1920*1080*3/2, "NV12 buffer length initialized");
            ComPtr<IMFDXGIBuffer> dxgi;check(buffer.As(&dxgi), "DXGI buffer");ComPtr<ID3D11Texture2D> texture;check(dxgi->GetResource(IID_PPV_ARGS(&texture)), "Resource");
            expect(textures.insert(texture.Get()).second, "In-flight samples own distinct textures");held.push_back(sample);
        }
        ComPtr<IMFSample> extra;ComPtr<ID3D11VideoProcessorOutputView> view;expect(!pool.acquire(extra,view), "Pool must stop at eight retained samples");
        held.front().Reset();
        for(int n=0;n<1000&&!extra;++n){if(!pool.acquire(extra,view))std::this_thread::sleep_for(std::chrono::milliseconds(1));}
        expect(bool(extra), "Releasing a sample returns capacity");
        expect(FramePacer::following(100,101,10)==110, "Normal cadence does not drift");
        expect(FramePacer::following(100,1000,10)==1010, "Idle acquisition discards deadline debt");
        FramePacer timer(60);timer.wait();
        std::cout<<"PASS: pool ownership, initialized length, eight-sample bound, release recovery, pacing cadence and idle rebase\n";
        return 0;
    } catch(const std::exception& e) { std::cerr<<"FAIL: "<<e.what()<<'\n';return 1; }
}
