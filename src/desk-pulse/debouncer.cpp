#include "debouncer.hpp"

#include <cstdint>
#include <cstring>
#include <unistd.h>
#include <sys/timerfd.h>

namespace fox_pulse {

Debouncer::Debouncer(std::chrono::milliseconds delay)
    : delay_(delay) {
    fd_ = ::timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
}

Debouncer::~Debouncer() {
    if (fd_ >= 0) ::close(fd_);
}

void Debouncer::trigger() {
    if (fd_ < 0) return;
    itimerspec spec{};
    auto secs  = delay_.count() / 1000;
    auto nsecs = (delay_.count() % 1000) * 1'000'000;
    spec.it_value.tv_sec  = secs;
    spec.it_value.tv_nsec = nsecs;
    // it_interval left zero — single-shot, re-armed every trigger().
    ::timerfd_settime(fd_, 0, &spec, nullptr);
}

void Debouncer::read_and_consume() {
    if (fd_ < 0) return;
    uint64_t v;
    (void)::read(fd_, &v, sizeof(v));
}

}  // namespace fox_pulse
