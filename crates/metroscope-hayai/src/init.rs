/// Bootstrap the skill tree from an existing Metroscope index.
///
/// Reads `.metro/index.json`, converts the indexer-generated quests into
/// Act 1 TreeQuests, and writes the initial `tree.json` + `context.json`.
use std::path::Path;

use anyhow::{Context, Result};
use chrono::Utc;
use uuid::Uuid;

use crate::{
    store::Store,
    types::{Act, ActStatus, QuestStatus, StateEvent, TreeQuest},
};

/// Minimal subset of the Metroscope index we need for bootstrapping.
#[derive(serde::Deserialize)]
struct MetroIndex {
    system_summary: String,
    quests: Vec<MetroQuest>,
}

#[derive(serde::Deserialize)]
struct MetroQuest {
    title: String,
    component: String,
    why: String,
    difficulty: MetroDifficulty,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "snake_case")]
enum MetroDifficulty {
    Easy,
    Medium,
    Hard,
}

impl MetroDifficulty {
    fn as_str(&self) -> &'static str {
        match self {
            MetroDifficulty::Easy => "easy",
            MetroDifficulty::Medium => "medium",
            MetroDifficulty::Hard => "hard",
        }
    }
}

pub async fn run(index_path: &Path, metro_dir: &Path) -> Result<()> {
    let raw = tokio::fs::read(index_path)
        .await
        .with_context(|| format!("Could not read {:?} — run the indexer first", index_path))?;

    let index: MetroIndex = serde_json::from_slice(&raw).context("Failed to parse index.json")?;

    let store = Store::load(metro_dir).await?;

    // Check if tree already has quests — don't overwrite unless empty
    {
        let tree = store.tree.read().await;
        if !tree.quests.is_empty() {
            anyhow::bail!(
                "tree.json already has {} quests. Use --force to overwrite.",
                tree.quests.len()
            );
        }
    }

    let now = Utc::now();
    let act_number = 1u32;

    // Convert indexer quests → TreeQuests
    let quest_ids: Vec<String> = index
        .quests
        .iter()
        .map(|_| Uuid::new_v4().to_string())
        .collect();

    {
        let mut tree = store.tree.write().await;

        for (id, metro_quest) in quest_ids.iter().zip(index.quests.iter()) {
            let description = format!(
                "{}\n\nComponent: {} | Difficulty: {}",
                metro_quest.why,
                metro_quest.component,
                metro_quest.difficulty.as_str()
            );

            let quest = TreeQuest {
                id: id.clone(),
                title: metro_quest.title.clone(),
                description,
                act: act_number,
                status: QuestStatus::Available,
                depends_on: vec![],
                unlocks: vec![],
                fork_ids: vec![],
                created_at: now,
            };

            tree.quests.insert(id.clone(), quest);
        }

        // Create Act 1
        tree.acts.push(Act {
            number: act_number,
            title: format!("Act 1 — {}", first_sentence(&index.system_summary)),
            status: ActStatus::Active,
            quest_ids: quest_ids.clone(),
        });
    }

    store.save_tree().await?;

    // Update context
    {
        let mut ctx = store.context.write().await;
        ctx.current_act = act_number;
        ctx.active_quest_id = quest_ids.first().cloned();
    }
    store.save_context().await?;

    store.append_log(StateEvent::ReIndexed).await?;

    println!(
        "Bootstrapped Act 1 with {} quests from the Metroscope index.",
        quest_ids.len()
    );
    println!("System summary: {}", first_sentence(&index.system_summary));
    println!("\nQuests:");
    for (i, id) in quest_ids.iter().enumerate() {
        let tree = store.tree.read().await;
        if let Some(q) = tree.quests.get(id) {
            println!("  {}. {} [{}]", i + 1, q.title, id);
        }
    }
    println!("\nRun `hayai serve` to start the MCP server.");

    Ok(())
}

fn first_sentence(s: &str) -> &str {
    s.find(". ")
        .or_else(|| s.find(".\n"))
        .map(|i| &s[..i + 1])
        .unwrap_or(s)
        .trim()
}
