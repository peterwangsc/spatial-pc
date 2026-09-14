// Transport test fixture: no DXGI capture and no SendInput calls/imports.
#define NOMINMAX
#include <windows.h>
#include <io.h>
#include <fcntl.h>
#include <iostream>
#include <string>
#include "../windows/host/InputEngine.h"
void u32(unsigned char* out,uint32_t value){for(int i=0;i<4;++i)out[i]=BYTE(value>>(24-8*i));}
int main(int argc,char** argv){
    if(argc==2&&std::string(argv[1])=="--stream"){
        _setmode(_fileno(stdout),_O_BINARY);
        const std::string hello="{\"version\":1,\"codec\":\"h264-annexb\",\"width\":2,\"height\":2,\"fps\":60,\"hardwareEncoder\":true}";
        unsigned char header[16]={'S','P','C','1'};u32(header+4,uint32_t(hello.size()));
        fwrite(header,1,8,stdout);fwrite(hello.data(),1,hello.size(),stdout);fflush(stdout);
        std::cerr<<"fixture_capture_started\n";
        const bool flood=GetEnvironmentVariableA("SPATIAL_INPUT_FIXTURE_FLOOD",nullptr,0)>0;
        std::vector<unsigned char> payload(flood?1048576:8,0);payload[3]=1;payload[4]=0x65;
        for(uint64_t frame=0;frame<3600;++frame){
            u32(header,uint32_t(payload.size()));for(int i=0;i<8;++i)header[4+i]=BYTE((frame*166667)>>(56-8*i));u32(header+12,0);
            if(fwrite(header,1,16,stdout)!=16||fwrite(payload.data(),1,payload.size(),stdout)!=payload.size()||fflush(stdout))break;
            if(!flood)Sleep(16);
        }
        return 0;
    }
    const bool textEnabled=argc==6&&std::string(argv[5])=="--enable-text";
    uint64_t downs=0,ups=0,events=0;
    InputEngine engine({{0,0,2,2},{0,0,2,2},2,2},[&](const std::vector<INPUT>& values){for(const auto& item:values){++events;if(item.type==INPUT_KEYBOARD){if(item.ki.dwFlags&KEYEVENTF_KEYUP)++ups;else ++downs;}else {if(item.mi.dwFlags&(MOUSEEVENTF_LEFTDOWN|MOUSEEVENTF_RIGHTDOWN|MOUSEEVENTF_MIDDLEDOWN))++downs;if(item.mi.dwFlags&(MOUSEEVENTF_LEFTUP|MOUSEEVENTF_RIGHTUP|MOUSEEVENTF_MIDDLEUP))++ups;}}return UINT(values.size());});
    std::cout<<"{\"ready\":true,\"width\":2,\"height\":2}\n"<<std::flush;
    int result=0;
    try{
        const auto input=GetStdHandle(STD_INPUT_HANDLE);std::array<uint8_t,24> bytes{};DWORD used=0;const auto start=GetTickCount64();
        while(GetTickCount64()-start<10000){
            if(engine.expired(GetTickCount64()))throw std::runtime_error("Lease");
            DWORD available=0;if(!PeekNamedPipe(input,nullptr,0,nullptr,&available,nullptr))break;
            if(!available){Sleep(5);continue;}
            DWORD count=0;if(!ReadFile(input,bytes.data()+used,std::min<DWORD>(24-used,available),&count,nullptr)||!count)break;
            used+=count;if(used==24){const auto event=parseInput(bytes,textEnabled);engine.apply(event,GetTickCount64());if(event.kind==5)std::cerr<<"fixture_control_active\n";used=0;}
        }
    }catch(const std::exception&){result=2;}
    engine.release();
    std::cerr<<"fixture_input_summary={\"events\":"<<events<<",\"downs\":"<<downs<<",\"ups\":"<<ups<<"}\n";
    return result;
}
