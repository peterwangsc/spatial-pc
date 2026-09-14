#define NOMINMAX
#include <windows.h>
#include <iostream>
#include <stdexcept>
#include "../windows/host/InputEngine.h"
void expect(bool yes,const char* message){if(!yes)throw std::runtime_error(message);}
template<class F> void rejects(F operation){bool rejected=false;try{operation();}catch(const std::exception&){rejected=true;}expect(rejected,"Expected rejection");}
int main(){try{
    std::vector<INPUT> seen;bool fail=false;
    InputEngine engine({{-1920,0,0,1080},{-1920,-100,1920,1080},1920,1080},[&](const auto& values){if(fail)return UINT(0);seen.insert(seen.end(),values.begin(),values.end());return UINT(values.size());});
    rejects([&]{engine.apply({1,0,1,0,0,0},0);});
    engine.apply({5,0,2,0,0,0},0);
    engine.apply({2,1,3,0,0,1},1);
    expect(seen.size()==2&&seen[0].mi.dx==0&&seen[0].mi.dy>0&&seen[0].mi.dwFlags==(MOUSEEVENTF_MOVE|MOUSEEVENTF_ABSOLUTE|MOUSEEVENTF_VIRTUALDESK)&&seen[1].mi.dwFlags==MOUSEEVENTF_LEFTDOWN,"Click maps negative-origin monitor before button down");
    engine.apply({1,0,4,65535,65535,0},2);
    expect(seen.back().mi.dx<32768&&seen.back().mi.dx>32700&&seen.back().mi.dy==65535,"Pointer endpoint remains on captured monitor");
    engine.apply({4,1,5,0xe4,0,0},3);
    expect(seen.back().ki.wScan==0x1d&&seen.back().ki.dwFlags==(KEYEVENTF_SCANCODE|KEYEVENTF_EXTENDEDKEY),"Right control uses extended physical scan code");
    engine.apply({4,1,6,4,0,0},4);const auto held=seen.size();
    engine.apply({4,1,7,4,0,0},5);expect(seen.size()==held,"Duplicate keydown is idempotent");
    engine.apply({4,3,8,4,0,0},6);expect(seen.size()==held+1,"Explicit held-key repeat is delivered");
    engine.apply({6,0,9,0,0,0},7);
    expect(!engine.active()&&seen.size()==held+4&&seen.back().mi.dwFlags==MOUSEEVENTF_LEFTUP,"Stop releases owned ordinary key, modifier and button");
    rejects([&]{engine.apply({1,0,10,0,0,0},8);});
    engine.apply({5,0,11,0,0,0},10);
    expect(!engine.expired(2009)&&engine.expired(2010),"Independent lease deadline is bounded");
    engine.apply({7,0,12,0,0,0},1000);expect(!engine.expired(2500),"Heartbeat renews an active lease");
    rejects([&]{engine.apply({4,3,13,5,0,0},1001);});
    fail=true;rejects([&]{engine.apply({4,1,14,6,0,0},1002);});
    expect(!engine.release(),"Failed injection retains conservative release state");
    fail=false;expect(engine.release()&&(seen.back().ki.dwFlags&KEYEVENTF_KEYUP),"Recovery retries release after injection failure");
    engine.apply({5,0,15,0,0,0},1100);
    for(uint32_t i=0;i<32;++i)engine.apply({4,1,16+i,int32_t(i+4),0,0},1101);
    rejects([&]{engine.apply({4,1,48,36,0,0},1102);});expect(engine.release(),"Bounded held keys release");
    engine.apply({5,0,49,0,0,0},1200);engine.apply({4,1,50,4,0,0},1201);engine.apply({2,1,51,0,0,1},1202);
    fail=true;rejects([&]{engine.apply({4,0,52,4,0,0},1203);});rejects([&]{engine.apply({2,0,53,0,0,1},1204);});
    fail=false;const auto beforeRelease=seen.size();expect(engine.release()&&seen.size()==beforeRelease+2,"Failed key/button ups retain ownership for teardown retry");
    std::array<uint8_t,24> packet{};std::memcpy(packet.data(),"SPI1",4);packet[4]=5;packet[11]=1;
    expect(parseInput(packet).kind==5,"Control record parses");
    packet[6]=1;rejects([&]{parseInput(packet);});packet[6]=0;packet[4]=4;packet[15]=0x46;rejects([&]{parseInput(packet);});
    expect(hidScanCode(0x44)==0x57&&hidScanCode(0x58)==0x11c&&hidScanCode(0x65)==0x15d&&!hidScanCode(0x46)&&!hidScanCode(0x48),"HID allowlist and extended keypad mapping");
    auto textPacket=[&](int32_t scalar){packet.fill(0);std::memcpy(packet.data(),"SPI1",4);packet[4]=8;packet[11]=1;for(int i=0;i<4;++i)packet[12+i]=uint8_t(uint32_t(scalar)>>(24-8*i));};
    for(int32_t scalar:{0x20,0x7e,0xa0,0xd7ff,0xe000,0xffff,0x10000,0x1f642,0x10ffff}){textPacket(scalar);expect(parseInput(packet,true).a==scalar,"Valid scalar");rejects([&]{parseInput(packet);});}
    for(int32_t scalar:{-1,0,0x1f,0x7f,0x9f,0xd800,0xdfff,0x110000}){textPacket(scalar);rejects([&]{parseInput(packet,true);});}
    textPacket(0x41);packet[5]=1;rejects([&]{parseInput(packet,true);});packet[5]=0;packet[19]=1;rejects([&]{parseInput(packet,true);});
    for(int32_t scalar:{0x41,0xe9,0x4e2d,0x1f642,0x10ffff}){
        std::vector<std::vector<INPUT>> batches;
        InputEngine textEngine({{0,0,2,2},{0,0,2,2},2,2},[&](const auto& v){batches.push_back(v);return UINT(v.size());});
        textEngine.apply({5,0,1,0,0,0},0);textEngine.apply({8,0,2,scalar,0,0},1);
        expect(batches.size()==1&&batches[0].size()==(scalar>0xffff?4u:2u),"One bounded batch per scalar");
        const auto& v=batches[0];for(size_t i=0;i<v.size();i+=2)expect(v[i].type==INPUT_KEYBOARD&&v[i].ki.wVk==0&&v[i].ki.dwFlags==KEYEVENTF_UNICODE&&v[i+1].ki.dwFlags==(KEYEVENTF_UNICODE|KEYEVENTF_KEYUP)&&v[i].ki.wScan==v[i+1].ki.wScan,"Unicode down/up pair");
        if(scalar>0xffff)expect(v[0].ki.wScan==0xd800+((scalar-0x10000)>>10)&&v[2].ki.wScan==0xdc00+((scalar-0x10000)&0x3ff),"Surrogate pair order");
        else expect(v[0].ki.wScan==scalar,"BMP unit");
        expect(textEngine.release()&&batches.size()==1,"Successful text retains no held units");
    }
    for(int32_t scalar:{0x41,0x1f642})for(UINT partial=0;partial<(scalar>0xffff?4u:2u);++partial){
        std::vector<INPUT> lastBatch;bool recovered=false;
        InputEngine textEngine({{0,0,2,2},{0,0,2,2},2,2},[&](const auto& v){lastBatch=v;return recovered?UINT(v.size()):std::min(partial,UINT(v.size()-1));});
        textEngine.apply({5,0,1,0,0,0},0);rejects([&]{textEngine.apply({8,0,2,scalar,0,0},1);});
        rejects([&]{textEngine.apply({8,0,3,0x42,0,0},2);});
        expect(!textEngine.release(),"Failed Unicode release keeps ownership");recovered=true;
        expect(textEngine.release()&&lastBatch.size()==(scalar>0xffff?2u:1u),"Retry releases every possibly held UTF16 unit");
        for(const auto& v:lastBatch)expect(v.ki.dwFlags==(KEYEVENTF_UNICODE|KEYEVENTF_KEYUP),"Cleanup never repeats Unicode down");
    }
    std::cout<<"PASS: input engine and Unicode scalar, UTF16 batch, negotiation, partial failure release checks\n";return 0;
}catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}}
