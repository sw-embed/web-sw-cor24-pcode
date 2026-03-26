//! Demo registry — embedded .spc/.pasm test programs.
//!
//! Placeholder for step 7 of the saga. Will hold embedded p-code
//! program sources for quick-load demo scenarios.

/// A demo entry with a name and p-code assembly source.
pub struct Demo {
    pub name: &'static str,
    pub source: &'static str,
}

/// Available demos. Empty for now — populated in step 7.
pub static DEMOS: &[Demo] = &[];
