// Vault store unit tests — pure in-memory, no socket, no daemon.

#include "../vault_store.hpp"

#include <cstdio>
#include <cstring>
#include <string>

namespace {

int g_failed = 0;
#define EXPECT(cond) do {                                              \
    if (!(cond)) {                                                     \
        std::fprintf(stderr, "FAIL %s:%d  %s\n",                       \
                     __FILE__, __LINE__, #cond);                       \
        ++g_failed;                                                    \
    }                                                                  \
} while (0)

void test_roundtrip() {
    fox_vault::Vault v;
    const char* s = "topsecret";
    EXPECT(v.set("a", reinterpret_cast<const uint8_t*>(s), std::strlen(s)));

    std::string out;
    EXPECT(v.get("a", out));
    EXPECT(out == "topsecret");
}

void test_missing_key() {
    fox_vault::Vault v;
    std::string out;
    EXPECT(!v.get("nope", out));
}

void test_del() {
    fox_vault::Vault v;
    const char* s = "x";
    v.set("k", reinterpret_cast<const uint8_t*>(s), 1);
    EXPECT(v.del("k"));
    std::string out;
    EXPECT(!v.get("k", out));
}

void test_clear() {
    fox_vault::Vault v;
    const char* s = "x";
    v.set("a", reinterpret_cast<const uint8_t*>(s), 1);
    v.set("b", reinterpret_cast<const uint8_t*>(s), 1);
    EXPECT(v.list().size() == 2);
    v.clear();
    EXPECT(v.list().empty());
}

void test_large_value() {
    fox_vault::Vault v;
    std::string big(8192, 'Z');
    EXPECT(v.set("big",
        reinterpret_cast<const uint8_t*>(big.data()), big.size()));
    std::string out;
    EXPECT(v.get("big", out));
    EXPECT(out == big);
}

}  // namespace

int main() {
    test_roundtrip();
    test_missing_key();
    test_del();
    test_clear();
    test_large_value();
    if (g_failed == 0) {
        std::printf("desk-vault tests: OK\n");
        return 0;
    }
    std::fprintf(stderr, "desk-vault tests: %d failure(s)\n", g_failed);
    return 1;
}
