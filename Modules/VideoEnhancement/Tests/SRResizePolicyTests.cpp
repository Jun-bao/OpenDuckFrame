#include "SPSRResizePolicy.hpp"
#include <cassert>
#include <cstdio>
int main() {
    int w=0,h=0;
    assert(sp::resizedNativeSROutput(1280,704,1920,1056,1280,720,w,h) && w==1920 && h==1080);
    assert(sp::resizedNativeSROutput(1280,720,1920,1080,1280,704,w,h) && w==1920 && h==1056);
    assert(sp::resizedNativeSROutput(480,270,1920,1080,320,180,w,h) && w==1280 && h==720);
    assert(!sp::resizedNativeSROutput(1280,720,1920,1056,1280,704,w,h));
    assert(!sp::resizedNativeSROutput(1280,720,1280,720,1280,704,w,h));
    assert(!sp::resizedNativeSROutput(1280,720,1920,1080,1279,720,w,h));
    assert(!sp::resizedNativeSROutput(480,270,1920,1080,1280,720,w,h));
    std::puts("native SR resize policy: valid transitions and invalid/manual/budget cases pass");
}
