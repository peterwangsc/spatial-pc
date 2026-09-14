#pragma once
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <mutex>

// Local binary pipe only. The separate TLS harness owns network authentication.
// Each record is big-endian: payload length u32, timestamp in 100 ns u64,
// sample flags u32, followed by one H.264 access unit.
class EncodedSink final : public IMFSampleGrabberSinkCallback {
    std::atomic<ULONG> references{1};
    std::mutex mutex;
public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** result) override {
        if (!result) return E_POINTER;
        *result = nullptr;
        if (id == __uuidof(IUnknown) || id == __uuidof(IMFClockStateSink) ||
            id == __uuidof(IMFSampleGrabberSinkCallback)) {
            *result = static_cast<IMFSampleGrabberSinkCallback*>(this);
            AddRef(); return S_OK;
        }
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references; }
    ULONG STDMETHODCALLTYPE Release() override {
        const auto count = --references; if (!count) delete this; return count;
    }
    HRESULT STDMETHODCALLTYPE OnSetPresentationClock(IMFPresentationClock*) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnShutdown() override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnClockStart(MFTIME, LONGLONG) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnClockStop(MFTIME) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnClockPause(MFTIME) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnClockRestart(MFTIME) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnClockSetRate(MFTIME, float) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnProcessSample(REFGUID, DWORD flags, LONGLONG time,
        LONGLONG, const BYTE* data, DWORD length) override {
        if (!length || length > 16 * 1024 * 1024) return E_INVALIDARG;
        std::lock_guard<std::mutex> lock(mutex);
        unsigned char header[16];
        for (int i = 0; i < 4; ++i) header[i] = BYTE(length >> (24 - 8*i));
        for (int i = 0; i < 8; ++i) header[4+i] = BYTE(uint64_t(time) >> (56 - 8*i));
        for (int i = 0; i < 4; ++i) header[12+i] = BYTE(flags >> (24 - 8*i));
        if (fwrite(header, 1, sizeof(header), stdout) != sizeof(header) ||
            fwrite(data, 1, length, stdout) != length || fflush(stdout)) return E_FAIL;
        return S_OK;
    }
};
