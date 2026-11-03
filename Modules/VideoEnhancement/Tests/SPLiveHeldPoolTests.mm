#include "SPLiveHeldPolicy.hpp"
#include <CoreVideo/CoreVideo.h>
#include <cassert>
#include <cstdio>
#include <map>
#include <vector>

static CVPixelBufferRef allocate(CVPixelBufferPoolRef pool, int cap) {
    const void *keys[] = { kCVPixelBufferPoolAllocationThresholdKey };
    CFNumberRef n = CFNumberCreate(nullptr, kCFNumberIntType, &cap);
    const void *values[] = { n };
    CFDictionaryRef aux = CFDictionaryCreate(nullptr, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CVPixelBufferRef b = nullptr;
    CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nullptr, pool, aux, &b);
    CFRelease(aux); CFRelease(n); return b;
}
static void mark(CVPixelBufferRef b, unsigned char v) {
    CVPixelBufferLockBaseAddress(b, 0); *static_cast<unsigned char *>(CVPixelBufferGetBaseAddress(b)) = v; CVPixelBufferUnlockBaseAddress(b, 0);
}
static unsigned char read(CVPixelBufferRef b) {
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly); auto v = *static_cast<unsigned char *>(CVPixelBufferGetBaseAddress(b)); CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly); return v;
}
int main() {
    for (int cap : {4,6,7,8,16}) {
        int width = 32, height = 32, format = kCVPixelFormatType_32BGRA;
        CFNumberRef w=CFNumberCreate(nullptr,kCFNumberIntType,&width), h=CFNumberCreate(nullptr,kCFNumberIntType,&height), f=CFNumberCreate(nullptr,kCFNumberIntType,&format);
        const void *keys[]={kCVPixelBufferWidthKey,kCVPixelBufferHeightKey,kCVPixelBufferPixelFormatTypeKey};
        const void *values[]={w,h,f};
        auto attrs=CFDictionaryCreate(nullptr,keys,values,3,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
        CVPixelBufferPoolRef pool=nullptr; assert(CVPixelBufferPoolCreate(nullptr,nullptr,attrs,&pool)==kCVReturnSuccess);
        CFRelease(attrs); CFRelease(w); CFRelease(h); CFRelease(f);
        std::map<uint64_t,CVPixelBufferRef> held;
        for (uint64_t i=1; i<=150; ++i) {
            auto b=allocate(pool,cap); assert(b); mark(b,(unsigned char)i); held[i]=b;
            std::vector<sp::HeldLease> leases; for (auto &it:held) leases.push_back({it.first,0});
            for (auto id:sp::reclaimableHeld(leases)) { CVPixelBufferRelease(held.at(id)); held.erase(id); }
            assert(held.size()<=2 && read(b)==(unsigned char)i);
        }
        // An older pinned identity survives trimming; completion unpins it
        // and immediately invokes the same policy without requiring a new frame.
        const auto oldID = held.begin()->first;
        auto newBuffer = allocate(pool, cap); assert(newBuffer); mark(newBuffer, 201); held[151] = newBuffer;
        std::vector<sp::HeldLease> pinnedLeases;
        for (auto &it:held) pinnedLeases.push_back({it.first, it.first == oldID ? 1 : 0});
        assert(sp::reclaimableHeld(pinnedLeases).empty());
        pinnedLeases.clear(); for (auto &it:held) pinnedLeases.push_back({it.first,0});
        for (auto id:sp::reclaimableHeld(pinnedLeases)) { CVPixelBufferRelease(held.at(id)); held.erase(id); }
        assert(held.count(oldID)==0 && held.size()==2);
        // Simulate consumers retaining every free slot. No reuse may mutate a
        // pinned buffer; releasing consumers must make allocation possible.
        auto pinned=held.begin()->second; CVPixelBufferRetain(pinned); auto expected=read(pinned);
        std::vector<CVPixelBufferRef> consumers;
        while (auto b=allocate(pool,cap)) { mark(b,77); consumers.push_back(b); }
        assert(!allocate(pool,cap) && read(pinned)==expected);
        for (auto b:consumers) CVPixelBufferRelease(b);
        auto resumed=allocate(pool,cap); assert(resumed && read(pinned)==expected);
        CVPixelBufferRelease(resumed); CVPixelBufferRelease(pinned);
        for (auto &it:held) CVPixelBufferRelease(it.second);
        CVPixelBufferPoolRelease(pool);
        printf("cap=%d progressed=150 exhausted=1 resumed=1 pinnedImmutable=1\n",cap);
    }
}
