// A fault-time view of an already-open source. Metadata and patches are fixed;
// the underlying file is not frozen. Call current() before accepting a result.
#pragma once

#include <cstdint>
#include <functional>
#include <cstddef>

namespace sp {
struct ReadSourceView {
    using Reader = std::function<int64_t(int64_t, uint8_t*, size_t)>;
    Reader read;
    std::function<bool()> current;
    int64_t physicalSize = 0;
    int64_t size = 0;
    explicit operator bool() const { return read && current && size > 0; }
};
} // namespace sp
