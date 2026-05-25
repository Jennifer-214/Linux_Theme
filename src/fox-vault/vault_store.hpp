#ifndef FOX_VAULT_STORE_HPP
#define FOX_VAULT_STORE_HPP

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace fox_vault {

// SecureBuffer: a value held on an mlock()'d, anonymous, MAP_PRIVATE
// region. Contents are XOR-obfuscated against a per-secret keystream
// derived from the process's session key + a per-secret random salt,
// so two secrets stored under the same Vault don't share a keystream
// (no XOR-of-two-ciphertexts plaintext-recovery weakness). Destructor
// explicit_bzero's the buffer before munmap'ing.
class SecureBuffer {
public:
    SecureBuffer() = default;
    SecureBuffer(const uint8_t* data, size_t len, const uint8_t* key, size_t key_len);
    SecureBuffer(SecureBuffer&& other) noexcept;
    SecureBuffer& operator=(SecureBuffer&& other) noexcept;
    SecureBuffer(const SecureBuffer&)            = delete;
    SecureBuffer& operator=(const SecureBuffer&) = delete;
    ~SecureBuffer();

    // Returns a plaintext copy. Caller is responsible for wiping it.
    std::string reveal(const uint8_t* key, size_t key_len) const;

    size_t size() const { return len_; }

private:
    void reset() noexcept;

    void*   page_ = nullptr;   // mmap'd region
    size_t  map_size_ = 0;     // bytes actually mmap'd (page-rounded)
    size_t  len_  = 0;         // logical length (<= map_size_)
    uint8_t salt_[16]{};       // per-secret random salt for keystream derivation
};

class Vault {
public:
    Vault();
    ~Vault();

    bool set(const std::string& name, const uint8_t* data, size_t len);
    bool get(const std::string& name, std::string& out) const;
    bool del(const std::string& name);
    void clear();
    std::vector<std::string> list() const;

    // True if the session key was sourced from real kernel entropy.
    // False means getrandom + /dev/urandom both failed and the key
    // is zeroed — callers should refuse to operate in that state
    // rather than silently storing unobfuscated secrets.
    bool entropy_ok() const { return entropy_ok_; }

private:
    std::unordered_map<std::string, SecureBuffer> store_;
    uint8_t session_key_[32]{};
    bool    entropy_ok_ = false;
};

}  // namespace fox_vault

#endif
