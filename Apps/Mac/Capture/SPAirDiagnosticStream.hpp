#pragma once

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <mach/mach_time.h>
#include <cerrno>
#include <array>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <time.h>
#include <unistd.h>
#include <unordered_map>
#include <vector>

namespace spAirDiagnostic {

inline NSData *encodeJSON(id document, NSError **error) {
    @try { return [NSJSONSerialization dataWithJSONObject:document options:0 error:error]; }
    @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:@"OpenDuckFrame.DiagnosticJSON" code:1
            userInfo:@{NSLocalizedDescriptionKey:exception.reason ?: @"JSON encoding failed",
                @"exception":exception.name}];
        return nil;
    }
}

inline bool setError(NSError **error, NSString *operation, int code) {
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"%@: %s", operation, std::strerror(code)]}];
    return false;
}

struct WriteBudget {
    std::atomic<bool> cancelled{false};
    uint64_t deadlineHostTicks;
    explicit WriteBudget(uint64_t deadline) : deadlineHostTicks(deadline) {}
};

inline thread_local WriteBudget *activeWriteBudget = nullptr;

class ScopedWriteBudget final {
    WriteBudget *previous_;
public:
    explicit ScopedWriteBudget(WriteBudget *budget) : previous_(activeWriteBudget) { activeWriteBudget = budget; }
    ~ScopedWriteBudget() { activeWriteBudget = previous_; }
    ScopedWriteBudget(const ScopedWriteBudget &) = delete;
    ScopedWriteBudget &operator=(const ScopedWriteBudget &) = delete;
};

inline bool checkWriteBudget(WriteBudget *budget, NSError **error) {
    if (!budget) return true;
    if (budget->cancelled.load(std::memory_order_acquire)) return setError(error, @"diagnostic export cancelled", ECANCELED);
    if (mach_absolute_time() >= budget->deadlineHostTicks) return setError(error, @"diagnostic export deadline", ETIMEDOUT);
    return true;
}

inline bool writeAll(int descriptor, const void *bytes, size_t length, NSError **error, WriteBudget *budget = activeWriteBudget) {
    const auto *cursor = static_cast<const uint8_t *>(bytes);
    while (length) {
        if (!checkWriteBudget(budget, error)) return false;
        const ssize_t written = ::write(descriptor, cursor, length);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return setError(error, @"diagnostic write", written < 0 ? errno : EIO);
        cursor += written;
        length -= size_t(written);
    }
    return true;
}

inline bool appendProgress(NSString *path, NSString *stage, NSDictionary *fields, NSError **error, WriteBudget *budget = activeWriteBudget) {
    if (!checkWriteBudget(budget, error)) return false;
    const uint64_t before = mach_absolute_time();
    timespec utc{};
    if (clock_gettime(CLOCK_REALTIME, &utc)) return setError(error, @"read UTC clock", errno);
    const uint64_t after = mach_absolute_time();
    NSMutableDictionary *record = fields ? [fields mutableCopy] : [NSMutableDictionary dictionary];
    record[@"schema"] = @"odf-air-export-progress-v1";
    record[@"stage"] = stage;
    record[@"pid"] = @(getpid());
    record[@"machTicks"] = @(after);
    record[@"machBeforeTicks"] = @(before);
    record[@"machAfterTicks"] = @(after);
    record[@"utcEpochNs"] = @(uint64_t(utc.tv_sec) * 1000000000ULL + uint64_t(utc.tv_nsec));
    NSData *data = encodeJSON(record, error);
    if (!data) return false;
    const int descriptor = ::open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (descriptor < 0) return setError(error, @"open durable diagnostic progress", errno);
    const bool written = writeAll(descriptor, data.bytes, data.length, error, budget)
        && writeAll(descriptor, "\n", 1, error, budget);
    if (written && !checkWriteBudget(budget, error)) { ::close(descriptor); return false; }
    const bool synced = written && ::fsync(descriptor) == 0;
    const int syncError = errno;
    ::close(descriptor);
    if (written && !synced) return setError(error, @"sync durable diagnostic progress", syncError);
    return written && synced;
}

inline bool writeJSONFile(NSString *path, NSDictionary *document, NSError **error, WriteBudget *budget = activeWriteBudget) {
    if (!checkWriteBudget(budget, error)) return false;
    NSData *data = encodeJSON(document, error);
    if (!data) return false;
    const int descriptor = ::open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (descriptor < 0) return setError(error, @"open diagnostic manifest", errno);
    const bool written = writeAll(descriptor, data.bytes, data.length, error, budget)
        && writeAll(descriptor, "\n", 1, error, budget);
    if (written && !checkWriteBudget(budget, error)) { ::close(descriptor); return false; }
    const bool synced = written && ::fsync(descriptor) == 0;
    const int syncError = errno;
    ::close(descriptor);
    if (written && !synced) return setError(error, @"sync diagnostic manifest", syncError);
    return written && synced;
}

class NDJSONWriter final {
    int descriptor_ = -1;
    __strong NSString *relativePath_;
    __strong NSString *name_;
    __strong NSString *progressPath_;
    CC_SHA256_CTX digest_{};
    uint64_t rows_ = 0;
    uint64_t bytes_ = 0;
    bool failed_ = false;
    WriteBudget *budget_ = nullptr;

public:
    NDJSONWriter(NSString *directory, NSString *name, NSString *progressPath, NSError **error, WriteBudget *budget = activeWriteBudget)
        : relativePath_([@"traces" stringByAppendingPathComponent:[name stringByAppendingString:@".ndjson"]]),
          name_(name), progressPath_(progressPath), budget_(budget) {
        if (!checkWriteBudget(budget_, error)) { failed_ = true; return; }
        NSString *path = [directory stringByAppendingPathComponent:relativePath_];
        if (![[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                withIntermediateDirectories:YES attributes:nil error:error]) {
            failed_ = true;
            return;
        }
        descriptor_ = ::open(path.fileSystemRepresentation, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (descriptor_ < 0) { failed_ = true; setError(error, @"open trace output", errno); return; }
        CC_SHA256_Init(&digest_);
        if (progressPath_ && !appendProgress(progressPath_, @"trace-export-begin", @{@"name":name_, @"path":relativePath_}, error, budget_))
            failed_ = true;
    }

    NDJSONWriter(const NDJSONWriter &) = delete;
    NDJSONWriter &operator=(const NDJSONWriter &) = delete;
    ~NDJSONWriter() { if (descriptor_ >= 0) ::close(descriptor_); }

    bool valid() const { return descriptor_ >= 0 && !failed_; }
    uint64_t rows() const { return rows_; }
    uint64_t bytes() const { return bytes_; }

    NSData *readData(uint64_t offset, uint64_t length, NSError **error) {
        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)length];
        size_t copied = 0;
        while (copied < length) {
            if (!checkWriteBudget(budget_, error)) return nil;
            const ssize_t count = ::pread(descriptor_, static_cast<uint8_t *>(data.mutableBytes) + copied,
                size_t(length) - copied, off_t(offset + copied));
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) { setError(error, @"read written trace version", count < 0 ? errno : EIO); return nil; }
            copied += size_t(count);
        }
        return data;
    }

    bool appendData(NSData *data, NSError **error) {
        if (!valid()) return setError(error, @"append closed or failed trace", EIO);
        if (!writeAll(descriptor_, data.bytes, data.length, error, budget_) || !writeAll(descriptor_, "\n", 1, error, budget_)) {
            failed_ = true;
            return false;
        }
        CC_SHA256_Update(&digest_, data.bytes, CC_LONG(data.length));
        CC_SHA256_Update(&digest_, "\n", 1);
        ++rows_;
        bytes_ += data.length + 1;
        return true;
    }

    bool append(NSDictionary *record, NSError **error) {
        if (!checkWriteBudget(budget_, error)) { failed_ = true; return false; }
        NSData *data = encodeJSON(record, error);
        if (!data) { failed_ = true; return false; }
        return appendData(data, error);
    }

    NSDictionary *finish(NSError **error) {
        if (!valid()) { setError(error, @"finish failed trace", EIO); return nil; }
        if (!checkWriteBudget(budget_, error)) { failed_ = true; return nil; }
        if (::fsync(descriptor_)) { failed_ = true; setError(error, @"sync trace output", errno); return nil; }
        if (!checkWriteBudget(budget_, error)) { failed_ = true; return nil; }
        if (::close(descriptor_)) { descriptor_ = -1; failed_ = true; setError(error, @"close trace output", errno); return nil; }
        descriptor_ = -1;
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256_Final(digest, &digest_);
        NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
        for (unsigned char value : digest) [hex appendFormat:@"%02x", value];
        NSDictionary *result = @{@"name":name_, @"path":relativePath_, @"rows":@(rows_),
            @"bytes":@(bytes_), @"sha256":hex, @"format":@"ndjson"};
        if (progressPath_ && !appendProgress(progressPath_, @"trace-export-end", result, error, budget_)) {
            failed_ = true;
            return nil;
        }
        return result;
    }
};

inline NSDictionary *finishSingleView(NDJSONWriter &writer, NSArray *target, NSError **error) {
    NSDictionary *base = writer.finish(error);
    if (!base) return nil;
    NSMutableDictionary *result = [base mutableCopy];
    result[@"views"] = @[@{@"name":@"final", @"target":target,
        @"indexRanges":writer.rows() ? @[@[@0, @(writer.rows())]] : @[], @"rows":@(writer.rows())}];
    return result;
}

inline NSDictionary *writeArray(NSString *directory, NSString *name, NSString *progressPath,
        NSArray *records, NSArray *target, NSError **error) {
    NDJSONWriter writer(directory, name, progressPath, error);
    if (!writer.valid()) return nil;
    for (NSDictionary *record in records) {
        @autoreleasepool { if (!writer.append(record, error)) return nil; }
    }
    return finishSingleView(writer, target, error);
}

class SharedTraceWriter final {
    struct Version { std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> digest; uint64_t index, offset, length; };
    NDJSONWriter writer_;
    std::unordered_map<uint64_t, std::vector<Version>> versions_;
    __strong NSMutableArray<NSMutableDictionary *> *views_ = [NSMutableArray array];

public:
    SharedTraceWriter(NSString *directory, NSString *name, NSString *progressPath, NSError **error)
        : writer_(directory, name, progressPath, error) {}

    bool valid() const { return writer_.valid(); }

    NSUInteger addView(NSString *name, NSArray<NSString *> *target) {
        [views_ addObject:[@{@"name":name, @"target":[target copy],
            @"indexRanges":[NSMutableArray array], @"rows":@0} mutableCopy]];
        return views_.count - 1;
    }

    bool append(NSUInteger view, uint64_t identity, NSDictionary *record, NSError **error) {
        if (view >= views_.count) return setError(error, @"unknown trace view", EINVAL);
        NSData *data = encodeJSON(record, error);
        if (!data) return false;
        std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> fingerprint;
        CC_SHA256(data.bytes, CC_LONG(data.length), fingerprint.data());
        auto &versions = versions_[identity];
        uint64_t index = writer_.rows();
        bool found = false;
        for (const auto &version : versions) {
            bool equal = version.length == data.length && version.digest == fingerprint;
            if (!equal) {
                NSData *written = writer_.readData(version.offset, version.length, error);
                if (!written) return false;
                id previous = [NSJSONSerialization JSONObjectWithData:written options:0 error:error];
                if (!previous) return false;
                equal = [previous isEqual:record];
            }
            if (equal) { index = version.index; found = true; break; }
        }
        if (!found) {
            const uint64_t offset = writer_.bytes();
            if (!writer_.appendData(data, error)) return false;
            versions.push_back({fingerprint, index, offset, uint64_t(data.length)});
        }
        NSMutableDictionary *entry = views_[view];
        NSMutableArray<NSMutableArray<NSNumber *> *> *ranges = entry[@"indexRanges"];
        NSMutableArray<NSNumber *> *last = ranges.lastObject;
        if (last && last[1].unsignedLongLongValue == index) last[1] = @(index + 1);
        else [ranges addObject:[@[@(index), @(index + 1)] mutableCopy]];
        entry[@"rows"] = @([entry[@"rows"] unsignedLongLongValue] + 1);
        return true;
    }

    NSDictionary *finish(NSError **error) {
        NSDictionary *base = writer_.finish(error);
        if (!base) return nil;
        NSMutableDictionary *result = [base mutableCopy];
        result[@"views"] = views_;
        result[@"scope"] = @"Rows are actual immutable checkpoint values. Identical values of one record identity share a line. View ranges preserve each checkpoint's original order and may be non-monotone.";
        return result;
    }
};

} // namespace spAirDiagnostic
