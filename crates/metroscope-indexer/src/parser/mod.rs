pub mod rust;

use anyhow::Result;
use metroscope_types::{Location, StationKind};

/// A parsed function extracted from source.
#[derive(Debug, Clone)]
pub struct ParsedFunction {
    pub id: String,
    pub name: String,
    pub kind: StationKind,
    pub location: Location,
    pub body: String,
    /// raw source text of the function body (for llm summarization)
    /// Names of functions this function calls (best-effort)
    pub calls: Vec<String>,
}

impl ParsedFunction {
    /// FNV-1a hash of the function body, hex-encoded.
    pub fn body_hash(&self) -> String {
        let mut hash: u64 = 0xcbf29ce484222325;
        for byte in self.body.bytes() {
            hash ^= byte as u64;
            hash = hash.wrapping_mul(0x100000001b3);
        }
        format!("{:016x}", hash)
    }
}

/// A parsed file containing its functions.
#[derive(Debug, Clone)]
pub struct ParsedFile {
    /// Relative path, e.g. "src/main.rs"
    pub file_id: String,
    /// Display name, e.g. "main"
    pub file_name: String,
    /// Raw source text (for file-level summarization)
    pub source: String,
    pub functions: Vec<ParsedFunction>,
}

/// Trait that any language parser must implement.
/// Implement this for Rust, JS/TS, etc.
pub trait LanguageParser {
    fn parse(&self, source: &str, file_id: &str) -> Result<ParsedFile>;
}
