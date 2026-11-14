#pragma once
#include <algorithm>
#include <string>

namespace desk_install::input {
inline int mode(int argc, char** argv) {
    int result = 0;
    for (int i = 1; i < argc && std::string(argv[i]) != "--"; ++i) {
        const std::string option = argv[i];
#define DESK_INPUT_OPTION(flag, value) if (option == flag) result = std::max(result, value);
#define DESK_INPUT_VALUE(flag) if (option == flag && i + 1 < argc) ++i;
#include "input_options.def"
#undef DESK_INPUT_OPTION
#undef DESK_INPUT_VALUE
    }
    return result;
}
}
