// OpenDuckFrame - executor, budgets, outcome classes and source identity for private trial decodes (pure C++, unit-testable)
//
// Private trial decodes (FLAC configuration candidates, alternate audio tracks, H.264 PPS, AV1 sequence
// header copies, MP4 ctts) used to open their own contexts and read until satisfied, with no interrupt
// callback, no cap on packets from other streams and no wall-clock limit. This header gathers the shared
// bounded / cancellable / stale-result-rejecting parts:
//   - Budget: caps on target-stream packets, any-stream packets, bytes and wall clock, set per entry point;
//   - Outcome: evidence / insufficient / rejected / open failed / read failed / cancelled / budget exhausted;
//   - SourceIdentity: dev/ino/size/mtime plus a digest of the first 4 KiB, used only to reject stale results;
//   - Executor: lazily started single worker with a bounded queue; every job gets a cancel token, cancelAll
//     covers queued and in-flight jobs, and results are posted back by the job after re-checking the token
//     and the session / seek / track generations. The worker is detached and shares its state with the
//     executor; destruction never joins it, so a job must own all of the state it uses.
// FFmpeg's interrupt callback is cooperative: it breaks avio retry loops but cannot interrupt a blocked
// read(2) or a single decode call. A cancelled job drops its result and releases its own decoder and buffers.
#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#include <sys/stat.h>

namespace sptrial {

struct Budget {
    int maxTargetPkts = 16;
    int maxAnyPkts = 2048;
    int64_t maxBytes = 64ll << 20;
    int64_t maxWallUs = 3000000;
};

enum class Outcome : uint8_t {
    Evidence = 0,
    Insufficient,
    Rejected,
    OpenFailed,
    ReadFailed,
    Cancelled,
    BudgetExhausted,
};

inline const char* outcomeName(Outcome o) {
    switch (o) {
        case Outcome::Evidence: return "evidence";
        case Outcome::Insufficient: return "insufficient";
        case Outcome::Rejected: return "rejected";
        case Outcome::OpenFailed: return "open-failed";
        case Outcome::ReadFailed: return "read-failed";
        case Outcome::Cancelled: return "cancelled";
        case Outcome::BudgetExhausted: return "budget-exhausted";
    }
    return "?";
}

struct Stats {
    int64_t samples = 0;
    int64_t cleanSamples = 0;
    int frames = 0;
    int flaggedFrames = 0;
    int sendErrors = 0;        // avcodec_send_packet < 0
    int targetPkts = 0;
    int anyPkts = 0;
    int64_t bytes = 0;
    int64_t wallUs = 0;
    Outcome outcome = Outcome::Insufficient;
};

inline bool withinBudget(const Budget& b, Stats& s, int64_t startUs, int64_t nowUs, const std::function<bool()>* abort) {
    if (abort && *abort && (*abort)()) { s.outcome = Outcome::Cancelled; return false; }
    if (s.targetPkts >= b.maxTargetPkts) return false;
    if (s.anyPkts >= b.maxAnyPkts || s.bytes >= b.maxBytes || nowUs - startUs >= b.maxWallUs) { s.outcome = Outcome::BudgetExhausted; return false; }
    return true;
}

inline Outcome classify(const Stats& s, int64_t minClean) {
    if (s.outcome == Outcome::Cancelled || s.outcome == Outcome::BudgetExhausted || s.outcome == Outcome::OpenFailed ||
        s.outcome == Outcome::ReadFailed) return s.outcome;
    if (s.sendErrors > 0 || s.flaggedFrames > 0) return Outcome::Rejected;
    const int64_t clean = s.cleanSamples > 0 ? s.cleanSamples : (s.frames - s.flaggedFrames);
    return clean >= minClean && clean > 0 ? Outcome::Evidence : Outcome::Insufficient;
}

inline int64_t monotonicNowUs() {
    return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

struct SourceIdentity {
    std::string path;
    uint64_t dev = 0, ino = 0;
    int64_t size = -1;
    int64_t mtimeNs = 0;
    uint64_t headHash = 0;
    bool valid = false;
};

inline uint64_t fnv1a(const uint8_t* d, size_t n, uint64_t h = 14695981039346656037ull) {
    for (size_t i = 0; i < n; ++i) h = (h ^ d[i]) * 1099511628211ull;
    return h;
}

inline bool captureSource(const std::string& path, SourceIdentity& out) {
    out = SourceIdentity{};
    out.path = path;
    struct stat sb {};
    if (::stat(path.c_str(), &sb) != 0 || !S_ISREG(sb.st_mode)) return false;
    out.dev = (uint64_t)sb.st_dev; out.ino = (uint64_t)sb.st_ino; out.size = (int64_t)sb.st_size;
    out.mtimeNs = (int64_t)sb.st_mtimespec.tv_sec * 1000000000ll + sb.st_mtimespec.tv_nsec;
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    uint8_t buf[4096];
    const size_t n = std::fread(buf, 1, sizeof buf, f);
    std::fclose(f);
    out.headHash = fnv1a(buf, n);
    out.valid = true;
    return true;
}

inline bool sourceUnchanged(const SourceIdentity& id) {
    if (!id.valid) return false;
    SourceIdentity now;
    if (!captureSource(id.path, now)) return false;
    return now.dev == id.dev && now.ino == id.ino && now.size == id.size && now.mtimeNs == id.mtimeNs && now.headHash == id.headHash;
}

// ───────────────────────── Executor ─────────────────────────
// The worker is detached and shares state with the executor through a shared_ptr. Destruction cancels all jobs and
// sets quit but never joins: an in-flight job may be blocked in a read(2) that cannot be interrupted (the default
// FFmpeg file protocol on a spinning-up disk or a dropped network share), and joining would stall the thread that
// destroys the executor. A job must therefore own all of its state (captured values, shared_ptr or weak references)
// and must not reference members of the executor owner or the caller's stack. After its in-flight job the worker
// sees quit, exits and releases the shared state.
class Executor {
public:
    using Token = std::shared_ptr<std::atomic<bool>>;
    using Work = std::function<void(const std::atomic<bool>& cancelled)>;

    explicit Executor(size_t maxQueued = 4) : st_(std::make_shared<State>()) { st_->maxQueued = maxQueued; }
    Executor(const Executor&) = delete;
    Executor& operator=(const Executor&) = delete;
    ~Executor() {
        cancelAll();
        {
            std::lock_guard<std::mutex> lk(st_->mtx);
            st_->quit = true;
        }
        st_->cv.notify_all();

    }

    Token submit(Work work) {
        std::lock_guard<std::mutex> lk(st_->mtx);
        if (st_->quit || st_->queue.size() + (st_->running ? 1 : 0) >= st_->maxQueued) return nullptr;
        auto token = std::make_shared<std::atomic<bool>>(false);
        if (!st_->workerStarted) {
            try {
                std::thread([st = st_] { loop(st); }).detach();
            } catch (...) {
                return nullptr;
            }
            st_->workerStarted = true;
        }
        st_->queue.push_back(Job{token, std::move(work)});
        st_->cv.notify_one();
        return token;
    }

    void cancelAll() {
        std::deque<Job> dropped;
        {
            std::lock_guard<std::mutex> lk(st_->mtx);
            dropped.swap(st_->queue);
            if (st_->running) st_->running->store(true, std::memory_order_release);
        }
        for (auto& j : dropped) j.token->store(true, std::memory_order_release);
    }

    size_t pending() const {
        std::lock_guard<std::mutex> lk(st_->mtx);
        return st_->queue.size() + (st_->running ? 1 : 0);
    }

    void drain() {
        std::unique_lock<std::mutex> lk(st_->mtx);
        st_->idle.wait(lk, [this] { return st_->queue.empty() && !st_->running; });
    }

    std::weak_ptr<const void> workerLifetime() const { return std::weak_ptr<const void>(st_); }

private:
    struct Job {
        Token token;
        Work work;
    };
    struct State {
        mutable std::mutex mtx;
        std::condition_variable cv, idle;
        std::deque<Job> queue;
        Token running;
        size_t maxQueued = 4;
        bool quit = false;
        bool workerStarted = false;
    };
    static void loop(std::shared_ptr<State> st) {
        for (;;) {
            Job job;
            {
                std::unique_lock<std::mutex> lk(st->mtx);
                st->cv.wait(lk, [&] { return st->quit || !st->queue.empty(); });
                if (st->queue.empty()) return;
                job = std::move(st->queue.front());
                st->queue.pop_front();
                st->running = job.token;
            }
            if (!job.token->load(std::memory_order_acquire)) job.work(*job.token);
            job.work = nullptr;
            {
                std::lock_guard<std::mutex> lk(st->mtx);
                st->running.reset();
            }
            st->idle.notify_all();
        }
    }
    std::shared_ptr<State> st_;
};

} // namespace sptrial
