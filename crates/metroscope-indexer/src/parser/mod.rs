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
    /// Raw source text of the function body (for LLM summarization)
    pub body: String,
    /// Names of functions this function calls (best-effort)
    pub calls: Vec<String>,
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
