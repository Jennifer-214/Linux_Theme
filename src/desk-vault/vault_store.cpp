#include "vault_store.hpp"

#include <cstring>
#include <fcntl.h>
#include <openssl/hmac.h>
#include <sys/mman.h>
#include <sys/random.h>
#include <unistd.h>

namespace fox_vault {

namespace {

size_t page_size() {
    long p = ::sysconf(_SC_PAGESIZE);
    return p > 0 ? static_cast<size_t>(p) : 4096;
}

size_t round_to_page(size_t n) {
    size_t ps = page_size();
    if (n == 0) return ps;
    return ((n + ps - 1) / ps) * ps;
}

// Derive a per-secret XOR keystream of `len` bytes from `key` + `salt`
// using HMAC-SHA256 in counter mode. Each secret has its own keystream,
// so XOR-of-two-ciphertexts no longer reveals plaintext_A XOR plaintext_B.
void derive_keystream(uint8_t* out, size_t len,
                      const uint8_t* key, size_t key_len,
                      const uint8_t* salt, size_t salt_len) {
    uint8_t block_input[64];
    uint8_t block_output[32];
    uint32_t counter = 0;
    size_t produced = 0;
    while (produced < len) {
        if (salt_len > sizeof(block_input) - 4) salt_len = sizeof(block_input) - 4;
        std::memcpy(block_input, salt, salt_len);
        block_input[salt_len + 0] = (counter >> 24) & 0xff;
        block_input[salt_len + 1] = (counter >> 16) & 0xff;
        block_input[salt_len + 2] = (counter >> 8)  & 0xff;
        block_input[salt_len + 3] = (counter)       & 0xff;
        unsigned int outlen = 0;
        ::HMAC(EVP_sha256(), key, static_cast<int>(key_len),
               block_input, salt_len + 4, block_output, &outlen);
        size_t take = (len - produced > outlen) ? outlen : (len - produced);
        std::memcpy(out + produced, block_output, take);
        produced += take;
        ++counter;
    }
}

void xor_with_keystream(uint8_t* buf, size_t len,
                        const uint8_t* key, size_t key_len,
                        const uint8_t* salt, size_t salt_len) {
    if (len == 0 || key_len == 0) return;
    std::vector<uint8_t> ks(len);
    derive_keystream(ks.data(), len, key, key_len, salt, salt_len);
    for (size_t i = 0; i < len; ++i) buf[i] ^= ks[i];
    // Wipe the local copy of the keystream.
    volatile uint8_t* vp = ks.data();
    for (size_t i = 0; i < len; ++i) vp[i] = 0;
}

// Best-effort explicit zeroing that survives optimizer DCE. Use glibc's
// explicit_bzero when available; fall back to a volatile loop on libcs
// that lack it.
#if defined(__GLIBC__)
extern "C" void explicit_bzero(void* s, size_t n);
#else
static void explicit_bzero(void* s, size_t n) {
    volatile uint8_t* p = static_cast<volatile uint8_t*>(s);
    while (n--) *p++ = 0;
}
#endif

}  // namespace

SecureBuffer::SecureBuffer(const uint8_t* data, size_t len,
                           const uint8_t* key, size_t key_len) {
    // Each SecureBuffer gets a unique random salt so two secrets in
    // the same Vault don't share a keystream.
    ssize_t r = ::getrandom(salt_, sizeof(salt_), 0);
    if (r != static_cast<ssize_t>(sizeof(salt_))) {
        // Salt entropy failure is fatal: a constant salt collapses
        // back to the OTP-reuse weakness we're trying to avoid.
        return;
    }
    map_size_ = round_to_page(len > 0 ? len : 1);
    page_ = ::mmap(nullptr, map_size_, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (page_ == MAP_FAILED) {
        page_ = nullptr;
        map_size_ = 0;
        return;
    }
    // mlock failure is non-fatal (may exceed RLIMIT_MEMLOCK on default
    // installs); the secret is still XOR-obfuscated, just not swap-proof.
    ::mlock(page_, map_size_);
    auto* p = static_cast<uint8_t*>(page_);
    std::memcpy(p, data, len);
    xor_with_keystream(p, len, key, key_len, salt_, sizeof(salt_));
    len_ = len;
}

SecureBuffer::SecureBuffer(SecureBuffer&& other) noexcept
    : page_(other.page_), map_size_(other.map_size_), len_(other.len_) {
    std::memcpy(salt_, other.salt_, sizeof(salt_));
    other.page_ = nullptr;
    other.map_size_ = 0;
    other.len_ = 0;
    explicit_bzero(other.salt_, sizeof(other.salt_));
}

SecureBuffer& SecureBuffer::operator=(SecureBuffer&& other) noexcept {
    if (this != &other) {
        reset();
        page_ = other.page_;
        map_size_ = other.map_size_;
        len_ = other.len_;
        std::memcpy(salt_, other.salt_, sizeof(salt_));
        other.page_ = nullptr;
        other.map_size_ = 0;
        other.len_ = 0;
        explicit_bzero(other.salt_, sizeof(other.salt_));
    }
    return *this;
}

SecureBuffer::~SecureBuffer() { reset(); }

void SecureBuffer::reset() noexcept {
    if (page_) {
        explicit_bzero(page_, map_size_);
        ::munlock(page_, map_size_);
        ::munmap(page_, map_size_);
    }
    explicit_bzero(salt_, sizeof(salt_));
    page_ = nullptr;
    map_size_ = 0;
    len_ = 0;
}

std::string SecureBuffer::reveal(const uint8_t* key, size_t key_len) const {
    if (!page_ || len_ == 0) return {};
    std::string out;
    out.resize(len_);
    auto* dst = reinterpret_cast<uint8_t*>(&out[0]);
    std::memcpy(dst, page_, len_);
    xor_with_keystream(dst, len_, key, key_len, salt_, sizeof(salt_));
    return out;
}

Vault::Vault() {
    // getrandom is the standard kernel entropy source on Linux 3.17+.
    ssize_t r = ::getrandom(session_key_, sizeof(session_key_), 0);
    if (r == static_cast<ssize_t>(sizeof(session_key_))) {
        entropy_ok_ = true;
        return;
    }
    // Fall back to /dev/urandom.
    int fd = ::open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        ssize_t got = ::read(fd, session_key_, sizeof(session_key_));
        ::close(fd);
        if (got == static_cast<ssize_t>(sizeof(session_key_))) {
            entropy_ok_ = true;
            return;
        }
    }
    // Both failed. Leave session_key_ zeroed and entropy_ok_ false so
    // the caller can refuse to operate — a zero session key would
    // make every secret stored as plaintext bytes in the mmap, which
    // is strictly worse than refusing to run.
    explicit_bzero(session_key_, sizeof(session_key_));
    entropy_ok_ = false;
}

Vault::~Vault() {
    clear();
    explicit_bzero(session_key_, sizeof(session_key_));
}

bool Vault::set(const std::string& name, const uint8_t* data, size_t len) {
    SecureBuffer buf(data, len, session_key_, sizeof(session_key_));
    if (buf.size() != len) return false;
    store_[name] = std::move(buf);
    return true;
}

bool Vault::get(const std::string& name, std::string& out) const {
    auto it = store_.find(name);
    if (it == store_.end()) return false;
    out = it->second.reveal(session_key_, sizeof(session_key_));
    return true;
}

bool Vault::del(const std::string& name) {
    return store_.erase(name) > 0;
}

void Vault::clear() {
    store_.clear();
}

std::vector<std::string> Vault::list() const {
    std::vector<std::string> out;
    out.reserve(store_.size());
    for (auto& kv : store_) out.push_back(kv.first);
    return out;
}

}  // namespace fox_vault
