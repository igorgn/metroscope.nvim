use std::collections::HashMap;
use std::io::Write;
use std::process::{Command, Stdio};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::parser::ParsedFile;

const API_URL: &str = "https://api.anthropic.com/v1/messages";
const MODEL: &str = "claude-haiku-4-5-20251001";
/// Max functions to summarize in a single API call / CLI invocation
const BATCH_SIZE: usize = 20;

pub enum LlmBackend {
    /// Direct API access with key
    Api { key: String },
    /// Delegate to the `claude` CLI (already authenticated)
    Cli,
}

pub struct Summaries {
    pub function_summaries: HashMap<String, String>,
    pub file_summaries: HashMap<String, String>,
    pub system_summary: String,
}

// ─── API structs ──────────────────────────────────────────────────────────────

#[derive(Serialize)]
struct ApiRequest {
    model: String,
    max_tokens: u32,
    messages: Vec<ApiMessage>,
}

#[derive(Serialize)]
struct ApiMessage {
    role: String,
    content: String,
}

#[derive(Deserialize)]
struct ApiResponse {
    content: Vec<ContentBlock>,
}

#[derive(Deserialize)]
struct ContentBlock {
    text: String,
}

// ─── Backend dispatch ─────────────────────────────────────────────────────────

async fn call_claude(backend: &LlmBackend, prompt: &str) -> Result<String> {
    match backend {
        LlmBackend::Api { key } => call_via_api(key, prompt).await,
        LlmBackend::Cli => call_via_cli(prompt),
    }
}

async fn call_via_api(api_key: &str, prompt: &str) -> Result<String> {
    let client = reqwest::Client::new();
    let req = ApiRequest {
        model: MODEL.to_string(),
        max_tokens: 4096,
        messages: vec![ApiMessage {
            role: "user".to_string(),
            content: prompt.to_string(),
        }],
    };

    let resp = client
        .post(API_URL)
        .header("x-api-key", api_key)
        .header("anthropic-version", "2023-06-01")
        .json(&req)
        .send()
        .await
        .context("Failed to send request to Claude API")?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Claude API error {status}: {body}");
    }

    let parsed: ApiResponse = resp.json().await.context("Failed to parse API response")?;
    Ok(parsed
        .content
        .into_iter()
        .map(|b| b.text)
        .collect::<Vec<_>>()
        .join(""))
}

/// Invoke `claude -p` with the prompt piped to stdin.
fn call_via_cli(prompt: &str) -> Result<String> {
    let mut child = Command::new("claude")
        .arg("--no-session-persistence")
        .arg("-p") // --print: non-interactive, print response to stdout
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .context("Failed to spawn `claude` CLI — is it installed and on PATH?")?;

    child
        .stdin
        .take()
        .unwrap()
        .write_all(prompt.as_bytes())
        .context("Failed to write prompt to claude stdin")?;

    let output = child
        .wait_with_output()
        .context("Failed to wait for claude CLI")?;

    if !output.status.success() {
        anyhow::bail!(
            "`claude` exited with status {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        );
    }

    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

// ─── Public entry point ───────────────────────────────────────────────────────

pub async fn generate_summaries(files: &[ParsedFile], backend: &LlmBackend) -> Result<Summaries> {
    let mut function_summaries: HashMap<String, String> = HashMap::new();
    let mut file_summaries: HashMap<String, String> = HashMap::new();

    // --- Function summaries (batched) ---
    let all_functions: Vec<_> = files.iter().flat_map(|f| f.functions.iter()).collect();

    let batches: Vec<_> = all_functions.chunks(BATCH_SIZE).collect();
    println!(
        "  Summarizing {} functions in {} batches...",
        all_functions.len(),
        batches.len()
    );

    for (i, batch) in batches.iter().enumerate() {
        println!("  Batch {}/{}", i + 1, batches.len());
        let prompt = build_function_batch_prompt(batch);
        let response = call_claude(backend, &prompt).await?;
        parse_function_batch_response(&response, batch, &mut function_summaries);
    }

    // --- File summaries ---
    println!("  Summarizing {} files...", files.len());
    for file in files {
        if file.functions.is_empty() {
            continue;
        }
        let prompt = build_file_prompt(file);
        let summary = call_claude(backend, &prompt).await?;
        file_summaries.insert(file.file_id.clone(), summary.trim().to_string());
    }

    // --- System summary ---
    println!("  Generating system summary...");
    let system_prompt = build_system_prompt(files, &file_summaries);
    let system_summary = call_claude(backend, &system_prompt).await?;

    Ok(Summaries {
        function_summaries,
        file_summaries,
        system_summary: system_summary.trim().to_string(),
    })
}

// ─── Prompt builders ──────────────────────────────────────────────────────────

fn build_function_batch_prompt(functions: &[&crate::parser::ParsedFunction]) -> String {
    let mut prompt = String::from(
        "You are summarizing Rust functions for a code navigation tool. \
For each function below, write a single sentence (≤15 words) describing what it does. \
Be concrete and specific. Use present tense. Do not mention the language.\n\n\
Respond with exactly one line per function in this format:\n\
<id>|<summary>\n\n\
Functions:\n",
    );

    for func in functions {
        prompt.push_str(&format!(
            "---\nID: {}\n```rust\n{}\n```\n",
            func.id, func.body
        ));
    }

    prompt
}

fn parse_function_batch_response(
    response: &str,
    functions: &[&crate::parser::ParsedFunction],
    out: &mut HashMap<String, String>,
) {
    let id_set: std::collections::HashSet<_> = functions.iter().map(|f| &f.id).collect();

    for line in response.lines() {
        if let Some((id, summary)) = line.split_once('|') {
            let id = id.trim().to_string();
            if id_set.contains(&id) {
                out.insert(id, summary.trim().to_string());
            }
        }
    }

    for func in functions {
        out.entry(func.id.clone())
            .or_insert_with(|| "No summary available.".to_string());
    }
}

fn build_file_prompt(file: &ParsedFile) -> String {
    let fn_names: Vec<_> = file.functions.iter().map(|f| f.name.as_str()).collect();
    format!(
        "You are summarizing a Rust source file for a code navigation tool.\n\
Write a single sentence (≤20 words) describing what this file/module does.\n\
Be concrete. Use present tense.\n\n\
File: {}\nFunctions: {}\n\nSource:\n```rust\n{}\n```",
        file.file_id,
        fn_names.join(", "),
        &file.source[..file.source.len().min(6000)]
    )
}

fn build_system_prompt(files: &[ParsedFile], file_summaries: &HashMap<String, String>) -> String {
    let mut lines = vec![
        "You are summarizing a Rust project for a code navigation tool.".to_string(),
        "Write a single sentence (≤25 words) describing the overall purpose of this project."
            .to_string(),
        "Be concrete. Use present tense.\n".to_string(),
        "Files and their summaries:".to_string(),
    ];

    for file in files {
        let summary = file_summaries
            .get(&file.file_id)
            .map(|s| s.as_str())
            .unwrap_or("(no summary)");
        lines.push(format!("- {}: {}", file.file_id, summary));
    }

    lines.join("\n")
}
