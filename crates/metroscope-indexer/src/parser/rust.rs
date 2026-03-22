use anyhow::{Context, Result};
use metroscope_types::{Location, StationKind};
use std::path::Path;
use streaming_iterator::StreamingIterator;
use tree_sitter::{Node, Parser, Query, QueryCursor};

use super::{LanguageParser, ParsedFile, ParsedFunction};

pub struct RustParser {
    language: tree_sitter::Language,
}

impl RustParser {
    pub fn new() -> Result<Self> {
        Ok(Self {
            language: tree_sitter_rust::LANGUAGE.into(),
        })
    }
}

impl LanguageParser for RustParser {
    fn parse(&self, source: &str, file_id: &str) -> Result<ParsedFile> {
        let mut parser = Parser::new();
        parser
            .set_language(&self.language)
            .context("Failed to set language")?;

        let tree = parser
            .parse(source, None)
            .context("tree-sitter parse returned None")?;

        let file_name = Path::new(file_id)
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| file_id.to_string());

        let functions = extract_functions(source, file_id, tree.root_node())?;

        Ok(ParsedFile {
            file_id: file_id.to_string(),
            file_name,
            source: source.to_string(),
            functions,
        })
    }
}

fn extract_functions(source: &str, file_id: &str, root: Node) -> Result<Vec<ParsedFunction>> {
    let query_src = r#"
        (function_item
            name: (identifier) @fn_name
        ) @fn_def
    "#;

    let language: tree_sitter::Language = tree_sitter_rust::LANGUAGE.into();
    let query = Query::new(&language, query_src).context("Failed to compile query")?;

    let mut cursor = QueryCursor::new();
    let mut matches = cursor.matches(&query, root, source.as_bytes());

    let fn_def_idx = query.capture_index_for_name("fn_def").unwrap();
    let fn_name_idx = query.capture_index_for_name("fn_name").unwrap();

    let mut functions = Vec::new();
    let mut seen_ids = std::collections::HashSet::new();

    while let Some(m) = matches.next() {
        let def_node = match m.captures.iter().find(|c| c.index == fn_def_idx) {
            Some(c) => c.node,
            None => continue,
        };
        let name_node = match m.captures.iter().find(|c| c.index == fn_name_idx) {
            Some(c) => c.node,
            None => continue,
        };

        let fn_name = &source[name_node.start_byte()..name_node.end_byte()];
        let body_text = &source[def_node.start_byte()..def_node.end_byte()];

        let start_line = def_node.start_position().row as u32 + 1;
        let end_line = def_node.end_position().row as u32 + 1;

        // Determine if this is a method (inside an impl block)
        let kind = if is_inside_impl(def_node) {
            StationKind::Method
        } else {
            StationKind::Function
        };

        let id = format!("{file_id}::{fn_name}");

        if !seen_ids.insert(id.clone()) {
            continue;
        }

        let calls = extract_calls(source, def_node);

        functions.push(ParsedFunction {
            id,
            name: fn_name.to_string(),
            kind,
            location: Location {
                file: file_id.to_string(),
                line_start: start_line,
                line_end: end_line,
            },
            body: body_text.to_string(),
            calls,
        });
    }

    functions.sort_by_key(|f| f.location.line_start);
    Ok(functions)
}

fn is_inside_impl(node: Node) -> bool {
    let mut current = node.parent();
    while let Some(n) = current {
        if n.kind() == "impl_item" {
            return true;
        }
        current = n.parent();
    }
    false
}

fn extract_calls(source: &str, fn_node: Node) -> Vec<String> {
    let language: tree_sitter::Language = tree_sitter_rust::LANGUAGE.into();
    let query_src = r#"
        (call_expression
            function: [
                (identifier) @callee
                (field_expression field: (field_identifier) @callee)
                (scoped_identifier name: (identifier) @callee)
            ]
        )
    "#;

    let Ok(query) = Query::new(&language, query_src) else {
        return vec![];
    };

    let callee_idx = query.capture_index_for_name("callee").unwrap();
    let mut cursor = QueryCursor::new();
    let mut matches = cursor.matches(&query, fn_node, source.as_bytes());

    let mut calls: Vec<String> = Vec::new();
    while let Some(m) = matches.next() {
        for c in m.captures.iter().filter(|c| c.index == callee_idx) {
            calls.push(source[c.node.start_byte()..c.node.end_byte()].to_string());
        }
    }

    calls.sort();
    calls.dedup();
    calls
}
