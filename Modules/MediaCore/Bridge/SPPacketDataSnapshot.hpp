// Immutable packet payload view. OpenIssued callers may retain this NSData past
// packet unref / cancellation without copying a multi-MB keyframe. Packet payload
// remains read-only; writers must follow AVBufferRef's normal make-writable rule.
#pragma once

#import <Foundation/Foundation.h>
#include <cstdint>
extern "C" {
#include <libavcodec/packet.h>
#include <libavutil/buffer.h>
}

namespace sp {

// The retain function is an injectable allocation boundary for deterministic
// failure tests. Normal callers use the default and need no test/runtime flag.
inline NSData *packetDataSnapshot(
    const AVPacket *packet,
    AVBufferRef *(*retainBuffer)(const AVBufferRef *) = av_buffer_ref) {
    if (!packet || packet->size < 0 || (packet->size > 0 && !packet->data)) return nil;
    if (packet->size == 0) return [NSData data];

    const size_t size = static_cast<size_t>(packet->size);
    // AVPacket data may be a slice inside its backing buffer. Retaining an
    // unrelated buf would not keep a borrowed payload alive, so copy that case.
    const uintptr_t data = reinterpret_cast<uintptr_t>(packet->data);
    const uintptr_t base = packet->buf
        ? reinterpret_cast<uintptr_t>(packet->buf->data) : 0;
    const bool backed = packet->buf && packet->buf->data && data >= base &&
        size <= packet->buf->size && data - base <= packet->buf->size - size;
    if (backed) {
        if (AVBufferRef *reference = retainBuffer(packet->buf)) {
            return [[NSData alloc] initWithBytesNoCopy:packet->data
                length:size deallocator:^(void *, NSUInteger) {
                    // Never free the potentially interior data pointer. Exactly
                    // one retained FFmpeg reference owns the whole backing.
                    AVBufferRef *owned = reference;
                    av_buffer_unref(&owned);
                }];
        }
    }
    // Borrowed packets and ref-allocation failure preserve the former owned-copy
    // behavior. A snapshot is never an unretained view of packet memory.
    return [NSData dataWithBytes:packet->data length:size];
}

} // namespace sp
