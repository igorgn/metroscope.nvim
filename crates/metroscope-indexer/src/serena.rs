/// Serena MCP client — enriches the index with LSP-accurate call graph data.
///
/// Spawns `python -m serena.cli start-mcp-server --project <path> --transport stdio`
/// and calls:
///   - `find_referencing_symbols` per function  → CalledBy connections
///   - `get_symbols_overview` per file          → struct/trait/enum kinds
use std::collections::HashMap;
use std::path::Path;

use anyhow::{Context, Result};
use rmcp::{
    ServiceExt,
    model::CallToolRequestParams,
    transport::TokioChildProcess,
};
use serde_json::{Value, json};
use tokio::process::Command;

/// Caller info returned by find_referencing_symbols
#[derive(Debug)]
pub struct CallerRef {
    /// The name_path of the calling symbol, e.g. "/index_project"
    pub name_path: String,
    /// File where the caller lives
    pub relative_path: String,
}

/// All Serena-derived enrichment for a project
pub struct SerenaIndex {
    /// function id → list of callers
    pub callers: HashMap<String, Vec<CallerRef>>,
}

pub async fn enrich(
    project_root: &Path,
    function_ids: &[String],   // "rel/path/to/file.rs::fn_name"
    serena_dir: &Path,         // path to serena repo (for `python -m serena.cli`)
) -> Result<SerenaIndex> {
    let project_str = project_root.to_string_lossy();

    // Spawn Serena MCP server over stdio
    let mut cmd = Command::new("python");
    cmd.arg("-m")
        .arg("serena.cli")
        .arg("start-mcp-server")
        .arg("--project")
        .arg(project_str.as_ref())
        .arg("--transport")
        .arg("stdio")
        .arg("--context")
        .arg("no-context")   // skip onboarding prompts
        .current_dir(serena_dir)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit());

    let transport = TokioChildProcess::new(cmd)
        .context("Failed to spawn Serena MCP server")?;

    let client = ().serve(transport).await
        .context("Failed to initialize MCP session with Serena")?;

    let mut callers: HashMap<String, Vec<CallerRef>> = HashMap::new();

    for id in function_ids {
        // id format: "crates/foo/src/bar.rs::fn_name"
        let (rel_path, fn_name) = match id.split_once("::") {
            Some(pair) => pair,
            None => continue,
        };

        let args: rmcp::model::JsonObject = serde_json::from_value(json!({
            "name_path": fn_name,
            "relative_path": rel_path,
            "include_kinds": [6, 12]   // Method=6, Function=12
        })).unwrap();

        let result = client.call_tool(
            CallToolRequestParams::new("find_referencing_symbols")
                .with_arguments(args)
        ).await;

        let result = match result {
            Ok(r) => r,
            Err(e) => {
                eprintln!("  Serena: find_referencing_symbols failed for {id}: {e}");
                continue;
            }
        };

        let text = match result.content.first().and_then(|c| c.as_text()) {
            Some(t) => t.text.clone(),
            None => continue,
        };

        if let Ok(refs) = parse_referencing_symbols(&text) {
            if !refs.is_empty() {
                callers.insert(id.clone(), refs);
            }
        }
    }

    // Graceful shutdown — ignore errors (process may have already exited)
    drop(client);

    Ok(SerenaIndex { callers })
}

/// Parse find_referencing_symbols response.
///
/// Response shape:
/// {
///   "src/other.rs": {
///     "Function": [{ "name_path": "/caller", "relative_path": "src/other.rs", ... }]
///   }
/// }
fn parse_referencing_symbols(text: &str) -> Result<Vec<CallerRef>> {
    let v: Value = serde_json::from_str(text).context("parse find_referencing_symbols")?;

    let mut refs = Vec::new();

    if let Value::Object(by_file) = &v {
        for (file_path, by_kind) in by_file {
            if let Value::Object(kinds) = by_kind {
                for (_kind, symbols) in kinds {
                    if let Value::Array(syms) = symbols {
                        for sym in syms {
                            if let Some(name_path) = sym["name_path"].as_str() {
                                refs.push(CallerRef {
                                    name_path: name_path.to_string(),
                                    relative_path: file_path.clone(),
                                });
                            }
                        }
                    }
                }
            }
        }
    }

    Ok(refs)
}
