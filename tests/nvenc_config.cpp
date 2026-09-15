#define NOMINMAX
#include <windows.h>
#include <cstdint>
#include "../windows/host/NvencConfig.h"
#include <iostream>
void require(bool value){if(!value)throw std::runtime_error("configuration mismatch");}
int main() {
 try {
    NV_ENC_CONFIG c{};c.frameIntervalP=4;c.rcParams.enableLookahead=1;c.rcParams.lookaheadDepth=16;
    c.rcParams.enableAQ=1;c.rcParams.enableTemporalAQ=1;c.rcParams.multiPass=NV_ENC_TWO_PASS_FULL_RESOLUTION;
    c.encodeCodecConfig.h264Config.inputBitDepth=NV_ENC_BIT_DEPTH_10;
    c.encodeCodecConfig.h264Config.h264VUIParameters.videoSignalTypePresentFlag=1;
    configureNvenc(c,60);
    require(c.version==NV_ENC_CONFIG_VER&&c.frameIntervalP==1&&c.gopLength==60&&c.profileGUID==NV_ENC_H264_PROFILE_HIGH_GUID);
    require(c.rcParams.rateControlMode==NV_ENC_PARAMS_RC_CBR&&c.rcParams.averageBitRate==20000000&&c.rcParams.maxBitRate==20000000);
    require(!c.rcParams.enableLookahead&&!c.rcParams.lookaheadDepth&&!c.rcParams.enableAQ&&!c.rcParams.enableTemporalAQ);
    require(c.rcParams.multiPass==NV_ENC_MULTI_PASS_DISABLED&&c.rcParams.zeroReorderDelay&&c.rcParams.vbvBufferSize==333333&&c.rcParams.vbvInitialDelay==333333);
    auto& h=c.encodeCodecConfig.h264Config;
    require(h.chromaFormatIDC==1&&h.inputBitDepth==NV_ENC_BIT_DEPTH_8&&h.outputBitDepth==NV_ENC_BIT_DEPTH_8&&h.repeatSPSPPS&&h.idrPeriod==60);
    require(!h.h264VUIParameters.videoSignalTypePresentFlag&&!h.enableTemporalSVC&&!h.enableIntraRefresh&&!h.enableFillerDataInsertion);
    validateNvencSize(1920,1080,60);validateNvencSize(8192,8192,60);
    unsigned invalid=0;
    for(auto dimensions:{std::pair{0u,1080u},std::pair{1921u,1080u},std::pair{1920u,1081u},std::pair{8194u,1080u}}){
      try{validateNvencSize(dimensions.first,dimensions.second,60);}catch(const std::runtime_error&){++invalid;}}
    try{validateNvencSize(1920,1080,120);}catch(const std::runtime_error&){++invalid;}
    require(invalid==5);
    std::cout<<"nvenc_settings pass invalid_dimensions_or_rate=5 no_gpu=1 bitstream_verified=0\n";return 0;
 }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
