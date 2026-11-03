// In-process, long-lived wrapper over the upstream MIT Real-CUGAN adapter.
// Input/output are tightly packed RGB8. The caller owns all buffers and
// serializes use of one handle; the wrapper bounds dimensions before ncnn.
#include "realcugan.h"
#include "gpu.h"
#include <cstdint>
#include <cstring>
#include <mutex>
#include <new>

namespace {
std::mutex globalMutex;
unsigned liveHandles=0;
struct Handle { RealCUGAN *model=nullptr; std::mutex work; };
}
extern "C" {
int odf_realcugan_abi_version() { return 1; }
void *odf_realcugan_create(const char *parameters,const char *weights,int *status) {
    if(status)*status=-1;
    if(!parameters || !weights)return nullptr;
    std::lock_guard<std::mutex> lock(globalMutex);
    if(liveHandles==0 && ncnn::create_gpu_instance()!=0)return nullptr;
    if(ncnn::get_gpu_count()<1){if(liveHandles==0)ncnn::destroy_gpu_instance();return nullptr;}
    Handle *handle=new(std::nothrow) Handle;
    if(!handle){if(liveHandles==0)ncnn::destroy_gpu_instance();return nullptr;}
    handle->model=new(std::nothrow) RealCUGAN(0,false,1);
    if(!handle->model || handle->model->load(parameters,weights)!=0){delete handle->model;delete handle;if(liveHandles==0)ncnn::destroy_gpu_instance();return nullptr;}
    int noise=-1;
    if(strstr(parameters,"denoise1x"))noise=1;
    else if(strstr(parameters,"denoise2x"))noise=2;
    else if(strstr(parameters,"denoise3x"))noise=3;
    handle->model->noise=noise;handle->model->scale=2;handle->model->tilesize=200;handle->model->prepadding=18;handle->model->syncgap=noise<0?0:3;
    liveHandles++;if(status)*status=0;return handle;
}
int odf_realcugan_process(void *opaque,const uint8_t *rgb,int width,int height,uint8_t *output) {
    if(!opaque||!rgb||!output||width<2||height<2||width>1920||height>1080)return -1;
    Handle *handle=static_cast<Handle *>(opaque);std::lock_guard<std::mutex> lock(handle->work);
    ncnn::Mat input(width,height,(void *)rgb,(size_t)3,3);
    ncnn::Mat result(width*2,height*2,(size_t)3,3);
    if(result.empty())return -2;
    int code=handle->model->process(input,result);
    if(code!=0)return code;
    memcpy(output,result.data,(size_t)width*height*4*3);return 0;
}
void odf_realcugan_destroy(void *opaque) {
    if(!opaque)return;
    Handle *handle=static_cast<Handle *>(opaque);
    std::lock_guard<std::mutex> lock(globalMutex);
    delete handle->model;delete handle;if(liveHandles>0)liveHandles--;if(liveHandles==0)ncnn::destroy_gpu_instance();
}
}
