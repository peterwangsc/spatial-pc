#pragma once
#include <mferror.h>

class VideoSurfaces {
    ComPtr<IMFVideoSampleAllocatorEx> allocator;
    std::map<ID3D11Texture2D*, ComPtr<ID3D11VideoProcessorOutputView>> outputs;
    ComPtr<ID3D11VideoProcessorInputView> input;
    ComPtr<ID3D11Texture2D> lastInput;
    ID3D11Device* device;
    ID3D11VideoDevice* video;
    ID3D11VideoProcessorEnumerator* enumerator;
    UINT width, height;
public:
    VideoSurfaces(ID3D11Device* d, ID3D11VideoDevice* v, ID3D11VideoProcessorEnumerator* e, IMFDXGIDeviceManager* manager, IMFMediaType* type, UINT w, UINT h, bool pool)
        : device(d), video(v), enumerator(e), width(w), height(h) {
        if (pool) {
            check(MFCreateVideoSampleAllocatorEx(IID_PPV_ARGS(&allocator)), "Video sample allocator");
            check(allocator->SetDirectXManager(manager), "Allocator DirectX manager");
            ComPtr<IMFAttributes> attrs; check(MFCreateAttributes(&attrs, 2), "Allocator attributes");
            check(attrs->SetUINT32(MF_SA_D3D11_BINDFLAGS, D3D11_BIND_RENDER_TARGET), "Allocator bind flags");
            check(attrs->SetUINT32(MF_SA_BUFFERS_PER_SAMPLE, 1), "Allocator buffers");
            check(allocator->InitializeSampleAllocatorEx(4, 8, attrs.Get(), type), "Initialize bounded sample pool");
        }
    }
    bool acquire(ComPtr<IMFSample>& sample, ComPtr<ID3D11VideoProcessorOutputView>& target) {
        ComPtr<ID3D11Texture2D> texture;
        if (allocator) {
            const auto hr = allocator->AllocateSample(&sample);
            if (hr == MF_E_SAMPLEALLOCATOR_EMPTY) return false;
            check(hr, "Allocate pooled sample");
            ComPtr<IMFMediaBuffer> buffer; check(sample->GetBufferByIndex(0, &buffer), "Pooled buffer");
            ComPtr<IMFDXGIBuffer> dxgi; check(buffer.As(&dxgi), "Pooled DXGI buffer");
            check(dxgi->GetResource(IID_PPV_ARGS(&texture)), "Pooled texture");
            UINT subresource = 0; check(dxgi->GetSubresourceIndex(&subresource), "Pooled subresource");
            D3D11_TEXTURE2D_DESC desc{}; texture->GetDesc(&desc);
            if (subresource != 0 || desc.ArraySize != 1) throw std::runtime_error("Unexpected pooled texture layout");
            ComPtr<IMF2DBuffer> buffer2d; check(buffer.As(&buffer2d), "Pooled Buffer2D");
            DWORD length = 0; check(buffer2d->GetContiguousLength(&length), "Pooled buffer length");
            check(buffer->SetCurrentLength(length), "Pooled current length");
            const auto found = outputs.find(texture.Get());
            if (found != outputs.end()) { target = found->second; return true; }
        } else {
            D3D11_TEXTURE2D_DESC td{}; td.Width = width; td.Height = height; td.MipLevels = 1; td.ArraySize = 1;
            td.Format = DXGI_FORMAT_NV12; td.SampleDesc.Count = 1; td.Usage = D3D11_USAGE_DEFAULT; td.BindFlags = D3D11_BIND_RENDER_TARGET;
            check(device->CreateTexture2D(&td, nullptr, &texture), "NV12Texture");
            ComPtr<IMFMediaBuffer> buffer; check(MFCreateDXGISurfaceBuffer(__uuidof(ID3D11Texture2D), texture.Get(), 0, FALSE, &buffer), "DXGISurfaceBuffer");
            ComPtr<IMF2DBuffer> buffer2d; check(buffer.As(&buffer2d), "Buffer2D"); DWORD length = 0;
            check(buffer2d->GetContiguousLength(&length), "BufferLength"); check(buffer->SetCurrentLength(length), "SetCurrentLength");
            check(MFCreateSample(&sample), "Sample"); check(sample->AddBuffer(buffer.Get()), "Sample buffer");
        }
        D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ov{}; ov.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
        check(video->CreateVideoProcessorOutputView(texture.Get(), enumerator, &ov, &target), "ProcessorOutput");
        if (allocator) outputs.emplace(texture.Get(), target);
        return true;
    }
    ID3D11VideoProcessorInputView* source(ID3D11Texture2D* texture) {
        if (!allocator || texture != lastInput.Get()) {
            input.Reset(); lastInput = texture;
            D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC iv{}; iv.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
            check(video->CreateVideoProcessorInputView(texture, enumerator, &iv, &input), "ProcessorInput");
        }
        return input.Get();
    }
};
