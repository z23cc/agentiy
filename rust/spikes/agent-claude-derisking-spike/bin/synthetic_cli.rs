//! E-P6-3 synthetic CLI stand-in (design section 8 / contract section 5.4). Selected by `mode` in
//! argv[1]; writes NDJSON-shaped lines to stdout per the chosen adversarial behavior. Does not
//! implement the real `stream-json` protocol (that is P6-3's codec, out of this spike's scope) --
//! lines are `{"seq":N,"payload":"..."}`, enough for the reader (`src/stream.rs`) to frame and
//! count without needing a real decoder.
//!
//! Modes implemented (see the P6-2 results doc for the full E-P6-3 matrix and which rows this
//! subset does and does not cover):
//! - `flood <bytes_per_sec> <duration_ms>`: writes well-formed lines at approximately the given
//!   rate for the given duration, then exits 0.
//! - `oversized-line <mib>`: writes one line of the given size (intended > the reader's 8 MiB
//!   framer cap), then a trailing well-formed line, then exits 0.
//! - `mid-line-stall <stall_ms>`: writes a partial (unterminated) line, sleeps, then completes it
//!   and exits 0.
//! - `stdin-starved-flood <duration_ms>`: the deadlock probe -- floods stdout at max rate and
//!   never reads stdin at all, for the given duration, then exits 0.

use std::io::Write;
use std::time::{Duration, Instant};

fn write_line(out: &mut impl Write, seq: u64) -> std::io::Result<()> {
    writeln!(out, r#"{{"seq":{seq},"payload":"synthetic-cli-line"}}"#)
}

fn flood(bytes_per_sec: u64, duration: Duration) {
    let stdout = std::io::stdout();
    let mut out = std::io::BufWriter::new(stdout.lock());
    let start = Instant::now();
    let mut seq: u64 = 0;
    let approx_line_len: u64 = 40;
    let target_lines_per_sec = (bytes_per_sec / approx_line_len).max(1);
    let mut last_flush = Instant::now();
    while start.elapsed() < duration {
        for _ in 0..target_lines_per_sec.min(4096) {
            let _ = write_line(&mut out, seq);
            seq += 1;
        }
        if last_flush.elapsed() >= Duration::from_millis(20) {
            let _ = out.flush();
            last_flush = Instant::now();
        }
    }
    let _ = out.flush();
}

fn oversized_line(mib: u64) {
    let stdout = std::io::stdout();
    let mut out = std::io::BufWriter::new(stdout.lock());
    let payload_len = (mib * 1024 * 1024) as usize;
    let payload = "x".repeat(payload_len);
    let _ = writeln!(out, r#"{{"seq":0,"payload":"{payload}"}}"#);
    let _ = write_line(&mut out, 1);
    let _ = out.flush();
}

fn mid_line_stall(stall: Duration) {
    let stdout = std::io::stdout();
    let mut out = std::io::BufWriter::new(stdout.lock());
    let _ = write!(out, r#"{{"seq":0,"payload":"partial-before-stall"#);
    let _ = out.flush();
    std::thread::sleep(stall);
    let _ = writeln!(out, r#"-after-stall"}}"#);
    let _ = write_line(&mut out, 1);
    let _ = out.flush();
}

fn stdin_starved_flood(duration: Duration) {
    // Deliberately never touches stdin -- the deadlock-probe shape (design section 8 E-P6-3: "a
    // child that stops reading its stdin while continuing to write stdout at max rate").
    flood(50_000_000, duration);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("flood") => {
            let bps: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(10_000_000);
            let ms: u64 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(500);
            flood(bps, Duration::from_millis(ms));
        }
        Some("oversized-line") => {
            let mib: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(9);
            oversized_line(mib);
        }
        Some("mid-line-stall") => {
            let ms: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(500);
            mid_line_stall(Duration::from_millis(ms));
        }
        Some("stdin-starved-flood") => {
            let ms: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(2000);
            stdin_starved_flood(Duration::from_millis(ms));
        }
        other => {
            eprintln!("unknown synthetic_cli mode: {other:?}");
            std::process::exit(2);
        }
    }
}
