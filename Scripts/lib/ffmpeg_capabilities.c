/* Build-time checks against the linked libraries, never the reference source's
 * generated config. Keep runtime registration out of the player's open path. */
#include <stdio.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavcodec/codec_desc.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>

static int failures;

static void json_string(const char *s) {
    putchar('"');
    for (const unsigned char *p = (const unsigned char *)s; *p; ++p) {
        if (*p == '"' || *p == '\\') { putchar('\\'); putchar(*p); }
        else if (*p < 32) printf("\\u%04x", *p);
        else putchar(*p);
    }
    putchar('"');
}

static void require_decoder(const char *descriptor_name) {
    const AVCodecDescriptor *desc = avcodec_descriptor_get_by_name(descriptor_name);
    const AVCodec *codec = desc ? avcodec_find_decoder(desc->id) : NULL;
    if (!codec || !av_codec_is_decoder(codec)) {
        fprintf(stderr, "Missing required decoder for codec ID: %s\n", descriptor_name);
        ++failures;
    }
}

static void require_parser(enum AVCodecID id, const char *name) {
    void *opaque = NULL;
    const AVCodecParser *parser;
    while ((parser = av_parser_iterate(&opaque))) {
        for (unsigned i = 0; i < sizeof(parser->codec_ids) / sizeof(parser->codec_ids[0]); ++i)
            if (parser->codec_ids[i] == (int)id) return;
    }
    fprintf(stderr, "Missing required parser for codec ID: %s\n", name);
    ++failures;
}

static void require_unique_decoder(enum AVCodecID id, const char *name) {
    const AVCodec *selected = avcodec_find_decoder(id), *codec;
    void *opaque = NULL;
    int count = 0;
    while ((codec = av_codec_iterate(&opaque)))
        if (av_codec_is_decoder(codec) && codec->id == id) ++count;
    if (!selected || strcmp(selected->name, name) || count != 1) {
        fprintf(stderr, "Codec ID %d must uniquely resolve to %s; count=%d selected=%s\n",
                id, name, count, selected ? selected->name : "missing");
        ++failures;
    }
}

int main(int argc, char **argv) {
    if (argc != 1 && (argc != 3 || strcmp(argv[1], "--require-decoder") != 0)) {
        fprintf(stderr, "usage: %s [--require-decoder codec-descriptor-name]\n", argv[0]);
        return 2;
    }
    const char *decoders[] = {
        "flv1", "h264", "hevc", "av1", "mpeg2video", "dvvideo", "vvc",
        "cavs", "dnxhd", "jpeg2000", "ffv1", "speex", "wmalossless",
        "aac", "mp3", "pcm_s16le"
    };
    for (unsigned i = 0; i < sizeof(decoders) / sizeof(decoders[0]); ++i)
        require_decoder(decoders[i]);
    if (argc == 3) require_decoder(argv[2]);
    require_unique_decoder(AV_CODEC_ID_SPEEX, "libspeex");
    const AVCodec *flv = avcodec_find_decoder(AV_CODEC_ID_FLV1);
    if (flv && strcmp(flv->name, "flv") != 0) {
        fprintf(stderr, "FLV1 must resolve to native flv decoder, got %s\n", flv->name);
        ++failures;
    }
    const char *demuxers[] = {
        "mov", "matroska", "mpegts", "flv", "mxf", "av1", "obu", "dv",
        "vvc", "cavsvideo", "dnxhd"
    };
    for (unsigned i = 0; i < sizeof(demuxers) / sizeof(demuxers[0]); ++i) {
        if (!av_find_input_format(demuxers[i])) {
            fprintf(stderr, "Missing required demuxer: %s\n", demuxers[i]);
            ++failures;
        }
    }
    require_parser(AV_CODEC_ID_AV1, "av1");
    require_parser(AV_CODEC_ID_VVC, "vvc");
    require_parser(AV_CODEC_ID_CAVS, "cavs");
    require_parser(AV_CODEC_ID_DNXHD, "dnxhd");
    require_parser(AV_CODEC_ID_JPEG2000, "jpeg2000");
    require_parser(AV_CODEC_ID_FFV1, "ffv1");
    if (!av_bsf_get_by_name("av1_frame_merge")) {
        fprintf(stderr, "Missing required AV1 demux bitstream filter: av1_frame_merge\n");
        ++failures;
    }
    const char *codec_license = avcodec_license(), *format_license = avformat_license();
    if (strcmp(codec_license, "LGPL version 2.1 or later") != 0 ||
        strcmp(format_license, "LGPL version 2.1 or later") != 0) {
        fprintf(stderr, "Unexpected FFmpeg license: codec=%s format=%s\n", codec_license, format_license);
        ++failures;
    }
    /* ffmpeg_version = FFMPEG_VERSION compiled into libavutil; the build script
     * requires it to equal the locked release. */
    printf("{\"ffmpeg_version\":"); json_string(av_version_info());
    printf(",\"avcodec_version\":%u,\"avformat_version\":%u,\"avcodec_license\":",
           avcodec_version(), avformat_version());
    json_string(codec_license);
    printf(",\"avformat_license\":"); json_string(format_license);
    printf(",\"avcodec_configuration\":"); json_string(avcodec_configuration());
    printf(",\"avformat_configuration\":"); json_string(avformat_configuration());
    printf(",\"demuxers\":[");
    void *opaque = NULL;
    const AVInputFormat *fmt;
    int comma = 0;
    while ((fmt = av_demuxer_iterate(&opaque))) {
        if (comma++) putchar(',');
        json_string(fmt->name);
    }
    printf("],\"decoders\":[");
    opaque = NULL; comma = 0;
    const AVCodec *codec;
    while ((codec = av_codec_iterate(&opaque))) {
        if (!av_codec_is_decoder(codec)) continue;
        if (comma++) putchar(',');
        printf("{\"name\":"); json_string(codec->name);
        printf(",\"id\":%d,\"type\":%d}", codec->id, codec->type);
    }
    printf("],\"failures\":%d}\n", failures);
    return failures ? 1 : 0;
}
