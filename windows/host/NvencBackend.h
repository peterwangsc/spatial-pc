#pragma once
#include "NvencConfig.h"
#include "NvencFrame.h"
#include "NvencDeadline.h"
#include <array>
#include <functional>
#include <vector>
#include <memory>
#include <string>
#include <algorithm>

class NvencUnavailable : public std::runtime_error { public: using std::runtime_error::runtime_error; };

inline void nvCheck(NVENCSTATUS status, const char* operation) {
    if (status != NV_ENC_SUCCESS)
        throw std::runtime_error(std::string(operation) + " status=" + std::to_string(status));
}

class NvencApi {
    HMODULE library = nullptr;
public:
    NvencApi() = default;
    NvencApi(const NvencApi&) = delete;
    NvencApi& operator=(const NvencApi&) = delete;
    NV_ENCODE_API_FUNCTION_LIST functions{};
    uint32_t maximum = 0;
    ~NvencApi() { if (library) FreeLibrary(library); }
    void load() {
        // Never consult cwd, PATH, or the app directory for an encoder DLL.
        library = LoadLibraryExW(L"nvEncodeAPI64.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!library) throw std::runtime_error("System NVENC library unavailable");
        using Version = NVENCSTATUS(NVENCAPI*)(uint32_t*);
        using Create = NVENCSTATUS(NVENCAPI*)(NV_ENCODE_API_FUNCTION_LIST*);
        auto version = reinterpret_cast<Version>(GetProcAddress(library, "NvEncodeAPIGetMaxSupportedVersion"));
        auto create = reinterpret_cast<Create>(GetProcAddress(library, "NvEncodeAPICreateInstance"));
        if (!version || !create) throw std::runtime_error("NVENC exports unavailable");
        nvCheck(version(&maximum), "NvEncodeAPIGetMaxSupportedVersion");
        if (maximum < ((NVENCAPI_MAJOR_VERSION << 4) | NVENCAPI_MINOR_VERSION))
            throw std::runtime_error("NVENC driver API is older than 12.2");
        functions.version = NV_ENCODE_API_FUNCTION_LIST_VER;
        nvCheck(create(&functions), "NvEncodeAPICreateInstance");
        if (!functions.nvEncOpenEncodeSessionEx || !functions.nvEncGetEncodeGUIDCount || !functions.nvEncGetEncodeGUIDs ||
            !functions.nvEncGetEncodeCaps || !functions.nvEncGetInputFormatCount || !functions.nvEncGetInputFormats ||
            !functions.nvEncGetEncodePresetConfigEx || !functions.nvEncInitializeEncoder || !functions.nvEncRegisterResource ||
            !functions.nvEncUnregisterResource || !functions.nvEncMapInputResource || !functions.nvEncUnmapInputResource ||
            !functions.nvEncCreateBitstreamBuffer || !functions.nvEncDestroyBitstreamBuffer || !functions.nvEncEncodePicture ||
            !functions.nvEncRegisterAsyncEvent || !functions.nvEncUnregisterAsyncEvent || !functions.nvEncLockBitstream ||
            !functions.nvEncUnlockBitstream || !functions.nvEncDestroyEncoder)
            throw std::runtime_error("Incomplete NVENC 12.2 function table");
    }
};

// Correctness-first optional streaming backend. Four reusable I/O surfaces,
// one outstanding submission; no hidden frame queue or encode/output delay.
class NvencBackend {
    struct Slot {
        ComPtr<ID3D11Texture2D> texture;
        ComPtr<ID3D11VideoProcessorOutputView> view;
        ComPtr<ID3D11Query> producer;
        NV_ENC_REGISTERED_PTR registered = nullptr;
        NV_ENC_INPUT_PTR mapped = nullptr;
        NV_ENC_OUTPUT_PTR output = nullptr;
        HANDLE completion = nullptr;
        bool eventRegistered = false, locked = false;
    };
    struct Resources {
        NvencApi api;
        ComPtr<ID3D11Device> device;
        ComPtr<ID3D11DeviceContext> context;
        std::array<Slot, 4> slots;
        void* session = nullptr;
        bool initialized = false;
    };
    std::unique_ptr<Resources> resources = std::make_unique<Resources>();
    NvencDeadline watchdog;
    UINT width = 0, height = 0, fps = 60;
    size_t next = 0;
    uint32_t frames = 0;
    bool unsafe = false, leased = false;
    uint64_t timestamp = 0;
    PerfStats& stats;
    std::function<void(uint64_t, const BYTE*, uint32_t)> output;

    template<class F> auto call(F&& f) { NvencDeadline::Guard guard(watchdog); return f(); }
    auto& api() { return resources->api.functions; }
    Slot& slot() { return resources->slots[next]; }
    int cap(NV_ENC_CAPS id) {
        NV_ENC_CAPS_PARAM query{}; query.version = NV_ENC_CAPS_PARAM_VER; query.capsToQuery = id;
        int value = 0;
        call([&] { nvCheck(api().nvEncGetEncodeCaps(resources->session, NV_ENC_CODEC_H264_GUID, &query, &value), "NVENC capability"); });
        return value;
    }
    static void boundedCount(uint32_t n) { if (!n || n > 64) throw std::runtime_error("Invalid NVENC capability count"); }
    void initialize(ID3D11Device* device, ID3D11DeviceContext* context, ID3D11VideoDevice* video,
                    ID3D11VideoProcessorEnumerator* enumerator, UINT w, UINT h) {
        validateNvencSize(w, h, fps); width = w; height = h;
        resources->device = device; resources->context = context;
        call([&] { resources->api.load(); });
        NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS open{};
        open.version = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER; open.deviceType = NV_ENC_DEVICE_TYPE_DIRECTX;
        open.device = device; open.apiVersion = NVENCAPI_VERSION;
        call([&] { nvCheck(api().nvEncOpenEncodeSessionEx(&open, &resources->session), "NVENC open D3D11 session"); });
        uint32_t count = 0, written = 0;
        call([&] { nvCheck(api().nvEncGetEncodeGUIDCount(resources->session, &count), "NVENC codec count"); });
        boundedCount(count); std::vector<GUID> codecs(count);
        call([&] { nvCheck(api().nvEncGetEncodeGUIDs(resources->session, codecs.data(), count, &written), "NVENC codecs"); });
        if (written > count || std::find(codecs.begin(), codecs.begin() + written, NV_ENC_CODEC_H264_GUID) == codecs.begin() + written)
            throw std::runtime_error("NVENC H264 unavailable");
        call([&] { nvCheck(api().nvEncGetInputFormatCount(resources->session, NV_ENC_CODEC_H264_GUID, &count), "NVENC format count"); });
        boundedCount(count); std::vector<NV_ENC_BUFFER_FORMAT> formats(count);
        call([&] { nvCheck(api().nvEncGetInputFormats(resources->session, NV_ENC_CODEC_H264_GUID, formats.data(), count, &written), "NVENC formats"); });
        if (written > count || std::find(formats.begin(), formats.begin() + written, NV_ENC_BUFFER_FORMAT_NV12) == formats.begin() + written)
            throw std::runtime_error("NVENC NV12 unavailable");
        const auto async = cap(NV_ENC_CAPS_ASYNC_ENCODE_SUPPORT), maxWidth = cap(NV_ENC_CAPS_WIDTH_MAX), maxHeight = cap(NV_ENC_CAPS_HEIGHT_MAX);
        if (async != 1 || maxWidth < int(width) || maxHeight < int(height))
            throw std::runtime_error("NVENC async/dimension capability unavailable");
        NV_ENC_PRESET_CONFIG preset{}; preset.version = NV_ENC_PRESET_CONFIG_VER; preset.presetCfg.version = NV_ENC_CONFIG_VER;
        call([&] { nvCheck(api().nvEncGetEncodePresetConfigEx(resources->session, NV_ENC_CODEC_H264_GUID,
            NV_ENC_PRESET_P1_GUID, NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY, &preset), "NVENC P1 ULL preset"); });
        configureNvenc(preset.presetCfg, fps);
        NV_ENC_INITIALIZE_PARAMS init{}; init.version = NV_ENC_INITIALIZE_PARAMS_VER;
        init.encodeGUID = NV_ENC_CODEC_H264_GUID; init.presetGUID = NV_ENC_PRESET_P1_GUID;
        init.encodeWidth = init.darWidth = init.maxEncodeWidth = width;
        init.encodeHeight = init.darHeight = init.maxEncodeHeight = height;
        init.frameRateNum = fps; init.frameRateDen = 1; init.enableEncodeAsync = 1; init.enablePTD = 1;
        init.tuningInfo = NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY; init.encodeConfig = &preset.presetCfg;
        call([&] { nvCheck(api().nvEncInitializeEncoder(resources->session, &init), "NVENC initialize"); });
        resources->initialized = true;
        for (auto& s : resources->slots) {
            D3D11_TEXTURE2D_DESC td{}; td.Width = width; td.Height = height; td.MipLevels = 1; td.ArraySize = 1;
            td.Format = DXGI_FORMAT_NV12; td.SampleDesc.Count = 1; td.Usage = D3D11_USAGE_DEFAULT; td.BindFlags = D3D11_BIND_RENDER_TARGET;
            check(device->CreateTexture2D(&td, nullptr, &s.texture), "NVENC texture");
            D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ov{}; ov.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
            check(video->CreateVideoProcessorOutputView(s.texture.Get(), enumerator, &ov, &s.view), "NVENC processor target");
            D3D11_QUERY_DESC query{ D3D11_QUERY_EVENT, 0 }; check(device->CreateQuery(&query, &s.producer), "NVENC producer query");
            NV_ENC_REGISTER_RESOURCE reg{}; reg.version = NV_ENC_REGISTER_RESOURCE_VER;
            reg.resourceType = NV_ENC_INPUT_RESOURCE_TYPE_DIRECTX; reg.resourceToRegister = s.texture.Get();
            reg.width = width; reg.height = height; reg.bufferFormat = NV_ENC_BUFFER_FORMAT_NV12; reg.bufferUsage = NV_ENC_INPUT_IMAGE;
            call([&] { nvCheck(api().nvEncRegisterResource(resources->session, &reg), "NVENC register texture"); });
            s.registered = reg.registeredResource;
            NV_ENC_CREATE_BITSTREAM_BUFFER buffer{}; buffer.version = NV_ENC_CREATE_BITSTREAM_BUFFER_VER;
            call([&] { nvCheck(api().nvEncCreateBitstreamBuffer(resources->session, &buffer), "NVENC output buffer"); });
            s.output = buffer.bitstreamBuffer;
            s.completion = CreateEventW(nullptr, FALSE, FALSE, nullptr);
            if (!s.completion) throw std::runtime_error("NVENC event allocation");
            NV_ENC_EVENT_PARAMS event{}; event.version = NV_ENC_EVENT_PARAMS_VER; event.completionEvent = s.completion;
            call([&] { nvCheck(api().nvEncRegisterAsyncEvent(resources->session, &event), "NVENC register event"); });
            s.eventRegistered = true;
        }
        std::cerr << "nvenc_caps api_max=" << resources->api.maximum << " async=" << async << " width_max=" << maxWidth << " height_max=" << maxHeight << '\n';
        std::cerr << "nvenc_settings api=12.2 codec=h264 profile=high preset=P1 tuning=ULL fps=60 bitrate=20000000 max_bitrate=20000000 gop=60 b_frames_requested=0 lookahead=0 multipass=0 aq=0 temporal_aq=0 vbv_bits=333333 initial_vbv_bits=333333 pool=4 max_inflight=1 color_vui=unspecified bitstream_verified=0\n";
    }
    void close() {
        if (!resources) return;
        try {
        if (unsafe || leased) {
            // Unknown producer/driver ownership cannot safely be unregistered.
            // This capture process will exit; keep device, surfaces and DLL alive.
            resources.release();
            throw std::runtime_error("NVENC resources quarantined until capture process exit");
        }
        if (resources->initialized) finish();
        if (resources->session) {
            for (auto& s : resources->slots) {
                if (s.mapped) unmapSlot(s);
                if (s.registered) { call([&] { nvCheck(api().nvEncUnregisterResource(resources->session, s.registered), "NVENC unregister texture"); }); s.registered = nullptr; }
                if (s.output) { call([&] { nvCheck(api().nvEncDestroyBitstreamBuffer(resources->session, s.output), "NVENC destroy output"); }); s.output = nullptr; }
                if (s.eventRegistered) {
                    NV_ENC_EVENT_PARAMS event{}; event.version = NV_ENC_EVENT_PARAMS_VER; event.completionEvent = s.completion;
                    call([&] { nvCheck(api().nvEncUnregisterAsyncEvent(resources->session, &event), "NVENC unregister event"); }); s.eventRegistered = false;
                }
                if (s.completion) { CloseHandle(s.completion); s.completion = nullptr; }
            }
            call([&] { nvCheck(api().nvEncDestroyEncoder(resources->session), "NVENC destroy session"); }); resources->session = nullptr;
        }
        resources.reset();
        } catch (...) {
            // An ambiguous cleanup failure must not be retried by the destructor.
            resources.release();
            throw;
        }
    }
    void unmapSlot(Slot& s) {
        call([&] { nvCheck(api().nvEncUnmapInputResource(resources->session, s.mapped), "NVENC unmap texture"); }); s.mapped = nullptr;
    }
public:
    NvencBackend(PerfStats& p, std::function<void(uint64_t, const BYTE*, uint32_t)> sink) : stats(p), output(std::move(sink)) {}
    ~NvencBackend() {
        try { close(); } catch (const std::exception& e) { resources.release(); std::cerr << "nvenc_cleanup_failed=" << e.what() << '\n'; }
    }
    static std::unique_ptr<NvencBackend> create(ID3D11Device* d, ID3D11DeviceContext* c, ID3D11VideoDevice* v,
        ID3D11VideoProcessorEnumerator* e, UINT w, UINT h, PerfStats& p, std::function<void(uint64_t, const BYTE*, uint32_t)> sink) {
        auto result = std::make_unique<NvencBackend>(p, std::move(sink));
        try { result->initialize(d, c, v, e, w, h); }
        catch (const std::exception& error) {
            const std::string reason = error.what();
            result->close(); // Fallback is allowed ONLY after successful cleanup, before first frame.
            throw NvencUnavailable(reason);
        }
        return result;
    }
    ID3D11VideoProcessorOutputView* acquire() {
        if (!resources || unsafe || leased) throw std::runtime_error("NVENC surface ownership invalid");
        leased = true; return slot().view.Get();
    }
    void abandonUnwritten() { // Only for AcquireNextFrame timeout: no GPU writes were issued.
        if (!leased) throw std::runtime_error("NVENC no surface lease");
        leased = false;
    }
    void drainAbandonedProducer() noexcept {
        if (!leased) return;
        try {
            if (unsafe || slot().mapped) throw std::runtime_error("Unknown abandoned frame ownership");
            call([&] { resources->context->End(slot().producer.Get()); resources->context->Flush(); });
            waitProducer(); leased = false;
        } catch (...) { TerminateProcess(GetCurrentProcess(), 72); }
    }
    template<class Alive> bool encode(uint64_t pts, Alive&& alive) {
        if (!leased || unsafe) throw std::runtime_error("NVENC encode ownership invalid");
        timestamp = pts;
        call([&] { resources->context->End(slot().producer.Get()); resources->context->Flush(); });
        bool delivered = false;
        try { delivered = spatialpc::finishNvencFrame(*this, std::forward<Alive>(alive)); }
        catch (...) {
            // Do not unwind the DXGI frame lease if completion is uncertain.
            // Kill only this opt-in capture child; OS/driver reclaim its objects.
            if (unsafe) TerminateProcess(GetCurrentProcess(), 72);
            throw;
        }
        leased = false; next = (next + 1) % resources->slots.size();
        return delivered;
    }
    void waitProducer() {
        NvencDeadline::Guard guard(watchdog); const auto start = perfCounter(); BOOL ready = FALSE;
        for (;;) {
            const auto hr = resources->context->GetData(slot().producer.Get(), &ready, sizeof(ready), D3D11_ASYNC_GETDATA_DONOTFLUSH);
            check(hr, "NVENC producer completion"); if (hr == S_OK && ready) break;
            if (perfMs(perfCounter() - start) >= 5000) throw std::runtime_error("NVENC producer timeout"); Sleep(1);
        }
        stats.add("nvenc_producer_wait_ms", perfMs(perfCounter() - start));
    }
    void map() {
        NV_ENC_MAP_INPUT_RESOURCE map{}; map.version = NV_ENC_MAP_INPUT_RESOURCE_VER; map.registeredResource = slot().registered;
        call([&] { nvCheck(api().nvEncMapInputResource(resources->session, &map), "NVENC map texture"); }); slot().mapped = map.mappedResource;
    }
    void submit() {
        ResetEvent(slot().completion);
        NV_ENC_PIC_PARAMS pic{}; pic.version = NV_ENC_PIC_PARAMS_VER; pic.inputBuffer = slot().mapped;
        pic.bufferFmt = NV_ENC_BUFFER_FORMAT_NV12; pic.inputWidth = width; pic.inputHeight = height;
        pic.outputBitstream = slot().output; pic.completionEvent = slot().completion;
        pic.inputTimeStamp = timestamp; pic.inputDuration = 10000000 / fps; pic.frameIdx = frames;
        pic.pictureStruct = NV_ENC_PIC_STRUCT_FRAME;
        if (!frames) pic.encodePicFlags = NV_ENC_PIC_FLAG_FORCEIDR;
        const auto start = perfCounter();
        call([&] { nvCheck(api().nvEncEncodePicture(resources->session, &pic), "NVENC submit"); }); ++frames;
        stats.add("nvenc_submit_ms", perfMs(perfCounter() - start));
    }
    void waitEncoder() {
        NvencDeadline::Guard guard(watchdog);
        const auto start = perfCounter();
        if (WaitForSingleObject(slot().completion, 5000) != WAIT_OBJECT_0) throw std::runtime_error("NVENC completion timeout");
        stats.add("nvenc_completion_wait_ms", perfMs(perfCounter() - start));
    }
    void deliver() {
        NV_ENC_LOCK_BITSTREAM locked{}; locked.version = NV_ENC_LOCK_BITSTREAM_VER; locked.outputBitstream = slot().output; locked.doNotWait = 1;
        call([&] { nvCheck(api().nvEncLockBitstream(resources->session, &locked), "NVENC lock output"); });
        slot().locked = true;
        try {
            if (!locked.bitstreamBufferPtr || !locked.bitstreamSizeInBytes || locked.bitstreamSizeInBytes > 16 * 1024 * 1024 || locked.outputTimeStamp != timestamp)
                throw std::runtime_error("NVENC output bounds/timestamp mismatch");
            // Frame bytes live only until the existing synchronous pipe callback completes.
            call([&] { output(timestamp, static_cast<const BYTE*>(locked.bitstreamBufferPtr), locked.bitstreamSizeInBytes); });
        } catch (...) {
            call([&] { nvCheck(api().nvEncUnlockBitstream(resources->session, slot().output), "NVENC unlock output"); }); slot().locked = false; throw;
        }
        call([&] { nvCheck(api().nvEncUnlockBitstream(resources->session, slot().output), "NVENC unlock output"); }); slot().locked = false;
    }
    void unmap() { if (slot().locked) { quarantine(); throw std::runtime_error("NVENC output remains locked"); } unmapSlot(slot()); }
    void quarantine() noexcept { unsafe = true; }
    void finish() {
        if (!resources || !resources->initialized) return;
        if (leased || unsafe) throw std::runtime_error("NVENC finish has outstanding ownership");
        if (frames) {
            ResetEvent(slot().completion);
            NV_ENC_PIC_PARAMS eos{}; eos.version = NV_ENC_PIC_PARAMS_VER; eos.encodePicFlags = NV_ENC_PIC_FLAG_EOS; eos.completionEvent = slot().completion;
            unsafe = true;
            call([&] { nvCheck(api().nvEncEncodePicture(resources->session, &eos), "NVENC EOS"); }); waitEncoder(); unsafe = false;
        }
        resources->initialized = false;
    }
};
