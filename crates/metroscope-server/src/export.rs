use metroscope_types::{ConnectionKind, Index, StationKind};
use std::collections::HashMap;

// ── Layout constants ──────────────────────────────────────────────────────────

const BOX_W: f64 = 240.0;
const BOX_PADDING: f64 = 14.0;
const BOX_HEADER_H: f64 = 28.0;
const LINE_H: f64 = 16.0;
const WRAP_COLS: usize = 32;

const STATION_GAP_Y: f64 = 18.0;
const FILE_GAP_Y: f64 = 36.0;
const CRATE_GAP_X: f64 = 60.0;
const CRATE_PADDING_X: f64 = 24.0;
const CRATE_PADDING_TOP: f64 = 52.0;
const CRATE_PADDING_BOT: f64 = 24.0;
const MARGIN: f64 = 40.0;

// Colors
const BG: &str = "#0a0e1a";
const STATION_BG: &str = "#0f172a";
const STATION_BORDER: &str = "#334155";
const STATION_NAME_C: &str = "#f1f5f9";
const EXPL_C: &str = "#94a3b8";
const FILE_LABEL_C: &str = "#64748b";
const ARROW_C: &str = "#475569";
const ARROW_CROSS_C: &str = "#f59e0b";
const LEGEND_C: &str = "#94a3b8";

// Crate color palette: (background, accent)
const CRATE_COLORS: &[(&str, &str)] = &[
    ("#1a1f2e", "#3b82f6"),
    ("#1e1a2e", "#a855f7"),
    ("#1a2e1e", "#22c55e"),
    ("#2e1a1a", "#ef4444"),
    ("#2e261a", "#f59e0b"),
    ("#1a2a2e", "#06b6d4"),
];

// ── Helpers ───────────────────────────────────────────────────────────────────

fn word_wrap(text: &str, cols: usize) -> Vec<String> {
    let mut lines = Vec::new();
    let mut current = String::new();
    for word in text.split_whitespace() {
        if current.is_empty() {
            current = word.to_string();
        } else if current.len() + 1 + word.len() <= cols {
            current.push(' ');
            current.push_str(word);
        } else {
            lines.push(current.clone());
            current = word.to_string();
        }
    }
    if !current.is_empty() {
        lines.push(current);
    }
    if lines.is_empty() {
        lines.push(String::new());
    }
    lines
}

fn xml(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn crate_id_of(line_id: &str) -> &str {
    let parts: Vec<&str> = line_id.splitn(4, '/').collect();
    if parts.len() >= 2 && parts[0] == "crates" {
        parts[1]
    } else {
        "root"
    }
}

fn kind_badge(k: &StationKind) -> &'static str {
    match k {
        StationKind::Function => "fn",
        StationKind::Method   => "→",
        StationKind::Closure  => "λ",
        StationKind::Struct   => "st",
        StationKind::Enum     => "en",
        StationKind::Trait    => "tr",
        StationKind::Impl     => "im",
        StationKind::Module   => "mod",
    }
}

// ── Layout ────────────────────────────────────────────────────────────────────

struct StationLayout {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    cy: f64,
}

// ── SVG builder helpers ───────────────────────────────────────────────────────

fn rect(x: f64, y: f64, w: f64, h: f64, rx: f64, fill: &str, stroke: &str, stroke_w: f64, extra: &str) -> String {
    format!(
        r#"  <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" ry="{rx}" fill="{fill}" stroke="{stroke}" stroke-width="{stroke_w}"{extra}/>"#
    )
}

fn text(x: f64, y: f64, size: f64, fill: &str, weight: &str, anchor: &str, content: &str, extra: &str) -> String {
    format!(
        r#"  <text x="{x}" y="{y}" font-size="{size}" fill="{fill}" font-weight="{weight}" text-anchor="{anchor}"{extra}>{content}</text>"#
    )
}

fn line_el(x1: f64, y1: f64, x2: f64, y2: f64, stroke: &str, sw: f64, extra: &str) -> String {
    format!(r#"  <line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{stroke}" stroke-width="{sw}"{extra}/>"#)
}

// ── Main export ───────────────────────────────────────────────────────────────

pub fn render_svg(index: &Index) -> String {
    // Group lines by crate
    let mut crate_lines: HashMap<String, Vec<String>> = HashMap::new();
    let mut sorted_line_ids: Vec<&str> = index.lines.keys().map(|s| s.as_str()).collect();
    sorted_line_ids.sort();
    for lid in &sorted_line_ids {
        crate_lines
            .entry(crate_id_of(lid).to_string())
            .or_default()
            .push(lid.to_string());
    }
    let mut crate_names: Vec<String> = crate_lines.keys().cloned().collect();
    crate_names.sort();

    // Station box heights
    let station_h: HashMap<&str, f64> = index.stations.iter().map(|(id, s)| {
        let lines = word_wrap(&s.explanation, WRAP_COLS);
        let h = BOX_HEADER_H + BOX_PADDING + (lines.len() as f64) * LINE_H + BOX_PADDING;
        (id.as_str(), h)
    }).collect();

    // Layout pass
    let mut layouts: HashMap<String, StationLayout> = HashMap::new();

    struct CrateBox { name: String, x: f64, y: f64, w: f64, h: f64, ci: usize }
    let mut crate_boxes: Vec<CrateBox> = Vec::new();

    let mut cursor_x = MARGIN;

    for (ci, crate_name) in crate_names.iter().enumerate() {
        let lines_in_crate = &crate_lines[crate_name];
        let crate_x = cursor_x;
        let mut cursor_y = MARGIN + CRATE_PADDING_TOP;

        for (fi, line_id) in lines_in_crate.iter().enumerate() {
            let line = match index.lines.get(line_id) { Some(l) => l, None => continue };
            if fi > 0 { cursor_y += FILE_GAP_Y; }
            cursor_y += 20.0; // file label
            for sid in &line.stations {
                let h = *station_h.get(sid.as_str()).unwrap_or(&60.0);
                let bx = crate_x + CRATE_PADDING_X;
                layouts.insert(sid.clone(), StationLayout {
                    x: bx, y: cursor_y, w: BOX_W, h,
                    cy: cursor_y + h / 2.0,
                });
                cursor_y += h + STATION_GAP_Y;
            }
        }

        let crate_h = cursor_y - (MARGIN + CRATE_PADDING_TOP) + CRATE_PADDING_BOT + MARGIN;
        let crate_w = BOX_W + CRATE_PADDING_X * 2.0;
        crate_boxes.push(CrateBox { name: crate_name.clone(), x: crate_x, y: MARGIN, w: crate_w, h: crate_h, ci });
        cursor_x += crate_w + CRATE_GAP_X;
    }

    let total_w = cursor_x - CRATE_GAP_X + MARGIN;
    let total_h = crate_boxes.iter().map(|c| c.y + c.h + MARGIN).fold(0.0f64, f64::max) + 40.0;

    let mut out = Vec::<String>::new();

    // SVG header
    out.push(format!(
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="{total_w}" height="{total_h}" viewBox="0 0 {total_w} {total_h}" style="font-family: 'JetBrains Mono', 'Fira Code', 'Cascadia Code', monospace; background: {BG};">"#
    ));

    // Defs
    // Build defs without inline hex in raw strings (avoids "# terminator issue)
    out.push(format!(
        "  <defs>\n\
        \x20   <marker id=\"arr\" markerWidth=\"8\" markerHeight=\"8\" refX=\"6\" refY=\"3\" orient=\"auto\">\n\
        \x20     <path d=\"M0,0 L0,6 L8,3 z\" fill=\"{ac}\"/>\n\
        \x20   </marker>\n\
        \x20   <marker id=\"arr-x\" markerWidth=\"8\" markerHeight=\"8\" refX=\"6\" refY=\"3\" orient=\"auto\">\n\
        \x20     <path d=\"M0,0 L0,6 L8,3 z\" fill=\"{axc}\"/>\n\
        \x20   </marker>\n\
        \x20   <filter id=\"sh\">\n\
        \x20     <feDropShadow dx=\"0\" dy=\"3\" stdDeviation=\"6\" flood-color=\"{shadow}\" flood-opacity=\"0.5\"/>\n\
        \x20   </filter>\n\
        \x20   <style>text {{ dominant-baseline: auto; }}</style>\n\
          </defs>",
        ac = ARROW_C, axc = ARROW_CROSS_C, shadow = "#000000"
    ));

    // System summary
    out.push(text(MARGIN, 26.0, 11.0, FILE_LABEL_C, "normal", "start",
        &xml(&index.system_summary.chars().take(130).collect::<String>()), r#" font-style="italic""#));

    // Crate panels
    for cb in &crate_boxes {
        let (cbg, cacc) = CRATE_COLORS[cb.ci % CRATE_COLORS.len()];
        // Panel
        out.push(rect(cb.x, cb.y, cb.w, cb.h, 12.0, cbg, cacc, 1.5, r#" filter="url(#sh)""#));
        // Header bar
        out.push(rect(cb.x, cb.y, cb.w, 36.0, 12.0, cacc, "none", 0.0, r#" opacity="0.12""#));
        // Crate name
        out.push(text(
            cb.x + cb.w / 2.0, cb.y + 23.0, 12.0, cacc, "bold", "middle",
            &xml(&cb.name.to_uppercase()), r#" letter-spacing="1.5""#,
        ));
    }

    // File labels + station boxes
    for (ci, crate_name) in crate_names.iter().enumerate() {
        let (_, cacc) = CRATE_COLORS[ci % CRATE_COLORS.len()];
        let cb = &crate_boxes[ci];
        let lines_in_crate = &crate_lines[crate_name];

        for line_id in lines_in_crate {
            let line = match index.lines.get(line_id) { Some(l) => l, None => continue };
            let short = line_id.split('/').last().unwrap_or(&line.name);

            // File label above first station
            if let Some(first_sl) = line.stations.first().and_then(|s| layouts.get(s)) {
                out.push(text(
                    cb.x + CRATE_PADDING_X, first_sl.y - 5.0, 10.0, cacc,
                    "normal", "start", &xml(short), r#" opacity="0.8""#,
                ));
            }

            // Stations
            for sid in &line.stations {
                let station = match index.stations.get(sid) { Some(s) => s, None => continue };
                let sl = match layouts.get(sid) { Some(l) => l, None => continue };
                let wrapped = word_wrap(&station.explanation, WRAP_COLS);

                // Box
                out.push(rect(sl.x, sl.y, sl.w, sl.h, 8.0, STATION_BG, STATION_BORDER, 1.0, ""));
                // Left accent bar
                out.push(rect(sl.x, sl.y + 4.0, 3.0, sl.h - 8.0, 2.0, cacc, "none", 0.0, ""));
                // Name
                out.push(text(sl.x + 14.0, sl.y + 19.0, 12.0, STATION_NAME_C, "bold", "start",
                    &xml(&station.name), ""));
                // Kind badge
                out.push(text(sl.x + sl.w - 8.0, sl.y + 18.0, 9.0, cacc, "normal", "end",
                    kind_badge(&station.kind), r#" opacity="0.7""#));
                // Divider
                out.push(line_el(sl.x + 10.0, sl.y + BOX_HEADER_H,
                    sl.x + sl.w - 10.0, sl.y + BOX_HEADER_H,
                    STATION_BORDER, 0.5, r#" opacity="0.4""#));
                // Explanation lines
                for (li, wline) in wrapped.iter().enumerate() {
                    out.push(text(
                        sl.x + 14.0,
                        sl.y + BOX_HEADER_H + BOX_PADDING + li as f64 * LINE_H,
                        10.0, EXPL_C, "normal", "start", &xml(wline), "",
                    ));
                }
            }
        }
    }

    // Arrows
    for station in index.stations.values() {
        let from_sl = match layouts.get(&station.id) { Some(l) => l, None => continue };
        let from_crate = crate_id_of(&station.line_id);

        for conn in &station.connections {
            if conn.kind != ConnectionKind::Calls { continue; }
            let to_sl = match layouts.get(&conn.to) { Some(l) => l, None => continue };
            let to_station = match index.stations.get(&conn.to) { Some(s) => s, None => continue };
            let to_crate = crate_id_of(&to_station.line_id);
            let cross = from_crate != to_crate;

            let (color, marker) = if cross { (ARROW_CROSS_C, "arr-x") } else { (ARROW_C, "arr") };

            let x1 = from_sl.x + from_sl.w;
            let y1 = from_sl.cy;
            let x2 = to_sl.x;
            let y2 = to_sl.cy;
            let dx = (x2 - x1).abs().max(60.0);
            let cx1 = x1 + dx * 0.5;
            let cy1 = y1;
            let cx2 = x2 - dx * 0.5;
            let cy2 = y2;

            out.push(format!(
                r#"  <path d="M{x1},{y1} C{cx1},{cy1} {cx2},{cy2} {x2},{y2}" fill="none" stroke="{color}" stroke-width="1.2" marker-end="url(#{marker})" opacity="0.55"/>"#
            ));
        }
    }

    // Legend
    let ly = total_h - 26.0;
    out.push(line_el(MARGIN, ly, MARGIN + 28.0, ly, ARROW_C, 1.5, r#" marker-end="url(#arr)""#));
    out.push(text(MARGIN + 34.0, ly + 4.0, 10.0, LEGEND_C, "normal", "start", "calls (same crate)", ""));
    out.push(line_el(MARGIN + 170.0, ly, MARGIN + 198.0, ly, ARROW_CROSS_C, 1.5, r#" marker-end="url(#arr-x)""#));
    out.push(text(MARGIN + 204.0, ly + 4.0, 10.0, LEGEND_C, "normal", "start", "calls (cross-crate)", ""));

    out.push("</svg>".to_string());
    out.join("\n")
}
