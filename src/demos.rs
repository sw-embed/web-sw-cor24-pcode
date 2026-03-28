//! Demo registry — pre-assembled p-code programs.
//!
//! Demo .spc files are assembled to .p24 binaries at build time by pa24r
//! (in build.rs). The binaries are embedded via include_bytes! and loaded
//! directly into emulator memory — no runtime assembly needed.

/// A demo entry with a name, description, and pre-assembled .p24 binary.
pub struct Demo {
    pub name: &'static str,
    pub description: &'static str,
    pub p24: &'static [u8],
}

pub const DEMOS: &[Demo] = &[
    Demo {
        name: "Hello World",
        description: "Print Hello with a puts procedure",
        p24: include_bytes!(concat!(env!("OUT_DIR"), "/hello.p24")),
    },
    Demo {
        name: "Arithmetic",
        description: "7 × 6 = 42, prints '*' (ASCII 42)",
        p24: include_bytes!(concat!(env!("OUT_DIR"), "/t02-arith.p24")),
    },
    Demo {
        name: "Globals",
        description: "Global variable store, load, and increment",
        p24: include_bytes!(concat!(env!("OUT_DIR"), "/t03-globals.p24")),
    },
    Demo {
        name: "Countdown",
        description: "Loop counting down from 5 with procedure call",
        p24: include_bytes!(concat!(env!("OUT_DIR"), "/t04-loop.p24")),
    },
];
