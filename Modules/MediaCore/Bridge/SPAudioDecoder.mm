#include "SPAudioDecoder.h"
#include "SPRuntimeGates.hpp"
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <CommonCrypto/CommonDigest.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dict.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
}
#include <vector>

static const int kOutSampleRate = 48000;

@implementation SPAudioDecoder {
    int _dbgRecvErrLogs;
    AVCodecContext *_ctx;
    AVFrame *_frame;
    struct SwrContext *_swr;
    double _inSampleRate;
    uint8_t *_convertBuf;
    int _convertBufCapacity;

    int _swrInFmt;
    int _swrInRate;
    AVChannelLayout _swrInLayout;
    AVChannelLayout _outLayout;
    int _outChannels;
    CC_MD5_CTX _md5;
    BOOL _md5Valid;
    uint64_t _md5Samples;
    std::vector<uint8_t> _md5Buf;
    int _lastErrorFlaggedFrames;
    int _lastCleanFrames;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _ctx = nullptr;
        _frame = nullptr;
        _swr = nullptr;
        _convertBuf = nullptr;
        _convertBufCapacity = 0;
        _swrInFmt = AV_SAMPLE_FMT_NONE;
        _swrInRate = 0;
        _swrInLayout = {};
        _outLayout = {};
        _outChannels = 0;
    }
    return self;
}

- (void)dealloc {
    [self shutdown];
    av_channel_layout_uninit(&_outLayout);
}

#define SPLOG(fmt, ...) NSLog(@"[c%u]" fmt, self->_spLogId, ##__VA_ARGS__)

- (int)outputChannels { return _outChannels; }

static const AVChannelLayout *spDecoderDownmixRequest(enum AVCodecID id, const AVChannelLayout *target) {
    static const AVChannelLayout kStereo = AV_CHANNEL_LAYOUT_STEREO;
    static const AVChannelLayout kFive1Side = AV_CHANNEL_LAYOUT_5POINT1;
    static const AVChannelLayout kFive1Back = AV_CHANNEL_LAYOUT_5POINT1_BACK;
    const bool isStereo = av_channel_layout_compare(target, &kStereo) == 0;
    const bool is51 = av_channel_layout_compare(target, &kFive1Back) == 0 ||
                      av_channel_layout_compare(target, &kFive1Side) == 0;
    switch (id) {
        case AV_CODEC_ID_AC3:
        case AV_CODEC_ID_EAC3:
            return isStereo ? &kStereo : nullptr;
        case AV_CODEC_ID_DTS:
        case AV_CODEC_ID_TRUEHD:
        case AV_CODEC_ID_MLP:
            return isStereo ? &kStereo : is51 ? &kFive1Side : nullptr;
        default:
            return nullptr;
    }
}

- (struct SwrContext *)makeSwrForFormat:(int)fmt rate:(int)rate layout:(const AVChannelLayout *)in {
    struct SwrContext *swr = nullptr;
    int sret = swr_alloc_set_opts2(&swr, &_outLayout, AV_SAMPLE_FMT_FLT, kOutSampleRate,
                                   in, (AVSampleFormat)fmt, rate, 0, nullptr);
    if (sret < 0 || !swr) return nullptr;
    av_opt_set_double(swr, "rematrix_maxval", 1.0, 0);
    if (swr_init(swr) < 0) {
        swr_free(&swr);
        return nullptr;
    }
    return swr;
}

- (int)setupWithCodecParameters:(const AVCodecParameters *)par {
    return [self setupWithCodecParameters:par outputChannelMask:0];
}

- (int)setupWithCodecParameters:(const AVCodecParameters *)par
              outputChannelMask:(uint64_t)outputChannelMask {
    [self shutdown];

    av_channel_layout_uninit(&_outLayout);
    if (outputChannelMask == 0 || av_channel_layout_from_mask(&_outLayout, outputChannelMask) < 0) {
        av_channel_layout_default(&_outLayout, 2);
    }
    _outChannels = _outLayout.nb_channels;

    const AVCodec *codec = avcodec_find_decoder((AVCodecID)par->codec_id);
    if (!codec) return -1;

    _ctx = avcodec_alloc_context3(codec);
    if (!_ctx) return -2;
    if (avcodec_parameters_to_context(_ctx, par) < 0) return -3;

    AVDictionary *opts = nullptr;
    const bool dolby = par->codec_id == AV_CODEC_ID_AC3 || par->codec_id == AV_CODEC_ID_EAC3;
    if (dolby) {

        av_dict_set(&opts, "drc_scale", "0", 0);
    }
    bool requestedDownmix = false;
    if (par->ch_layout.nb_channels > _outChannels) {
        const AVChannelLayout *req = spDecoderDownmixRequest((AVCodecID)par->codec_id, &_outLayout);
        char buf[64];
        if (req && av_channel_layout_describe(req, buf, sizeof(buf)) > 0) {
            av_dict_set(&opts, "downmix", buf, 0);
            requestedDownmix = true;
        }
    }
    int oret = avcodec_open2(_ctx, codec, &opts);
    av_dict_free(&opts);
    if (oret < 0) return -4;

    _frame = av_frame_alloc();
    if (!_frame) return -5;

    _inSampleRate = _ctx->sample_rate > 0 ? _ctx->sample_rate : 48000;

    _swr = [self makeSwrForFormat:_ctx->sample_fmt rate:(int)_inSampleRate layout:&_ctx->ch_layout];
    if (!_swr) return -6;
    _swrInFmt = _ctx->sample_fmt;
    _swrInRate = (int)_inSampleRate;
    if (av_channel_layout_copy(&_swrInLayout, &_ctx->ch_layout) < 0) return -7;

    _convertBufCapacity = 8192;
    _convertBuf = (uint8_t *)av_malloc((size_t)_convertBufCapacity * _outChannels * sizeof(float));
    if (!_convertBuf) return -8;
    _md5Valid = _nativeMd5Enabled ? YES : NO;
    _md5Samples = 0;
    if (_md5Valid) CC_MD5_Init(&_md5);
    if (spDebug()) {
        char inDesc[64] = "?", outDesc[64] = "?";
        av_channel_layout_describe(&par->ch_layout, inDesc, sizeof(inDesc));
        av_channel_layout_describe(&_outLayout, outDesc, sizeof(outDesc));

        SPLOG(@"[Audio] 解码器 %s：源 %s %dHz → 输出 %s（%@%@）",
              codec->name, inDesc, par->sample_rate, outDesc,
              requestedDownmix ? @"解码器内建降混" : @"swr 归一化矩阵",
              dolby ? @"，DRC 关" : @"");
    }
    return 0;
}

- (int)lastErrorFlaggedFrames { return _lastErrorFlaggedFrames; }
- (int)lastCleanFrames { return _lastCleanFrames; }
- (int)codecIdValue { return _ctx ? (int)_ctx->codec_id : 0; }
- (int)inputSampleRate { return _ctx ? _ctx->sample_rate : 0; }

- (int)decodePacket:(const AVPacket *)pkt into:(NSMutableData *)outData {
    if (!_ctx) return 0;
    _lastErrorFlaggedFrames = 0;
    _lastCleanFrames = 0;
    const NSUInteger frameBytes = (NSUInteger)_outChannels * sizeof(float);
    if (!pkt) {

        avcodec_send_packet(_ctx, NULL);
        int produced = [self receiveInto:outData];
        while (_swr) {
            int n = swr_convert(_swr, &_convertBuf, _convertBufCapacity, nullptr, 0);
            if (n <= 0) break;
            [outData appendBytes:_convertBuf length:(NSUInteger)n * frameBytes];
            produced = 1;
            if (n < _convertBufCapacity) break;
        }
        return produced;
    }

    int ret = avcodec_send_packet(_ctx, pkt);
    if (ret == AVERROR(EAGAIN)) {

        int got = [self receiveInto:outData];
        ret = avcodec_send_packet(_ctx, pkt);
        if (ret < 0 && ret != AVERROR(EAGAIN)) return got;
        return [self receiveInto:outData] || got;
    }
    if (ret < 0) return ret;
    return [self receiveInto:outData];
}

- (int)receiveInto:(NSMutableData *)outData {
    int produced = 0;
    const NSUInteger frameBytes = (NSUInteger)_outChannels * sizeof(float);
    while (true) {
        int ret = avcodec_receive_frame(_ctx, _frame);
        if (ret == 0) {
            if (_frame->decode_error_flags) ++_lastErrorFlaggedFrames; else ++_lastCleanFrames;
            if (_md5Valid) [self md5FeedFrame:_frame];

            if (!_swr || _frame->format != _swrInFmt ||
                _frame->sample_rate != _swrInRate ||
                av_channel_layout_compare(&_frame->ch_layout, &_swrInLayout) != 0) {

                while (_swr) {
                    int n = swr_convert(_swr, &_convertBuf, _convertBufCapacity,
                                        nullptr, 0);
                    if (n <= 0) break;
                    [outData appendBytes:_convertBuf length:(NSUInteger)n * frameBytes];
                    produced = 1;
                    if (n < _convertBufCapacity) break;
                }
                if (_swr) swr_free(&_swr);
                _swr = [self makeSwrForFormat:_frame->format rate:_frame->sample_rate
                                       layout:&_frame->ch_layout];
                if (!_swr) {

                    av_frame_unref(_frame);
                    continue;
                }
                _swrInFmt = _frame->format;
                _swrInRate = _frame->sample_rate;
                if (av_channel_layout_copy(&_swrInLayout, &_frame->ch_layout) < 0) {
                    swr_free(&_swr);
                    av_frame_unref(_frame);
                    continue;
                }
                if (spDebug()) {
                    SPLOG(@"[Audio] 轨内格式变化 → 重建重采样器 fmt=%d rate=%d ch=%d",
                          _frame->format, _frame->sample_rate,
                          _frame->ch_layout.nb_channels);
                }
            }

            const uint8_t **in = (const uint8_t **)_frame->extended_data;
            int inCount = _frame->nb_samples;
            while (true) {
                int outFrames = swr_convert(_swr, &_convertBuf, _convertBufCapacity, in, inCount);
                if (outFrames <= 0) break;
                [outData appendBytes:_convertBuf length:(NSUInteger)outFrames * frameBytes];
                produced = 1;
                in = nullptr;
                inCount = 0;
                if (outFrames < _convertBufCapacity) break;
            }
            av_frame_unref(_frame);
        } else {

            if (ret != AVERROR(EAGAIN) && ret != AVERROR_EOF &&
                spDebug()) {
                if (_dbgRecvErrLogs++ < 3) SPLOG(@"[Audio] receive_frame 错误 %d（丢弃）", ret);
            }
            break;
        }
    }
    return produced;
}

- (void)md5FeedFrame:(const AVFrame *)fr {
    const int ch = fr->ch_layout.nb_channels, n = fr->nb_samples;
    int bps = _ctx->bits_per_raw_sample;
    const int fmt = fr->format;
    if (bps <= 0) bps = (fmt == AV_SAMPLE_FMT_S16 || fmt == AV_SAMPLE_FMT_S16P) ? 16 : 0;
    if (ch <= 0 || n <= 0 || bps < 4 || bps > 32 ||
        (fmt != AV_SAMPLE_FMT_S16 && fmt != AV_SAMPLE_FMT_S16P && fmt != AV_SAMPLE_FMT_S32 && fmt != AV_SAMPLE_FMT_S32P)) { _md5Valid = NO; return; }
    const bool s16 = fmt == AV_SAMPLE_FMT_S16 || fmt == AV_SAMPLE_FMT_S16P;
    const bool planar = fmt == AV_SAMPLE_FMT_S16P || fmt == AV_SAMPLE_FMT_S32P;
    if (s16 && bps > 16) { _md5Valid = NO; return; }
    const int bytes = (bps + 7) / 8;
    _md5Buf.resize((size_t)n * (size_t)ch * (size_t)bytes);
    uint8_t *o = _md5Buf.data();
    for (int i = 0; i < n; ++i) {
        for (int c = 0; c < ch; ++c) {
            int32_t v;
            if (s16) { const int16_t *p = (const int16_t *)(planar ? fr->extended_data[c] : fr->extended_data[0]); v = planar ? p[i] : p[(size_t)i * ch + c]; }
            else { const int32_t *p = (const int32_t *)(planar ? fr->extended_data[c] : fr->extended_data[0]); v = planar ? p[i] : p[(size_t)i * ch + c]; v >>= (32 - bps); }
            for (int b = 0; b < bytes; ++b) *o++ = (uint8_t)(v >> (8 * b));
        }
    }
    CC_MD5_Update(&_md5, _md5Buf.data(), (CC_LONG)_md5Buf.size());
    _md5Samples += (uint64_t)n;
}

- (BOOL)nativeMd5Digest:(uint8_t *)out16 samples:(uint64_t *)samples {
    if (!_md5Valid || !out16) return NO;
    CC_MD5_CTX copy = _md5;
    CC_MD5_Final(out16, &copy);
    if (samples) *samples = _md5Samples;
    return YES;
}

- (void)stopNativeMd5 {
    _md5Valid = NO;
    std::vector<uint8_t>().swap(_md5Buf);
}

- (BOOL)nativeMd5Active { return _md5Valid; }

- (void)flush {
    _md5Valid = NO;
    if (_ctx) avcodec_flush_buffers(_ctx);

    while (_swr && _convertBuf) {
        int n = swr_convert(_swr, &_convertBuf, _convertBufCapacity, nullptr, 0);
        if (n < _convertBufCapacity) break;
    }
}

- (void)shutdown {
    if (_swr) { swr_free(&_swr); }
    av_channel_layout_uninit(&_swrInLayout);
    _swrInFmt = AV_SAMPLE_FMT_NONE;
    _swrInRate = 0;
    if (_convertBuf) { av_free(_convertBuf); _convertBuf = nullptr; }
    if (_frame) { av_frame_free(&_frame); }
    if (_ctx) { avcodec_free_context(&_ctx); }
}

@end
#pragma clang diagnostic pop
