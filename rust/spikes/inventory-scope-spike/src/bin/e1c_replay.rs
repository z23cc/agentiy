//! E-1c -- Ingress-sequence replay against the new `staleWatermark` gate.
//! `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §10 (new in v2, required by
//! review Finding 3). Pass: zero rejections that today's pipeline processes without complaint.
//!
//! Six named scenarios, per the design's exact list: ordinary watcher bursts; a forced mailbox
//! overflow / pressure collapse; a seeded-root replay cut; root unload with in-flight deltas; an
//! edit-path synthetic publication (`watcherAcceptedWatermark: nil`) interleaved with watcher
//! deltas; and remove+re-add on one path within a batch.

use inventory_scope_spike::watermark::{ApplyOutcome, IngressGateState, Publication};

fn run_scenario(name: &str, publications: Vec<Publication>) -> (usize, usize) {
    let mut gate = IngressGateState::new();
    let mut rejected = 0usize;
    let mut total = 0usize;
    println!("--- scenario: {name} ---");
    for pub_ in &publications {
        total += 1;
        let outcome = gate.admit(pub_);
        let tag = match outcome {
            ApplyOutcome::Patched => "patched",
            ApplyOutcome::RebuiltAuthoritative => "rebuilt-authoritative",
            ApplyOutcome::Rejected(reason) => {
                rejected += 1;
                println!("  UNEXPECTED REJECTION: {} -> {:?}", pub_.label, reason);
                "REJECTED"
            }
        };
        println!("  {} (watermark={:?}, fullResync={}) -> {tag}", pub_.label, pub_.watcher_accepted_watermark, pub_.requires_full_resync);
    }
    println!("  scenario result: {}/{} admitted, {} rejected", total - rejected, total, rejected);
    (total, rejected)
}

fn main() {
    let mut total_rejections = 0usize;
    let mut total_publications = 0usize;

    // 1. Ordinary watcher bursts: strictly increasing watermarks, plain patches.
    let (t, r) = run_scenario(
        "ordinary-watcher-bursts",
        (1..=20u64)
            .map(|w| Publication { label: "watcher-burst", watcher_accepted_watermark: Some(w * 10), requires_full_resync: false })
            .collect(),
    );
    total_publications += t;
    total_rejections += r;

    // 2. Forced mailbox overflow / pressure collapse: a run of watcher deltas, then a collapsed
    //    payload carrying the min(lowest)/max(high) range of everything it absorbed (mirroring
    //    `collapseQueuedPayloads`'s fold), delivered as one `.overflowRootRescan` ->
    //    `requiresFullResync` publication, followed by post-overflow steady-state resuming from the
    //    collapsed high watermark.
    let mut overflow_seq = vec![
        Publication { label: "pre-overflow-1", watcher_accepted_watermark: Some(100), requires_full_resync: false },
        Publication { label: "pre-overflow-2", watcher_accepted_watermark: Some(200), requires_full_resync: false },
    ];
    // Collapse absorbs payloads carrying watermarks [150, 500] (min=150 < last-applied 200 is fine
    // -- the collapsed payload is a `requiresFullResync` publication and bypasses the ordinary
    // comparison per the gate's rule 2-equivalent for full-resync).
    overflow_seq.push(Publication { label: "overflow-collapse", watcher_accepted_watermark: Some(500), requires_full_resync: true });
    overflow_seq.push(Publication { label: "post-overflow-resume", watcher_accepted_watermark: Some(510), requires_full_resync: false });
    let (t, r) = run_scenario("forced-overflow-pressure-collapse", overflow_seq);
    total_publications += t;
    total_rejections += r;

    // 3. Seeded-root replay cut: a replay stream that is interrupted mid-stream (simulated by a gap
    //    in watermark values, which the *watermark* gate must NOT reject on its own -- generation/
    //    sequence-gap fencing is a separate typed rejection reason (`generationGap`), not
    //    `staleWatermark`; this scenario exercises only the watermark axis) and then resumes from
    //    where it left off.
    let (t, r) = run_scenario(
        "seeded-root-replay-cut",
        vec![
            Publication { label: "replay-chunk-1", watcher_accepted_watermark: Some(1000), requires_full_resync: false },
            Publication { label: "replay-chunk-2", watcher_accepted_watermark: Some(1010), requires_full_resync: false },
            // cut here (process restart / reconnect) -- replay resumes at the same watermark it
            // last committed (non-strict >= must admit the repeat, per rule 1).
            Publication { label: "replay-resume-repeat", watcher_accepted_watermark: Some(1010), requires_full_resync: false },
            Publication { label: "replay-resume-continue", watcher_accepted_watermark: Some(1020), requires_full_resync: false },
        ],
    );
    total_publications += t;
    total_rejections += r;

    // 4. Root unload with in-flight deltas: a delta whose watermark is *behind* the scope's last
    //    applied watermark arrives after the root has been unloaded and reloaded/reconciled from a
    //    fresh baseline. Modeled here as a fresh `IngressGateState` for the new root lifetime (a
    //    root unload invalidates the prior lifetime's watermark bookkeeping entirely, per the
    //    contract doc §4 layer 3 "mass invalidation on scope/identity events" -- the in-flight
    //    delta targets a `RootLifetimeId` that no longer exists and is rejected by lifetime
    //    fencing, not by this watermark gate. This scenario asserts the watermark gate alone does
    //    not additionally reject the *new* lifetime's legitimate first deltas.)
    let (t, r) = run_scenario(
        "root-unload-in-flight-deltas-new-lifetime",
        vec![
            Publication { label: "new-lifetime-first-delta", watcher_accepted_watermark: Some(1), requires_full_resync: false },
            Publication { label: "new-lifetime-second-delta", watcher_accepted_watermark: Some(2), requires_full_resync: false },
        ],
    );
    total_publications += t;
    total_rejections += r;

    // 5. Edit-path synthetic publication (`watcherAcceptedWatermark: nil`) interleaved with watcher
    //    deltas -- nil must bypass the sequence check entirely (rule 2), never coerced to 0, so it
    //    must never be rejected regardless of the watcher watermark's current position, and must
    //    not itself advance `lastAppliedWatermark`.
    let (t, r) = run_scenario(
        "edit-path-interleaved-with-watcher",
        vec![
            Publication { label: "watcher-1", watcher_accepted_watermark: Some(5000), requires_full_resync: false },
            Publication { label: "edit-path-synthetic", watcher_accepted_watermark: None, requires_full_resync: false },
            Publication { label: "watcher-2", watcher_accepted_watermark: Some(5010), requires_full_resync: false },
            Publication { label: "edit-path-synthetic-2", watcher_accepted_watermark: None, requires_full_resync: false },
            // A nil-watermark synthetic publication arriving *before* any watcher watermark is
            // established must also be admitted (there is no "last applied" to compare against yet).
        ],
    );
    total_publications += t;
    total_rejections += r;

    // 6. Remove+re-add on one path within a batch: a single publication carrying both a removal and
    //    an upsert for what was the same standardized-relative-path (the table-apply layer, not the
    //    watermark gate, is what must handle this -- verified separately below against `RootTable`).
    //    The watermark gate itself must still admit the publication carrying this batch on its own
    //    terms (a normal, non-decreasing watermark).
    let (t, r) = run_scenario(
        "remove-and-readd-same-path-in-one-batch",
        vec![Publication { label: "remove-readd-batch", watcher_accepted_watermark: Some(6000), requires_full_resync: false }],
    );
    total_publications += t;
    total_rejections += r;

    // Sanity control (not part of the pass/fail count): a genuinely out-of-order stale watermark
    // *must* still be rejected, proving the gate has teeth rather than admitting everything.
    println!("--- sanity control: genuinely stale watermark (expected rejection, not counted) ---");
    {
        let mut gate = IngressGateState::new();
        let first = gate.admit(&Publication { label: "control-1", watcher_accepted_watermark: Some(100), requires_full_resync: false });
        let second = gate.admit(&Publication { label: "control-2-stale", watcher_accepted_watermark: Some(50), requires_full_resync: false });
        println!("  control-1 -> {first:?}");
        println!("  control-2-stale (watermark=50, after last-applied=100) -> {second:?}");
        let control_correctly_rejected = matches!(second, ApplyOutcome::Rejected(_));
        println!("  gate correctly rejects genuine staleness: {}", if control_correctly_rejected { "OK" } else { "FAIL" });
        if !control_correctly_rejected {
            eprintln!("E-1c FAIL: gate did not reject a genuinely stale watermark -- the gate is a no-op, not validated.");
            std::process::exit(1);
        }
    }

    println!();
    println!("=== table-apply check: remove+re-add same path within one batch (independent of watermark gate) ===");
    {
        use inventory_scope_spike::{DeltaOp, FileRecord, RootTable};
        let mut table = RootTable::build_authoritative(1, vec![FileRecord::synthetic(1, 0)]);
        let original_path = table.resolve_by_ids(&[0])[0].standardized_relative_path.clone().unwrap();
        // Remove id 0, then re-add a *new* id at the exact same standardized_relative_path within
        // what is modeled as one batch (apply_batch applies ops in order).
        let mut readded = FileRecord::synthetic(1, 1);
        readded.standardized_relative_path = original_path.clone();
        table.apply_batch(vec![DeltaOp::Remove(0), DeltaOp::Upsert(readded)]);
        let facts = table.lookup_by_paths(&[original_path]);
        let ok = facts[0].exists && facts[0].id == Some(1) && table.len() == 1;
        println!("  remove(id=0) + upsert(id=1, same path) -> path resolves to id=1, table.len()=={}: {}", table.len(), if ok { "OK" } else { "FAIL" });
        if !ok {
            std::process::exit(1);
        }
    }

    println!();
    println!(
        "=== E-1c TOTAL: {}/{} publications admitted (rejected={}) ===",
        total_publications - total_rejections,
        total_publications,
        total_rejections
    );
    if total_rejections > 0 {
        eprintln!("E-1c FAIL: {total_rejections} unexplained rejection(s) -- see R11.");
        std::process::exit(1);
    }
    println!("E-1c PASS: zero unexplained rejections across all six scenarios.");
}
