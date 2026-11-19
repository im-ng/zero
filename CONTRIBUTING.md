# Contributing to zero

zero welcomes issues, docs fixes, example apps, and backend integrations.

## For humans

- Read `AGENTS.md` first — it is the authoritative style + verify guide and is
  short.
- Every change to `src/**/*.zig` and `examples/**/*.zig` must pass `zig fmt` and
  the brace/error-handling audit described in `AGENTS.md`.
- Verify before you open a PR:

  ```bash
  zig build test              # unit tests
  zig build test-integration  # SQLite :memory: + Postgres + fakeserver
  zig fmt --check src examples
  ```

- Good first issues are labelled `good first issue`. Ask in an issue before a
  large change so we align on scope.

## For AI agents

zero is built to be worked on by coding agents. Two files make that safe:

- `AGENTS.md` — conventions, toolchain (Zig 0.16.0), and the exact verify gates.
- `.opencode/skills/zero-feature-runbook` — the mandatory runbook for any src or
  examples change (pre-flight reading, scope discipline, per-task deviation log).

Point your agent at `AGENTS.md` and the runbook; do not skip the verify step.

## Built with zero

Shipped something on zero? Open a **Showcase** issue (template:
`Showcase.md`). We link accepted showcases from the README.
