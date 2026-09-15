#define NOMINMAX
#include "../windows/host/NvencDeadline.h"
#include <iostream>
#include <string>
int wmain(int argc,wchar_t** argv) {
    if(argc==2&&std::wstring(argv[1])==L"--wedged-child") {
        NvencDeadline d(std::chrono::milliseconds(100));NvencDeadline::Guard guard(d);
        Sleep(10000);return 1;
    }
    { NvencDeadline d(std::chrono::milliseconds(100));
      {NvencDeadline::Guard guard(d);Sleep(10);} Sleep(150);
      {NvencDeadline::Guard guard(d);Sleep(10);} }
    wchar_t exe[32768];if(!GetModuleFileNameW(nullptr,exe,32768))return 1;
    std::wstring command=L"\""+std::wstring(exe)+L"\" --wedged-child";
    STARTUPINFOW startup{};startup.cb=sizeof(startup);PROCESS_INFORMATION child{};
    if(!CreateProcessW(exe,command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&child))return 1;
    const auto wait=WaitForSingleObject(child.hProcess,3000);DWORD code=0;
    if(wait!=WAIT_OBJECT_0)TerminateProcess(child.hProcess,73);
    GetExitCodeProcess(child.hProcess,&code);CloseHandle(child.hThread);CloseHandle(child.hProcess);
    if(wait!=WAIT_OBJECT_0||code!=72)return 1;
    std::cout<<"nvenc_deadline normal_disarm=pass wedged_own_child=72 no_gpu=1\n";return 0;
}
