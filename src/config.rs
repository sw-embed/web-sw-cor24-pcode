//! VM configuration — pre-assembled pvm.s binary and label addresses.
//!
//! The COR24 assembler runs at build time (in build.rs), not in WASM.
//! This module provides the pre-assembled binary and key label addresses.

/// Pre-assembled pvm.s COR24 machine code.
pub const PVM_BINARY: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/pvm.bin"));

// Key label addresses from pvm.s assembly.
include!(concat!(env!("OUT_DIR"), "/pvm_labels.rs"));

/// Look up a label address by name.
pub fn label_addr(name: &str) -> u32 {
    PVM_LABELS
        .iter()
        .find(|(n, _)| *n == name)
        .map(|(_, a)| *a)
        .unwrap_or(0)
}
