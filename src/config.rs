//! VM configuration — selects which p-code VM assembly to load.

/// Placeholder assembly source for initial scaffold.
/// Will be replaced with actual pv24a VM assembly in later steps.
const PLACEHOLDER_ASM: &str = "\
    .org 0\n\
    ld r0, #0x48\n\
    out r0\n\
    ld r0, #0x69\n\
    out r0\n\
    ld r0, #0x0A\n\
    out r0\n\
    halt\n\
";

/// VM configuration holding the selected assembly source.
pub struct VmConfig {
    source: &'static str,
}

impl Default for VmConfig {
    fn default() -> Self {
        Self {
            source: PLACEHOLDER_ASM,
        }
    }
}

impl VmConfig {
    /// Returns the assembly source text for the current configuration.
    pub fn assembly(&self) -> &str {
        self.source
    }
}
