// M0: physical-display GPU capture -> NV12 video processor -> Media Foundation H.264.
// No network listener, input injection, clipboard, or background installation.
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <codecapi.h>
#include <wrl/client.h>
#include <chrono>
#include <iostream>
#include <stdexcept>
#include <string>
#include <io.h>
#include <fcntl.h>
#include <thread>
#include "EncodedSink.h"
using Microsoft::WRL::ComPtr;
void check(HRESULT hr,const char* where) { if(FAILED(hr)) {std::cerr<<where<<" HRESULT=0x"<<std::hex<<hr<<std::dec<<"\n";throw std::runtime_error(where);} }
#include "CursorCompositor.h"
struct FrameLease { IDXGIOutputDuplication* output; ~FrameLease(){output->ReleaseFrame();} };
int wmain(int argc,wchar_t** argv) {
 try {
  if(argc!=2) {std::cerr<<"Usage: capture_probe.exe PRIVATE_OUTPUT.mp4 | --stream\n";return 2;}
  const bool streaming = std::wstring(argv[1]) == L"--stream";
  if (streaming) _setmode(_fileno(stdout), _O_BINARY);
  check(CoInitializeEx(nullptr,COINIT_MULTITHREADED),"CoInitializeEx");
  check(MFStartup(MF_VERSION),"MFStartup");
  ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;
  D3D_FEATURE_LEVEL level;
  check(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT|D3D11_CREATE_DEVICE_VIDEO_SUPPORT,nullptr,0,D3D11_SDK_VERSION,&device,&level,&context),"D3D11CreateDevice");
  ComPtr<ID3D10Multithread> multithread;check(context.As(&multithread),"Multithread");multithread->SetMultithreadProtected(TRUE);
  ComPtr<IDXGIDevice> dxgi;check(device.As(&dxgi),"DXGIDevice");ComPtr<IDXGIAdapter> adapter;check(dxgi->GetAdapter(&adapter),"GetAdapter");
  ComPtr<IDXGIOutput> output;check(adapter->EnumOutputs(0,&output),"EnumOutputs");
  DXGI_OUTPUT_DESC desc;check(output->GetDesc(&desc),"GetDesc");
  ComPtr<IDXGIOutput1> output1;check(output.As(&output1),"Output1");
  ComPtr<IDXGIOutputDuplication> duplication;check(output1->DuplicateOutput(device.Get(),&duplication),"DuplicateOutput (requires active interactive desktop)");
  DXGI_OUTDUPL_DESC dd;duplication->GetDesc(&dd);
  const UINT width=dd.ModeDesc.Width&~1u,height=dd.ModeDesc.Height&~1u,fps=60;
  std::cerr<<"capture="<<width<<"x"<<height<<" fps_target="<<fps<<" format="<<dd.ModeDesc.Format<<"\n";
  ComPtr<ID3D11VideoDevice> videoDevice;ComPtr<ID3D11VideoContext> videoContext;
  check(device.As(&videoDevice),"VideoDevice");check(context.As(&videoContext),"VideoContext");
  D3D11_VIDEO_PROCESSOR_CONTENT_DESC vd{};vd.InputFrameFormat=D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;vd.InputWidth=width;vd.InputHeight=height;vd.OutputWidth=width;vd.OutputHeight=height;vd.InputFrameRate={fps,1};vd.OutputFrameRate={fps,1};vd.Usage=D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
  ComPtr<ID3D11VideoProcessorEnumerator> ve;check(videoDevice->CreateVideoProcessorEnumerator(&vd,&ve),"VideoProcessorEnumerator");
  ComPtr<ID3D11VideoProcessor> processor;check(videoDevice->CreateVideoProcessor(ve.Get(),0,&processor),"VideoProcessor");
  ComPtr<IMFDXGIDeviceManager> manager;UINT token=0;check(MFCreateDXGIDeviceManager(&token,&manager),"DeviceManager");check(manager->ResetDevice(device.Get(),token),"ResetDevice");
  ComPtr<IMFAttributes> attrs;check(MFCreateAttributes(&attrs,4),"Attributes");
  attrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS,TRUE);attrs->SetUINT32(MF_LOW_LATENCY,TRUE);attrs->SetUnknown(MF_SINK_WRITER_D3D_MANAGER,manager.Get());
  ComPtr<IMFSinkWriter> writer;
  ComPtr<IMFMediaSink> mediaSink;
  ComPtr<IMFActivate> sinkActivation;
  ComPtr<IMFMediaType> encoded;check(MFCreateMediaType(&encoded),"EncodedType");encoded->SetGUID(MF_MT_MAJOR_TYPE,MFMediaType_Video);encoded->SetGUID(MF_MT_SUBTYPE,MFVideoFormat_H264);encoded->SetUINT32(MF_MT_AVG_BITRATE,20000000);encoded->SetUINT32(MF_MT_INTERLACE_MODE,MFVideoInterlace_Progressive);MFSetAttributeSize(encoded.Get(),MF_MT_FRAME_SIZE,width,height);MFSetAttributeRatio(encoded.Get(),MF_MT_FRAME_RATE,fps,1);MFSetAttributeRatio(encoded.Get(),MF_MT_PIXEL_ASPECT_RATIO,1,1);
  DWORD stream = 0;
  if (streaming) {
   ComPtr<EncodedSink> callback; callback.Attach(new EncodedSink());
   check(MFCreateSampleGrabberSinkActivate(encoded.Get(), callback.Get(), &sinkActivation), "SampleGrabber");
   check(sinkActivation->SetUINT32(MF_SAMPLEGRABBERSINK_IGNORE_CLOCK, TRUE), "IgnoreClock");
   check(sinkActivation->ActivateObject(IID_PPV_ARGS(&mediaSink)), "ActivateSink");
   check(MFCreateSinkWriterFromMediaSink(mediaSink.Get(), attrs.Get(), &writer), "StreamWriter");
   ComPtr<IMFStreamSink> streamSink; check(mediaSink->GetStreamSinkByIndex(0, &streamSink), "StreamSink");
   check(streamSink->GetIdentifier(&stream), "StreamIdentifier");
  } else {
   check(MFCreateSinkWriterFromURL(argv[1], nullptr, attrs.Get(), &writer), "SinkWriter");
   check(writer->AddStream(encoded.Get(), &stream), "AddStream");
  }
  ComPtr<IMFMediaType> raw;check(MFCreateMediaType(&raw),"RawType");raw->SetGUID(MF_MT_MAJOR_TYPE,MFMediaType_Video);raw->SetGUID(MF_MT_SUBTYPE,MFVideoFormat_NV12);raw->SetUINT32(MF_MT_INTERLACE_MODE,MFVideoInterlace_Progressive);MFSetAttributeSize(raw.Get(),MF_MT_FRAME_SIZE,width,height);MFSetAttributeRatio(raw.Get(),MF_MT_FRAME_RATE,fps,1);MFSetAttributeRatio(raw.Get(),MF_MT_PIXEL_ASPECT_RATIO,1,1);
  check(writer->SetInputMediaType(stream,raw.Get(),nullptr),"SetInputMediaType");check(writer->BeginWriting(),"BeginWriting");
  ComPtr<IMFSinkWriterEx> ex;check(writer.As(&ex),"SinkWriterEx");bool hardware=false;
  for(DWORD i=0;i<8;i++){GUID category;ComPtr<IMFTransform> transform;if(FAILED(ex->GetTransformForStream(stream,i,&category,&transform)))break;ComPtr<IMFAttributes> a;if(SUCCEEDED(transform->GetAttributes(&a))){UINT32 aware=0;a->GetUINT32(MF_SA_D3D11_AWARE,&aware);UINT32 len=0;if(SUCCEEDED(a->GetStringLength(MFT_ENUM_HARDWARE_URL_Attribute,&len))&&len>0)hardware=true;std::cerr<<"transform="<<i<<" d3d11_aware="<<aware<<" hardware_marker="<<hardware<<"\n";}}
  // Enumerating hardware availability is evidence separate from selected encoder identity.
  IMFActivate** activations=nullptr;UINT32 count=0;MFT_REGISTER_TYPE_INFO outInfo={MFMediaType_Video,MFVideoFormat_H264};
  if(SUCCEEDED(MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,MFT_ENUM_FLAG_HARDWARE,nullptr,&outInfo,&activations,&count))){std::cerr<<"available_h264_hardware_encoders="<<count<<" selected_hardware_confirmed="<<hardware<<"\n";for(UINT32 i=0;i<count;i++)activations[i]->Release();CoTaskMemFree(activations);}
  if (streaming && !hardware) throw std::runtime_error("No verified hardware encoder; stream refused");
  if (streaming) {
   const std::string metadata = "{\"version\":1,\"codec\":\"h264-annexb\",\"width\":" + std::to_string(width) + ",\"height\":" + std::to_string(height) + ",\"fps\":" + std::to_string(fps) + ",\"hardwareEncoder\":true}";
   const uint32_t length = uint32_t(metadata.size());
   unsigned char header[8] = {'S','P','C','1',BYTE(length>>24),BYTE(length>>16),BYTE(length>>8),BYTE(length)};
   fwrite(header,1,8,stdout); fwrite(metadata.data(),1,metadata.size(),stdout); fflush(stdout);
  }
  CursorCompositor cursor(device.Get(),context.Get(),width,height);
  UINT frames=0,timeouts=0;double captureMs=0,submitMs=0;const auto start=std::chrono::steady_clock::now();
  while((streaming || frames<180) && std::chrono::steady_clock::now()-start<std::chrono::seconds(streaming?600:12)) {
   if (streaming) std::this_thread::sleep_until(start + std::chrono::microseconds(uint64_t(frames)*1000000/fps));
   DXGI_OUTDUPL_FRAME_INFO info{};ComPtr<IDXGIResource> resource;auto begin=std::chrono::steady_clock::now();
   HRESULT hr=duplication->AcquireNextFrame(100,&info,&resource);if(hr==DXGI_ERROR_WAIT_TIMEOUT){timeouts++;continue;}check(hr,"AcquireNextFrame");FrameLease lease{duplication.Get()};
   captureMs+=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();
   ComPtr<ID3D11Texture2D> source;check(resource.As(&source),"Texture");
   cursor.update(duplication.Get(),info);
   ID3D11Texture2D* captured=cursor.draw(source.Get());
   // Each sample owns its NV12 surface until the encoder releases it; never overwrite in flight.
   D3D11_TEXTURE2D_DESC td{};td.Width=width;td.Height=height;td.MipLevels=1;td.ArraySize=1;td.Format=DXGI_FORMAT_NV12;td.SampleDesc.Count=1;td.Usage=D3D11_USAGE_DEFAULT;td.BindFlags=D3D11_BIND_RENDER_TARGET;
   ComPtr<ID3D11Texture2D> nv12;check(device->CreateTexture2D(&td,nullptr,&nv12),"NV12Texture");
   D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC iv{};iv.ViewDimension=D3D11_VPIV_DIMENSION_TEXTURE2D;
   D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ov{};ov.ViewDimension=D3D11_VPOV_DIMENSION_TEXTURE2D;
   ComPtr<ID3D11VideoProcessorInputView> input;ComPtr<ID3D11VideoProcessorOutputView> target;
   check(videoDevice->CreateVideoProcessorInputView(captured,ve.Get(),&iv,&input),"ProcessorInput");check(videoDevice->CreateVideoProcessorOutputView(nv12.Get(),ve.Get(),&ov,&target),"ProcessorOutput");
   D3D11_VIDEO_PROCESSOR_STREAM vs{};vs.Enable=TRUE;vs.pInputSurface=input.Get();
   check(videoContext->VideoProcessorBlt(processor.Get(),target.Get(),frames,1,&vs),"VideoProcessorBlt");
   ComPtr<IMFMediaBuffer> buffer;check(MFCreateDXGISurfaceBuffer(__uuidof(ID3D11Texture2D),nv12.Get(),0,FALSE,&buffer),"DXGISurfaceBuffer");
   ComPtr<IMF2DBuffer> buffer2d;check(buffer.As(&buffer2d),"Buffer2D");DWORD bufferLength=0;check(buffer2d->GetContiguousLength(&bufferLength),"BufferLength");check(buffer->SetCurrentLength(bufferLength),"SetCurrentLength");
   ComPtr<IMFSample> sample;check(MFCreateSample(&sample),"Sample");sample->AddBuffer(buffer.Get());sample->SetSampleTime(streaming ? std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now()-start).count()/100 : LONGLONG(frames)*10000000/fps);sample->SetSampleDuration(10000000/fps);
   begin=std::chrono::steady_clock::now();check(writer->WriteSample(stream,sample.Get()),"WriteSample");submitMs+=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();frames++;
  }
  check(writer->Finalize(),"Finalize");double seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
  std::cerr<<"frames="<<frames<<" elapsed_s="<<seconds<<" captured_fps="<<frames/seconds<<" capture_wait_avg_ms="<<(frames?captureMs/frames:0)<<" encode_submit_avg_ms="<<(frames?submitMs/frames:0)<<" timeouts="<<timeouts<<"\n";
  if(!frames)return 3;return 0;
 }catch(const std::exception& e){std::cerr<<"probe_failed="<<e.what()<<"\n";return 1;}
}
