use std::collections::HashMap;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Location {
    pub file: String,
    pub line_start: u32,
    pub line_end: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum StationKind {
    Function,
    Method,
    Closure,
    Struct,
    Trait,
    Enum,
    Impl,
    Module,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionKind {
    Calls,
    CalledBy,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum QuestDifficulty {
    Easy,
    Medium,
    Hard,
}

/// An architectural improvement suggestion generated at index time.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Quest {
    /// Short title, e.g. "Add authentication layer"
    pub title: String,
    /// Crate name this applies to, or "system" for cross-cutting concerns
    pub component: String,
    /// 2-3 sentences on why it matters
    pub why: String,
    pub difficulty: QuestDifficulty,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Connection {
    /// Station id this connection points to
    pub to: String,
    pub kind: ConnectionKind,
}

/// A Station represents a single function/method/struct in the codebase.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Station {
    /// Unique id: "relative/path/to/file.rs::symbol_name"
    pub id: String,
    pub name: String,
    pub kind: StationKind,
    pub location: Location,
    /// LLM-generated plain-English summary (one sentence)
    pub summary: String,
    /// LLM-generated detailed explanation (multi-sentence)
    pub explanation: String,
    pub connections: Vec<Connection>,
    /// Which Line (file) this station belongs to
    pub line_id: String,
    /// FNV-1a hash of the function body — used for incremental re-indexing
    #[serde(default)]
    pub body_hash: String,
}

/// A Line represents a file/module in the codebase.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Line {
    /// Unique id: relative file path, e.g. "src/main.rs"
    pub id: String,
    /// Display name: file stem, e.g. "main"
    pub name: String,
    /// Hex color for rendering, e.g. "#E84B3A"
    pub color: String,
    /// LLM-generated plain-English summary
    pub summary: String,
    /// Station ids in source order
    pub stations: Vec<String>,
}

/// The full project index, persisted to `.metroscope/index.json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Index {
    pub project_root: String,
    pub created_at: u64,
    /// LLM-generated system-level summary
    pub system_summary: String,
    pub stations: HashMap<String, Station>,
    pub lines: HashMap<String, Line>,
    /// Station ids that are entry points (e.g. `main`)
    pub entry_points: Vec<String>,
    /// Architectural improvement suggestions generated at index time
    #[serde(default)]
    pub quests: Vec<Quest>,
}

impl Index {
    /// Find the station at the given file and line number.
    pub fn station_at(&self, file: &str, line: u32) -> Option<&Station> {
        self.stations.values().find(|s| {
            s.location.file == file && s.location.line_start <= line && line <= s.location.line_end
        })
    }
}
