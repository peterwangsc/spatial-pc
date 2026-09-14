// M0: physical-display GPU capture -> NV12 video processor -> Media Foundation H.264.
// No network listener, input injection, clipboard, or background installation.
#define NOMINMAX
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
using Microsoft::WRL::ComPtr;
void check(HRESULT hr,const char* where) { if(FAILED(hr)) {std::cerr<<where<<" HRESULT=0x"<<std::hex<<hr<<std::dec<<"\n";throw std::runtime_error(where);} }
#include "PerfStats.h"
#include "FramePacer.h"
#include "EncodedSink.h"
#include "EncoderSettings.h"
#include "VideoSurfaces.h"
#include "CursorCompositor.h"
struct FrameLease { IDXGIOutputDuplication* output; ~FrameLease(){output->ReleaseFrame();} };
int wmain(int argc,wchar_t** argv) {
 try {
  if(argc<2) {std::cerr<<"Usage: capture_probe.exe PRIVATE_OUTPUT.mp4 | --stream [--seconds N] [--legacy] [--no-pool] [--no-codec-config] [--unthrottled]\n";return 2;}
  const bool streaming = std::wstring(argv[1]) == L"--stream";
  bool legacy=false,pool=true,configure=true,unthrottled=false;int duration=streaming?600:12;
  for(int i=2;i<argc;++i) {
   const std::wstring option=argv[i];
   if(option==L"--legacy") legacy=true;
   else if(option==L"--no-pool") pool=false;
   else if(option==L"--no-codec-config") configure=false;
   else if(option==L"--unthrottled") unthrottled=true;
   else if(option==L"--seconds"&&i+1<argc) duration=std::stoi(argv[++i]);
   else throw std::runtime_error("Unknown capture option");
  }
  if(duration<1||duration>600||(!streaming&&unthrottled)) throw std::runtime_error("Invalid capture limits");
  if(legacy) {pool=false;configure=false;unthrottled=false;}
  auto statsOwner=std::make_shared<PerfStats>();auto& stats=*statsOwner;
  std::cerr<<"capture_options legacy="<<legacy<<" pool="<<pool<<" codec_config="<<configure<<" unthrottled="<<unthrottled<<" max_inflight="<<(legacy?0:4)<<" seconds="<<duration<<"\n";
  if (streaming) _setmode(_fileno(stdout), _O_BINARY);
  check(CoInitializeEx(nullptr,COINIT_MULTITHREADED),"CoInitializeEx");
  check(MFStartup(MF_VERSION),"MFStartup");
  ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;
  D3D_FEATURE_LEVEL level;
  check(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT|D3D11_CREATE_DEVICE_VIDEO_SUPPORT,nullptr,0,D3D11_SDK_VERSION,&device,&level,&context),"D3D11CreateDevice");
  ComPtr<ID3D10Multithread> multithread;check(context.As(&multithread),"Multithread");multithread->SetMultithreadProtected(TRUE);
  ComPtr<IDXGIDevice> dxgi;check(device.As(&dxgi),"DXGIDevice");ComPtr<IDXGIAdapter> adapter;check(dxgi->GetAdapter(&adapter),"GetAdapter");
  DXGI_ADAPTER_DESC adapterDesc{};check(adapter->GetDesc(&adapterDesc),"Adapter description");std::wcerr<<L"capture_adapter="<<adapterDesc.Description<<L" dedicated_bytes="<<adapterDesc.DedicatedVideoMemory<<L'\n';
  ComPtr<IDXGIOutput> output;check(adapter->EnumOutputs(0,&output),"EnumOutputs");
  DXGI_OUTPUT_DESC desc;check(output->GetDesc(&desc),"GetDesc");
  ComPtr<IDXGIOutput1> output1;check(output.As(&output1),"Output1");
  ComPtr<IDXGIOutputDuplication> duplication;check(output1->DuplicateOutput(device.Get(),&duplication),"DuplicateOutput (requires active interactive desktop)");
  DXGI_OUTDUPL_DESC dd;duplication->GetDesc(&dd);
  const UINT width=dd.ModeDesc.Width&~1u,height=dd.ModeDesc.Height&~1u,fps=60;
  std::cerr<<"capture="<<width<<"x"<<height<<" fps_target="<<fps<<" format="<<dd.ModeDesc.Format<<" display_refresh="<<dd.ModeDesc.RefreshRate.Numerator<<"/"<<dd.ModeDesc.RefreshRate.Denominator<<"\n";
  ComPtr<ID3D11VideoDevice> videoDevice;ComPtr<ID3D11VideoContext> videoContext;
  check(device.As(&videoDevice),"VideoDevice");check(context.As(&videoContext),"VideoContext");
  D3D11_VIDEO_PROCESSOR_CONTENT_DESC vd{};vd.InputFrameFormat=D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;vd.InputWidth=width;vd.InputHeight=height;vd.OutputWidth=width;vd.OutputHeight=height;vd.InputFrameRate={fps,1};vd.OutputFrameRate={fps,1};vd.Usage=D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
  ComPtr<ID3D11VideoProcessorEnumerator> ve;check(videoDevice->CreateVideoProcessorEnumerator(&vd,&ve),"VideoProcessorEnumerator");
  ComPtr<ID3D11VideoProcessor> processor;check(videoDevice->CreateVideoProcessor(ve.Get(),0,&processor),"VideoProcessor");
  ComPtr<IMFDXGIDeviceManager> manager;UINT token=0;check(MFCreateDXGIDeviceManager(&token,&manager),"DeviceManager");check(manager->ResetDevice(device.Get(),token),"ResetDevice");
  ComPtr<IMFAttributes> attrs;check(MFCreateAttributes(&attrs,4),"Attributes");
  attrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS,TRUE);attrs->SetUINT32(MF_LOW_LATENCY,TRUE);attrs->SetUnknown(MF_SINK_WRITER_D3D_MANAGER,manager.Get());
  if(unthrottled)check(attrs->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING,TRUE),"Explicitly bounded unthrottled writer");
  ComPtr<IMFSinkWriter> writer;
  ComPtr<IMFMediaSink> mediaSink;
  ComPtr<IMFActivate> sinkActivation;
  ComPtr<IMFMediaType> encoded;check(MFCreateMediaType(&encoded),"EncodedType");encoded->SetGUID(MF_MT_MAJOR_TYPE,MFMediaType_Video);encoded->SetGUID(MF_MT_SUBTYPE,MFVideoFormat_H264);encoded->SetUINT32(MF_MT_AVG_BITRATE,20000000);encoded->SetUINT32(MF_MT_INTERLACE_MODE,MFVideoInterlace_Progressive);MFSetAttributeSize(encoded.Get(),MF_MT_FRAME_SIZE,width,height);MFSetAttributeRatio(encoded.Get(),MF_MT_FRAME_RATE,fps,1);MFSetAttributeRatio(encoded.Get(),MF_MT_PIXEL_ASPECT_RATIO,1,1);
  DWORD stream = 0;
  if (streaming) {
   ComPtr<EncodedSink> callback; callback.Attach(new EncodedSink(statsOwner));
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
  check(writer->SetInputMediaType(stream,raw.Get(),nullptr),"SetInputMediaType");
  bool hardware=inspectEncoder(writer.Get(),stream,configure,fps);
  check(writer->BeginWriting(),"BeginWriting");
  if(!hardware)hardware=inspectEncoder(writer.Get(),stream,configure,fps);
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
  VideoSurfaces surfaces(device.Get(),videoDevice.Get(),ve.Get(),manager.Get(),raw.Get(),width,height,pool);
  GpuTimings gpuTimings(device.Get(),context.Get(),stats);
  UINT frames=0,timeouts=0;double captureMs=0,submitMs=0;const auto start=std::chrono::steady_clock::now();
  FramePacer pacer(fps);auto nextReport=start+std::chrono::seconds(5);const auto captureEpoch=perfCounter();
  while((streaming || frames<180) && std::chrono::steady_clock::now()-start<std::chrono::seconds(duration)) {
   if (streaming) {
    const auto pacing=perfCounter();
    if(legacy)std::this_thread::sleep_until(start+std::chrono::microseconds(uint64_t(frames)*1000000/fps));else pacer.wait();
    stats.add("pacing_wait_ms",perfMs(perfCounter()-pacing));
    if(!legacy) {const auto waiting=perfCounter();if(!stats.capacity(4))throw std::runtime_error("In-flight sample limit did not drain for five seconds");stats.add("capacity_wait_ms",perfMs(perfCounter()-waiting));}
   }
   ComPtr<IMFSample> sample;ComPtr<ID3D11VideoProcessorOutputView> target;
   const auto allocation=perfCounter();
   while(!surfaces.acquire(sample,target)) {
    if(perfMs(perfCounter()-allocation)>5000)throw std::runtime_error("Video sample pool stalled");
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
   }
   stats.add("surface_acquire_ms",perfMs(perfCounter()-allocation));
   DXGI_OUTDUPL_FRAME_INFO info{};ComPtr<IDXGIResource> resource;auto begin=std::chrono::steady_clock::now();
   HRESULT hr=duplication->AcquireNextFrame(100,&info,&resource);if(hr==DXGI_ERROR_WAIT_TIMEOUT){timeouts++;stats.timeout();continue;}check(hr,"AcquireNextFrame");FrameLease lease{duplication.Get()};
   const auto acquired=perfCounter();pacer.acquired(acquired);
   const auto waited=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();captureMs+=waited;stats.add("capture_wait_ms",waited);
   const auto latest=std::max(info.LastPresentTime.QuadPart,info.LastMouseUpdateTime.QuadPart);
   if(latest>0&&latest<=acquired)stats.add("desktop_age_at_acquire_ms",perfMs(acquired-latest));
   ComPtr<ID3D11Texture2D> source;check(resource.As(&source),"Texture");
   const auto conversion=perfCounter();gpuTimings.begin();
   cursor.update(duplication.Get(),info);
   ID3D11Texture2D* captured=cursor.draw(source.Get());
   D3D11_VIDEO_PROCESSOR_STREAM vs{};vs.Enable=TRUE;vs.pInputSurface=surfaces.source(captured);
   check(videoContext->VideoProcessorBlt(processor.Get(),target.Get(),frames,1,&vs),"VideoProcessorBlt");
   gpuTimings.end();context->Flush();stats.add("cursor_convert_cpu_ms",perfMs(perfCounter()-conversion));
   const LONGLONG timestamp=streaming?(legacy?std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now()-start).count()/100:perf100ns(acquired-captureEpoch)):LONGLONG(frames)*10000000/fps;
   check(sample->SetSampleTime(timestamp),"Sample time");check(sample->SetSampleDuration(10000000/fps),"Sample duration");
   if(streaming)stats.input(timestamp,acquired,info.AccumulatedFrames);
   begin=std::chrono::steady_clock::now();check(writer->WriteSample(stream,sample.Get()),"WriteSample");const auto submitted=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();submitMs+=submitted;stats.add("write_sample_ms",submitted);frames++;
   if(std::chrono::steady_clock::now()>=nextReport){stats.report();cursor.report();nextReport=std::chrono::steady_clock::now()+std::chrono::seconds(5);}
  }
  check(writer->Finalize(),"Finalize");gpuTimings.collect();stats.report();cursor.report();double seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
  std::cerr<<"frames="<<frames<<" elapsed_s="<<seconds<<" captured_fps="<<frames/seconds<<" capture_wait_avg_ms="<<(frames?captureMs/frames:0)<<" encode_submit_avg_ms="<<(frames?submitMs/frames:0)<<" timeouts="<<timeouts<<"\n";
  if(!frames)return 3;return 0;
 }catch(const std::exception& e){std::cerr<<"probe_failed="<<e.what()<<"\n";return 1;}
}
