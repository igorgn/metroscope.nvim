use anyhow::Result;
use reqwest::Client;
use serde::{Deserialize, Serialize};

#[derive(Clone)]
pub struct OllamaClient {
    client: Client,
    base_url: String,
    pub model: String,
}

#[derive(Serialize)]
struct GenerateRequest<'a> {
    model: &'a str,
    prompt: &'a str,
    stream: bool,
}

#[derive(Deserialize)]
struct GenerateResponse {
    response: String,
}

impl OllamaClient {
    pub fn new(base_url: impl Into<String>, model: impl Into<String>) -> Self {
        Self {
            client: Client::new(),
            base_url: base_url.into(),
            model: model.into(),
        }
    }

    pub async fn generate(&self, prompt: &str) -> Result<String> {
        let url = format!("{}/api/generate", self.base_url);
        let resp = self
            .client
            .post(&url)
            .json(&GenerateRequest {
                model: &self.model,
                prompt,
                stream: false,
            })
            .send()
            .await?
            .error_for_status()?
            .json::<GenerateResponse>()
            .await?;
        Ok(resp.response)
    }

    /// Ask the model to classify a file change as relevant or not to a given context.
    /// Returns true if the orchestrator should wake up.
    pub async fn is_relevant(&self, file: &str, active_quest: &str, pending_forks: &[String]) -> Result<bool> {
        if active_quest.is_empty() && pending_forks.is_empty() {
            return Ok(false);
        }

        let prompt = format!(
            "A file changed: {file}\n\
             Current quest: {active_quest}\n\
             Pending decisions: {forks}\n\n\
             Is this file change relevant to the current quest or pending decisions? \
             Answer with a single word: yes or no.",
            forks = pending_forks.join(", ")
        );

        let response = self.generate(&prompt).await?;
        Ok(response.trim().to_lowercase().starts_with("yes"))
    }

    /// Ask the model whether a fork can be auto-resolved or needs human input.
    /// Returns Some(option_id) if it can auto-resolve, None if it should escalate.
    pub async fn try_resolve_fork(
        &self,
        question: &str,
        options: &[(String, String)], // (id, label)
        context: &str,
    ) -> Result<Option<String>> {
        let options_text: String = options
            .iter()
            .map(|(id, label)| format!("- {id}: {label}"))
            .collect::<Vec<_>>()
            .join("\n");

        let prompt = format!(
            "You are an AI orchestrator managing a software project.\n\
             Context: {context}\n\n\
             Decision needed: {question}\n\
             Options:\n{options_text}\n\n\
             Can you confidently choose one option, or should a human decide?\n\
             If confident, respond with: RESOLVE <option_id>\n\
             If unsure, respond with: ESCALATE <reason>",
        );

        let response = self.generate(&prompt).await?;
        let trimmed = response.trim();

        if let Some(rest) = trimmed.strip_prefix("RESOLVE ") {
            let option_id = rest.split_whitespace().next().unwrap_or("").to_string();
            if options.iter().any(|(id, _)| id == &option_id) {
                return Ok(Some(option_id));
            }
        }

        Ok(None)
    }
}
