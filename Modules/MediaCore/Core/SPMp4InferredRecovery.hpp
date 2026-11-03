// Fault-only inferred video extraction. All reads retain a caller-owned source
// view; no path reopen, no healthy-path parser/decoder, no original-time claim.
#pragma once
#include "Recovery/RecoveryMp4.hpp"
#include "SPReadSourceView.hpp"
#include "SPTrialDecode.hpp"
#include <numeric>
#include <memory>

namespace sptrial {
struct Mp4InferredLimits { uint64_t readBytes = 64u << 20; uint32_t samples = 1024, segments = 64; int64_t wallUs = 2000000; };
enum class Mp4InferredStatus { NoMatch, Ready, Cancelled, Budget, SourceChanged, Allocation };
struct Mp4InferredResult {
    spresil::RecoveryPlan plan;
    Mp4InferredStatus status = Mp4InferredStatus::NoMatch;
    uint64_t bytesRead = 0;
    uint32_t samples = 0, segments = 0;
    int64_t wallUs = 0;
};
namespace mp4inferred {
using namespace spresil;
constexpr int64_t kMaxCodedPixels = 4096ll * 2304;
struct Syntax {
    bool hevc = false;
    int length = 4, frameBits = 0, pocBits = 0;
    uint32_t spsId = 0, ppsId = 0, num = 0, den = 0, addresses = 0;
    int addressBits = 0;
    bool ppsOutput = false; int extraBits = 0;
    std::vector<uint8_t> sps, pps, vps;
};
inline bool h264Sps(Syntax& s) {
    if (s.sps.size() < 5 || (s.sps[0] & 31) != 7) return false;
    detail::H264BitReader b(s.sps.data()+1,s.sps.size()-1,1024);
    uint32_t profile=b.bits(8);b.bits(16);s.spsId=b.ue();
    if(profile==100||profile==110||profile==122||profile==244||profile==44||profile==83||profile==86||profile==118||profile==128||profile==138||profile==139||profile==134||profile==135){
        uint32_t chroma=b.ue();if(chroma>2)return false;if(b.ue()>6||b.ue()>6)return false;b.bits(1);
        if(b.bits(1))for(int i=0;i<8&&!b.bad;++i)if(b.bits(1)){int last=8,next=8;for(int j=0;j<(i<6?16:64)&&!b.bad;++j){if(next)next=(last+b.se()+256)%256;if(next)last=next;}}
    }
    uint32_t frame=b.ue();if(frame>12||b.ue()!=0)return false;s.frameBits=(int)frame+4;
    uint32_t poc=b.ue();if(poc>12)return false;s.pocBits=(int)poc+4;
    if(b.ue()>16)return false;b.bits(1);uint32_t wm=b.ue(),hm=b.ue();if(wm>1023||hm>1023)return false;s.addresses=(wm+1)*(hm+1);if((uint64_t)s.addresses*256>(uint64_t)kMaxCodedPixels)return false;if(!b.bits(1))return false;b.bits(1);
    if(b.bits(1)){b.ue();b.ue();b.ue();b.ue();}
    if(b.bad||!b.bits(1))return false;
    if(b.bits(1)&&b.bits(8)==255){b.bits(16);b.bits(16);}if(b.bits(1))b.bits(1);
    if(b.bits(1)){b.bits(3);b.bits(1);if(b.bits(1)){b.bits(8);b.bits(8);b.bits(8);}}
    if(b.bits(1)){b.ue();b.ue();}if(!b.bits(1))return false;
    uint32_t nu=b.bits(32),ts=b.bits(32);if(!b.bits(1)||!nu||nu>UINT32_MAX/2||!ts)return false;
    // HRD and pic_struct signalling need further timing semantics: not this subset.
    if(b.bits(1)||b.bits(1)||b.bits(1))return false;
    s.num=ts;s.den=2*nu;
    if(b.bad||s.spsId>31||s.pps.size()<2||(s.pps[0]&31)!=8)return false;
    detail::H264BitReader p(s.pps.data()+1,s.pps.size()-1);
    s.ppsId=p.ue();uint32_t sid=p.ue();p.bits(1);bool bottom=p.bits(1);uint32_t groups=p.ue();
    return !p.bad&&s.ppsId<=255&&sid==s.spsId&&!bottom&&!groups;
}
inline bool hevcSps(Syntax& s) {
    if(s.sps.size()<16||s.pps.size()<4||s.vps.size()<3)return false;
    detail::H264BitReader b(s.sps.data()+2,s.sps.size()-2,2048);
    const uint32_t vid=b.bits(4);int sub=(int)b.bits(3);b.bits(1);
    b.bits(8);b.bits(32);bool progressive=b.bits(1),interlaced=b.bits(1);b.bits(1);bool frameOnly=b.bits(1);b.skip(44);b.bits(8);
    if(!progressive||interlaced||!frameOnly)return false;
    bool prof[8]={},lev[8]={};for(int i=0;i<sub;++i){prof[i]=b.bits(1);lev[i]=b.bits(1);}if(sub)for(int i=sub;i<8;++i)b.bits(2);
    for(int i=0;i<sub;++i){if(prof[i])b.skip(88);if(lev[i])b.bits(8);}
    s.spsId=b.ue();uint32_t chroma=b.ue();if(chroma>2)return false;uint32_t width=b.ue(),height=b.ue();if(!width||!height||width>16384||height>16384||(uint64_t)width*height>(uint64_t)kMaxCodedPixels)return false;if(b.bits(1)){b.ue();b.ue();b.ue();b.ue();}
    if(b.ue()>6||b.ue()>6)return false;uint32_t lp=b.ue();if(lp>12)return false;s.pocBits=(int)lp+4;
    bool ordering=b.bits(1);for(int i=ordering?0:sub;i<=sub;++i){if(b.ue()>15||b.ue()>15)return false;b.ue();}
    uint32_t minCb=b.ue(),diffCb=b.ue();if(minCb>3||diffCb>3||minCb+diffCb>3)return false;uint32_t cb=1u<<(minCb+diffCb+3);s.addresses=((width+cb-1)/cb)*((height+cb-1)/cb);while((1u<<s.addressBits)<s.addresses)++s.addressBits;
    b.ue();b.ue();b.ue();b.ue();
    if(b.bits(1)&&b.bits(1))for(int z=0;z<4&&!b.bad;++z)for(int m=0;m<6&&!b.bad;m+=(z==3?3:1)){if(!b.bits(1)){b.ue();continue;}if(z>1)b.se();for(int i=0;i<std::min(64,1<<(4+(z<<1)));++i)b.se();}
    b.bits(1);b.bits(1);if(b.bits(1)){b.bits(4);b.bits(4);b.ue();b.ue();b.bits(1);}
    uint32_t sets=b.ue();if(b.bad||sets>64)return false;std::vector<int> counts(sets,0);
    for(uint32_t i=0;i<sets&&!b.bad;++i){bool inter=i&&b.bits(1);if(inter){b.bits(1);b.ue();int ref=counts[i-1];for(int j=0;j<=ref;++j){bool used=b.bits(1);bool delta=used||b.bits(1);if(delta)++counts[i];}}else{uint32_t neg=b.ue(),pos=b.ue();if(neg>16||pos>16)return false;for(uint32_t j=0;j<neg+pos;++j){b.ue();b.bits(1);}counts[i]=(int)(neg+pos);}}
    if(b.bits(1)){uint32_t n=b.ue();if(n>32)return false;for(uint32_t i=0;i<n;++i){b.bits(s.pocBits);b.bits(1);}}
    b.bits(1);b.bits(1);if(b.bad||!b.bits(1))return false;
    if(b.bits(1)&&b.bits(8)==255){b.bits(16);b.bits(16);}if(b.bits(1))b.bits(1);
    if(b.bits(1)){b.bits(3);b.bits(1);if(b.bits(1)){b.bits(8);b.bits(8);b.bits(8);}}
    if(b.bits(1)){b.ue();b.ue();}b.bits(1);if(b.bits(1)||b.bits(1))return false; // field_seq/frame_field_info
    if(b.bits(1)){b.ue();b.ue();b.ue();b.ue();}if(!b.bits(1))return false;
    s.den=b.bits(32);s.num=b.bits(32);
    // This subset has one output picture per POC tick. Other tick scales and
    // HRD timing need their own timeline proof rather than a guessed ratio.
    if(b.bits(1)&&b.ue()!=0)return false;
    if(b.bits(1))return false;
    if(b.bad||!s.den||!s.num||s.spsId>15||(s.vps[2]>>4)!=vid)return false;
    detail::H264BitReader p(s.pps.data()+2,s.pps.size()-2);s.ppsId=p.ue();uint32_t sid=p.ue();
    if(p.bits(1))return false; // dependent slices not handled by this first subset
    s.ppsOutput=p.bits(1);s.extraBits=(int)p.bits(3);
    return !p.bad&&s.ppsId<=63&&sid==s.spsId;
}
inline bool syntax(const CarvedSamples& c,const std::vector<uint8_t>& first,Syntax& s){
    s.hevc=c.codec=="hevc";if(c.configBox.size()<(s.hevc?31u:14u))return false;
    s.length=(c.configBox[s.hevc?29:12]&3)+1;size_t pos=0;
    while(pos<first.size()){
        if(first.size()-pos<(size_t)s.length+2)return false;uint32_t n=0;for(int i=0;i<s.length;++i)n=(n<<8)|first[pos+i];pos+=s.length;if(n>first.size()-pos||n<2)return false;
        const uint8_t* p=first.data()+pos;int type=s.hevc?(p[0]>>1)&63:p[0]&31;
        std::vector<uint8_t>* out=type==(s.hevc?33:7)?&s.sps:type==(s.hevc?34:8)?&s.pps:s.hevc&&type==32?&s.vps:nullptr;
        if(out){if(n>2048)return false;if(out->empty())out->assign(p,p+n);else if(out->size()!=n||memcmp(out->data(),p,n))return false;}
        pos+=n;
    }
    if(!(s.hevc?hevcSps(s):h264Sps(s)))return false;
    const double fps=(double)s.num/s.den;return fps>=1&&fps<=240;
}
inline bool noTimingSei(const uint8_t* p,size_t n,int header){
    if(n<=(size_t)header||n>65536)return false;
    detail::H264BitReader br(p+header,n-header,65536);const auto& d=br.b;size_t at=0;
    while(at<d.size()&&d[at]!=0x80){uint32_t type=0,len=0;while(at<d.size()&&d[at]==255){type+=255;++at;}if(at==d.size())return false;type+=d[at++];while(at<d.size()&&d[at]==255){len+=255;++at;}if(at==d.size())return false;len+=d[at++];if(type==0||type==1||len>d.size()-at)return false;at+=len;}
    return at<d.size()&&d[at]==0x80;
}
struct Picture {int poc=0;bool idr=false;};
inline bool picture(const std::vector<uint8_t>& data,size_t size,const Syntax& s,Picture& pic){
    size_t pos=0;int vcl=0;uint32_t previousAddress=0,previousFrame=0,previousIdr=0;int temporal=-1;
    while(pos<size){
        if(size-pos<(size_t)s.length+2)return false;uint32_t n=0;for(int i=0;i<s.length;++i)n=(n<<8)|data[pos+i];pos+=s.length;if(n>size-pos||n<2)return false;
        const uint8_t* p=data.data()+pos;int type=0;if(!mp4NalHeaderOk(p,s.hevc,type)||(s.hevc&&((p[0]&1)||(p[1]>>3))))return false;
        const bool isVcl=s.hevc?type<=31:type==1||type==5;
        if(isVcl){
            detail::H264BitReader b(p+(s.hevc?2:1),n-(s.hevc?2:1),256);bool idr=false;uint32_t poc=0,address=0,frame=0,idrNumber=0;
            if(s.hevc){
                if(type>21||(type>=16&&type!=19&&type!=20)||type==8||type==9)return false;
                const bool firstSlice=b.bits(1);if(type>=16)b.bits(1);uint32_t pps=b.ue();if(pps!=s.ppsId)return false;
                if(!firstSlice)address=b.bits(s.addressBits);
                if(firstSlice!=(vcl==0))return false;
                b.skip(s.extraBits);if(b.ue()>2)return false;
                if(s.ppsOutput&&!b.bits(1))return false;idr=type==19||type==20;if(!idr)poc=b.bits(s.pocBits);
                const int layerTemporal=p[1]&7;if(temporal>=0&&temporal!=layerTemporal)return false;temporal=layerTemporal;
            }else{
                address=b.ue();const uint32_t slice=b.ue(),pps=b.ue();if(slice>9||pps!=s.ppsId)return false;frame=b.bits(s.frameBits);idr=type==5;if(idr)idrNumber=b.ue();poc=b.bits(s.pocBits);
            }
            if(b.bad||address>=s.addresses||(vcl==0?address!=0:address<=previousAddress))return false;
            if(vcl&&(pic.poc!=(int)poc||pic.idr!=idr||frame!=previousFrame||idrNumber!=previousIdr))return false;
            pic={(int)poc,idr};previousAddress=address;previousFrame=frame;previousIdr=idrNumber;++vcl;
        }else{
            const std::vector<uint8_t>* param=type==(s.hevc?33:7)?&s.sps:type==(s.hevc?34:8)?&s.pps:s.hevc&&type==32?&s.vps:nullptr;
            if(param){if(n!=param->size()||memcmp(p,param->data(),n))return false;}
            else if(type==(s.hevc?39:6)||(s.hevc&&type==40)){if(!noTimingSei(p,n,s.hevc?2:1))return false;}
            else if(type!=(s.hevc?35:9))return false;
        }
        pos+=n;
    }
    return vcl>=1;
}
struct Codec {
    AVCodecContext* c=nullptr;AVCodecParserContext* parser=nullptr;AVFrame* frame=nullptr;AVPacket* packet=nullptr;
    ~Codec(){av_packet_free(&packet);av_frame_free(&frame);if(parser)av_parser_close(parser);avcodec_free_context(&c);}
    bool open(const CarvedSamples& samples){
        const AVCodecID id=samples.codec=="hevc"?AV_CODEC_ID_HEVC:AV_CODEC_ID_H264;const AVCodec* dec=avcodec_find_decoder(id);if(!dec)return false;
        c=avcodec_alloc_context3(dec);parser=av_parser_init(id);frame=av_frame_alloc();packet=av_packet_alloc();if(!c||!parser||!frame||!packet)return false;
        c->max_pixels=kMaxCodedPixels;
        c->thread_count=1;c->thread_type=0;c->flags|=AV_CODEC_FLAG_COPY_OPAQUE;c->err_recognition=AV_EF_EXPLODE|AV_EF_BITSTREAM|AV_EF_BUFFER;
        const size_t n=samples.configBox.size()-8;c->extradata=(uint8_t*)av_mallocz(n+AV_INPUT_BUFFER_PADDING_SIZE);if(!c->extradata)return false;
        memcpy(c->extradata,samples.configBox.data()+8,n);c->extradata_size=(int)n;c->width=samples.width;c->height=samples.height;
        parser->flags|=PARSER_FLAG_COMPLETE_FRAMES;return avcodec_open2(c,dec,nullptr)>=0;
    }
};
} // namespace mp4inferred

inline Mp4InferredResult planMp4InferredRecovery(const sp::ReadSourceView& view,const spresil::AbortFn* abort=nullptr,const Mp4InferredLimits& limits={}) {
    using namespace spresil;using namespace mp4inferred;
    Mp4InferredResult out;const int64_t started=monotonicNowUs();
    try {
    auto current=[&](){
        if(out.status!=Mp4InferredStatus::NoMatch) return false;
        if(aborted(abort)){out.status=Mp4InferredStatus::Cancelled;return false;}
        if(monotonicNowUs()-started>=limits.wallUs){out.status=Mp4InferredStatus::Budget;return false;}
        if(!view||!view.current()){out.status=Mp4InferredStatus::SourceChanged;return false;}return true;
    };
    auto finish=[&](){out.wallUs=monotonicNowUs()-started;if(out.status!=Mp4InferredStatus::Ready)out.plan={};return out;};
    Reader read=[&](int64_t pos,uint8_t* d,size_t n)->int64_t{
        if(!current())return -1;if(out.bytesRead>limits.readBytes||n>limits.readBytes-out.bytesRead){out.status=Mp4InferredStatus::Budget;return -1;}
        const int64_t got=view.read(pos,d,n);if(got>0)out.bytesRead+=(uint64_t)got;if(!current())return -1;return got;
    };
    AbortFn stop=[&](){return !current();};
    if(!current()||limits.samples==0||limits.samples>1024||limits.segments>64)return finish();
    std::vector<Box> mdats;int64_t pos=0;int hops=0;
    while(pos<view.size&&hops++<128){
        Box b;if(!readBox(read,pos,view.size,b)||b.end()>view.size||b.end()<=pos)return finish();
        // Any surviving moov is preserved. This new branch only handles absent
        // metadata, never replaces a usable audio/video track with guessed video.
        if(b.is("mdat")){if(b.size>(uint64_t)b.hdr){if(mdats.size()>=limits.segments){out.status=Mp4InferredStatus::Budget;return finish();}mdats.push_back(b);}}
        else if(!(b.is("ftyp")||b.is("wide")||b.is("free")||b.is("skip")))return finish();
        pos=b.end();
    }
    if(pos!=view.size){if(hops>=128)out.status=Mp4InferredStatus::Budget;return finish();}
    if(mdats.empty())return finish();
    CarvedSamples samples;std::vector<uint32_t> starts;
    for(const Box& b:mdats){
        if(!current())return finish();CarvedSamples part;
        bool sampleLimit=false;
        if(!carveAvcHevc(read,b.pos+b.hdr,b.end(),part,&stop,true,limits.samples,&sampleLimit)){if(sampleLimit&&out.status==Mp4InferredStatus::NoMatch)out.status=Mp4InferredStatus::Budget;return finish();}
        if(sampleLimit){out.status=Mp4InferredStatus::Budget;return finish();}
        if(samples.samples.empty()){samples=part;starts.push_back(0);}
        else{
            if(part.codec!=samples.codec||part.width!=samples.width||part.height!=samples.height||part.configBox!=samples.configBox||part.fpsNum!=samples.fpsNum||part.fpsDen!=samples.fpsDen)return finish();
            const uint32_t base=(uint32_t)samples.samples.size();starts.push_back(base);for(uint32_t key:part.keyframes)samples.keyframes.push_back(base+key);
            samples.samples.insert(samples.samples.end(),part.samples.begin(),part.samples.end());samples.containsB|=part.containsB;
        }
        if(samples.samples.size()>limits.samples){out.status=Mp4InferredStatus::Budget;return finish();}
    }
    if(mdats.size()==1&&!samples.containsB)return finish(); // existing no-B branch remains unchanged
    if(samples.samples.empty()||samples.samples[0].second>(4u<<20))return finish();
    const auto first=readSpan(read,samples.samples[0].first,samples.samples[0].second);Syntax syntax;
    if(first.size()!=samples.samples[0].second||!mp4inferred::syntax(samples,first,syntax))return finish();
    const uint32_t gcd=std::gcd(syntax.num,syntax.den);syntax.num/=gcd;syntax.den/=gcd;
    if(syntax.num>INT_MAX||syntax.den>INT_MAX||(uint64_t)samples.samples.size()*syntax.den>UINT32_MAX)return finish();samples.fpsNum=(int)syntax.num;samples.fpsDen=(int)syntax.den;samples.fpsFromStream=true;
    Codec codec;if(!codec.open(samples))return finish();
    std::vector<Picture> pictures;std::vector<uint32_t> output;
    auto receive=[&](bool drain){
        for(;;){if(!current())return false;const int r=avcodec_receive_frame(codec.c,codec.frame);if(r==AVERROR(EAGAIN))return !drain;if(r==AVERROR_EOF)return drain;if(r<0)return false;
            AVFrame* f=codec.frame;
            if(f->decode_error_flags||(f->flags&(AV_FRAME_FLAG_CORRUPT|AV_FRAME_FLAG_DISCARD|AV_FRAME_FLAG_INTERLACED))||f->repeat_pict||f->width!=samples.width||f->height!=samples.height||
               !f->opaque_ref||f->opaque_ref->size!=sizeof(uint32_t))return false;
            uint32_t id;memcpy(&id,f->opaque_ref->data,sizeof(id));if(id>=samples.samples.size()||std::find(output.begin(),output.end(),id)!=output.end())return false;
            output.push_back(id);av_frame_unref(f);if(output.size()>limits.samples)return false;
        }
    };
    for(uint32_t i=0;i<samples.samples.size();++i){
        if(!current())return finish();const auto sm=samples.samples[i];if(sm.second>(4u<<20))return finish();
        auto data=readSpan(read,sm.first,sm.second);if(data.size()!=sm.second)return finish();Picture pic;
        if(!picture(data,data.size(),syntax,pic))return finish();
        if(std::binary_search(starts.begin(),starts.end(),i)&&!pic.idr)return finish();
        if(i==0&&!pic.idr)return finish();data.resize(data.size()+AV_INPUT_BUFFER_PADDING_SIZE,0);
        uint8_t* parsed=nullptr;int parsedSize=0;codec.parser->output_picture_number=INT_MIN;
        const int used=av_parser_parse2(codec.parser,codec.c,&parsed,&parsedSize,data.data(),sm.second,AV_NOPTS_VALUE,AV_NOPTS_VALUE,sm.first);
        if(used!=(int)sm.second||parsedSize!=(int)sm.second||codec.parser->output_picture_number!=pic.poc||codec.parser->repeat_pict!=(syntax.hevc?0:1))return finish();
        const AVRational parsedRate=codec.c->framerate;
        if(parsedRate.num>0&&parsedRate.den>0&&av_cmp_q(parsedRate,AVRational{(int)syntax.num,(int)syntax.den})!=0)return finish();
        pictures.push_back(pic);
        if(av_new_packet(codec.packet,(int)sm.second)<0)return finish();memcpy(codec.packet->data,data.data(),sm.second);
        codec.packet->opaque_ref=av_buffer_alloc(sizeof(uint32_t));if(!codec.packet->opaque_ref)return finish();memcpy(codec.packet->opaque_ref->data,&i,sizeof(i));
        const int sent=avcodec_send_packet(codec.c,codec.packet);av_packet_unref(codec.packet);if(sent<0||!receive(false))return finish();
        // Bounded in-flight/reorder count includes decoder-held output delay.
        if(i+1-output.size()>32)return finish();
    }
    if(!current()||avcodec_send_packet(codec.c,nullptr)<0||!receive(true)||output.size()!=samples.samples.size())return finish();
    std::vector<uint32_t> expected;samples.keyframes.clear();samples.compositionOffsets.assign(samples.samples.size(),0);
    for(uint32_t from=0;from<pictures.size();){
        if(!pictures[from].idr||pictures[from].poc!=0)return finish();uint32_t until=from+1;while(until<pictures.size()&&!pictures[until].idr)++until;
        std::vector<uint32_t> ids;for(uint32_t i=from;i<until;++i)ids.push_back(i);
        std::sort(ids.begin(),ids.end(),[&](uint32_t a,uint32_t b){return pictures[a].poc<pictures[b].poc;});
        const int step=syntax.hevc?1:2;
        for(uint32_t rank=0;rank<ids.size();++rank){if(pictures[ids[rank]].poc!=(int)rank*step)return finish();
            const int64_t offset=((int64_t)from+rank-ids[rank])*syntax.den;if(offset<INT32_MIN||offset>INT32_MAX)return finish();samples.compositionOffsets[ids[rank]]=(int32_t)offset;
        }
        expected.insert(expected.end(),ids.begin(),ids.end());samples.keyframes.push_back(from);from=until;
    }
    if(output!=expected||!current())return finish();
    for(const Box& b:mdats)if(b.sizeFieldZero||b.largeSizeZero){Patch p;p.offset=b.pos+(b.hdr==16?8:0);if(b.hdr==16)putBe64(p.bytes,b.size);else{if(b.size>UINT32_MAX)return finish();putBe32(p.bytes,(uint32_t)b.size);}out.plan.patches.push_back(std::move(p));}
    Patch moov;moov.offset=view.size;moov.bytes=buildSyntheticMoov(samples);if(moov.bytes.empty())return finish();out.plan.patches.push_back(std::move(moov));
    out.plan.kind=mdats.size()>1?"mp4-carve-file-order-inferred":"mp4-carve-b-order-inferred";
    out.plan.detail="按明确码流 cadence 推定的视频片段；显示顺序经全部 AU 独立软件解码验证；跨 mdat 按文件物理顺序提取，原时间/编辑/片序及音轨未恢复";
    out.plan.damagedFrom=view.size;out.plan.damagedUntil=view.size;if(!current())return finish();out.samples=(uint32_t)samples.samples.size();out.segments=(uint32_t)mdats.size();out.status=Mp4InferredStatus::Ready;return finish();
    } catch(const std::bad_alloc&) {
        out.plan={};out.status=Mp4InferredStatus::Allocation;
        out.wallUs=monotonicNowUs()-started;return out;
    }
}
} // namespace sptrial
