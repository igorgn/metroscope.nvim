use metroscope_types::{Index, Line, Station};
use serde::Serialize;

/// How many stations to show on each side of the focused station
const CONTEXT_RADIUS: usize = 3;
/// How many adjacent lines to show above/below the focused line
const LINE_RADIUS: usize = 2;

#[derive(Serialize)]
pub struct MapResponse {
    /// The station the cursor is on (may be null if no function at cursor)
    pub focused_station: Option<String>,
    /// Lines to render, in display order
    pub lines: Vec<LineView>,
}

#[derive(Serialize)]
pub struct LineView {
    pub id: String,
    pub name: String,
    pub color: String,
    pub summary: String,
    /// Stations to display, in order
    pub stations: Vec<StationView>,
    /// Whether this is the line containing the focused station
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
}

pub fn build_map_response(index: &Index, focused: Option<&Station>) -> MapResponse {
    // Collect and sort lines by id for stable ordering
    let mut all_lines: Vec<&Line> = index.lines.values().collect();
    all_lines.sort_by(|a, b| a.id.cmp(&b.id));

    let focused_line_id = focused.map(|s| s.line_id.as_str());

    // Find the index of the focused line in the sorted list
    let focused_line_idx = focused_line_id.and_then(|fid| {
        all_lines.iter().position(|l| l.id == fid)
    });

    // Determine which lines to include
    let line_range = if let Some(fi) = focused_line_idx {
        let start = fi.saturating_sub(LINE_RADIUS);
        let end = (fi + LINE_RADIUS + 1).min(all_lines.len());
        start..end
    } else {
        0..all_lines.len().min(5)
    };

    let lines = all_lines[line_range]
        .iter()
        .map(|line| {
            let is_focused_line = Some(line.id.as_str()) == focused_line_id;
            let focused_station_id = focused.map(|s| s.id.as_str());

            // Find focused station index within this line's stations
            let focused_idx = focused_station_id.and_then(|fid| {
                line.stations.iter().position(|sid| sid == fid)
            });

            // Determine which stations to show
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
    }
}
