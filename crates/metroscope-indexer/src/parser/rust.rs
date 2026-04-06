use anyhow::{Context, Result};
use metroscope_types::{Location, StationKind};
use std::path::Path;
use streaming_iterator::StreamingIterator;
use tree_sitter::{Node, Parser, Query, QueryCursor};

/// Build a display name for a file that disambiguates common names like "main" or "lib".
/// "crates/metroscope-indexer/src/main.rs" → "indexer/main"
/// "src/main.rs" → "main"
/// "crates/foo/src/bar.rs" → "foo/bar"
fn disambiguate_name(file_id: &str) -> String {
    let path = Path::new(file_id);
    let stem = path.file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| file_id.to_string());

    // Find parent dir — if it's "src", go one level higher for the crate name
    let parent = path.parent();
    let crate_name = parent.and_then(|p| {
        let dir = p.file_name()?.to_string_lossy();
        if dir == "src" {
            // go up one more: crates/metroscope-indexer/src → metroscope-indexer
            p.parent()?.file_name().map(|n| {
                let s = n.to_string_lossy();
                // strip common prefixes like "metroscope-"
                s.splitn(2, '-').nth(1).unwrap_or(&s).to_string()
            })
        } else {
            None
        }
    });

    match crate_name {
        Some(crate_name) if crate_name != stem => format!("{}/{}", crate_name, stem),
        _ => stem,
    }
}

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

        let file_name = disambiguate_name(file_id);

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
    let language: tree_sitter::Language = tree_sitter_rust::LANGUAGE.into();
    let mut items = Vec::new();
    let mut seen_ids = std::collections::HashSet::new();

    // ── 1. Structs and enums ─────────────────────────────────────────────────
    let type_query_src = r#"
        [
          (struct_item name: (type_identifier) @type_name) @type_def
          (enum_item   name: (type_identifier) @type_name) @type_def
        ]
    "#;
    let type_query = Query::new(&language, type_query_src).context("Failed to compile type query")?;
    let type_def_idx = type_query.capture_index_for_name("type_def").unwrap();
    let type_name_idx = type_query.capture_index_for_name("type_name").unwrap();

    let mut cursor = QueryCursor::new();
    let mut matches = cursor.matches(&type_query, root, source.as_bytes());
    while let Some(m) = matches.next() {
        let def_node = match m.captures.iter().find(|c| c.index == type_def_idx) {
            Some(c) => c.node,
            None => continue,
        };
        let name_node = match m.captures.iter().find(|c| c.index == type_name_idx) {
            Some(c) => c.node,
            None => continue,
        };
        let type_name = &source[name_node.start_byte()..name_node.end_byte()];
        let body_text = &source[def_node.start_byte()..def_node.end_byte()];
        let id = format!("{file_id}::{type_name}");
        if !seen_ids.insert(id.clone()) {
            continue;
        }
        let kind = if def_node.kind() == "enum_item" {
            StationKind::Enum
        } else {
            StationKind::Struct
        };
        items.push(ParsedFunction {
            id,
            name: type_name.to_string(),
            kind,
            location: Location {
                file: file_id.to_string(),
                line_start: def_node.start_position().row as u32 + 1,
                line_end: def_node.end_position().row as u32 + 1,
            },
            body: body_text.to_string(),
            calls: vec![],
            owner: None,
        });
    }

    // ── 2. Functions and methods ─────────────────────────────────────────────
    let fn_query_src = r#"
        (function_item
            name: (identifier) @fn_name
        ) @fn_def
    "#;
    let fn_query = Query::new(&language, fn_query_src).context("Failed to compile fn query")?;
    let fn_def_idx = fn_query.capture_index_for_name("fn_def").unwrap();
    let fn_name_idx = fn_query.capture_index_for_name("fn_name").unwrap();

    let mut cursor2 = QueryCursor::new();
    let mut fn_matches = cursor2.matches(&fn_query, root, source.as_bytes());
    while let Some(m) = fn_matches.next() {
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

        let owner = impl_type_name(def_node, source);
        let kind = if owner.is_some() {
            StationKind::Method
        } else {
            StationKind::Function
        };

        let id = match &owner {
            Some(type_name) => format!("{file_id}::{type_name}::{fn_name}"),
            None => format!("{file_id}::{fn_name}"),
        };

        if !seen_ids.insert(id.clone()) {
            continue;
        }

        let calls = extract_calls(source, def_node);

        items.push(ParsedFunction {
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
            owner,
        });
    }

    items.sort_by_key(|f| f.location.line_start);
    Ok(items)
}

/// Walk up the tree from a function node. If it's inside an `impl_item`,
/// return the type name that impl is for.
fn impl_type_name(node: Node, source: &str) -> Option<String> {
    let mut current = node.parent();
    while let Some(n) = current {
        if n.kind() == "impl_item" {
            // The type being implemented is the first `type_identifier` child
            for i in 0..n.child_count() {
                let child = n.child(i)?;
                if child.kind() == "type_identifier" {
                    return Some(source[child.start_byte()..child.end_byte()].to_string());
                }
            }
            return None;
        }
        current = n.parent();
    }
    None
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
