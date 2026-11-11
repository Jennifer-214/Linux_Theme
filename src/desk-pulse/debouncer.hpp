#ifndef FOX_PULSE_DEBOUNCER_HPP
#define FOX_PULSE_DEBOUNCER_HPP

#include <chrono>

namespace fox_pulse {

// timerfd-backed single-shot debouncer. trigger() arms (or re-arms) the
// timer to fire `delay` from now; whoever epoll's on fd() sees POLLIN
// after the quiet period. read_and_consume() drains the expiration count
// so the fd is ready to be re-armed.
class Debouncer {
public:
    explicit Debouncer(std::chrono::milliseconds delay);
    Debouncer(const Debouncer&) = delete;
    Debouncer& operator=(const Debouncer&) = delete;
    ~Debouncer();

    int  fd() const { return fd_; }
    void trigger();
    void read_and_consume();

private:
    int  fd_ = -1;
    std::chrono::milliseconds delay_;
};

}  // namespace fox_pulse

#endif
