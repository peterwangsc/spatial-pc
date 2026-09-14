#pragma once
#include <array>
#include <cstdint>
#include <cstring>
#include <stdexcept>

struct InputEvent { uint8_t kind, flags; uint32_t sequence; int32_t a,b,c; };
inline uint16_t hidScanCode(int usage) {
    static constexpr uint16_t letters[]={0x1e,0x30,0x2e,0x20,0x12,0x21,0x22,0x23,0x17,0x24,0x25,0x26,0x32,0x31,0x18,0x19,0x10,0x13,0x1f,0x14,0x16,0x2f,0x11,0x2d,0x15,0x2c};
    if(usage>=4&&usage<=29)return letters[usage-4];
    if(usage>=30&&usage<=38)return uint16_t(usage-28);
    if(usage==39)return 0x0b;
    static constexpr uint16_t controls[]={0x1c,0x01,0x0e,0x0f,0x39,0x0c,0x0d,0x1a,0x1b,0x2b,0x2b,0x27,0x28,0x29,0x33,0x34,0x35,0x3a};
    if(usage>=0x28&&usage<=0x39)return controls[usage-0x28];
    if(usage>=0x3a&&usage<=0x43)return uint16_t(usage+1);
    if(usage==0x44)return 0x57;
    if(usage==0x45)return 0x58;
    static constexpr uint16_t navigation[]={0x152,0x147,0x149,0x153,0x14f,0x151,0x14d,0x14b,0x150,0x148};
    if(usage>=0x49&&usage<=0x52)return navigation[usage-0x49];
    static constexpr uint16_t keypad[]={0x45,0x135,0x37,0x4a,0x4e,0x11c,0x4f,0x50,0x51,0x4b,0x4c,0x4d,0x47,0x48,0x49,0x52,0x53,0x56,0x15d};
    if(usage>=0x53&&usage<=0x65)return keypad[usage-0x53];
    static constexpr uint16_t modifiers[]={0x1d,0x2a,0x38,0x15b,0x11d,0x36,0x138,0x15c};
    return usage>=0xe0&&usage<=0xe7?modifiers[usage-0xe0]:0;
}
inline InputEvent parseInput(const std::array<uint8_t,24>& bytes) {
    auto u32=[&](size_t offset){return uint32_t(bytes[offset])<<24|uint32_t(bytes[offset+1])<<16|uint32_t(bytes[offset+2])<<8|bytes[offset+3];};
    auto i32=[&](size_t offset){const auto value=u32(offset);int32_t result;std::memcpy(&result,&value,4);return result;};
    InputEvent e{bytes[4],bytes[5],u32(8),i32(12),i32(16),i32(20)};
    if(std::memcmp(bytes.data(),"SPI1",4)||bytes[6]||bytes[7]||!e.sequence||e.kind<1||e.kind>7)throw std::runtime_error("Invalid input header");
    const auto allowed=e.kind==2?1:e.kind==4?3:0;
    if(e.flags&~allowed)throw std::runtime_error("Invalid input flags");
    if(e.kind<=2) {
        if(e.a<0||e.a>65535||e.b<0||e.b>65535||(e.kind==1?e.c!=0:e.c<1||e.c>3))throw std::runtime_error("Invalid pointer input");
    } else if(e.kind==3) {
        if(e.a < -1200||e.a>1200||e.b < -1200||e.b>1200||e.c)throw std::runtime_error("Invalid wheel input");
    } else if(e.kind==4) {
        if(!hidScanCode(e.a)||e.b||e.c||e.flags==2)throw std::runtime_error("Invalid keyboard input");
    } else if(e.a||e.b||e.c)throw std::runtime_error("Invalid control input");
    return e;
}
