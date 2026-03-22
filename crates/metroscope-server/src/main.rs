mod map;

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use axum::{
    extract::{Path, Query, State},
    response::IntoResponse,
    routing::get,
    Json, Router,
};
use clap::Parser as ClapParser;
use metroscope_types::{ConnectionKind, Index};
use serde::{Deserialize, Serialize};
use tower_http::cors::CorsLayer;

#[derive(ClapParser)]
#[command(name = "metroscope-server")]
struct Cli {
    #[arg(long)]
    index_path: PathBuf,
    #[arg(long, default_value = "7777")]
    port: u16,
}

type AppState = Arc<Index>;

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    let index_file = cli.index_path.join(".metroscope/index.json");
    let json = std::fs::read_to_string(&index_file)
        .with_context(|| format!("Cannot read {}", index_file.display()))?;
    let index: Index = serde_json::from_str(&json).context("Failed to parse index.json")?;

    println!(
        "Loaded index: {} stations, {} lines",
        index.stations.len(),
        index.lines.len()
    );
    println!("System: {}", index.system_summary);

    let state: AppState = Arc::new(index);

    let app = Router::new()
        .route("/map", get(handle_map))
        .route("/station/*id", get(handle_station))
        .route("/connections", get(handle_connections))
        .layer(CorsLayer::permissive())
        .with_state(state);

    let addr = format!("127.0.0.1:{}", cli.port);
    println!("Listening on http://{addr}");

    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

// ── /map ─────────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct MapParams {
    file: String,
    line: u32,
}

async fn handle_map(
    State(index): State<AppState>,
    Query(params): Query<MapParams>,
) -> impl IntoResponse {
    let station = index.station_at(&params.file, params.line);
    Json(map::build_map_response(&index, station))
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
    calls: Vec<ResolvedConnection>,
    called_by: Vec<ResolvedConnection>,
    line_summary: String,
}

async fn handle_station(
    State(index): State<AppState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
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
    Json(map::build_file_connections(&index, &params.file))
}
