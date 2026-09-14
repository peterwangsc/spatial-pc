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
  cursor.position={{1,1},TRUE};cursor.shape={DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR,1,1,4,{0,0}};
  cursor.bytes={0,0,255,255};cursor.uploadShape();ComPtr<ID3D11Texture2D> retainedPointer=cursor.pointer;
  const auto allocations=cursor.textureAllocations,uploads=cursor.shapeUploads;
  cursor.uploadShape();expect(cursor.textureAllocations==allocations&&cursor.shapeUploads==uploads&&cursor.duplicateShapes>0,"identical shape skips upload and allocation");
  // Queue a readback of the old image, update the same pointer resource, then
  // draw again before waiting. Both queued draws must preserve their own shape.
  ComPtr<ID3D11Texture2D> before;check(d->CreateTexture2D(&td,nullptr,&before),"prior frame");
  c->CopyResource(before.Get(),cursor.draw(src.Get()));
  cursor.bytes={0,255,0,255};cursor.uploadShape();p=pixels();
  D3D11_MAPPED_SUBRESOURCE prior{};check(c->Map(before.Get(),0,D3D11_MAP_READ,0,&prior),"prior frame map");
  const auto priorColor=reinterpret_cast<uint32_t*>(static_cast<BYTE*>(prior.pData)+prior.RowPitch)[1]&0xFFFFFF;c->Unmap(before.Get(),0);
  expect(priorColor==0xFF0000&&p[5]==0x00FF00&&cursor.pointer.Get()==retainedPointer.Get()&&cursor.textureAllocations==allocations,"in-flight old shape preserved while same-size texture reused");
  cursor.bytes={0,0,255,128};cursor.uploadShape();expect(pixels()[5]==0x99334C,"partial alpha blend");
  cursor.shape={DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR,2,2,8,{0,0}};cursor.bytes={0,0,255,255,255,255,255,255,0,255,0,255,255,0,0,255};cursor.uploadShape();
  cursor.position.Position={3,3};p=pixels();expect(p[15]==0xFF0000&&p[14]==0x336699&&p[11]==0x336699,"right and bottom scissor clipping");
  cursor.position.Position={1,1};p=pixels();expect(p[5]==0xFF0000&&p[6]==0xFFFFFF&&p[9]==0x00FF00&&p[10]==0x0000FF&&p[15]==0x336699,"moving pointer restores old desktop region");
  cursor.position.Position={4,0};expect(cursor.draw(src.Get())==src.Get(),"fully offscreen pointer bypasses composition");
  // Vary the desktop too: uniform backgrounds cannot detect an incorrect
  // source/destination offset in the small background copy under the pointer.
  for(size_t i=0;i<data.size();++i)data[i]=0xFF000000u|uint32_t((i*31)%256)<<16|uint32_t((i*53)%256)<<8|uint32_t((i*79)%256);
  c->UpdateSubresource(src.Get(),0,nullptr,data.data(),16,0);
  const POINT positions[]={{1,1},{-1,2},{2,-1},{3,3},{-3,-3},{4,4}};
  for(UINT kind:{UINT(DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR),UINT(DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MASKED_COLOR),UINT(DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME)}) {
   const bool mono=kind==DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME;
   cursor.shape={kind,3,mono?6u:3u,mono?1u:12u,{0,0}};
   cursor.bytes.assign(mono?6:36,0);
   if(mono)cursor.bytes={0x20,0x40,0xA0,0xC0,0x60,0xA0};
   else for(UINT i=0;i<9;++i){cursor.bytes[i*4]=BYTE(i*27);cursor.bytes[i*4+1]=BYTE(255-i*17);cursor.bytes[i*4+2]=BYTE(i*19);cursor.bytes[i*4+3]=BYTE(kind==DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR?(i%3)*127:(i%2)*255);}
   cursor.uploadShape();
   for(const auto& origin:positions) {
    cursor.position.Position=origin;p=pixels();auto wanted=data;
    for(UINT y=0;y<4;++y)for(UINT x=0;x<4;++x) {
     auto& value=wanted[y*4+x];value&=0xFFFFFF;const int qx=int(x)-origin.x,qy=int(y)-origin.y;
     if(qx<0||qy<0||qx>=3||qy>=3)continue;
     if(mono){const BYTE bit=BYTE(0x80>>qx);value=(value&((cursor.bytes[size_t(qy)]&bit)?0xFFFFFF:0))^((cursor.bytes[size_t(qy+3)]&bit)?0xFFFFFF:0);}
     else {
      uint32_t pointerColor=0;std::memcpy(&pointerColor,cursor.bytes.data()+(size_t(qy)*3+size_t(qx))*4,4);
      const UINT alpha=pointerColor>>24;
      if(kind==DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MASKED_COLOR)value=alpha==255?value^(pointerColor&0xFFFFFF):pointerColor&0xFFFFFF;
      else {uint32_t blended=0;for(UINT shift=0;shift<24;shift+=8)blended|=((((value>>shift)&255)*(255-alpha)+((pointerColor>>shift)&255)*alpha+127)/255)<<shift;value=blended;}
     }
    }
    bool matches=true;
    for(size_t i=0;i<p.size();++i)for(UINT shift=0;shift<24;shift+=8) {
     const int qx=int(i%4)-origin.x,qy=int(i/4)-origin.y;
     const int tolerance=kind==DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR&&qx>=0&&qy>=0&&qx<3&&qy<3?1:0;
     // Float alpha blending followed by UNORM conversion can differ from the
     // integer CPU reference by one LSB. Copy/XOR/monochrome paths stay exact.
     if(std::abs(int((p[i]>>shift)&255)-int((wanted[i]>>shift)&255))>tolerance)matches=false;
    }
    expect(matches,"gradient desktop matches CPU reference across pointer edges");
   }
  }
  cursor.report();
 }
};
int main(){try{CursorCompositorTest::run();return 0;}catch(const std::exception& e){std::cerr<<e.what()<<"\n";return 1;}}
