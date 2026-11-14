# Claude mod API fixture

These are unmodified declarations exported by the Claude Code version in `manifest.json`. They let hosted CI
type-check the notebook without an authenticated Claude account. They are test inputs and are never installed.
`manifest.json` owns the Claude and TypeScript pins and the hashes of the exported files.

When updating Claude, export its `.claude-plugin/types` from a disposable mod, replace the three declaration
files and `tsconfig.json`, and update the manifest version and SHA-256 hashes together. Run
`make test-work-integrations`; an engine/fixture mismatch, modified fixture or missing tool fails that target.
