use std::path::{Path, PathBuf};

use anyhow::Result;
use chrono::Utc;
use tokio::{
    fs,
    io::AsyncWriteExt,
    sync::RwLock,
};

use crate::types::{Context, LogEntry, StateEvent, Tree};

pub struct Store {
    metro_dir: PathBuf,
    pub tree: RwLock<Tree>,
    pub context: RwLock<Context>,
}

impl Store {
    pub async fn load(metro_dir: impl AsRef<Path>) -> Result<Self> {
        let metro_dir = metro_dir.as_ref().to_path_buf();
        fs::create_dir_all(&metro_dir).await?;

        let tree = load_json(&metro_dir.join("tree.json"))
            .await
            .unwrap_or_default();
        let context = load_json(&metro_dir.join("context.json"))
            .await
            .unwrap_or_default();

        Ok(Self {
            metro_dir,
            tree: RwLock::new(tree),
            context: RwLock::new(context),
        })
    }

    pub async fn save_tree(&self) -> Result<()> {
        let tree = self.tree.read().await;
        save_json(&self.metro_dir.join("tree.json"), &*tree).await
    }

    pub async fn save_context(&self) -> Result<()> {
        let mut ctx = self.context.write().await;
        ctx.updated_at = Some(Utc::now());
        save_json(&self.metro_dir.join("context.json"), &*ctx).await
    }

    pub async fn append_log(&self, event: StateEvent) -> Result<()> {
        let entry = LogEntry { ts: Utc::now(), event };
        let line = serde_json::to_string(&entry)? + "\n";
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.metro_dir.join("state.log"))
            .await?;
        file.write_all(line.as_bytes()).await?;
        Ok(())
    }
}

async fn load_json<T: serde::de::DeserializeOwned>(path: &Path) -> Option<T> {
    let bytes = fs::read(path).await.ok()?;
    serde_json::from_slice(&bytes).ok()
}

async fn save_json<T: serde::Serialize>(path: &Path, value: &T) -> Result<()> {
    let json = serde_json::to_string_pretty(value)?;
    fs::write(path, json).await?;
    Ok(())
}
