/// Deterministically assign a hex color to a file path.
/// Uses a small palette of metro-style colors.
const PALETTE: &[&str] = &[
    "#E84B3A", // red
    "#3A9BE8", // blue
    "#3AE87A", // green
    "#E8C03A", // yellow
    "#C03AE8", // purple
    "#E8753A", // orange
    "#3AE8D8", // teal
    "#E83A9B", // pink
];

pub fn for_file(file_id: &str) -> String {
    let hash: u64 = file_id
        .bytes()
        .fold(0xcbf29ce484222325u64, |acc, b| {
            acc.wrapping_mul(0x100000001b3).wrapping_add(b as u64)
        });
    PALETTE[(hash as usize) % PALETTE.len()].to_string()
}
