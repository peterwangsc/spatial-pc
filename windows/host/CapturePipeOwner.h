#pragma once
#include <windows.h>
#include <stdexcept>

// Capture starts only after its parent assigns the kill-on-close Job and sends
// one readiness byte. EOF also stops an idle desktop with no video writes.
class CapturePipeOwner {
    HANDLE input=INVALID_HANDLE_VALUE;
public:
    explicit CapturePipeOwner(bool enabled) {
        if(!enabled)return;
        input=GetStdHandle(STD_INPUT_HANDLE);
        if(GetFileType(input)!=FILE_TYPE_PIPE)throw std::runtime_error("Capture owner pipe required");
        const auto started=GetTickCount64();
        while(GetTickCount64()-started<5000){
            DWORD available=0;
            if(!PeekNamedPipe(input,nullptr,0,nullptr,&available,nullptr))throw std::runtime_error("Capture owner ended");
            if(available){
                char ready=0;DWORD received=0;
                if(available!=1||!ReadFile(input,&ready,1,&received,nullptr)||received!=1||ready!='C')
                    throw std::runtime_error("Capture owner handshake invalid");
                return;
            }
            Sleep(5);
        }
        throw std::runtime_error("Capture owner handshake expired");
    }
    bool alive() const {
        if(input==INVALID_HANDLE_VALUE)return true;
        DWORD available=0;
        if(!PeekNamedPipe(input,nullptr,0,nullptr,&available,nullptr))return false;
        if(available)throw std::runtime_error("Unexpected capture owner data");
        return true;
    }
};
