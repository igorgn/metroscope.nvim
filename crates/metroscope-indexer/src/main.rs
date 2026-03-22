mod parser;
mod llm;
mod color;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use clap::Parser as ClapParser;
use metroscope_types::{Connection, ConnectionKind, Index, Line, Station};
use walkdir::WalkDir;

use parser::{ParsedFile, LanguageParser};
use parser::rust::RustParser;

#[derive(ClapParser)]
#[command(name = "metroscope-indexer")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(clap::Subcommand)]
enum Command {
    /// Index a project directory
    Index {
        /// Path to the project root
        path: PathBuf,
        /// Anthropic API key
        #[arg(long, env = "ANTHROPIC_API_KEY")]
        api_key: String,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Index { path, api_key } => index_project(&path, &api_key).await,
    }
}

async fn index_project(project_root: &Path, api_key: &str) -> Result<()> {
    let project_root = project_root
        .canonicalize()
        .context("Failed to canonicalize project root")?;

    println!("Indexing {}", project_root.display());

    // Collect all Rust files
    let rust_files: Vec<PathBuf> = WalkDir::new(&project_root)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| {
            e.file_type().is_file()
                && e.path().extension().map(|x| x == "rs").unwrap_or(false)
                && !is_ignored(e.path())
        })
        .map(|e| e.path().to_path_buf())
        .collect();

    println!("Found {} Rust files", rust_files.len());

    let parser = RustParser::new()?;
    let mut parsed_files: Vec<ParsedFile> = Vec::new();

    for path in &rust_files {
        let source = std::fs::read_to_string(path)?;
        let rel_path = path
            .strip_prefix(&project_root)
            .unwrap()
            .to_string_lossy()
            .replace('\\', "/");

        match parser.parse(&source, &rel_path) {
            Ok(pf) => parsed_files.push(pf),
            Err(e) => eprintln!("  Warning: failed to parse {}: {e}", rel_path),
        }
    }

    let total_fns: usize = parsed_files.iter().map(|f| f.functions.len()).sum();
    println!("Extracted {} functions across {} files", total_fns, parsed_files.len());

    // Generate LLM summaries (batched)
    println!("Generating summaries with Claude...");
    let summaries = llm::generate_summaries(&parsed_files, api_key).await?;

    // Build index
    let mut stations: HashMap<String, Station> = HashMap::new();
    let mut lines: HashMap<String, Line> = HashMap::new();
    let mut entry_points: Vec<String> = Vec::new();

    for pf in &parsed_files {
        let line_color = color::for_file(&pf.file_id);
        let station_ids: Vec<String> = pf.functions.iter().map(|f| f.id.clone()).collect();

        let line_summary = summaries
            .file_summaries
            .get(&pf.file_id)
            .cloned()
            .unwrap_or_default();

        let line = Line {
            id: pf.file_id.clone(),
            name: pf.file_name.clone(),
            color: line_color,
            summary: line_summary,
            stations: station_ids,
        };
        lines.insert(pf.file_id.clone(), line);

        for func in &pf.functions {
            let summary = summaries
                .function_summaries
                .get(&func.id)
                .cloned()
                .unwrap_or_default();

            // Build connections from call graph
            let connections: Vec<Connection> = func
                .calls
                .iter()
                .map(|callee_name| Connection {
                    to: callee_name.clone(),
                    kind: ConnectionKind::Calls,
                })
                .collect();

            if func.name == "main" {
                entry_points.push(func.id.clone());
            }

            let station = Station {
                id: func.id.clone(),
                name: func.name.clone(),
                kind: func.kind.clone(),
                location: func.location.clone(),
                summary,
                connections,
                line_id: pf.file_id.clone(),
            };
            stations.insert(func.id.clone(), station);
        }
    }

    let index = Index {
        project_root: project_root.to_string_lossy().into_owned(),
        created_at: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs(),
        system_summary: summaries.system_summary,
        stations,
        lines,
        entry_points,
    };

    // Write index
    let index_dir = project_root.join(".metroscope");
    std::fs::create_dir_all(&index_dir)?;
    let index_path = index_dir.join("index.json");
    let json = serde_json::to_string_pretty(&index)?;
    std::fs::write(&index_path, json)?;

    println!("Index written to {}", index_path.display());
    println!(
        "  {} stations, {} lines",
        index.stations.len(),
        index.lines.len()
    );

    Ok(())
}

fn is_ignored(path: &Path) -> bool {
    path.components().any(|c| {
        let s = c.as_os_str().to_string_lossy();
        s == "target" || s == ".git" || s == ".metroscope"
    })
}
