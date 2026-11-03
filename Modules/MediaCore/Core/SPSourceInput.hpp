// Isolated FFmpeg input over a fault-time read view. All probe, header and seek
// reads share one byte budget and deadline. Never opens a filesystem pathname.
#pragma once

#include "SPReadSourceView.hpp"
#include "SPTrialDecode.hpp"
#include <algorithm>
#include <cerrno>
#include <limits>

namespace sptrial {

class SourceInput {
public:
    SourceInput(sp::ReadSourceView view, InterruptCtx interrupt, int64_t maxBytes)
        : view_(std::move(view)), interrupt_(std::move(interrupt)), maxBytes_(maxBytes) {}
    SourceInput(const SourceInput&) = delete;
    SourceInput& operator=(const SourceInput&) = delete;
    ~SourceInput() { close(); }

    int open(const AVInputFormat* format = nullptr, AVDictionary** options = nullptr) {
        if (format_ || avio_ || !view_ || maxBytes_ <= 0) return AVERROR(EINVAL);
        if (!usable()) return error_;
        auto* buffer = static_cast<uint8_t*>(av_malloc(32 * 1024));
        if (!buffer) return error_ = AVERROR(ENOMEM);
        avio_ = avio_alloc_context(buffer, 32 * 1024, 0, this, readCallback, nullptr, seekCallback);
        if (!avio_) { av_free(buffer); return error_ = AVERROR(ENOMEM); }
        format_ = avformat_alloc_context();
        if (!format_) return error_ = AVERROR(ENOMEM);
        format_->pb = avio_;
        format_->flags |= AVFMT_FLAG_CUSTOM_IO;
        format_->interrupt_callback = {interruptCallback, this};
        // An empty neutral name carries no extension or externally reopenable
        // path. The caller may fix the already-recognized container explicitly.
        const int result = avformat_open_input(&format_, "", format, options);
        if (result < 0) return error_ = result;
        return usable() ? 0 : error_;
    }
    AVFormatContext* get() const { return format_; }
    int64_t bytesRead() const { return bytesRead_; }
    int error() const { return error_; }
    bool current() const { return view_.current && view_.current(); }
    bool usable() {
        if (error_ < 0) return false;
        if (interrupt_.cancelled()) { error_ = AVERROR_EXIT; return false; }
        if (!current()) { error_ = AVERROR(ESTALE); return false; }
        return true;
    }

    // Public for independent boundary tests; normal access is through AVIO.
    int read(uint8_t* destination, int requested) {
        if (requested < 0 || (!destination && requested)) return error_ = AVERROR(EINVAL);
        if (!usable()) return error_;
        if (requested == 0) return 0;
        if (position_ >= view_.size) return AVERROR_EOF;
        const int64_t remaining = maxBytes_ - bytesRead_;
        if (remaining <= 0) return error_ = AVERROR(ENOBUFS);
        const size_t want = static_cast<size_t>(std::min<int64_t>({requested, remaining, view_.size - position_}));
        const int64_t count = view_.read(position_, destination, want);
        if (count < 0) return error_ = static_cast<int>(count);
        if (count > static_cast<int64_t>(want)) return error_ = AVERROR(EIO);
        if (count == 0) return error_ = AVERROR(EIO); // premature read is not final EOF
        bytesRead_ += count;
        position_ += count;
        if (!usable()) return error_;
        return static_cast<int>(count);
    }
    int64_t seek(int64_t offset, int whence) {
        if (!usable()) return error_;
        whence &= ~AVSEEK_FORCE;
        if (whence == AVSEEK_SIZE) return view_.size;
        int64_t base;
        switch (whence) {
            case SEEK_SET: base = 0; break;
            case SEEK_CUR: base = position_; break;
            case SEEK_END: base = view_.size; break;
            default: return AVERROR(EINVAL);
        }
        if ((offset > 0 && base > INT64_MAX - offset) ||
            (offset < 0 && offset < -base)) return AVERROR(EINVAL);
        position_ = base + offset;
        return position_;
    }

private:
    static int readCallback(void* opaque, uint8_t* bytes, int count) {
        return static_cast<SourceInput*>(opaque)->read(bytes, count);
    }
    static int64_t seekCallback(void* opaque, int64_t offset, int whence) {
        return static_cast<SourceInput*>(opaque)->seek(offset, whence);
    }
    static int interruptCallback(void* opaque) { return !static_cast<SourceInput*>(opaque)->usable(); }
    void close() {
        if (format_) avformat_close_input(&format_);
        if (avio_) { av_freep(&avio_->buffer); avio_context_free(&avio_); }
    }
    sp::ReadSourceView view_;
    InterruptCtx interrupt_;
    int64_t maxBytes_ = 0;
    int64_t bytesRead_ = 0;
    int64_t position_ = 0;
    int error_ = 0;
    AVFormatContext* format_ = nullptr;
    AVIOContext* avio_ = nullptr;
};
} // namespace sptrial
