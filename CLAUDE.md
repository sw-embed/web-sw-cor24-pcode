# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## CRITICAL: AgentRail Session Protocol (MUST follow exactly)

This project uses AgentRail. Every session follows this exact sequence:

### 1. START (do this FIRST, before anything else)
```bash
agentrail next
```
Read the output carefully. It tells you your current step, prompt, skill docs, and past trajectories.

### 2. BEGIN (immediately after reading the next output)
```bash
agentrail begin
```

### 3. WORK (do what the step prompt says)
Do NOT ask the user "want me to proceed?" or "shall I start?". The step prompt IS your instruction. Execute it.

### 4. COMMIT (after the work is done)
Commit your code changes with git.

### 5. COMPLETE (LAST thing, after committing)
```bash
agentrail complete --summary "what you accomplished" \
  --reward 1 \
  --actions "tools and approach used" \
  --next-slug "next-step-slug" \
  --next-prompt "what the next step should do" \
  --next-task-type "task-type"
```
If the step failed: `--reward -1 --failure-mode "what went wrong"`
If the saga is finished: use `--done` instead of `--next-*` flags
Always define the next step unless the saga is done — otherwise the next session has no step to begin.

### 6. STOP (after complete, DO NOT continue working)
Do NOT make any further code changes after running agentrail complete.
Any changes after complete are untracked and invisible to the next session.
If you see more work to do, it belongs in the NEXT step, not this session.

Do NOT skip any of these steps. The next session depends on your trajectory recording.

## Project: web-dv24r -- P-Code VM Debugger on COR24

Browser-based p-code VM debugger running the pv24a VM on the cor24-rs emulator via WASM. Two-level debugging: p-code semantic level (primary) and COR24 host implementation level (secondary drill-down).

## Multi-Agent Coordination (Wiki)

This project coordinates with other agents via a shared wiki. See `docs/agent-cas-wiki.md` for the full API reference and CAS protocol.

- **Wiki server:** `http://localhost:7402` (git backend)
- **Key pages:** [[AgentToAgentRequests]], [[AgentStatus]], [[P24Toolchain]], [[COR24Architecture]], [[WebDV24R]]
- **Our role:** web-dv24r is the top-level integration point and project coordinator. We drive the toolchain forward by tracking requests, unblocking other agents, and validating end-to-end.
- **On session start:** Read [[AgentToAgentRequests]] and [[AgentStatus]] to check for new requests or updates from other agents. Update our status.

## Related Projects

- `~/github/sw-vibe-coding/pv24a` -- P-code VM and p-code assembler (COR24 assembly, `pvm.s`)
- `~/github/softwarewrighter/pa24r` -- P-code assembler (Rust, .spc → .p24)
- `~/github/softwarewrighter/pl24r` -- P-code text-level linker (Rust)
- `~/github/softwarewrighter/p24p` -- Pascal compiler (C, compiled by tc24r)
- `~/github/softwarewrighter/pr24p` -- Pascal runtime library (.spc sources)
- `~/github/sw-vibe-coding/tc24r` -- COR24 C compiler (Rust)
- `~/github/sw-embed/cor24-rs` -- COR24 assembler and emulator (Rust)
- `~/github/sw-vibe-coding/web-tf24a` -- Forth debugger (pattern reference for debugger UI)
- `~/github/sw-vibe-coding/web-tml24c` -- Lisp REPL (pattern reference for Yew UI)
- `~/github/sw-vibe-coding/web-tc24r` -- C compiler UI (pattern reference)
- `~/github/sw-vibe-coding/agentrail-domain-coding` -- Coding skills domain

## Available Task Types

`rust-project-init`, `rust-clippy-fix`, `yew-component`, `wasm-build`, `pre-commit`

## Key Documentation (READ BEFORE WORKING)

- `docs/research.txt` -- Deep research on p-code VM design, memory model, calling conventions, instruction set, p-code assembler design, and Pascal compiler architecture.
- `docs/debugger.txt` -- Debugger UI design: panels, state model, stepping semantics, what to show/hide, extensibility for watches and breakpoints.
- `docs/linking-loading.md` -- Toolchain architecture: pipeline, .p24 format, loader design, dependency architecture, debug info plan.
- `docs/agent-cas-wiki.md` -- Wiki API for multi-agent coordination (CAS protocol, endpoints, workflow).

## Build

Edition 2024 for any Rust code. Never suppress warnings.

```bash
trunk build                    # Build WASM to dist/
./scripts/serve.sh             # Dev server
./scripts/build-pages.sh       # Release build to pages/ for GitHub Pages
cargo clippy --all-targets --all-features -- -D warnings  # Lint
cargo fmt --all                # Format
```

## Utilities

- `ep2ms` -- returns milliseconds since epoch; use for `?ts=` cache-busting on image URLs in README

## Architecture

- **Trunk** builds the WASM binary and serves it
- **cor24-emulator** provides `EmulatorCore` + `Assembler` (path dep to `../../sw-embed/cor24-rs`)
- **Yew 0.21** CSR framework for the UI
- Component-based architecture using `Component` trait with `Msg` enum for state updates
- Assembly files in `asm/` are `include_str!`'d and assembled at runtime
- Batch execution loop (50K instructions per tick) prevents browser blocking
- UART I/O bridges user input to the VM running in the emulator

## Key Files

- `src/debugger.rs` -- Main debugger component (emulator loop, UI panels, all state)
- `src/config.rs` -- VM configuration (currently loads pvmasm.s)
- `src/demos.rs` -- Demo registry (embedded .spc files fed via UART)
- `asm/pvm.s` -- P-code VM only (from pv24a)
- `asm/pvmasm.s` -- Integrated assembler+VM (from pv24a, currently active)
- `demos/*.spc` -- Demo p-code programs (hello, arith, globals, countdown)
- `index.html` -- Entry point with Catppuccin Mocha theme
- `src/debugger.css` -- Debugger panel styling
- `build.rs` -- Build script (BUILD_SHA, BUILD_HOST, BUILD_TIMESTAMP)
- `scripts/serve.sh` -- Dev server script
- `scripts/build-pages.sh` -- Release build to pages/
- `.github/workflows/pages.yml` -- Deploy pages/ on push to main
