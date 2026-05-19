// state_manifest.hpp — per-module install state, persisted as JSON.
//
// Phase 6 Step 1 of the architecture refactor. The manifest answers
// "what did the last install do?" — so subsequent runs can classify
// each module as noop / update / conflict / fresh and avoid the
// "re-run everything every time" pattern.
//
// Format (~/.config/foxml/install-state.json):
//   {
//     "schema_version": 1,
//     "fox_version": "5.10.x-<sha>",
//     "modules": {
//       "render":   { "version": "...", "source_hash": "...", "deployed_at": "..." },
//       "waybar":   { ... },
//       ...
//     }
//   }
//
// All writes are atomic (tmp + rename per CLAUDE.md convention).

#pragma once

#include <filesystem>
#include <map>
#include <string>

namespace fox_install::state {

struct ModuleState {
    std::string version;       // fox release identifier at install time
    std::string source_hash;   // content hash of what was deployed
    std::string deployed_at;   // ISO 8601 timestamp (UTC)
};

struct Manifest {
    int schema_version = 1;
    std::string fox_version;
    std::map<std::string, ModuleState> modules;
};

// Default storage path: $HOME/.config/foxml/install-state.json. Honors
// $XDG_CONFIG_HOME if set.
std::filesystem::path default_path();

// Read manifest from `path`. Returns a default-constructed (empty)
// Manifest if the file does not exist. Throws std::runtime_error on
// any parse/IO error so callers can decide how to handle a corrupted
// state file (typically: log + treat as empty + write fresh next time).
Manifest read(const std::filesystem::path& path);

// Write `m` atomically: serializes JSON to `path + ".tmp"`, then
// std::filesystem::rename to `path`. Creates parent directories if
// missing. Throws std::runtime_error on IO failure.
void write(const std::filesystem::path& path, const Manifest& m);

// Helper: current UTC time as ISO 8601 string (for ModuleState::deployed_at).
std::string now_iso8601();

}  // namespace fox_install::state
