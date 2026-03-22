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
use metroscope_types::{Index, Station};
use serde::{Deserialize, Serialize};
use tower_http::cors::CorsLayer;

#[derive(ClapParser)]
#[command(name = "metroscope-server")]
struct Cli {
    /// Path to project root (must contain .metroscope/index.json)
    #[arg(long)]
    index_path: PathBuf,
    /// Port to listen on
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
        .route("/station/{id}", get(handle_station))
        .layer(CorsLayer::permissive())
        .with_state(state);

    let addr = format!("127.0.0.1:{}", cli.port);
    println!("Listening on http://{addr}");

    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

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
    let response = map::build_map_response(&index, station);
    Json(response)
}

#[derive(Deserialize)]
struct StationPath {
    id: String,
}

#[derive(Serialize)]
struct StationResponse {
    station: Option<Station>,
}

async fn handle_station(
    State(index): State<AppState>,
    Path(params): Path<StationPath>,
) -> impl IntoResponse {
    // The id in the URL uses '/' separators; axum captures the full path segment
    let station = index.stations.get(&params.id).cloned();
    Json(StationResponse { station })
}
