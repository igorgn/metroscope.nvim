mod mcp;
mod mcp_server;
mod ollama;
mod store;
mod types;

use std::{net::SocketAddr, path::PathBuf, sync::Arc};

use anyhow::Result;
use clap::{Parser, Subcommand};
use rmcp::transport::streamable_http_server::{
    StreamableHttpServerConfig, StreamableHttpService,
    session::local::LocalSessionManager,
};
use tower_http::cors::CorsLayer;
use tracing::info;

use crate::{mcp::AppState, mcp_server::HayaiMcpServer, ollama::OllamaClient, store::Store};

#[derive(Parser)]
#[command(name = "hayai", about = "Metroscope skill tree orchestrator")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Start the MCP server
    Serve {
        /// Path to the .metro directory
        #[arg(long, default_value = ".metro")]
        metro_dir: PathBuf,

        /// Port to listen on
        #[arg(long, default_value = "7778")]
        port: u16,

        /// Ollama base URL
        #[arg(long, default_value = "http://localhost:11434")]
        ollama_url: String,

        /// Ollama model to use for background orchestration
        #[arg(long, default_value = "qwen2.5-coder:14b")]
        ollama_model: String,
    },

    /// Notify the server of a file change (called by the PostToolUse hook)
    NotifyChange {
        /// Changed file path
        #[arg(long)]
        file: String,

        /// Hayai server URL
        #[arg(long, default_value = "http://localhost:7778")]
        server: String,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();

    let cli = Cli::parse();

    match cli.command {
        Command::Serve {
            metro_dir,
            port,
            ollama_url,
            ollama_model,
        } => serve(metro_dir, port, ollama_url, ollama_model).await,
        Command::NotifyChange { file, server } => notify_change(file, server).await,
    }
}

async fn serve(
    metro_dir: PathBuf,
    port: u16,
    ollama_url: String,
    ollama_model: String,
) -> Result<()> {
    info!("Loading store from {:?}", metro_dir);
    let store = Arc::new(Store::load(&metro_dir).await?);

    let ollama = Arc::new(OllamaClient::new(ollama_url, ollama_model));
    info!("Ollama model: {}", ollama.model);

    // Plain HTTP routes (used by the hook CLI command)
    let app_state = Arc::new(AppState {
        store: store.clone(),
        ollama,
    });
    let http_routes = mcp::router(app_state);

    // Proper MCP server over Streamable HTTP (used by Claude Code via .mcp.json)
    let mcp_store = store.clone();
    let mcp_service: StreamableHttpService<HayaiMcpServer, LocalSessionManager> = StreamableHttpService::new(
        move || {
            Ok(HayaiMcpServer {
                store: mcp_store.clone(),
            })
        },
        Default::default(),
        StreamableHttpServerConfig::default(),
    );

    let app = axum::Router::new()
        .nest_service("/mcp", mcp_service)
        .merge(http_routes)
        .layer(CorsLayer::permissive());

    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    info!("Hayai listening on http://{addr}");
    info!("  MCP endpoint: http://{addr}/mcp  (add to .mcp.json)");
    info!("  Hook endpoint: http://{addr}/notify-change");

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

async fn notify_change(file: String, server: String) -> Result<()> {
    let client = reqwest::Client::new();
    let url = format!("{server}/notify-change");
    client
        .post(&url)
        .json(&serde_json::json!({ "file": file }))
        .send()
        .await?;
    Ok(())
}
