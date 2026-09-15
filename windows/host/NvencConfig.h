#pragma once
#include <nvEncodeAPI.h>
#include <stdexcept>

static_assert(NVENCAPI_MAJOR_VERSION == 12 && NVENCAPI_MINOR_VERSION == 2,
              "This adapter requires the pinned NVENC 12.2 ABI");

inline void configureNvenc(NV_ENC_CONFIG& config, uint32_t fps) {
    // Start from the queried P1/ULL preset, then override all latency controls.
    config.version = NV_ENC_CONFIG_VER;
    config.profileGUID = NV_ENC_H264_PROFILE_HIGH_GUID;
    config.gopLength = fps;
    config.frameIntervalP = 1; // zero B frames, subject to later bitstream verification
    config.frameFieldMode = NV_ENC_PARAMS_FRAME_FIELD_MODE_FRAME;
    config.rcParams.rateControlMode = NV_ENC_PARAMS_RC_CBR;
    config.rcParams.averageBitRate = 20000000;
    config.rcParams.maxBitRate = 20000000;
    config.rcParams.enableLookahead = 0;
    config.rcParams.lookaheadDepth = 0;
    config.rcParams.enableAQ = 0;
    config.rcParams.enableTemporalAQ = 0;
    config.rcParams.multiPass = NV_ENC_MULTI_PASS_DISABLED;
    config.rcParams.zeroReorderDelay = 1;
    config.rcParams.vbvBufferSize = 20000000 / fps;
    config.rcParams.vbvInitialDelay = config.rcParams.vbvBufferSize;
    auto& h264 = config.encodeCodecConfig.h264Config;
    h264.chromaFormatIDC = 1;
    h264.inputBitDepth = h264.outputBitDepth = NV_ENC_BIT_DEPTH_8;
    h264.useBFramesAsRef = NV_ENC_BFRAME_REF_MODE_DISABLED;
    h264.idrPeriod = fps;
    h264.repeatSPSPPS = 1;
    h264.disableSPSPPS = 0;
    h264.enableIntraRefresh = 0;
    h264.enableTemporalSVC = 0;
    h264.enableFillerDataInsertion = 0;
    // Baseline does not set a color matrix/range VUI. Keep it unspecified;
    // preserve the identical D3D11 VideoProcessor conversion/defaults.
    h264.h264VUIParameters = {};
}

inline void validateNvencSize(uint32_t width, uint32_t height, uint32_t fps) {
    if (!width || !height || (width & 1) || (height & 1) || width > 8192 || height > 8192 || fps != 60)
        throw std::runtime_error("NVENC candidate requires bounded even dimensions at 60fps");
}
