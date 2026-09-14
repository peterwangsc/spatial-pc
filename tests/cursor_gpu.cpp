#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <iostream>
#include <stdexcept>
using Microsoft::WRL::ComPtr;
void check(HRESULT hr,const char* name) { if(FAILED(hr)) throw std::runtime_error(name); }
#include "../windows/host/CursorCompositor.h"
struct CursorCompositorTest {
 static void run() {
  ComPtr<ID3D11Device> d;ComPtr<ID3D11DeviceContext> c;D3D_FEATURE_LEVEL level;
  check(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,nullptr,0,D3D11_SDK_VERSION,&d,&level,&c),"device");
  CursorCompositor cursor(d.Get(),c.Get(),4,4);
  std::vector<uint32_t> data(16,0xFF336699);
  D3D11_TEXTURE2D_DESC td{};td.Width=4;td.Height=4;td.MipLevels=1;td.ArraySize=1;td.Format=DXGI_FORMAT_B8G8R8A8_UNORM;td.SampleDesc.Count=1;
  D3D11_SUBRESOURCE_DATA input{data.data(),16,0};ComPtr<ID3D11Texture2D> src,read;
  check(d->CreateTexture2D(&td,&input,&src),"source");td.Usage=D3D11_USAGE_STAGING;td.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
  check(d->CreateTexture2D(&td,nullptr,&read),"readback");
  auto pixels=[&]() {
   c->CopyResource(read.Get(),cursor.draw(src.Get()));D3D11_MAPPED_SUBRESOURCE m{};check(c->Map(read.Get(),0,D3D11_MAP_READ,0,&m),"map");
   std::vector<uint32_t> result;for(UINT y=0;y<4;y++) for(UINT x=0;x<4;x++) result.push_back(reinterpret_cast<uint32_t*>(static_cast<BYTE*>(m.pData)+y*m.RowPitch)[x]&0xFFFFFF);
   c->Unmap(read.Get(),0);return result;
  };
  auto expect=[](bool ok,const char* label) {if(!ok)throw std::runtime_error(label);std::cout<<label<<" pass\n";};
  cursor.position={{1,1},TRUE};cursor.shape={DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR,1,1,4,{0,0}};
  cursor.bytes={0,0,255,255};cursor.uploadShape();auto p=pixels();expect(p[5]==0xFF0000&&p[0]==0x336699,"opaque color + untouched desktop");
  cursor.bytes={0,0,0,0};cursor.uploadShape();expect(pixels()[5]==0x336699,"transparent color");
  cursor.shape.Type=DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MASKED_COLOR;cursor.bytes={255,255,255,255};cursor.uploadShape();expect(pixels()[5]==0xCC9966,"masked XOR");
  cursor.bytes={0,255,0,0};cursor.uploadShape();expect(pixels()[5]==0x00FF00,"masked replace");
  cursor.shape={DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME,4,2,1,{0,0}};cursor.position.Position={0,0};cursor.bytes={0x30,0x50};cursor.uploadShape();p=pixels();expect(p[0]==0&&p[1]==0xFFFFFF&&p[2]==0x336699&&p[3]==0xCC9966,"monochrome AND XOR truth table");
  cursor.position.Position={-1,0};p=pixels();expect(p[0]==0xFFFFFF&&p[1]==0x336699&&p[2]==0xCC9966&&p[3]==0x336699,"negative edge clipping");
  cursor.position.Visible=FALSE;expect(pixels()==std::vector<uint32_t>(16,0x336699),"hidden or embedded pointer unchanged");
 }
};
int main(){try{CursorCompositorTest::run();return 0;}catch(const std::exception& e){std::cerr<<e.what()<<"\n";return 1;}}
