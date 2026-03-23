mod parser;
mod llm;
mod color;
mod serena;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use clap::Parser as ClapParser;
use metroscope_types::{Connection, ConnectionKind, Index, Line, Station};
use walkdir::WalkDir;

use parser::{ParsedFile, LanguageParser};
use parser::rust::RustParser;
use llm::LlmBackend;

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
        /// Anthropic API key. If omitted, the `claude` CLI is used instead.
        #[arg(long, env = "ANTHROPIC_API_KEY")]
        api_key: Option<String>,
        /// Path to the Serena repo for LSP-accurate call graph enrichment (optional).
        #[arg(long, env = "SERENA_DIR")]
        serena_dir: Option<PathBuf>,
        /// Override the function summary prompt prefix.
        #[arg(long)]
        function_prompt: Option<String>,
        /// Override the file/module summary prompt prefix.
        #[arg(long)]
        file_prompt: Option<String>,
        /// Override the system summary prompt prefix.
        #[arg(long)]
        system_prompt: Option<String>,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Index { path, api_key, serena_dir, function_prompt, file_prompt, system_prompt } => {
            let backend = match api_key {
                Some(key) => LlmBackend::Api { key },
                None => {
                    println!("No API key provided — using `claude` CLI");
                    LlmBackend::Cli
                }
            };
            let prompts = llm::PromptOverrides {
                function_prompt,
                file_prompt,
                system_prompt,
            };
            index_project(&path, &backend, serena_dir.as_deref(), &prompts).await
        }
    }
}

async fn index_project(
    project_root: &Path,
    backend: &LlmBackend,
    serena_dir: Option<&Path>,
    prompts: &llm::PromptOverrides,
) -> Result<()> {
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
    let summaries = llm::generate_summaries(&parsed_files, backend, prompts).await?;

    // Build initial stations (outgoing calls from tree-sitter)
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

        lines.insert(pf.file_id.clone(), Line {
            id: pf.file_id.clone(),
            name: pf.file_name.clone(),
            color: line_color,
            summary: line_summary,
            stations: station_ids,
        });

        for func in &pf.functions {
            let summary = summaries
                .function_summaries
                .get(&func.id)
                .cloned()
                .unwrap_or_default();
            let explanation = summaries
                .function_explanations
                .get(&func.id)
                .cloned()
                .unwrap_or_default();

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

            stations.insert(func.id.clone(), Station {
                id: func.id.clone(),
                name: func.name.clone(),
                kind: func.kind.clone(),
                location: func.location.clone(),
                summary,
                explanation,
                connections,
                line_id: pf.file_id.clone(),
            });
        }
    }

    // Optionally enrich with Serena (CalledBy connections)
    if let Some(serena_dir) = serena_dir {
        let serena_dir = serena_dir
            .canonicalize()
            .context("Failed to canonicalize --serena-dir")?;

        println!("Enriching with Serena (LSP call graph)...");
        let all_ids: Vec<String> = stations.keys().cloned().collect();

        match serena::enrich(&project_root, &all_ids, &serena_dir).await {
            Ok(serena_index) => {
                let mut added = 0usize;
                for (station_id, callers) in serena_index.callers {
                    if let Some(station) = stations.get_mut(&station_id) {
                        for caller in callers {
                            // Resolve caller name_path to a station id if possible
                            // name_path is like "/fn_name" — match by name within the caller's file
                            let caller_name = caller.name_path.trim_start_matches('/');
                            let caller_id = format!("{}::{}", caller.relative_path, caller_name);
                            station.connections.push(Connection {
                                to: caller_id,
                                kind: ConnectionKind::CalledBy,
                            });
                            added += 1;
                        }
                    }
                }
                println!("  Added {added} CalledBy connections from Serena");
            }
            Err(e) => {
                eprintln!("  Warning: Serena enrichment failed: {e}");
                eprintln!("  Continuing with tree-sitter call graph only");
            }
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

    let index_dir = project_root.join(".metroscope");
    std::fs::create_dir_all(&index_dir)?;
    let index_path = index_dir.join("index.json");
    std::fs::write(&index_path, serde_json::to_string_pretty(&index)?)?;

    println!("Index written to {}", index_path.display());
    println!("  {} stations, {} lines", index.stations.len(), index.lines.len());

    Ok(())
}

fn is_ignored(path: &Path) -> bool {
    path.components().any(|c| {
        let s = c.as_os_str().to_string_lossy();
        s == "target" || s == ".git" || s == ".metroscope"
    })
}
