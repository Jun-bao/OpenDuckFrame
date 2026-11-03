#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <utility>

namespace sp {

enum class PushResult {
    Pushed,
    Interrupted,
    Closed,
};

template <typename T>
class BoundedQueue {
public:
    explicit BoundedQueue(size_t capacity) : capacity_(capacity == 0 ? 1 : capacity) {}

    [[nodiscard]] bool push(T&& item) {
        std::unique_lock<std::mutex> lock(mu_);
        notFull_.wait(lock, [&] { return closed_ || queue_.size() < capacity_.load(std::memory_order_relaxed); });
        if (closed_) return false;
        queue_.push_back(std::move(item));
        lock.unlock();
        notEmpty_.notify_one();
        return true;
    }

    [[nodiscard]] PushResult pushInterruptibly(T&& item, uint64_t expectedGeneration) {
        std::unique_lock<std::mutex> lock(mu_);
        notFull_.wait(lock, [&] {
            return closed_ || interruptGeneration_.load(std::memory_order_acquire) != expectedGeneration ||
                   queue_.size() < capacity_.load(std::memory_order_relaxed);
        });
        if (closed_) return PushResult::Closed;
        if (interruptGeneration_.load(std::memory_order_relaxed) != expectedGeneration) {
            return PushResult::Interrupted;
        }
        queue_.push_back(std::move(item));
        lock.unlock();
        notEmpty_.notify_one();
        return PushResult::Pushed;
    }

    [[nodiscard]] bool pushForTransition(T&& item) {
        std::unique_lock<std::mutex> lock(mu_);
        if (closed_) return false;
        queue_.push_back(std::move(item));
        lock.unlock();
        notEmpty_.notify_one();
        return true;
    }

    bool pop(T& out) {
        std::unique_lock<std::mutex> lock(mu_);
        notEmpty_.wait(lock, [&] { return closed_ || !queue_.empty(); });
        if (closed_ && queue_.empty()) return false;
        out = std::move(queue_.front());
        queue_.pop_front();
        lock.unlock();
        notFull_.notify_one();
        return true;
    }

    template <typename Rep, typename Period>
    bool tryPop(T& out, const std::chrono::duration<Rep, Period>& timeout) {
        std::unique_lock<std::mutex> lock(mu_);
        if (!notEmpty_.wait_for(lock, timeout, [&] { return closed_ || !queue_.empty(); })) {
            return false;
        }
        if (closed_ && queue_.empty()) return false;
        out = std::move(queue_.front());
        queue_.pop_front();
        lock.unlock();
        notFull_.notify_one();
        return true;
    }

    template <typename F>
    void peekEach(size_t maxItems, F&& f) {
        std::unique_lock<std::mutex> lock(mu_);
        size_t i = 0;
        for (const T& item : queue_) {
            if (i++ >= maxItems || !f(item)) break;
        }
    }

    bool peek(T& out) {
        std::unique_lock<std::mutex> lock(mu_);
        if (queue_.empty()) return false;
        out = queue_.front();
        return true;
    }

    template <typename Pred>
    bool tryPopIf(T& out, Pred&& pred) {
        std::unique_lock<std::mutex> lock(mu_);
        if (queue_.empty()) return false;
        if (!pred(static_cast<const T&>(queue_.front()))) return false;
        out = std::move(queue_.front());
        queue_.pop_front();
        lock.unlock();
        notFull_.notify_one();
        return true;
    }

    template <typename F>
    void drain(F&& dispose) {
        std::deque<T> tmp;
        {
            std::unique_lock<std::mutex> lock(mu_);
            tmp.swap(queue_);
            notFull_.notify_all();
        }
        for (auto& item : tmp) dispose(std::move(item));
    }

    size_t size() const {
        std::lock_guard<std::mutex> lock(mu_);
        return queue_.size();
    }

    size_t capacity() const { return capacity_.load(std::memory_order_relaxed); }

    void setCapacity(size_t capacity) {
        std::unique_lock<std::mutex> lock(mu_);
        capacity_.store(capacity == 0 ? 1 : capacity, std::memory_order_relaxed);
        notFull_.notify_all();
    }

    uint64_t interruptGeneration() const noexcept {
        return interruptGeneration_.load(std::memory_order_acquire);
    }

    void interruptPushes() {
        std::unique_lock<std::mutex> lock(mu_);
        interruptGeneration_.fetch_add(1, std::memory_order_release);
        notFull_.notify_all();
    }

    void close() {
        std::unique_lock<std::mutex> lock(mu_);
        closed_ = true;
        notEmpty_.notify_all();
        notFull_.notify_all();
    }

    void reopen() {
        std::unique_lock<std::mutex> lock(mu_);
        closed_ = false;
    }

private:
    std::atomic<size_t> capacity_;
    std::deque<T> queue_;
    mutable std::mutex mu_;
    std::condition_variable notEmpty_;
    std::condition_variable notFull_;
    std::atomic<uint64_t> interruptGeneration_{0};
    bool closed_ = false;
};

} // namespace sp
