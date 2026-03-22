use metroscope_types::{ConnectionKind, Index, Line, Station};
use serde::Serialize;

const CONTEXT_RADIUS: usize = 3;
const LINE_RADIUS: usize = 2;

#[derive(Serialize)]
pub struct MapResponse {
    pub focused_station: Option<String>,
    pub lines: Vec<LineView>,
    /// System-level summary shown in the status bar
    pub system_summary: String,
}

#[derive(Serialize)]
pub struct LineView {
    pub id: String,
    pub name: String,
    pub color: String,
    pub summary: String,
    pub stations: Vec<StationView>,
    pub is_focused: bool,
}

#[derive(Serialize)]
pub struct StationView {
    pub id: String,
    pub name: String,
    pub summary: String,
    pub is_focused: bool,
    pub line_start: u32,
    pub line_end: u32,
    /// True if this station has connections to/from stations on OTHER lines
    pub has_cross_line: bool,
}

pub fn build_map_response(index: &Index, focused: Option<&Station>) -> MapResponse {
    let mut all_lines: Vec<&Line> = index.lines.values().collect();
    all_lines.sort_by(|a, b| a.id.cmp(&b.id));

    let focused_line_id = focused.map(|s| s.line_id.as_str());

    let focused_line_idx = focused_line_id
        .and_then(|fid| all_lines.iter().position(|l| l.id == fid));

    let line_range = if let Some(fi) = focused_line_idx {
        let start = fi.saturating_sub(LINE_RADIUS);
        let end = (fi + LINE_RADIUS + 1).min(all_lines.len());
        start..end
    } else {
        0..all_lines.len().min(5)
    };

    let lines = all_lines[line_range]
        .iter()
        .filter(|line| !line.stations.is_empty())
        .map(|line| {
            let is_focused_line = Some(line.id.as_str()) == focused_line_id;
            let focused_station_id = focused.map(|s| s.id.as_str());

            let focused_idx = focused_station_id
                .and_then(|fid| line.stations.iter().position(|sid| sid == fid));

            let station_range = if let Some(fi) = focused_idx {
                let start = fi.saturating_sub(CONTEXT_RADIUS);
                let end = (fi + CONTEXT_RADIUS + 1).min(line.stations.len());
                start..end
            } else {
                0..line.stations.len().min(CONTEXT_RADIUS * 2 + 1)
            };

            let stations: Vec<StationView> = line.stations[station_range]
                .iter()
                .filter_map(|sid| index.stations.get(sid))
                .map(|s| StationView {
                    id: s.id.clone(),
                    name: s.name.clone(),
                    summary: s.summary.clone(),
                    is_focused: Some(s.id.as_str()) == focused_station_id,
                    line_start: s.location.line_start,
                    line_end: s.location.line_end,
                    has_cross_line: station_has_cross_line(index, s),
                })
                .collect();

            LineView {
                id: line.id.clone(),
                name: line.name.clone(),
                color: line.color.clone(),
                summary: line.summary.clone(),
                stations,
                is_focused: is_focused_line,
            }
        })
        .collect();

    MapResponse {
        focused_station: focused.map(|s| s.id.clone()),
        lines,
        system_summary: index.system_summary.clone(),
    }
}

/// True if any of this station's connections point to a station in a different file.
///
/// Connections from tree-sitter store bare names (e.g. "call_claude"), not full ids.
/// Connections from Serena store full ids ("path/to/file.rs::fn").
/// We handle both: try full-id lookup first, then fall back to name match.
fn station_has_cross_line(index: &Index, station: &Station) -> bool {
    station.connections.iter().any(|conn| {
        // Full-id lookup (Serena-enriched connections)
        if let Some(target) = index.stations.get(&conn.to) {
            return target.line_id != station.line_id;
        }
        // Name-only lookup (tree-sitter connections) — check if any station
        // with that name lives in a different file
        let name = conn.to.split("::").last().unwrap_or(&conn.to);
        index.stations.values().any(|s| {
            s.name == name && s.line_id != station.line_id
        })
    })
}

/// Cross-line connection summary for a file — which other files does it connect to?
#[derive(Serialize)]
pub struct FileConnections {
    pub file_id: String,
    /// Files this file calls into
    pub calls_into: Vec<FileLink>,
    /// Files that call into this file
    pub called_from: Vec<FileLink>,
}

#[derive(Serialize)]
pub struct FileLink {
    pub file_id: String,
    pub file_name: String,
    pub color: String,
    /// Specific cross-line connections
    pub connections: Vec<CrossConnection>,
}

#[derive(Serialize)]
pub struct CrossConnection {
    pub from_station: String,
    pub to_station: String,
    pub kind: String,
}

pub fn build_file_connections(index: &Index, file_id: &str) -> FileConnections {
    let mut calls_into: std::collections::HashMap<String, Vec<CrossConnection>> =
        std::collections::HashMap::new();
    let mut called_from: std::collections::HashMap<String, Vec<CrossConnection>> =
        std::collections::HashMap::new();

    // Gather all stations in this file
    let file_stations: Vec<&Station> = index
        .stations
        .values()
        .filter(|s| s.line_id == file_id)
        .collect();

    for station in &file_stations {
        for conn in &station.connections {
            // Resolve target: try full-id first, then name-only match
            let target = index.stations.get(&conn.to).or_else(|| {
                let name = conn.to.split("::").last().unwrap_or(&conn.to);
                index.stations.values().find(|s| s.name == name && s.line_id != station.line_id)
            });

            if let Some(target) = target {
                if target.line_id == file_id {
                    continue;
                }
                let cross = CrossConnection {
                    from_station: station.name.clone(),
                    to_station: target.name.clone(),
                    kind: match conn.kind {
                        ConnectionKind::Calls => "calls".to_string(),
                        ConnectionKind::CalledBy => "called_by".to_string(),
                    },
                };
                match conn.kind {
                    ConnectionKind::Calls => {
                        calls_into.entry(target.line_id.clone()).or_default().push(cross);
                    }
                    ConnectionKind::CalledBy => {
                        called_from.entry(target.line_id.clone()).or_default().push(cross);
                    }
                }
            }
        }
    }

    let to_file_links = |map: std::collections::HashMap<String, Vec<CrossConnection>>| {
        let mut links: Vec<FileLink> = map
            .into_iter()
            .filter_map(|(fid, conns)| {
                let line = index.lines.get(&fid)?;
                Some(FileLink {
                    file_id: fid,
                    file_name: line.name.clone(),
                    color: line.color.clone(),
                    connections: conns,
                })
            })
            .collect();
        links.sort_by(|a, b| a.file_id.cmp(&b.file_id));
        links
    };

    FileConnections {
        file_id: file_id.to_string(),
        calls_into: to_file_links(calls_into),
        called_from: to_file_links(called_from),
    }
}
