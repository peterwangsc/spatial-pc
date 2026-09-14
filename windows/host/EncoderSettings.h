#pragma once
#include <strmif.h>

inline void codecSetting(ICodecAPI* api, const GUID& property, const char* name, ULONG desired, bool boolean, bool configure) {
    VARIANT value; VariantInit(&value);
    HRESULT set = S_FALSE;
    if (configure) {
        value.vt = static_cast<VARTYPE>(boolean ? VT_BOOL : VT_UI4);
        if (boolean) value.boolVal = desired ? VARIANT_TRUE : VARIANT_FALSE; else value.ulVal = desired;
        set = api->SetValue(&property, &value);
    }
    VariantClear(&value); VariantInit(&value);
    const HRESULT get = api->GetValue(&property, &value);
    std::cerr << "codec_setting=" << name << " set_hr=0x" << std::hex << set << " get_hr=0x" << get << std::dec;
    if (SUCCEEDED(get)) {
        if (value.vt == VT_UI4) std::cerr << " value=" << value.ulVal;
        else if (value.vt == VT_BOOL) std::cerr << " value=" << (value.boolVal != VARIANT_FALSE);
        else std::cerr << " variant_type=" << value.vt;
    }
    std::cerr << '\n'; VariantClear(&value);
}

inline bool inspectEncoder(IMFSinkWriter* writer, DWORD stream, bool configure, UINT fps) {
    ComPtr<IMFSinkWriterEx> ex; check(writer->QueryInterface(IID_PPV_ARGS(&ex)), "SinkWriterEx");
    bool hardware = false;
    for (DWORD i = 0; i < 8; ++i) {
        GUID category; ComPtr<IMFTransform> transform;
        if (FAILED(ex->GetTransformForStream(stream, i, &category, &transform))) break;
        ComPtr<IMFAttributes> attrs;
        if (SUCCEEDED(transform->GetAttributes(&attrs))) {
            UINT32 aware = 0, length = 0; attrs->GetUINT32(MF_SA_D3D11_AWARE, &aware);
            const bool isHardware = SUCCEEDED(attrs->GetStringLength(MFT_ENUM_HARDWARE_URL_Attribute, &length)) && length;
            hardware = hardware || isHardware;
            std::cerr << "transform=" << i << " d3d11_aware=" << aware << " hardware_marker=" << isHardware << '\n';
            WCHAR name[512]{};
            if (SUCCEEDED(attrs->GetString(MFT_FRIENDLY_NAME_Attribute, name, 512, nullptr))) std::wcerr << L"selected_encoder=" << name << L'\n';
        }
        if (category == MFT_CATEGORY_VIDEO_ENCODER) {
            ComPtr<ICodecAPI> api;
            if (SUCCEEDED(transform.As(&api))) {
                codecSetting(api.Get(), CODECAPI_AVLowLatencyMode, "low_latency", 1, true, configure);
                codecSetting(api.Get(), CODECAPI_AVEncMPVDefaultBPictureCount, "b_frames", 0, false, configure);
                codecSetting(api.Get(), CODECAPI_AVEncMPVGOPSize, "gop", fps, false, configure);
                codecSetting(api.Get(), CODECAPI_AVEncCommonRateControlMode, "rate_control", eAVEncCommonRateControlMode_CBR, false, configure);
                codecSetting(api.Get(), CODECAPI_AVEncCommonMeanBitRate, "bitrate", 20000000, false, configure);
                codecSetting(api.Get(), CODECAPI_AVEncCommonBufferSize, "buffer_size", 0, false, false);
            }
        }
    }
    return hardware;
}
