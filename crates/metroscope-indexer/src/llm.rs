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

/// Optional prompt overrides from the user (via CLI args / Lua config).
/// Each field replaces the instruction prefix of the corresponding prompt.
pub struct PromptOverrides {
    pub function_prompt: Option<String>,
    pub file_prompt: Option<String>,
    pub system_prompt: Option<String>,
}

pub struct Summaries {
    pub function_summaries: HashMap<String, String>,
    pub function_explanations: HashMap<String, String>,
    pub file_summaries: HashMap<String, String>,
    pub system_summary: String,
    pub quests: Vec<metroscope_types::Quest>,
    pub tokens_in: u32,
    pub tokens_out: u32,
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
    usage: ApiUsage,
}

#[derive(Deserialize)]
struct ApiUsage {
    input_tokens: u32,
    output_tokens: u32,
}

#[derive(Deserialize)]
struct ContentBlock {
    text: String,
}

// ─── Backend dispatch ─────────────────────────────────────────────────────────

/// Returns (text, input_tokens, output_tokens). CLI backend returns 0 tokens.
async fn call_claude(backend: &LlmBackend, prompt: &str) -> Result<(String, u32, u32)> {
    match backend {
        LlmBackend::Api { key } => call_via_api(key, prompt).await,
        LlmBackend::Cli => call_via_cli(prompt).map(|t| (t, 0, 0)),
    }
}

async fn call_via_api(api_key: &str, prompt: &str) -> Result<(String, u32, u32)> {
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
    let text = parsed.content.into_iter().map(|b| b.text).collect::<Vec<_>>().join("");
    Ok((text, parsed.usage.input_tokens, parsed.usage.output_tokens))
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

pub async fn generate_summaries(
    files: &[ParsedFile],
    backend: &LlmBackend,
    prompts: &PromptOverrides,
    // id -> (summary, explanation, body_hash) from previous index
    cache: &HashMap<String, (String, String, String)>,
) -> Result<Summaries> {
    let mut function_summaries: HashMap<String, String> = HashMap::new();
    let mut function_explanations: HashMap<String, String> = HashMap::new();
    let mut file_summaries: HashMap<String, String> = HashMap::new();
    let mut tokens_in: u32 = 0;
    let mut tokens_out: u32 = 0;

    macro_rules! call {
        ($backend:expr, $prompt:expr) => {{
            let (text, ti, to) = call_claude($backend, $prompt).await?;
            tokens_in += ti;
            tokens_out += to;
            text
        }};
    }

    // --- Seed from cache for unchanged functions ---
    let all_functions: Vec<_> = files.iter().flat_map(|f| f.functions.iter()).collect();
    let mut skipped = 0usize;
    for func in &all_functions {
        if let Some((cached_summary, cached_explanation, cached_hash)) = cache.get(&func.id) {
            if *cached_hash == func.body_hash() {
                function_summaries.insert(func.id.clone(), cached_summary.clone());
                function_explanations.insert(func.id.clone(), cached_explanation.clone());
                skipped += 1;
            }
        }
    }
    if skipped > 0 {
        println!("  Skipping {skipped} unchanged functions (cached)");
    }

    // Only process new/changed functions
    let new_functions: Vec<_> = all_functions
        .iter()
        .filter(|f| !function_summaries.contains_key(&f.id))
        .cloned()
        .collect();

    if !new_functions.is_empty() {
        // --- Function summaries (batched) ---
        let batches: Vec<_> = new_functions.chunks(BATCH_SIZE).collect();
        println!(
            "  Summarizing {} new/changed functions in {} batches...",
            new_functions.len(),
            batches.len()
        );
        for (i, batch) in batches.iter().enumerate() {
            println!("  Batch {}/{}", i + 1, batches.len());
            let prompt = build_function_batch_prompt(batch, prompts.function_prompt.as_deref());
            let response = call!(backend, &prompt);
            parse_function_batch_response(&response, batch, &mut function_summaries);
        }

        // --- Function explanations (batched) ---
        let expl_batches: Vec<_> = new_functions.chunks(BATCH_SIZE).collect();
        println!(
            "  Generating explanations for {} functions in {} batches...",
            new_functions.len(),
            expl_batches.len()
        );
        for (i, batch) in expl_batches.iter().enumerate() {
            println!("  Explanation batch {}/{}", i + 1, expl_batches.len());
            let prompt = build_explanation_batch_prompt(batch);
            let response = call!(backend, &prompt);
            parse_function_batch_response(&response, batch, &mut function_explanations);
        }
    } else {
        println!("  All functions unchanged — skipping LLM summary passes");
    }

    // --- File summaries ---
    println!("  Summarizing {} files...", files.len());
    for file in files {
        if file.functions.is_empty() {
            continue;
        }
        let prompt = build_file_prompt(file, prompts.file_prompt.as_deref());
        let summary = call!(backend, &prompt);
        file_summaries.insert(file.file_id.clone(), summary.trim().to_string());
    }

    // --- System summary ---
    println!("  Generating system summary...");
    let system_prompt = build_system_prompt(files, &file_summaries, prompts.system_prompt.as_deref());
    let system_summary = call!(backend, &system_prompt);
    let system_summary = system_summary.trim().to_string();

    // --- Architectural quests ---
    println!("  Generating architectural quests...");
    let mut crate_summaries: std::collections::HashMap<String, Vec<String>> = std::collections::HashMap::new();
    for (file_id, summary) in &file_summaries {
        let crate_name = {
            let parts: Vec<&str> = file_id.splitn(4, '/').collect();
            if parts.len() >= 2 && parts[0] == "crates" {
                parts[1].to_string()
            } else {
                "root".to_string()
            }
        };
        crate_summaries.entry(crate_name).or_default().push(summary.clone());
    }
    let crate_list: Vec<(String, String)> = crate_summaries
        .into_iter()
        .map(|(name, summaries)| (name, summaries.join("; ")))
        .collect();
    let quests_prompt = build_quests_prompt(&system_summary, &crate_list);
    let quests_response = call!(backend, &quests_prompt);
    let quests = parse_quests(&quests_response);
    println!("  Generated {} quests", quests.len());

    Ok(Summaries {
        function_summaries,
        function_explanations,
        file_summaries,
        system_summary,
        quests,
        tokens_in,
        tokens_out,
    })
}

// ─── Prompt builders ──────────────────────────────────────────────────────────

fn build_function_batch_prompt(functions: &[&crate::parser::ParsedFunction], override_prefix: Option<&str>) -> String {
    let prefix = override_prefix.unwrap_or(
        "You are summarizing Rust functions for a code navigation tool. \
For each function below, write a single sentence (≤15 words) describing what it does. \
Be concrete and specific. Use present tense. Do not mention the language."
    );
    let mut prompt = format!(
        "{}\n\nRespond with exactly one line per function in this format:\n\
<id>|<summary>\n\nFunctions:\n",
        prefix
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

fn build_explanation_batch_prompt(functions: &[&crate::parser::ParsedFunction]) -> String {
    let mut prompt = "You are explaining Rust functions for a developer reading a code navigation tool.\n\
For each function below, write 2-4 sentences explaining:\n\
1. What the function does and why it exists\n\
2. Any notable implementation details or gotchas\n\
3. Where to look next — name the most important caller or callee that continues this logic\n\
Use plain English. Present tense. No code snippets in the response.\n\
\n\
Respond with exactly one entry per function in this format:\n\
<id>|<explanation>\n\
\n\
Functions:\n".to_string();

    for func in functions {
        prompt.push_str(&format!(
            "---\nID: {}\n```rust\n{}\n```\n",
            func.id, func.body
        ));
    }

    prompt
}

fn build_file_prompt(file: &ParsedFile, override_prefix: Option<&str>) -> String {
    let prefix = override_prefix.unwrap_or(
        "You are summarizing a Rust source file for a code navigation tool.\n\
Write a single sentence (≤20 words) describing what this file/module does.\n\
Be concrete. Use present tense."
    );
    let fn_names: Vec<_> = file.functions.iter().map(|f| f.name.as_str()).collect();
    format!(
        "{}\n\nFile: {}\nFunctions: {}\n\nSource:\n```rust\n{}\n```",
        prefix,
        file.file_id,
        fn_names.join(", "),
        &file.source[..file.source.len().min(6000)]
    )
}

fn build_system_prompt(files: &[ParsedFile], file_summaries: &HashMap<String, String>, override_prefix: Option<&str>) -> String {
    let prefix = override_prefix.unwrap_or(
        "You are summarizing a Rust project for a code navigation tool.\n\
Write a single sentence (≤25 words) describing the overall purpose of this project.\n\
Be concrete. Use present tense."
    );
    let mut lines = vec![
        prefix.to_string(),
        String::new(),
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

fn build_quests_prompt(system_summary: &str, crate_summaries: &[(String, String)]) -> String {
    let mut prompt = format!(
        "You are a senior software architect reviewing a codebase.\n\
System summary: {system_summary}\n\
\n\
Components:\n"
    );
    for (name, summary) in crate_summaries {
        prompt.push_str(&format!("- {name}: {summary}\n"));
    }
    prompt.push_str(
        "\nIdentify 3-7 architectural improvements for this system.\n\
Focus ONLY on system-level concerns: security, observability, resilience, scalability, \
missing layers, integration gaps.\n\
Do NOT suggest code style changes or function-level improvements.\n\
\n\
Respond with one quest per line, exactly in this format:\n\
component|easy/medium/hard|Short title (max 8 words)|Why it matters (2-3 sentences)\n\
\n\
Use \"system\" as component for cross-cutting concerns.",
    );
    prompt
}

fn parse_quests(response: &str) -> Vec<metroscope_types::Quest> {
    use metroscope_types::{Quest, QuestDifficulty};
    let mut quests = Vec::new();
    for line in response.lines() {
        let parts: Vec<&str> = line.splitn(4, '|').collect();
        if parts.len() != 4 { continue; }
        let difficulty = match parts[1].trim().to_lowercase().as_str() {
            "easy"   => QuestDifficulty::Easy,
            "hard"   => QuestDifficulty::Hard,
            _        => QuestDifficulty::Medium,
        };
        quests.push(Quest {
            component:  parts[0].trim().to_string(),
            difficulty,
            title:      parts[2].trim().to_string(),
            why:        parts[3].trim().to_string(),
        });
    }
    quests
}
