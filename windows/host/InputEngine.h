#pragma once
#include <windows.h>
#include <array>
#include <functional>
#include <vector>
#include "InputProtocol.h"

struct InputGeometry { RECT monitor; RECT desktop; int width,height; };
class InputEngine {
    InputGeometry geometry;
    std::function<UINT(const std::vector<INPUT>&)> inject;
    std::array<bool,256> keys{};
    std::array<bool,4> buttons{};
    std::array<WORD,2> unicodeOwned{};
    size_t unicodeCount=0;
    uint32_t sequence=0;
    uint64_t last=0;
    bool controlling=false;
    INPUT unicodeKey(WORD unit,bool down) const {
        INPUT value{};value.type=INPUT_KEYBOARD;value.ki.wScan=unit;
        value.ki.dwFlags=KEYEVENTF_UNICODE|(down?0:KEYEVENTF_KEYUP);return value;
    }
    INPUT key(int usage,bool down) const {
        const auto scan=hidScanCode(usage);INPUT value{};value.type=INPUT_KEYBOARD;
        value.ki.wScan=WORD(scan&255);value.ki.dwFlags=KEYEVENTF_SCANCODE|(scan&0x100?KEYEVENTF_EXTENDEDKEY:0)|(down?0:KEYEVENTF_KEYUP);
        return value;
    }
    INPUT button(int id,bool down) const {
        INPUT value{};value.type=INPUT_MOUSE;
        static constexpr DWORD flags[3][2]={{MOUSEEVENTF_LEFTUP,MOUSEEVENTF_LEFTDOWN},{MOUSEEVENTF_RIGHTUP,MOUSEEVENTF_RIGHTDOWN},{MOUSEEVENTF_MIDDLEUP,MOUSEEVENTF_MIDDLEDOWN}};
        value.mi.dwFlags=flags[id-1][down?1:0];return value;
    }
    INPUT move(int x,int y) const {
        const int64_t px=geometry.monitor.left+(int64_t(x)*(geometry.width-1)+32767)/65535;
        const int64_t py=geometry.monitor.top+(int64_t(y)*(geometry.height-1)+32767)/65535;
        const int64_t dw=geometry.desktop.right-geometry.desktop.left-1,dh=geometry.desktop.bottom-geometry.desktop.top-1;
        INPUT value{};value.type=INPUT_MOUSE;value.mi.dwFlags=MOUSEEVENTF_MOVE|MOUSEEVENTF_ABSOLUTE|MOUSEEVENTF_VIRTUALDESK;
        value.mi.dx=LONG(((px-geometry.desktop.left)*65535+dw/2)/dw);
        value.mi.dy=LONG(((py-geometry.desktop.top)*65535+dh/2)/dh);return value;
    }
public:
    InputEngine(InputGeometry bounds,std::function<UINT(const std::vector<INPUT>&)> sink):geometry(bounds),inject(std::move(sink)) {
        if(bounds.width<2||bounds.height<2||bounds.monitor.right-bounds.monitor.left<bounds.width||bounds.monitor.bottom-bounds.monitor.top<bounds.height||bounds.desktop.right-bounds.desktop.left<2||bounds.desktop.bottom-bounds.desktop.top<2||bounds.monitor.left<bounds.desktop.left||bounds.monitor.top<bounds.desktop.top||bounds.monitor.right>bounds.desktop.right||bounds.monitor.bottom>bounds.desktop.bottom)throw std::runtime_error("Invalid input geometry");
    }
    bool active() const {return controlling;}
    bool release() {
        controlling=false;std::vector<INPUT> releases;
        for(size_t i=0;i<keys.size();++i)if(keys[i])releases.push_back(key(int(i),false));
        for(int i=1;i<=3;++i)if(buttons[size_t(i)])releases.push_back(button(i,false));
        for(size_t i=0;i<unicodeCount;++i)releases.push_back(unicodeKey(unicodeOwned[i],false));
        if(!releases.empty()&&inject(releases)!=releases.size())return false;
        keys.fill(false);buttons.fill(false);unicodeOwned.fill(0);unicodeCount=0;return true;
    }
    bool expired(uint64_t now) const {return controlling&&now-last>=2000;}
    void apply(const InputEvent& e,uint64_t now) {
        // The authenticated wire gate checks sequence 1. Local queue cancellation
        // and adjacent-move replacement can leave gaps before this helper.
        if(e.sequence<=sequence||expired(now))throw std::runtime_error("Input sequence or lease invalid");
        sequence=e.sequence;last=now;
        if(e.kind==5){if(!release())throw std::runtime_error("Input release failed");controlling=true;return;}
        if(e.kind==6){if(!release())throw std::runtime_error("Input release failed");return;}
        if(e.kind==7)return;
        if(!controlling)throw std::runtime_error("Input control inactive");
        if(unicodeCount)throw std::runtime_error("Pending text release");
        auto desiredKeys=keys;auto desiredButtons=buttons;
        std::vector<INPUT> values;
        if(e.kind==1)values.push_back(move(e.a,e.b));
        else if(e.kind==2){values.push_back(move(e.a,e.b));const bool down=(e.flags&1)!=0;if(buttons[size_t(e.c)]!=down){desiredButtons[size_t(e.c)]=down;if(down)buttons[size_t(e.c)]=true;values.push_back(button(e.c,down));}}
        else if(e.kind==3){for(int axis=0;axis<2;++axis){const int amount=axis?e.b:e.a;if(amount){INPUT value{};value.type=INPUT_MOUSE;value.mi.dwFlags=axis?MOUSEEVENTF_HWHEEL:MOUSEEVENTF_WHEEL;value.mi.mouseData=DWORD(amount);values.push_back(value);}}}
        else if(e.kind==4){const bool down=(e.flags&1)!=0,repeat=(e.flags&2)!=0;if(repeat&&!keys[size_t(e.a)])throw std::runtime_error("Repeat without held key");if(down&&!keys[size_t(e.a)]&&e.a<0xe0){size_t held=0;for(size_t i=0;i<0xe0;++i)held+=keys[i]?1:0;if(held>=32)throw std::runtime_error("Held key bound exceeded");}if(keys[size_t(e.a)]!=down||repeat){desiredKeys[size_t(e.a)]=down;if(down)keys[size_t(e.a)]=true;values.push_back(key(e.a,down));}}
        else if(e.kind==8){
            if(e.flags||e.b||e.c||!validTextScalar(e.a))throw std::runtime_error("Invalid text input");
            if(e.a<=0xffff){unicodeOwned[0]=WORD(e.a);unicodeCount=1;}
            else {const auto scalar=uint32_t(e.a)-0x10000;unicodeOwned[0]=WORD(0xd800+(scalar>>10));unicodeOwned[1]=WORD(0xdc00+(scalar&0x3ff));unicodeCount=2;}
            for(size_t i=0;i<unicodeCount;++i){values.push_back(unicodeKey(unicodeOwned[i],true));values.push_back(unicodeKey(unicodeOwned[i],false));}
        }
        if(!values.empty()&&inject(values)!=values.size())throw std::runtime_error("Input injection failed");
        // Keep releases owned until Windows accepts them. Failed/partial downs
        // are conservatively owned too, so teardown retries every possible hold.
        keys=desiredKeys;buttons=desiredButtons;unicodeOwned.fill(0);unicodeCount=0;
    }
};
