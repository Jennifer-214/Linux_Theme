# Local AI

[← Back to the README](../README.md)

Agent setup, model serving, model roles and semantic project search.

## Setup

Install the agents, model downloads and router together:

```bash
./install.sh --only ai,models,llama_server --yes
```

The desktop preset also enables this stack; `setup` enables agents and downloads
but does not enable the router. Choose models and disk space to suit your machine.

The local stack uses Hugging Face GGUF models and **llama.cpp's router** at
`127.0.0.1:8080`. Terminal agents, AI tools and embeddings share that endpoint.
Models load on demand; llama.cpp handles GPU placement through its MoE-aware
auto-fit, with a 128k-context agent role.

| Module | Installs or configures |
| --- | --- |
| `--ai` | OpenCode and aider |
| `--models` | Background downloads of the RAM-tiered chat/coder stack and `mxbai-embed-large` embedder |
| `--llama-server` | llama.cpp and the model router |

## Agents

- **OpenCode** — Claude-Code-style terminal agent. Multi-provider; its local default is the llama.cpp router. Theme and skill paths are generated (skills from `~/code/*/claude-skills/`); `llm-update --sync` fills the model picker from what the router serves. Auto-wakes the router on launch.
- **pi** — minimal terminal coding agent with Linux_Theme extensions (permission gate, desktop notifications, per-project Claude skills); same local default as OpenCode.
- **aider** — git-native pair programmer. Commits its own edits per change. Useful for surgical "make this change" workflows where OpenCode's multi-turn agent loop is overkill.

## Local models (`fox-llm-*`)

| Piece | What it does |
|-------|--------------|
| `~/code/custom_models/roles.conf` | Your roles: which model fills each role (`agent`, `quick`, `fim`, `title`, `embed`) and on which router (`llama`, `llama-turbo`). Kept in a private `custom_models` repo, so `--github` brings it back on a reinstall; the installer links `~/.config/foxml/llm/roles.conf` to it (a real file there overrides it on one machine); `roles.default` ships |
| `~/code/custom_models/gguf-models.conf` | Your models: `name user/repo/file.gguf` lines (Hugging Face, single-file GGUFs); a `-name` line skips one from every list. `~/.config/foxml/llm/gguf-models.txt` is the same for one machine; `core-models.txt` ships the RAM-tiered defaults |
| `llm-update` | Downloads the lists into `~/.local/share/fox-llm/gguf/` — sha256-checked against Hugging Face's record, and each file's header through llama.cpp's loader before the download, so a model the build can't run never costs one. Daily timer: update notices, newer uploads, discovery of new tool-capable models on Hugging Face (`llm-discover`). `--queue` downloads in the background (resumes across reboots); `--sync` wires the models into OpenCode + pi |
| `llm-serve` | Builds the router's preset from the roles and the downloaded models — chat and embedding models; a once-per-file load check leaves out a model this llama.cpp can't run |
| `llm-run` | One answer from the router for scripts — `llm-run "prompt"`, `--list`, `--ps`, `--unload`; what the `fox-ai-*` shell tools use |

## Semantic project search (`fask` / `findex`)

`findex` builds a chunked semantic index of the current directory using `mxbai-embed-large`. Files are split into 100-line chunks with 10-line overlap so functions spanning chunk boundaries still appear whole somewhere. The model name is persisted in the index — re-running with a different embedder triggers a clean rebuild instead of mixing incompatible vectors. `fask` cosine-ranks chunks against your question, opens each top-K match at its exact line range, and streams a model answer.

| Command | What it does |
|---------|--------------|
| `findex [opts]` | Build semantic index (tunable via `--size`, `--model`, etc.) |
| `fask "<q>"` | RAG Q&A over the current project's `.foxml_index.json` |
| `desk-ask "<question>"` | One-shot terminal Q&A — no index needed; uses the configured model |
| `ai-commit` | AI-drafted commit message from staged diff |
| `ai-explain <file>` | Plain-English explanation of code/logs/errors |
| `ai-swap [tag]` | Switch the default model (OpenCode + the desk-ai tools) and free the old one's memory on whichever server runs it |
| `ai-doctor` | AI-augmented system diagnostics |
| `ai-review` | Pre-commit guardrail (`BLOCK:` / `WARN:` lines from local model) |
| `fhelp` | Full command reference |

`cd`-ing into a directory containing an `AGENT.md` auto-exports project context, scoping `fask`/`findex` to that workspace.

## Theme integration

- Palette-driven OpenCode theme (`templates/opencode/foxml.json`) rendered through the same `{{TOKEN}}` system — theme swaps re-render OpenCode too.
- `fask`/`desk-ask` pick up the active palette's `ANSI_ACCENT1` via `~/.config/foxml/ansi_colors.json` for status banners like `[Thinking...]`.
