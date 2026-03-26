# web-dv24r

Browser-based p-code VM debugger for the [pv24a](https://github.com/softwarewrighter/pv24a) virtual machine running on the [COR24](https://github.com/sw-embed/cor24-rs) emulator via WASM.

## Overview

web-dv24r provides two-level debugging for p-code programs:

- **P-code semantic level** (primary) -- step through p-code instructions, inspect the eval stack, call frames, and VM-managed memory regions.
- **COR24 host level** (secondary drill-down) -- inspect the underlying COR24 registers, disassembly, and machine state when you need to debug the VM implementation itself.

Built with Rust, Yew 0.21, and Trunk. Runs entirely in the browser as a WASM application.

## Documentation

- [docs/research.txt](docs/research.txt) -- P-code VM design, memory model, calling conventions, instruction set, and Pascal compiler architecture.
- [docs/debugger.txt](docs/debugger.txt) -- Debugger UI design: panels, state model, stepping semantics, extensibility for watches and breakpoints.

## Build

```bash
trunk build                    # Build WASM to dist/
./scripts/serve.sh             # Dev server (port 9247)
./scripts/build-pages.sh       # Release build to pages/ for GitHub Pages
```

## Related Projects

- [pv24a](https://github.com/softwarewrighter/pv24a) -- P-code VM and p-code assembler (COR24 assembly)
- [cor24-rs](https://github.com/sw-embed/cor24-rs) -- COR24 assembler and emulator
- [web-tf24a](https://github.com/sw-vibe-coding/web-tf24a) -- Forth debugger (pattern reference)
- [web-tml24c](https://github.com/sw-vibe-coding/web-tml24c) -- Lisp REPL (pattern reference)
- [web-tc24r](https://github.com/sw-vibe-coding/web-tc24r) -- C compiler UI (pattern reference)

## License

MIT License -- see [LICENSE](LICENSE) for details.

Copyright (c) 2026 Michael A. Wright
