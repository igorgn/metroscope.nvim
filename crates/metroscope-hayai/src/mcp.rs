/// MCP server — HTTP endpoints that Claude Code calls as tools.
///
/// Each endpoint corresponds to one MCP tool. Claude Code sends JSON,
/// gets JSON back. The MCP manifest (returned by GET /) tells Claude
/// what tools are available and what parameters they take.
use std::sync::Arc;

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Json, Response},
    routing::{get, post},
    Router,
};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    ollama::OllamaClient,
    store::Store,
    types::{
        ActStatus, Fork, ForkOption, ForkStatus, QuestStatus, StateEvent, Worker,
        WorkerStatus,
    },
};

pub struct AppState {
    pub store: Arc<Store>,
    pub ollama: Arc<OllamaClient>,
}

pub fn router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/", get(manifest))
        .route("/context", get(get_context))
        .route("/tree", get(get_tree))
        .route("/quest/:id", get(get_quest))
        .route("/fork/propose", post(propose_fork))
        .route("/fork/resolve", post(resolve_fork))
        .route("/fork/escalate", post(escalate_fork))
        .route("/fork/escalations", get(get_escalations))
        .route("/worker/dispatch", post(dispatch_worker))
        .route("/worker/done", post(worker_done))
        .route("/notify-change", post(notify_change))
        .with_state(state)
}

// ── Manifest ─────────────────────────────────────────────────────────────────

async fn manifest() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "name": "hayai",
        "vrsion": "0.1.0",
        "description": "Skill tree orchestrator for Metroscope. Tracks quests, forks, and workers across a coding session.",
        "tools": [
            { "name": "get_context",            "description": "Current act, active quest, pending forks. Call this at session start.",           "endpoint": "GET /context" },
            { "name": "get_tree",               "description": "Full skill tree: acts, quests, forks.",                                            "endpoint": "GET /tree" },
            { "name": "get_quest",              "description": "Quest detail + its forks.",                                                        "endpoint": "GET /quest/:id" },
            { "name": "propose_fork",           "description": "Add a decision point to a quest.",                                                 "endpoint": "POST /fork/propose" },
            { "name": "resolve_fork",           "description": "Record a fork decision (human or auto).",                                          "endpoint": "POST /fork/resolve" },
            { "name": "escalate",               "description": "Flag a fork for human decision with a description.",                               "endpoint": "POST /fork/escalate" },
            { "name": "get_pending_escalations","description": "List forks waiting for human input.",                                              "endpoint": "GET /fork/escalations" },
            { "name": "dispatch_worker",        "description": "Record that a worker (Claude Code) has been dispatched to implement a fork.",      "endpoint": "POST /worker/dispatch" },
            { "name": "worker_done",            "description": "Mark a worker complete. Triggers context update and quest completion check.",       "endpoint": "POST /worker/done" },
            { "name": "notify_change",          "description": "Called by the PostToolUse hook on every file edit. Runs relevance filter.",        "endpoint": "POST /notify-change" },
        ]
    }))
}

// ── get_context ───────────────────────────────────────────────────────────────

async fn get_context(State(s): State<Arc<AppState>>) -> Json<serde_json::Value> {
    let ctx = s.store.context.read().await;
    Json(serde_json::to_value(&*ctx).unwrap_or_default())
}

// ── get_tree ──────────────────────────────────────────────────────────────────

async fn get_tree(State(s): State<Arc<AppState>>) -> Json<serde_json::Value> {
    let tree = s.store.tree.read().await;
    Json(serde_json::to_value(&*tree).unwrap_or_default())
}

// ── get_quest ─────────────────────────────────────────────────────────────────

async fn get_quest(
    State(s): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Response {
    let tree = s.store.tree.read().await;
    match tree.quests.get(&id) {
        Some(quest) => {
            let forks: Vec<_> = quest
                .fork_ids
                .iter()
                .filter_map(|fid| tree.forks.get(fid))
                .collect();
            Json(serde_json::json!({ "quest": quest, "forks": forks })).into_response()
        }
        None => (StatusCode::NOT_FOUND, "quest not found").into_response(),
    }
}

// ── propose_fork ──────────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct ProposeForkRequest {
    pub quest_id: String,
    pub question: String,
    pub options: Vec<ProposeForkOption>,
}

#[derive(Deserialize)]
pub struct ProposeForkOption {
    pub label: String,
    pub description: String,
    pub unlocks: String,
    pub forecloses: String,
}

#[derive(Serialize)]
pub struct ProposeForkResponse {
    pub fork_id: String,
}

async fn propose_fork(
    State(s): State<Arc<AppState>>,
    Json(req): Json<ProposeForkRequest>,
) -> Response {
    let fork_id = Uuid::new_v4().to_string();
    let fork = Fork {
        id: fork_id.clone(),
        quest_id: req.quest_id.clone(),
        question: req.question,
        options: req
            .options
            .into_iter()
            .enumerate()
            .map(|(i, o)| ForkOption {
                id: format!("option_{i}"),
                label: o.label,
                description: o.description,
                unlocks: o.unlocks,
                forecloses: o.forecloses,
            })
            .collect(),
        status: ForkStatus::Pending,
        chosen_option_id: None,
        reason: None,
        worker_id: None,
        created_at: Utc::now(),
        resolved_at: None,
    };

    {
        let mut tree = s.store.tree.write().await;
        if let Some(quest) = tree.quests.get_mut(&req.quest_id) {
            quest.fork_ids.push(fork_id.clone());
        }
        tree.forks.insert(fork_id.clone(), fork);
    }

    let _ = s
        .store
        .append_log(StateEvent::ForkProposed {
            fork_id: fork_id.clone(),
            quest_id: req.quest_id,
        })
        .await;
    let _ = s.store.save_tree().await;

    // Update context
    {
        let mut ctx = s.store.context.write().await;
        if !ctx.pending_fork_ids.contains(&fork_id) {
            ctx.pending_fork_ids.push(fork_id.clone());
        }
    }
    let _ = s.store.save_context().await;

    Json(ProposeForkResponse { fork_id }).into_response()
}

// ── resolve_fork ──────────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct ResolveForkRequest {
    pub fork_id: String,
    pub chosen_option_id: String,
    pub reason: Option<String>,
}

async fn resolve_fork(
    State(s): State<Arc<AppState>>,
    Json(req): Json<ResolveForkRequest>,
) -> Response {
    {
        let mut tree = s.store.tree.write().await;
        match tree.forks.get_mut(&req.fork_id) {
            Some(fork) => {
                fork.status = ForkStatus::Resolved;
                fork.chosen_option_id = Some(req.chosen_option_id.clone());
                fork.reason = req.reason.clone();
                fork.resolved_at = Some(Utc::now());
            }
            None => return (StatusCode::NOT_FOUND, "fork not found").into_response(),
        }
    }

    let _ = s
        .store
        .append_log(StateEvent::ForkResolved {
            fork_id: req.fork_id.clone(),
            option_id: req.chosen_option_id,
            reason: req.reason.unwrap_or_default(),
        })
        .await;
    let _ = s.store.save_tree().await;

    // Remove from pending/escalated in context
    {
        let mut ctx = s.store.context.write().await;
        ctx.pending_fork_ids.retain(|id| id != &req.fork_id);
        ctx.escalated_fork_ids.retain(|id| id != &req.fork_id);
    }
    let _ = s.store.save_context().await;

    Json(serde_json::json!({ "ok": true })).into_response()
}

// ── escalate_fork ─────────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct EscalateRequest {
    pub fork_id: String,
    pub description: String,
}

async fn escalate_fork(
    State(s): State<Arc<AppState>>,
    Json(req): Json<EscalateRequest>,
) -> Response {
    {
        let mut tree = s.store.tree.write().await;
        match tree.forks.get_mut(&req.fork_id) {
            Some(fork) => fork.status = ForkStatus::Escalated,
            None => return (StatusCode::NOT_FOUND, "fork not found").into_response(),
        }
    }

    let _ = s
        .store
        .append_log(StateEvent::ForkEscalated {
            fork_id: req.fork_id.clone(),
            description: req.description.clone(),
        })
        .await;
    let _ = s.store.save_tree().await;

    {
        let mut ctx = s.store.context.write().await;
        ctx.pending_fork_ids.retain(|id| id != &req.fork_id);
        if !ctx.escalated_fork_ids.contains(&req.fork_id) {
            ctx.escalated_fork_ids.push(req.fork_id.clone());
        }
        ctx.open_questions.push(req.description);
    }
    let _ = s.store.save_context().await;

    Json(serde_json::json!({ "ok": true })).into_response()
}

// ── get_escalations ───────────────────────────────────────────────────────────

async fn get_escalations(State(s): State<Arc<AppState>>) -> Json<serde_json::Value> {
    let tree = s.store.tree.read().await;
    let escalated: Vec<_> = tree
        .forks
        .values()
        .filter(|f| f.status == ForkStatus::Escalated)
        .collect();
    Json(serde_json::json!({ "escalations": escalated }))
}

// ── dispatch_worker ───────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct DispatchWorkerRequest {
    pub fork_id: String,
    pub instructions: String,
}

#[derive(Serialize)]
pub struct DispatchWorkerResponse {
    pub worker_id: String,
}

async fn dispatch_worker(
    State(s): State<Arc<AppState>>,
    Json(req): Json<DispatchWorkerRequest>,
) -> Response {
    let worker_id = Uuid::new_v4().to_string();
    let worker = Worker {
        id: worker_id.clone(),
        fork_id: req.fork_id.clone(),
        instructions: req.instructions,
        status: WorkerStatus::Running,
        summary: None,
        created_at: Utc::now(),
        finished_at: None,
    };

    {
        let mut tree = s.store.tree.write().await;
        if let Some(fork) = tree.forks.get_mut(&req.fork_id) {
            fork.worker_id = Some(worker_id.clone());
        }
        tree.workers.insert(worker_id.clone(), worker);
    }

    let _ = s
        .store
        .append_log(StateEvent::WorkerDispatched {
            worker_id: worker_id.clone(),
            fork_id: req.fork_id,
        })
        .await;
    let _ = s.store.save_tree().await;

    Json(DispatchWorkerResponse { worker_id }).into_response()
}

// ── worker_done ───────────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct WorkerDoneRequest {
    pub worker_id: String,
    pub summary: String,
}

async fn worker_done(
    State(s): State<Arc<AppState>>,
    Json(req): Json<WorkerDoneRequest>,
) -> Response {
    let fork_id;
    let quest_id;

    {
        let mut tree = s.store.tree.write().await;
        match tree.workers.get_mut(&req.worker_id) {
            Some(worker) => {
                worker.status = WorkerStatus::Done;
                worker.summary = Some(req.summary.clone());
                worker.finished_at = Some(Utc::now());
                fork_id = worker.fork_id.clone();
            }
            None => return (StatusCode::NOT_FOUND, "worker not found").into_response(),
        }

        // Mark the fork resolved if it isn't already
        quest_id = tree
            .forks
            .get_mut(&fork_id)
            .map(|f| {
                if f.status != ForkStatus::Resolved {
                    f.status = ForkStatus::Resolved;
                    f.resolved_at = Some(Utc::now());
                }
                f.quest_id.clone()
            })
            .unwrap_or_default();

        // Check if all forks in the quest are resolved → mark quest complete
        let all_done = tree
            .quests
            .get(&quest_id)
            .map(|quest| {
                quest.fork_ids.iter().all(|fid| {
                    tree.forks
                        .get(fid)
                        .map(|f| f.status == ForkStatus::Resolved)
                        .unwrap_or(false)
                })
            })
            .unwrap_or(false);
        if all_done {
            if let Some(quest) = tree.quests.get_mut(&quest_id) {
                quest.status = QuestStatus::Complete;
            }
        }
    }

    let _ = s
        .store
        .append_log(StateEvent::WorkerDone {
            worker_id: req.worker_id,
            summary: req.summary,
        })
        .await;
    let _ = s.store.save_tree().await;

    // Rebuild context
    rebuild_context(&s.store).await;

    Json(serde_json::json!({ "ok": true, "quest_id": quest_id })).into_response()
}

// ── notify_change ─────────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct NotifyChangeRequest {
    pub file: String,
}

async fn notify_change(
    State(s): State<Arc<AppState>>,
    Json(req): Json<NotifyChangeRequest>,
) -> Json<serde_json::Value> {
    let _ = s
        .store
        .append_log(StateEvent::FileChanged { file: req.file.clone() })
        .await;

    // Update recently touched files
    {
        let mut ctx = s.store.context.write().await;
        ctx.recently_touched_files.retain(|f| f != &req.file);
        ctx.recently_touched_files.insert(0, req.file.clone());
        ctx.recently_touched_files.truncate(10);
    }

    // Relevance filter — ask Ollama if this file matters
    let (active_quest, pending_forks) = {
        let ctx = s.store.context.read().await;
        (
            ctx.active_quest_id.clone().unwrap_or_default(),
            ctx.pending_fork_ids.clone(),
        )
    };

    let relevant = s
        .ollama
        .is_relevant(&req.file, &active_quest, &pending_forks)
        .await
        .unwrap_or(false);

    if relevant {
        // Could trigger further orchestrator logic here in future
        tracing::info!(file = %req.file, "file change is relevant to active quest");
    }

    let _ = s.store.save_context().await;

    Json(serde_json::json!({ "relevant": relevant }))
}

// ── helpers ───────────────────────────────────────────────────────────────────

async fn rebuild_context(store: &Store) {
    let tree = store.tree.read().await;

    // Find lowest active act
    let current_act = tree
        .acts
        .iter()
        .find(|a| a.status == ActStatus::Active)
        .map(|a| a.number)
        .unwrap_or(1);

    // Find first in-progress quest
    let active_quest_id = tree
        .quests
        .values()
        .find(|q| q.act == current_act && q.status == QuestStatus::InProgress)
        .map(|q| q.id.clone());

    // Pending forks
    let pending_fork_ids: Vec<_> = tree
        .forks
        .values()
        .filter(|f| f.status == ForkStatus::Pending)
        .map(|f| f.id.clone())
        .collect();

    let escalated_fork_ids: Vec<_> = tree
        .forks
        .values()
        .filter(|f| f.status == ForkStatus::Escalated)
        .map(|f| f.id.clone())
        .collect();

    drop(tree);

    let mut ctx = store.context.write().await;
    ctx.current_act = current_act;
    ctx.active_quest_id = active_quest_id;
    ctx.pending_fork_ids = pending_fork_ids;
    ctx.escalated_fork_ids = escalated_fork_ids;
}
