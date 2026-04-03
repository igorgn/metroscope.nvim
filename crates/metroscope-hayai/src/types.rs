use std::collections::HashMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

// ── IDs ──────────────────────────────────────────────────────────────────────

pub type QuestId = String;
pub type ForkId = String;
pub type WorkerId = String;

// ── Skill tree ───────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ActStatus {
    Locked,
    Active,
    Complete,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Act {
    pub number: u32,
    pub title: String,
    pub status: ActStatus,
    pub quest_ids: Vec<QuestId>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum QuestStatus {
    Locked,
    Available,
    InProgress,
    Complete,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TreeQuest {
    pub id: QuestId,
    pub title: String,
    pub description: String,
    pub act: u32,
    pub status: QuestStatus,
    /// Quest IDs that must be complete before this one unlocks
    pub depends_on: Vec<QuestId>,
    /// Quest IDs that this quest unlocks
    pub unlocks: Vec<QuestId>,
    pub fork_ids: Vec<ForkId>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ForkStatus {
    Pending,
    /// Orchestrator decided without human input
    AutoResolved,
    /// Waiting for human decision
    Escalated,
    Resolved,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ForkOption {
    pub id: String,
    pub label: String,
    pub description: String,
    /// What this option enables downstream (human-readable)
    pub unlocks: String,
    /// What this option forecloses downstream (human-readable)
    pub forecloses: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Fork {
    pub id: ForkId,
    pub quest_id: QuestId,
    pub question: String,
    pub options: Vec<ForkOption>,
    pub status: ForkStatus,
    pub chosen_option_id: Option<String>,
    pub reason: Option<String>,
    pub worker_id: Option<WorkerId>,
    pub created_at: DateTime<Utc>,
    pub resolved_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum WorkerStatus {
    Running,
    Done,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Worker {
    pub id: WorkerId,
    pub fork_id: ForkId,
    pub instructions: String,
    pub status: WorkerStatus,
    pub summary: Option<String>,
    pub created_at: DateTime<Utc>,
    pub finished_at: Option<DateTime<Utc>>,
}

/// The full skill tree — persisted to `.metro/tree.json`.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Tree {
    pub acts: Vec<Act>,
    pub quests: HashMap<QuestId, TreeQuest>,
    pub forks: HashMap<ForkId, Fork>,
    pub workers: HashMap<WorkerId, Worker>,
}

// ── Hot context ───────────────────────────────────────────────────────────────

/// Cheap summary injected at every Claude Code session start.
/// Persisted to `.metro/context.json`.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Context {
    pub current_act: u32,
    pub active_quest_id: Option<QuestId>,
    pub pending_fork_ids: Vec<ForkId>,
    pub escalated_fork_ids: Vec<ForkId>,
    pub recently_touched_files: Vec<String>,
    pub open_questions: Vec<String>,
    pub updated_at: Option<DateTime<Utc>>,
}

// ── State log event ───────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum StateEvent {
    ForkProposed { fork_id: ForkId, quest_id: QuestId },
    ForkResolved { fork_id: ForkId, option_id: String, reason: String },
    ForkEscalated { fork_id: ForkId, description: String },
    WorkerDispatched { worker_id: WorkerId, fork_id: ForkId },
    WorkerDone { worker_id: WorkerId, summary: String },
    QuestComplete { quest_id: QuestId },
    ActComplete { act: u32 },
    FileChanged { file: String },
    ReIndexed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LogEntry {
    pub ts: DateTime<Utc>,
    pub event: StateEvent,
}
