# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project: web-sw-cor24-pcode -- P-Code VM Debugger on COR24

Browser-based p-code VM debugger running the sw-cor24-pcode VM on the cor24 emulator via WASM. Two-level debugging: p-code semantic level (primary) and COR24 host implementation level (secondary drill-down).

Forked from softwarewrighter/web-dv24r as part of the COR24 ecosystem reorganization.

## Related Projects

All COR24 repos live under `~/github/sw-embed/` as siblings:

- `sw-cor24-pcode` -- P-code VM, assembler, and linker (Rust workspace)
- `sw-cor24-emulator` -- COR24 assembler and emulator (Rust)
- `sw-cor24-assembler` -- COR24 assembler library
- `web-sw-cor24-assembler` -- COR24 assembly IDE (browser)
- `sw-cor24-rust` -- Rust-to-COR24 pipeline

## Build

Edition 2024 for any Rust code. Never suppress warnings.

```bash
trunk build                    # Build WASM to dist/
./scripts/serve.sh             # Dev server (port 9198)
./scripts/build-pages.sh       # Release build to pages/ for GitHub Pages
cargo clippy --all-targets --all-features -- -D warnings  # Lint
cargo fmt --all                # Format
```

## Architecture

- **Trunk** builds the WASM binary and serves it
- **cor24-emulator** provides `EmulatorCore` + `Assembler` (path dep to `../sw-cor24-emulator`)
- **pa24r** provides p-code assembler (path dep to `../sw-cor24-pcode/assembler`)
- **Yew 0.21** CSR framework for the UI
- Component-based architecture using `Component` trait with `Msg` enum for state updates
- `build.rs` pre-assembles pvm.s and demo .spc files at build time
- Batch execution loop (50K instructions per tick) prevents browser blocking
- UART I/O bridges user input to the VM running in the emulator

## Key Files

- `src/debugger.rs` -- Main debugger component (emulator loop, UI panels, all state)
- `src/config.rs` -- VM configuration (pre-assembled pvm.s binary and label addresses)
- `src/demos.rs` -- Demo registry (pre-assembled .p24 programs)
- `asm/pvm.s` -- P-code VM (COR24 assembly)
- `demos/*.spc` -- Demo p-code programs (hello, arith, globals, countdown)
- `index.html` -- Entry point with Catppuccin Mocha theme
- `src/debugger.css` -- Debugger panel styling
- `build.rs` -- Build script (pre-assembles pvm.s + demos, embeds build metadata)
- `scripts/serve.sh` -- Dev server script
- `scripts/build-pages.sh` -- Release build to pages/
- `scripts/run-pascal.sh` -- Compile + link + assemble + run Pascal program
