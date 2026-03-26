//! VM configuration — selects which p-code VM assembly to load.

/// P-code VM assembly from pv24a project (copied into asm/).
const PVM_ASM: &str = include_str!("../asm/pvm.s");

/// VM configuration holding the selected assembly source.
pub struct VmConfig {
    source: &'static str,
}

impl Default for VmConfig {
    fn default() -> Self {
        Self { source: PVM_ASM }
    }
}

impl VmConfig {
    /// Returns the assembly source text for the current configuration.
    pub fn assembly(&self) -> &str {
        self.source
    }
}
