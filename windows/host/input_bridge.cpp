#define NOMINMAX
#include <windows.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <iostream>
#include <memory>
#include <string>
#include "InputEngine.h"
using Microsoft::WRL::ComPtr;
void check(HRESULT result){if(FAILED(result))throw std::runtime_error("Input display unavailable");}
bool normalDesktop() {
    HDESK desktop=OpenInputDesktop(0,FALSE,DESKTOP_READOBJECTS);
    if(!desktop)return false;
    wchar_t name[128]{};DWORD size=0;
    const bool normal=GetUserObjectInformationW(desktop,UOI_NAME,name,sizeof(name),&size)&&wcscmp(name,L"Default")==0;
    CloseDesktop(desktop);return normal;
}
InputGeometry geometry(int width,int height) {
    ComPtr<IDXGIFactory1> factory;check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));
    ComPtr<IDXGIAdapter> adapter;check(factory->EnumAdapters(0,&adapter));
    ComPtr<IDXGIOutput> output;check(adapter->EnumOutputs(0,&output));DXGI_OUTPUT_DESC desc{};check(output->GetDesc(&desc));
    if(!desc.AttachedToDesktop||desc.Rotation!=DXGI_MODE_ROTATION_IDENTITY)throw std::runtime_error("Input display unsupported");
    const int x=GetSystemMetrics(SM_XVIRTUALSCREEN),y=GetSystemMetrics(SM_YVIRTUALSCREEN);
    return {desc.DesktopCoordinates,{x,y,x+GetSystemMetrics(SM_CXVIRTUALSCREEN),y+GetSystemMetrics(SM_CYVIRTUALSCREEN)},width,height};
}
bool sameDisplay(const InputGeometry& expected) {
    RECT area=expected.monitor;MONITORINFO info{};info.cbSize=sizeof(info);
    const auto monitor=MonitorFromRect(&area,MONITOR_DEFAULTTONULL);
    const int x=GetSystemMetrics(SM_XVIRTUALSCREEN),y=GetSystemMetrics(SM_YVIRTUALSCREEN);
    RECT desktop{x,y,x+GetSystemMetrics(SM_CXVIRTUALSCREEN),y+GetSystemMetrics(SM_CYVIRTUALSCREEN)};
    return monitor&&GetMonitorInfoW(monitor,&info)&&EqualRect(&info.rcMonitor,&expected.monitor)&&EqualRect(&desktop,&expected.desktop);
}
int wmain(int argc,wchar_t** argv) {
    std::unique_ptr<InputEngine> engine;
    try {
        const bool textEnabled=argc==6&&std::wstring(argv[5])==L"--enable-text";
        if((argc!=5&&!textEnabled)||std::wstring(argv[1])!=L"--width"||std::wstring(argv[3])!=L"--height")throw std::runtime_error("Input bridge arguments invalid");
        const int width=std::stoi(argv[2]),height=std::stoi(argv[4]);
        if(width<2||height<2||width>8192||height>8192)throw std::runtime_error("Input display bounds invalid");
        if(!SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2))throw std::runtime_error("Input DPI context unavailable");
        const auto bounds=geometry(width,height);
        engine=std::make_unique<InputEngine>(bounds,[](const std::vector<INPUT>& values){return SendInput(UINT(values.size()),const_cast<INPUT*>(values.data()),sizeof(INPUT));});
        const HANDLE input=GetStdHandle(STD_INPUT_HANDLE);
        if(GetFileType(input)!=FILE_TYPE_PIPE)throw std::runtime_error("Input requires a local pipe");
        std::cout<<"{\"ready\":true,\"width\":"<<width<<",\"height\":"<<height<<"}\n"<<std::flush;
        std::array<uint8_t,24> record{};DWORD used=0;
        const auto started=GetTickCount64();auto refill=started,partial=started,desktopCheck=started;
        double tokens=120;
        while(GetTickCount64()-started<600000) {
            const auto now=GetTickCount64();
            if(engine->expired(now))throw std::runtime_error("Input lease expired");
            if(used&&now-partial>=2000)throw std::runtime_error("Partial input record expired");
            if(now-desktopCheck>=50){desktopCheck=now;if(engine->active()&&(!normalDesktop()||!sameDisplay(bounds)))throw std::runtime_error("Input desktop changed");}
            DWORD available=0;
            if(!PeekNamedPipe(input,nullptr,0,nullptr,&available,nullptr)) {
                if(GetLastError()==ERROR_BROKEN_PIPE){if(!engine->release())throw std::runtime_error("Input release failed");return used?2:0;}
                throw std::runtime_error("Input pipe unavailable");
            }
            if(!available){Sleep(5);continue;}
            if(!used)partial=now;
            DWORD received=0;const DWORD wanted=std::min<DWORD>(24-used,available);
            if(!ReadFile(input,record.data()+used,wanted,&received,nullptr)||!received)throw std::runtime_error("Input pipe ended");
            used+=received;if(used<24)continue;used=0;
            tokens=std::min(120.0,tokens+double(now-refill)*.240);refill=now;
            if(tokens<1)throw std::runtime_error("Input rate exceeded");--tokens;
            const auto event=parseInput(record,textEnabled);
            if(event.kind==5) {
                if(!normalDesktop())throw std::runtime_error("Input desktop unavailable");
                // Do not adopt keys/buttons currently held by a local user.
                if(!engine->active())for(int vk=1;vk<256;++vk)if(GetAsyncKeyState(vk)&0x8000)throw std::runtime_error("Local input already held");
            }
            engine->apply(event,now);
        }
        if(!engine->release())throw std::runtime_error("Input release failed");return 0;
    } catch(const std::exception& error) {
        if(engine)engine->release();
        // No event bytes, coordinates, key usages or text in diagnostics.
        std::cerr<<"input_bridge_stopped reason="<<error.what()<<'\n';return 2;
    }
}
