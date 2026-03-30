mod map;
mod export;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use axum::{
    body::Body,
    extract::{Path, Query, State},
    http::{Request, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use clap::Parser as ClapParser;
use metroscope_types::{ConnectionKind, Index};
use notify::{Config, Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;
use tower_http::cors::CorsLayer;

#[derive(ClapParser)]
#[command(name = "metroscope-server")]
struct Cli {
    #[arg(long)]
    index_path: PathBuf,
    #[arg(long, default_value = "7777")]
    port: u16,
    /// Optional bearer token. When set, every request must include
    /// `Authorization: Bearer <token>` or a 401 is returned.
    #[arg(long)]
    auth_token: Option<String>,
}

type AppState = Arc<RwLock<Index>>;

fn load_index(index_file: &PathBuf) -> Result<Index> {
    let json = std::fs::read_to_string(index_file)
        .with_context(|| format!("Cannot read {}", index_file.display()))?;
    serde_json::from_str(&json).context("Failed to parse index.json")
}

async fn require_bearer(
    State(expected): State<Arc<Option<String>>>,
    req: Request<Body>,
    next: Next,
) -> Response {
    if let Some(token) = expected.as_ref() {
        let provided = req
            .headers()
            .get(axum::http::header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer "));
        if provided != Some(token.as_str()) {
            return (StatusCode::UNAUTHORIZED, "Unauthorized").into_response();
        }
    }
    next.run(req).await
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    let index_file = cli.index_path.join(".metroscope/index.json");
    let index = load_index(&index_file)?;

    println!(
        "Loaded index: {} stations, {} lines",
        index.stations.len(),
        index.lines.len()
    );
    println!("System: {}", index.system_summary);

    let state: AppState = Arc::new(RwLock::new(index));

    // Spawn file watcher that hot-reloads index.json on change.
    {
        let state = Arc::clone(&state);
        let index_file = index_file.clone();
        tokio::spawn(async move {
            watch_index(state, index_file).await;
        });
    }
    let state: AppState = Arc::new(index);
    let state: AppState = Arc::new(index);
    let auth_state: Arc<Option<String>> = Arc::new(cli.auth_token.clone());

    if cli.auth_token.is_some() {
        println!("Auth: bearer token required");
    } else {
        println!("Auth: none (consider --auth-token for security)");
    }

    let app = Router::new()
        .route("/map", get(handle_map))
        .route("/module-map", get(handle_module_map))
        .route("/station/*id", get(handle_station))
        .route("/connections", get(handle_connections))
        .route("/export/svg", get(handle_export_svg))
        .route("/quests", get(handle_quests))
        .layer(middleware::from_fn_with_state(
            auth_state,
            require_bearer,
        ))
        .layer(CorsLayer::permissive())
        .with_state(state);

    let addr = format!("127.0.0.1:{}", cli.port);
    println!("Listening on http://{addr}");

    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

/// Watches index_file for modifications and reloads the index in-place.
async fn watch_index(state: AppState, index_file: PathBuf) {
    let (tx, mut rx) = tokio::sync::mpsc::channel::<()>(1);

    // notify uses a std channel; bridge to tokio via a spawned thread.
    let index_file_clone = index_file.clone();
    let mut watcher: RecommendedWatcher = match notify::Watcher::new(
        move |res: notify::Result<Event>| {
            if let Ok(event) = res {
                if matches!(
                    event.kind,
                    EventKind::Modify(_) | EventKind::Create(_)
                ) {
                    // Ignore send errors (receiver may have been dropped on shutdown).
                    let _ = tx.try_send(());
                }
            }
        },
        Config::default().with_poll_interval(Duration::from_secs(1)),
    ) {
        Ok(w) => w,
        Err(e) => {
            eprintln!("[metroscope] Failed to create file watcher: {e}");
            return;
        }
    };

    // Watch the parent directory so we catch atomic writes (rename-into-place).
    let watch_dir = index_file_clone
        .parent()
        .expect("index file must have a parent directory");

    if let Err(e) = watcher.watch(watch_dir, RecursiveMode::NonRecursive) {
        eprintln!("[metroscope] Failed to watch {}: {e}", watch_dir.display());
        return;
    }

    println!(
        "[metroscope] Watching {} for changes",
        index_file.display()
    );

    while rx.recv().await.is_some() {
        // Drain any extra notifications that arrived while we were reloading.
        while rx.try_recv().is_ok() {}

        // Small delay to let the writer finish flushing.
        tokio::time::sleep(Duration::from_millis(100)).await;

        match load_index(&index_file) {
            Ok(new_index) => {
                let stations = new_index.stations.len();
                let lines = new_index.lines.len();
                *state.write().await = new_index;
                println!("[metroscope] Index reloaded: {stations} stations, {lines} lines");
            }
            Err(e) => {
                eprintln!("[metroscope] Failed to reload index: {e}");
            }
        }
    }
}

// ── /map ─────────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct MapParams {
    file: Option<String>,
    line: Option<u32>,
    /// If set, only show lines belonging to this crate id (e.g. "metroscope-indexer")
    #[serde(rename = "crate")]
    crate_filter: Option<String>,
}

async fn handle_map(
    State(index): State<AppState>,
    Query(params): Query<MapParams>,
) -> impl IntoResponse {
    let index = index.read().await;
    let station = match (&params.file, params.line) {
        (Some(f), Some(l)) => index.station_at(f, l),
        _ => None,
    };
    Json(map::build_map_response(&index, station, params.crate_filter.as_deref()))
}

// ── /station/:id ─────────────────────────────────────────────────────────────

#[derive(Serialize)]
struct ResolvedConnection {
    id: String,
    name: String,
    summary: String,
    file: String,
    line_start: u32,
}

#[derive(Serialize)]
struct StationDetail {
    id: String,
    name: String,
    kind: String,
    file: String,
    line_start: u32,
    line_end: u32,
    summary: String,
    explanation: String,
    calls: Vec<ResolvedConnection>,
    called_by: Vec<ResolvedConnection>,
    line_summary: String,
}

async fn handle_station(
    State(index): State<AppState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let index = index.read().await;
    let station = match index.stations.get(&id) {
        Some(s) => s,
        None => return Json(serde_json::json!({ "error": "not found", "id": id })),
    };

    let mut calls = Vec::new();
    let mut called_by = Vec::new();

    for conn in &station.connections {
        let resolved = if let Some(target) = index.stations.get(&conn.to) {
            ResolvedConnection {
                id: target.id.clone(),
                name: target.name.clone(),
                summary: target.summary.clone(),
                file: target.location.file.clone(),
                line_start: target.location.line_start,
            }
        } else {
            ResolvedConnection {
                id: conn.to.clone(),
                name: conn.to.split("::").last().unwrap_or(&conn.to).to_string(),
                summary: String::new(),
                file: String::new(),
                line_start: 0,
            }
        };

        // Only include connections that resolved to a known station
        if resolved.file.is_empty() { continue; }

        match conn.kind {
            ConnectionKind::Calls => calls.push(resolved),
            ConnectionKind::CalledBy => called_by.push(resolved),
        }
    }

    let line_summary = index
        .lines
        .get(&station.line_id)
        .map(|l| l.summary.as_str())
        .unwrap_or("")
        .to_string();

    Json(serde_json::to_value(StationDetail {
        id: station.id.clone(),
        name: station.name.clone(),
        kind: format!("{:?}", station.kind).to_lowercase(),
        file: station.location.file.clone(),
        line_start: station.location.line_start,
        line_end: station.location.line_end,
        summary: station.summary.clone(),
        explanation: station.explanation.clone(),
        calls,
        called_by,
        line_summary,
    }).unwrap())
}

// ── /connections ─────────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct ConnectionsParams {
    file: String,
}

async fn handle_connections(
    State(index): State<AppState>,
    Query(params): Query<ConnectionsParams>,
) -> impl IntoResponse {
    let index = index.read().await;
    Json(map::build_file_connections(&index, &params.file))
}

// ── /module-map ───────────────────────────────────────────────────────────────

async fn handle_module_map(State(index): State<AppState>) -> impl IntoResponse {
    let index = index.read().await;
    Json(map::build_module_map(&index))
}

// ── /export/svg ───────────────────────────────────────────────────────────────

async fn handle_export_svg(State(index): State<AppState>) -> impl IntoResponse {
    let index = index.read().await;
    let svg = export::render_svg(&index);
    (
        [(axum::http::header::CONTENT_TYPE, "image/svg+xml; charset=utf-8")],
        svg,
    )
}

// ── /quests ───────────────────────────────────────────────────────────────────

async fn handle_quests(State(index): State<AppState>) -> impl IntoResponse {
    let index = index.read().await;
    Json(index.quests.clone())
}
