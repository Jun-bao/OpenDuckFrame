// OpenDuckFrame - FFmpeg execution layer for private trial decodes (independent read-only context; bounded, cancellable; header-only)
//
// SPTrialExecutor.hpp holds the pure budget / outcome / identity / executor pieces; this file only provides:
//   openInput      - avformat_open_input with an interrupt callback (token + abort hook + deadline);
//   forEachPacket  - the packet loop that checks the Budget on every packet and hands target packets to a callback;
//   audioTrialDecode / h264TrialDecode - the two trial loops that used to be duplicated in the player core and the demuxer.
// Each entry point keeps its original evidence window through Budget.maxTargetPkts; acceptance gates are unchanged.
#pragma once

#include "SPTrialExecutor.hpp"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/frame.h>
#include <libavutil/mem.h>
}

#include <cstring>
#include <functional>
#include <string>

namespace sptrial {

struct InterruptCtx {
    const std::atomic<bool>* cancel = nullptr;
    std::function<bool()> abort;
    int64_t deadlineUs = 0;
    bool cancelled() const {
        if (cancel && cancel->load(std::memory_order_acquire)) return true;
        if (abort && abort()) return true;
        return deadlineUs > 0 && monotonicNowUs() >= deadlineUs;
    }
};

inline int interruptCallback(void* opaque) {
    const InterruptCtx* ic = static_cast<const InterruptCtx*>(opaque);
    return ic && ic->cancelled() ? 1 : 0;
}

inline AVFormatContext* openInput(const std::string& path, InterruptCtx* ic, AVDictionary** opts = nullptr) {
    AVFormatContext* fc = avformat_alloc_context();
    if (!fc) return nullptr;
    fc->interrupt_callback = {interruptCallback, ic};
    if (avformat_open_input(&fc, path.c_str(), nullptr, opts) < 0) return nullptr;
    return fc;
}

inline bool forEachPacket(AVFormatContext* fc, int targetStream, const Budget& b, Stats& s, const InterruptCtx& ic,
                          const std::function<bool(AVPacket*)>& onTarget) {
    AVPacket* pkt = av_packet_alloc();
    if (!pkt) { s.outcome = Outcome::OpenFailed; return false; }
    const int64_t start = monotonicNowUs();
    std::function<bool()> abortFn = [&ic] { return ic.cancelled(); };
    bool ok = true;
    for (;;) {
        if (!withinBudget(b, s, start, monotonicNowUs(), &abortFn)) { ok = s.targetPkts >= b.maxTargetPkts; break; }
        const int r = av_read_frame(fc, pkt);
        if (r < 0) {
            if (r != AVERROR_EOF && !ic.cancelled()) { s.outcome = Outcome::ReadFailed; ok = false; }
            else if (ic.cancelled()) { s.outcome = Outcome::Cancelled; ok = false; }
            break;
        }
        ++s.anyPkts;
        s.bytes += pkt->size;
        bool cont = true;
        if (pkt->stream_index == targetStream) {
            ++s.targetPkts;
            cont = onTarget(pkt);
        }
        av_packet_unref(pkt);
        if (!cont) break;
    }
    av_packet_free(&pkt);
    s.wallUs = monotonicNowUs() - start;
    return ok;
}

inline Stats audioTrialDecode(const std::string& path, int streamIndex, const uint8_t* extradata, int extradataSize,
                              const Budget& budget, const InterruptCtx& ic) {
    Stats s;
    AVFormatContext* fc = openInput(path, const_cast<InterruptCtx*>(&ic));
    if (!fc) { s.outcome = ic.cancelled() ? Outcome::Cancelled : Outcome::OpenFailed; return s; }
    if ((unsigned)streamIndex >= fc->nb_streams) { avformat_close_input(&fc); s.outcome = Outcome::OpenFailed; return s; }
    const AVCodecParameters* par = fc->streams[streamIndex]->codecpar;
    const AVCodec* dec = avcodec_find_decoder(par->codec_id);
    AVCodecContext* ctx = dec ? avcodec_alloc_context3(dec) : nullptr;
    bool opened = false;
    if (ctx && avcodec_parameters_to_context(ctx, par) >= 0) {
        if (extradata && extradataSize > 0) {
            uint8_t* e = (uint8_t*)av_mallocz((size_t)extradataSize + AV_INPUT_BUFFER_PADDING_SIZE);
            if (e) { std::memcpy(e, extradata, (size_t)extradataSize); av_freep(&ctx->extradata); ctx->extradata = e; ctx->extradata_size = extradataSize; }
        }
        opened = avcodec_open2(ctx, dec, nullptr) == 0;
    }
    if (!opened) {
        if (ctx) avcodec_free_context(&ctx);
        avformat_close_input(&fc);
        s.outcome = Outcome::OpenFailed;
        return s;
    }
    AVFrame* fr = av_frame_alloc();
    auto receive = [&] {
        while (fr && avcodec_receive_frame(ctx, fr) == 0) {
            s.samples += fr->nb_samples;
            if (fr->decode_error_flags != 0 || (fr->flags & AV_FRAME_FLAG_CORRUPT)) ++s.flaggedFrames; else s.cleanSamples += fr->nb_samples;
            av_frame_unref(fr);
        }
    };
    const bool ok = forEachPacket(fc, streamIndex, budget, s, ic, [&](AVPacket* pkt) {
        int r = avcodec_send_packet(ctx, pkt);
        if (r == AVERROR(EAGAIN)) { receive(); r = avcodec_send_packet(ctx, pkt); }
        if (r < 0) ++s.sendErrors;
        receive();
        return true;
    });
    if (ok) { avcodec_send_packet(ctx, nullptr); receive(); }
    av_frame_free(&fr);
    avcodec_free_context(&ctx);
    avformat_close_input(&fc);
    if (ok) s.outcome = classify(s, 1);
    return s;
}

inline Stats h264TrialDecode(const std::string& path, int64_t patchAt, uint8_t patchByte, const Budget& budget, const InterruptCtx& ic) {
    Stats s;
    AVFormatContext* fc = openInput(path, const_cast<InterruptCtx*>(&ic));
    if (!fc) { s.outcome = ic.cancelled() ? Outcome::Cancelled : Outcome::OpenFailed; return s; }
    int vi = -1;
    for (unsigned i = 0; i < fc->nb_streams; ++i) {
        if (fc->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && fc->streams[i]->codecpar->codec_id == AV_CODEC_ID_H264) { vi = (int)i; break; }
    }
    const AVCodec* dec = avcodec_find_decoder(AV_CODEC_ID_H264);
    AVCodecContext* ctx = (vi >= 0 && dec) ? avcodec_alloc_context3(dec) : nullptr;
    bool opened = false;
    if (ctx && avcodec_parameters_to_context(ctx, fc->streams[vi]->codecpar) >= 0) {
        ctx->thread_count = 1;
        ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
        opened = avcodec_open2(ctx, dec, nullptr) == 0;
    }
    if (!opened) {
        if (ctx) avcodec_free_context(&ctx);
        avformat_close_input(&fc);
        s.outcome = Outcome::OpenFailed;
        return s;
    }
    AVFrame* fr = av_frame_alloc();
    auto receive = [&] {
        while (fr && avcodec_receive_frame(ctx, fr) == 0) {
            ++s.frames;
            if (fr->decode_error_flags || (fr->flags & AV_FRAME_FLAG_CORRUPT)) ++s.flaggedFrames;
            av_frame_unref(fr);
        }
    };
    const bool ok = forEachPacket(fc, vi, budget, s, ic, [&](AVPacket* pkt) {
        if (patchAt >= 0 && pkt->pos >= 0 && patchAt >= pkt->pos && patchAt < pkt->pos + pkt->size && av_packet_make_writable(pkt) >= 0) {
            pkt->data[patchAt - pkt->pos] = patchByte;
        }
        int r = avcodec_send_packet(ctx, pkt);
        if (r == AVERROR(EAGAIN)) { receive(); r = avcodec_send_packet(ctx, pkt); }
        if (r < 0) ++s.sendErrors;
        receive();
        return true;
    });
    if (ok) { avcodec_send_packet(ctx, nullptr); receive(); }
    av_frame_free(&fr);
    avcodec_free_context(&ctx);
    avformat_close_input(&fc);
    if (ok) s.outcome = classify(s, 1);
    return s;
}

} // namespace sptrial
