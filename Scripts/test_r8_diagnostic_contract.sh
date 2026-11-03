#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="$ROOT/.build/r8-development"
mkdir -p "$OUT"
python3 - "$ROOT" "$OUT/r8-diagnostic-contract.mm" <<'PY'
import pathlib,sys
s=(pathlib.Path(sys.argv[1])/'Apps/Mac/Capture/SPLiveProcessor.mm').read_text()
helpers=s[s.index('static BOOL SPR8Enabled'):s.index('static const double SPInteractiveCapSec')]
main=r'''
int main() {
 @autoreleasepool {
  const int budget=SPR8Option(@"--odf-r8-budget-mib",160,@[@160,@320,@480]);
  const int admission=SPR8Option(@"--odf-r8-inflight",2,@[@1,@2,@3,@4]);
  const int sessions=SPR8Option(@"--odf-r8-sessions",2,@[@1,@2,@3,@4]);
  printf("%d %d %d %d\n",(int)SPR8Enabled(),budget,admission,sessions);
  const uint32_t seq=0x48a621; const bool mark[8]={1,1,0,1,0,0,1,1};
  for (OSType format : {kCVPixelFormatType_32BGRA,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange}) {
   CVPixelBufferRef b=nullptr; if (CVPixelBufferCreate(kCFAllocatorDefault,1280,720,format,nullptr,&b)!=kCVReturnSuccess) return 2;
   CVPixelBufferLockBaseAddress(b,0); bool planar=format!=kCVPixelFormatType_32BGRA;
   auto *p=(uint8_t *)(planar?CVPixelBufferGetBaseAddressOfPlane(b,0):CVPixelBufferGetBaseAddress(b));
   size_t stride=planar?CVPixelBufferGetBytesPerRowOfPlane(b,0):CVPixelBufferGetBytesPerRow(b); memset(p,0,stride*720);
   bool bits[64]; for(int i=0;i<8;i++) {bits[i]=mark[i];bits[56+i]=mark[7-i];}
   for(int i=0;i<24;i++){bits[8+i]=((seq>>(23-i))&1);bits[32+i]=!bits[8+i];}
   for(int y=80;y<120;y++)for(int x=0;x<1280;x++){int c=(int)floor(((double)x/1280-0.08)/0.84*64);
    if(c>=0&&c<64&&bits[c]){auto *q=p+y*stride+x*(planar?1:4);q[0]=planar?235:255;if(!planar){q[1]=255;q[2]=255;q[3]=255;}}}
   CVPixelBufferUnlockBaseAddress(b,0); if(SPR8DecodeFixture(b)!=(int)seq) return 3; CVPixelBufferRelease(b);
  }
  auto motion = [](OSType format, int phase) -> NSDictionary * {
   CVPixelBufferRef b=nullptr;
   if (CVPixelBufferCreate(kCFAllocatorDefault,1280,720,format,nullptr,&b)!=kCVReturnSuccess) return nil;
   CVPixelBufferLockBaseAddress(b,0); bool planar=format!=kCVPixelFormatType_32BGRA;
   auto *base=(uint8_t *)(planar ? CVPixelBufferGetBaseAddressOfPlane(b,0) : CVPixelBufferGetBaseAddress(b));
   size_t stride=planar ? CVPixelBufferGetBytesPerRowOfPlane(b,0) : CVPixelBufferGetBytesPerRow(b);
   memset(base,planar?32:20,stride*720);
   if (planar) {
    auto *uv=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,1); size_t uvs=CVPixelBufferGetBytesPerRowOfPlane(b,1); memset(uv,128,uvs*360);
    if (phase>=0) {
     for(int y=140;y<170;++y)for(int cx=150;cx<=250;++cx) {
      bool full=phase==2?(cx>=151&&cx<=250):(cx>=150&&cx<250), half=phase==1&&(cx==150||cx==250);
      if(full||half){ auto *q=uv+y*uvs+cx*2;q[0]=half?96:64;q[1]=half?160:192; }
     }
     for(int y=280;y<340;++y)memset(base+y*stride+300,150,202);
    }
   } else if (phase>=0) for(int y=280;y<340;++y)for(int x=300;x<=500;++x) {
    bool full=phase==2?(x>=301&&x<=500):(x>=300&&x<500),half=phase==1&&(x==300||x==500);
    if(full||half){auto *q=base+y*stride+x*4;q[0]=20;q[1]=half?85:150;q[2]=half?130:240;q[3]=255;}
   }
   if(phase == -2) {
    uint32_t state=0x12345678; auto byte=[&](){state=state*1664525u+1013904223u;return (uint8_t)((state>>16)&255);};
    if(planar){auto *uv=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,1);size_t uvs=CVPixelBufferGetBytesPerRowOfPlane(b,1);
     for(int y : {295,309,324}){memset(base+y*stride,128,1280);for(int x=0;x<640;x++){auto *p=uv+(y/2)*uvs+x*2;p[0]=byte();p[1]=byte();}}}
    else {for(int y : {295,309,324})for(int x=0;x<1280;x++){auto *p=base+y*stride+x*4;p[0]=byte();p[1]=byte();p[2]=byte();}}
   }
   CVPixelBufferUnlockBaseAddress(b,0); NSDictionary *event=SPR8FixtureMotion(b); CVPixelBufferRelease(b);return event;
  };
  for (OSType format : {kCVPixelFormatType_32BGRA,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange}) {
   NSDictionary *blank=motion(format,-1), *noise=motion(format,-2), *a=motion(format,0), *same=motion(format,0), *middle=motion(format,1), *next=motion(format,2);
   if([blank[@"valid"] boolValue] || [noise[@"valid"] boolValue] || ![a[@"valid"] boolValue] || ![middle[@"valid"] boolValue] || ![next[@"valid"] boolValue]) return 4;
   double x=[a[@"centroidX"] doubleValue], y=[same[@"centroidX"] doubleValue], m=[middle[@"centroidX"] doubleValue], z=[next[@"centroidX"] doubleValue];
   if(fabs(x-399.5)>0.05 || x!=y || !(x<m && m<z) || fabs((m-x)-(z-m))>0.05 || fabs((z-x)-(format==kCVPixelFormatType_32BGRA?1.0:2.0))>0.05 || [a[@"sampleDurationNs"] doubleValue]<=0) return 5;
  }
 }
 return 0;
}'''
pathlib.Path(sys.argv[2]).write_text('#import <Foundation/Foundation.h>\n#import <CoreVideo/CoreVideo.h>\n#include <algorithm>\n#include <cmath>\n#include <cstring>\n#include <initializer_list>\n'+helpers+main)
PY
xcrun clang++ -std=c++17 -fobjc-arc -fblocks "$OUT/r8-diagnostic-contract.mm" -framework Foundation -framework CoreVideo -o "$OUT/r8-diagnostic-contract"
exe="$OUT/r8-diagnostic-contract"
[ "$($exe --odf-r8-budget-mib 480 --odf-r8-inflight 4 --odf-r8-sessions 4)" = "0 160 2 2" ]
base=(--odf-r8-quality-diagnostics --odf-pixel-diagnostics --odf-isolated-profile /tmp/r8-profile --odf-live-log /tmp/r8-log)
[ "$($exe "${base[@]}" --odf-r8-budget-mib 320 --odf-r8-inflight 3 --odf-r8-sessions 4)" = "1 320 3 4" ]
[ "$($exe "${base[@]}" --odf-r8-budget-mib 999 --odf-r8-inflight 20 --odf-r8-sessions 9)" = "1 160 2 2" ]
[ "$($exe --odf-r8-quality-diagnostics --odf-pixel-diagnostics --odf-isolated-profile relative --odf-live-log /tmp/r8-log --odf-r8-budget-mib 480)" = "0 160 2 2" ]
echo 'R8 option isolation/default/allowlist, C++ decoder and BGRA/NV12 motion counterexamples passed'
