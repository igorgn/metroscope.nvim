/// Proper MCP server using rmcp — exposes Hayai tools over the Streamable HTTP transport.
/// Claude Code connects to this via .mcp.json as type "sse".
use std::sync::Arc;

use chrono::Utc;
use rmcp::{
    ServerHandler,
    handler::server::wrapper::{Json, Parameters},
    model::{Implementation, ServerCapabilities, ServerInfo},
    schemars,
    tool, tool_router,
};
use serde::Deserialize;
use uuid::Uuid;

use crate::{
    store::Store,
    types::{
        ActStatus, Fork, ForkOption, ForkStatus, QuestStatus, StateEvent, Worker, WorkerStatus,
    },
};

#[derive(Clone)]
pub struct HayaiMcpServer {
    pub store: Arc<Store>,
}

// ── Parameter types ───────────────────────────────────────────────────────────

#[derive(Deserialize, schemars::JsonSchema, Default)]
pub struct EmptyParams {}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct GetQuestParams {
    pub quest_id: String,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct ProposeForkOptionParam {
    pub label: String,
    pub description: String,
    pub unlocks: String,
    pub forecloses: String,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct ProposeForkParams {
    pub quest_id: String,
    pub question: String,
    pub options: Vec<ProposeForkOptionParam>,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct ResolveForkParams {
    pub fork_id: String,
    pub chosen_option_id: String,
    pub reason: Option<String>,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct EscalateParams {
    pub fork_id: String,
    pub description: String,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct DispatchWorkerParams {
    pub fork_id: String,
    pub instructions: String,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct WorkerDoneParams {
    pub worker_id: String,
    pub summary: String,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct NotifyChangeParams {
    pub file: String,
}

// ── Tool implementations ──────────────────────────────────────────────────────

#[tool_router]
impl HayaiMcpServer {
    #[tool(
        name = "get_context",
        description = "Returns current act, active quest, pending forks, and recently touched files. Call this at the start of every session to know where you left off."
    )]
    async fn get_context(&self, Parameters(_): Parameters<EmptyParams>) -> Json<serde_json::Value> {
        let ctx = self.store.context.read().await;
        Json(serde_json::to_value(&*ctx).unwrap_or_default())
    }

    #[tool(
        name = "get_tree",
        description = "Returns the full skill tree: acts, quests, forks, and workers."
    )]
    async fn get_tree(&self, Parameters(_): Parameters<EmptyParams>) -> Json<serde_json::Value> {
        let tree = self.store.tree.read().await;
        Json(serde_json::to_value(&*tree).unwrap_or_default())
    }

    #[tool(
        name = "get_quest",
        description = "Returns a quest and its forks by quest ID."
    )]
    async fn get_quest(
        &self,
        Parameters(p): Parameters<GetQuestParams>,
    ) -> Json<serde_json::Value> {
        let tree = self.store.tree.read().await;
        match tree.quests.get(&p.quest_id) {
            Some(quest) => {
                let forks: Vec<_> = quest
                    .fork_ids
                    .iter()
                    .filter_map(|fid| tree.forks.get(fid))
                    .collect();
                Json(serde_json::json!({ "quest": quest, "forks": forks }))
            }
            None => Json(serde_json::json!({ "error": "quest not found" })),
        }
    }

    #[tool(
        name = "propose_fork",
        description = "Add a decision point (fork) to a quest. Use this when you and the user are discussing an architectural choice that should be tracked."
    )]
    async fn propose_fork(
        &self,
        Parameters(p): Parameters<ProposeForkParams>,
    ) -> Json<serde_json::Value> {
        let fork_id = Uuid::new_v4().to_string();
        let fork = Fork {
            id: fork_id.clone(),
            quest_id: p.quest_id.clone(),
            question: p.question,
            options: p
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
            let mut tree = self.store.tree.write().await;
            if let Some(quest) = tree.quests.get_mut(&p.quest_id) {
                quest.fork_ids.push(fork_id.clone());
            }
            tree.forks.insert(fork_id.clone(), fork);
        }

        let _ = self
            .store
            .append_log(StateEvent::ForkProposed {
                fork_id: fork_id.clone(),
                quest_id: p.quest_id,
            })
            .await;

        {
            let mut ctx = self.store.context.write().await;
            if !ctx.pending_fork_ids.contains(&fork_id) {
                ctx.pending_fork_ids.push(fork_id.clone());
            }
        }

        let _ = self.store.save_tree().await;
        let _ = self.store.save_context().await;

        Json(serde_json::json!({ "fork_id": fork_id }))
    }

    #[tool(
        name = "resolve_fork",
        description = "Record a fork decision. Call this after the user (or Ollama) has chosen an option."
    )]
    async fn resolve_fork(
        &self,
        Parameters(p): Parameters<ResolveForkParams>,
    ) -> Json<serde_json::Value> {
        {
            let mut tree = self.store.tree.write().await;
            match tree.forks.get_mut(&p.fork_id) {
                Some(fork) => {
                    fork.status = ForkStatus::Resolved;
                    fork.chosen_option_id = Some(p.chosen_option_id.clone());
                    fork.reason = p.reason.clone();
                    fork.resolved_at = Some(Utc::now());
                }
                None => return Json(serde_json::json!({ "error": "fork not found" })),
            }
        }

        let _ = self
            .store
            .append_log(StateEvent::ForkResolved {
                fork_id: p.fork_id.clone(),
                option_id: p.chosen_option_id,
                reason: p.reason.unwrap_or_default(),
            })
            .await;

        {
            let mut ctx = self.store.context.write().await;
            ctx.pending_fork_ids.retain(|id| id != &p.fork_id);
            ctx.escalated_fork_ids.retain(|id| id != &p.fork_id);
        }

        let _ = self.store.save_tree().await;
        let _ = self.store.save_context().await;

        Json(serde_json::json!({ "ok": true }))
    }

    #[tool(
        name = "escalate",
        description = "Flag a fork as needing human input. Use this when the background orchestrator cannot confidently choose an option."
    )]
    async fn escalate(
        &self,
        Parameters(p): Parameters<EscalateParams>,
    ) -> Json<serde_json::Value> {
        {
            let mut tree = self.store.tree.write().await;
            match tree.forks.get_mut(&p.fork_id) {
                Some(fork) => fork.status = ForkStatus::Escalated,
                None => return Json(serde_json::json!({ "error": "fork not found" })),
            }
        }

        let _ = self
            .store
            .append_log(StateEvent::ForkEscalated {
                fork_id: p.fork_id.clone(),
                description: p.description.clone(),
            })
            .await;

        {
            let mut ctx = self.store.context.write().await;
            ctx.pending_fork_ids.retain(|id| id != &p.fork_id);
            if !ctx.escalated_fork_ids.contains(&p.fork_id) {
                ctx.escalated_fork_ids.push(p.fork_id.clone());
            }
            ctx.open_questions.push(p.description);
        }

        let _ = self.store.save_tree().await;
        let _ = self.store.save_context().await;

        Json(serde_json::json!({ "ok": true }))
    }

    #[tool(
        name = "get_pending_escalations",
        description = "Returns all forks currently waiting for human input."
    )]
    async fn get_pending_escalations(
        &self,
        Parameters(_): Parameters<EmptyParams>,
    ) -> Json<serde_json::Value> {
        let tree = self.store.tree.read().await;
        let escalated: Vec<_> = tree
            .forks
            .values()
            .filter(|f| f.status == ForkStatus::Escalated)
            .collect();
        Json(serde_json::json!({ "escalations": escalated }))
    }

    #[tool(
        name = "dispatch_worker",
        description = "Record that a worker has been dispatched to implement a fork. Returns a worker_id to pass to worker_done when complete."
    )]
    async fn dispatch_worker(
        &self,
        Parameters(p): Parameters<DispatchWorkerParams>,
    ) -> Json<serde_json::Value> {
        let worker_id = Uuid::new_v4().to_string();
        let worker = Worker {
            id: worker_id.clone(),
            fork_id: p.fork_id.clone(),
            instructions: p.instructions,
            status: WorkerStatus::Running,
            summary: None,
            created_at: Utc::now(),
            finished_at: None,
        };

        {
            let mut tree = self.store.tree.write().await;
            if let Some(fork) = tree.forks.get_mut(&p.fork_id) {
                fork.worker_id = Some(worker_id.clone());
            }
            tree.workers.insert(worker_id.clone(), worker);
        }

        let _ = self
            .store
            .append_log(StateEvent::WorkerDispatched {
                worker_id: worker_id.clone(),
                fork_id: p.fork_id,
            })
            .await;

        let _ = self.store.save_tree().await;

        Json(serde_json::json!({ "worker_id": worker_id }))
    }

    #[tool(
        name = "worker_done",
        description = "Mark a worker as complete. Automatically marks the parent fork resolved and checks if the quest is fully complete."
    )]
    async fn worker_done(
        &self,
        Parameters(p): Parameters<WorkerDoneParams>,
    ) -> Json<serde_json::Value> {
        let fork_id;
        let quest_id;

        {
            let mut tree = self.store.tree.write().await;
            match tree.workers.get_mut(&p.worker_id) {
                Some(worker) => {
                    worker.status = WorkerStatus::Done;
                    worker.summary = Some(p.summary.clone());
                    worker.finished_at = Some(Utc::now());
                    fork_id = worker.fork_id.clone();
                }
                None => return Json(serde_json::json!({ "error": "worker not found" })),
            }

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

        let _ = self
            .store
            .append_log(StateEvent::WorkerDone {
                worker_id: p.worker_id,
                summary: p.summary,
            })
            .await;

        let _ = self.store.save_tree().await;
        rebuild_context(&self.store).await;

        Json(serde_json::json!({ "ok": true, "quest_id": quest_id }))
    }

    #[tool(
        name = "notify_change",
        description = "Notify Hayai that a file was edited. Called automatically by the PostToolUse hook. Runs the Ollama relevance filter."
    )]
    async fn notify_change(
        &self,
        Parameters(p): Parameters<NotifyChangeParams>,
    ) -> Json<serde_json::Value> {
        let _ = self
            .store
            .append_log(StateEvent::FileChanged {
                file: p.file.clone(),
            })
            .await;

        {
            let mut ctx = self.store.context.write().await;
            ctx.recently_touched_files.retain(|f| f != &p.file);
            ctx.recently_touched_files.insert(0, p.file.clone());
            ctx.recently_touched_files.truncate(10);
        }

        let _ = self.store.save_context().await;

        Json(serde_json::json!({ "ok": true, "file": p.file }))
    }
}

// ── ServerHandler impl ────────────────────────────────────────────────────────

impl ServerHandler for HayaiMcpServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("hayai", "0.1.0"))
            .with_instructions(
                "Hayai is the skill tree orchestrator for this project. \
                 Call get_context at the start of every session. \
                 Use propose_fork to track architectural decisions as you make them. \
                 Use resolve_fork after a decision is made. \
                 Use dispatch_worker + worker_done to track implementation work.",
            )
    }
}

// ── helpers ───────────────────────────────────────────────────────────────────

async fn rebuild_context(store: &Store) {
    let tree = store.tree.read().await;

    let current_act = tree
        .acts
        .iter()
        .find(|a| a.status == ActStatus::Active)
        .map(|a| a.number)
        .unwrap_or(1);

    let active_quest_id = tree
        .quests
        .values()
        .find(|q| q.act == current_act && q.status == QuestStatus::InProgress)
        .map(|q| q.id.clone());

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
