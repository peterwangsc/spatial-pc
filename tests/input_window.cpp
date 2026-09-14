// Authorized visible test: inject only while this dedicated test window owns focus.
#define NOMINMAX
#include <windows.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <iostream>
#include <string>
#include <vector>
using Microsoft::WRL::ComPtr;
struct Observed {int down=0,up=0,buttonsDown=0,buttonsUp=0,wheel=0,horizontal=0;POINT move{-999,-999};} observed;
LRESULT CALLBACK windowProc(HWND window,UINT message,WPARAM w,LPARAM l){
    switch(message){
    case WM_KEYDOWN:case WM_SYSKEYDOWN:observed.down+=LOWORD(l);return 0;
    case WM_KEYUP:case WM_SYSKEYUP:++observed.up;return 0;
    case WM_CHAR:case WM_SYSCHAR:case WM_CONTEXTMENU:return 0;
    case WM_LBUTTONDOWN:case WM_RBUTTONDOWN:case WM_MBUTTONDOWN:++observed.buttonsDown;return 0;
    case WM_LBUTTONUP:case WM_RBUTTONUP:case WM_MBUTTONUP:++observed.buttonsUp;return 0;
    case WM_MOUSEMOVE:observed.move={LONG(short(LOWORD(l))),LONG(short(HIWORD(l)))};return 0;
    case WM_MOUSEWHEEL:++observed.wheel;return 0;
    case WM_MOUSEHWHEEL:++observed.horizontal;return 0;
    case WM_PAINT:{PAINTSTRUCT paint;HDC dc=BeginPaint(window,&paint);RECT bounds;GetClientRect(window,&bounds);DrawTextW(dc,L"Spatial PC input validation\nThis window closes automatically.",-1,&bounds,DT_CENTER|DT_VCENTER|DT_WORDBREAK);EndPaint(window,&paint);return 0;}
    }
    return DefWindowProcW(window,message,w,l);
}
void require(bool ok){if(!ok)throw std::runtime_error("Native window validation failed");}
void pump(){MSG message;while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)){TranslateMessage(&message);DispatchMessageW(&message);}}
int wmain(int argc,wchar_t** argv){
    HWND window=nullptr;HANDLE inputWrite=nullptr,outputRead=nullptr;PROCESS_INFORMATION child{};POINT originalCursor{};GetCursorPos(&originalCursor);
    int exitCode=1;const char* stage="initialization";
    try{
        require(argc==2||(argc==3&&std::wstring(argv[2])==L"--lease"));const bool leaseTest=argc==3;
        require(SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)!=FALSE);
        ComPtr<IDXGIFactory1> factory;require(SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))));
        ComPtr<IDXGIAdapter> adapter;require(SUCCEEDED(factory->EnumAdapters(0,&adapter)));
        ComPtr<IDXGIOutput> output;require(SUCCEEDED(adapter->EnumOutputs(0,&output)));DXGI_OUTPUT_DESC display{};require(SUCCEEDED(output->GetDesc(&display)));
        const int width=(display.DesktopCoordinates.right-display.DesktopCoordinates.left)&~1,height=(display.DesktopCoordinates.bottom-display.DesktopCoordinates.top)&~1;
        WNDCLASSW wc{};wc.lpfnWndProc=windowProc;wc.hInstance=GetModuleHandleW(nullptr);wc.lpszClassName=L"SpatialPCInputValidation";wc.hCursor=LoadCursor(nullptr,IDC_ARROW);wc.hbrBackground=GetSysColorBrush(COLOR_WINDOW);require(RegisterClassW(&wc)!=0);
        window=CreateWindowExW(0,wc.lpszClassName,L"Spatial PC input validation",WS_OVERLAPPEDWINDOW|WS_VISIBLE,display.DesktopCoordinates.left+width/2-240,display.DesktopCoordinates.top+height/2-120,480,240,nullptr,nullptr,wc.hInstance,nullptr);require(window!=nullptr);
        stage="window focus";SetForegroundWindow(window);SetFocus(window);pump();require(GetForegroundWindow()==window);
        SECURITY_ATTRIBUTES security{sizeof(security),nullptr,TRUE};HANDLE inputRead=nullptr,outputWrite=nullptr;
        require(CreatePipe(&inputRead,&inputWrite,&security,0)!=FALSE);require(CreatePipe(&outputRead,&outputWrite,&security,0)!=FALSE);
        SetHandleInformation(inputWrite,HANDLE_FLAG_INHERIT,0);SetHandleInformation(outputRead,HANDLE_FLAG_INHERIT,0);
        STARTUPINFOW startup{};startup.cb=sizeof(startup);startup.dwFlags=STARTF_USESTDHANDLES;startup.hStdInput=inputRead;startup.hStdOutput=outputWrite;startup.hStdError=outputWrite;
        std::wstring command=L"\""+std::wstring(argv[1])+L"\" --width "+std::to_wstring(width)+L" --height "+std::to_wstring(height);
        const BOOL created=CreateProcessW(nullptr,command.data(),nullptr,nullptr,TRUE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&child);
        CloseHandle(inputRead);CloseHandle(outputWrite);require(created!=FALSE);
        stage="helper ready";const auto start=GetTickCount64();std::string ready;
        while(GetTickCount64()-start<3000&&ready.find('\n')==std::string::npos){DWORD available=0;require(PeekNamedPipe(outputRead,nullptr,0,nullptr,&available,nullptr)!=FALSE);if(available){char buffer[512];DWORD got=0;require(ReadFile(outputRead,buffer,std::min<DWORD>(available,sizeof(buffer)),&got,nullptr)!=FALSE);ready.append(buffer,got);}pump();Sleep(5);}
        if(ready.find("\"ready\":true")==std::string::npos)std::cerr<<ready;
        require(ready.find("\"ready\":true")!=std::string::npos);require(GetForegroundWindow()==window);
        RECT client;GetClientRect(window,&client);POINT center{client.right/2,client.bottom/2},screen=center;ClientToScreen(window,&screen);
        const int x=int((int64_t(screen.x-display.DesktopCoordinates.left)*65535+(width-1)/2)/(width-1));
        const int y=int((int64_t(screen.y-display.DesktopCoordinates.top)*65535+(height-1)/2)/(height-1));
        std::vector<unsigned char> bytes;uint32_t sequence=0;
        auto event=[&](BYTE kind,BYTE flags,int a=0,int b=0,int c=0){const size_t offset=bytes.size();bytes.resize(offset+24);auto* p=bytes.data()+offset;std::memcpy(p,"SPI1",4);p[4]=kind;p[5]=flags;auto put=[&](size_t at,uint32_t value){for(int i=0;i<4;++i)p[at+size_t(i)]=BYTE(value>>(24-8*i));};put(8,++sequence);put(12,uint32_t(a));put(16,uint32_t(b));put(20,uint32_t(c));};
        event(5,0);event(1,0,x,y);event(2,1,x,y,1);event(2,0,x,y,1);event(3,0,120,-120);
        event(4,1,0xe0);event(4,1,4);event(4,3,4);event(4,0,4);event(4,0,0xe0);event(2,1,x,y,2);event(4,1,5);
        stage="event receipt";require(GetForegroundWindow()==window);DWORD written=0;require(WriteFile(inputWrite,bytes.data(),DWORD(bytes.size()),&written,nullptr)&&written==bytes.size());
        const auto injected=GetTickCount64();while(GetTickCount64()-injected<1000&&(observed.down<4||observed.buttonsDown<2)){pump();require(GetForegroundWindow()==window);Sleep(5);}
        require(observed.down==4&&observed.buttonsDown==2);stage=leaseTest?"independent lease release":"EOF release";
        if(!leaseTest){CloseHandle(inputWrite);inputWrite=nullptr;} // Lease mode leaves the parent pipe open and silent.
        const auto closed=GetTickCount64();while(GetTickCount64()-closed<3000){pump();if(WaitForSingleObject(child.hProcess,0)==WAIT_OBJECT_0&&observed.up>=3&&observed.buttonsUp>=2)break;Sleep(5);}
        DWORD code=99;require(GetExitCodeProcess(child.hProcess,&code)&&code==(leaseTest?2u:0u));
        if(leaseTest)require(GetTickCount64()-injected<2750);
        require(observed.up==3&&observed.buttonsUp==2&&observed.wheel==1&&observed.horizontal==1);stage="pointer position";
        require(abs(observed.move.x-center.x)<=1&&abs(observed.move.y-center.y)<=1);
        std::cout<<"PASS: native helper mapped pointer, ordered clicks, both wheel axes, physical key repeat/modifier and "<<(leaseTest?"independent lease":"EOF")<<" key/button release in dedicated window\n";exitCode=0;
    }catch(const std::exception&){std::cerr<<"Native window validation did not complete: "<<stage<<" counts="<<observed.down<<','<<observed.up<<','<<observed.buttonsDown<<','<<observed.buttonsUp<<','<<observed.wheel<<','<<observed.horizontal<<'\n';}
    if(inputWrite)CloseHandle(inputWrite);
    if(child.hProcess){const auto until=GetTickCount64()+3000;while(WaitForSingleObject(child.hProcess,0)!=WAIT_OBJECT_0&&GetTickCount64()<until){pump();Sleep(5);}CloseHandle(child.hProcess);CloseHandle(child.hThread);}
    if(outputRead){DWORD available=0;if(PeekNamedPipe(outputRead,nullptr,0,nullptr,&available,nullptr)&&available){char buffer[512];DWORD got=0;if(ReadFile(outputRead,buffer,std::min<DWORD>(available,sizeof(buffer)),&got,nullptr))std::cerr.write(buffer,got);}CloseHandle(outputRead);}
    if(window){if(GetForegroundWindow()==window)SetCursorPos(originalCursor.x,originalCursor.y);DestroyWindow(window);}
    return exitCode;
}
