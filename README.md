# web-dv24r

Browser-based p-code VM debugger for the [pv24a](https://github.com/softwarewrighter/pv24a) virtual machine running on the [COR24](https://github.com/sw-embed/cor24-rs) emulator via WASM.

[Live Demo](https://softwarewrighter.github.io/web-dv24r/)

## Overview

web-dv24r provides two-level debugging for p-code programs:

- **P-code semantic level** (primary) -- step through p-code instructions, inspect the eval stack, call frames, and VM-managed memory regions.
- **COR24 host level** (secondary drill-down) -- inspect the underlying COR24 registers, disassembly, and machine state when you need to debug the VM implementation itself.

Built with Rust, Yew 0.21, and Trunk. Runs entirely in the browser as a WASM application.

## Features

- P-code disassembly with current instruction highlighting
- VM state display (PC, ESP, CSP, FP, GP, HP)
- Eval stack and call stack inspection
- Hex memory viewer (code, globals, heap)
- Step P-Code / Step Over / Step Out / Step Host / Run
- Demo selector with pre-assembled .p24 programs (Hello World, Arithmetic, Globals, Countdown)
- UART I/O (input field + output panel)
- Fast .p24 loading via [pa24r](https://github.com/softwarewrighter/pa24r) (4,447x speedup over in-emulator assembly)

## Run a Pascal Program

```bash
./scripts/run-pascal.sh hello.pas           # compile + link + assemble + run
./scripts/run-pascal.sh hello.pas --verbose  # with build details
```

## Build

```bash
trunk build                    # Build WASM to dist/
./scripts/serve.sh             # Dev server (port 9198)
./scripts/build-pages.sh       # Release build to pages/ for GitHub Pages
cargo clippy --all-targets --all-features -- -D warnings
cargo fmt --all
```

## Documentation

- [docs/research.txt](docs/research.txt) -- P-code VM design, memory model, calling conventions, instruction set, and Pascal compiler architecture.
- [docs/debugger.txt](docs/debugger.txt) -- Debugger UI design: panels, state model, stepping semantics, extensibility for watches and breakpoints.
- [docs/linking-loading.md](docs/linking-loading.md) -- Toolchain architecture: pipeline, .p24 format, loader design, dependency architecture.
- [CHANGES.md](CHANGES.md) -- Change log.

## Related Projects

- [pv24a](https://github.com/softwarewrighter/pv24a) -- P-code VM and p-code assembler (COR24 assembly)
- [pa24r](https://github.com/softwarewrighter/pa24r) -- P-code assembler (Rust, .spc to .p24)
- [pl24r](https://github.com/softwarewrighter/pl24r) -- P-code text-level linker (Rust)
- [p24p](https://github.com/softwarewrighter/p24p) -- Pascal compiler (C, compiled by tc24r)
- [pr24p](https://github.com/softwarewrighter/pr24p) -- Pascal runtime library (.spc sources)
- [cor24-rs](https://github.com/sw-embed/cor24-rs) -- COR24 assembler and emulator
- [web-p24c](https://github.com/softwarewrighter/web-p24c) -- Pascal compiler IDE (browser)
- [web-tf24a](https://github.com/sw-vibe-coding/web-tf24a) -- Forth debugger
- [web-tml24c](https://github.com/sw-vibe-coding/web-tml24c) -- Lisp REPL
- [web-tc24r](https://github.com/sw-vibe-coding/web-tc24r) -- C compiler UI
- [COR24-TB](https://makerlisp.com) -- COR24 FPGA board

## License

MIT License -- see [LICENSE](LICENSE) for details.

Copyright (c) 2026 Michael A. Wright
