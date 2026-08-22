//! The `staleWatermark` ingress gate and the `generationGap` sequencing check, applied to every
//! `InventoryDeltaCommand` before the state machine attempts a patch or rebuild.
//!
//! Watermark rules verified against the live implementation during P4-2 and frozen in
//! `docs/architecture/rust-inventory-scope-v1.md` §5.1 (three constraints):
//! 1. Non-strict comparison (`accepted >= lastApplied`); consecutive publications may repeat a
//!    watermark value.
//! 2. `nil` (`None`) bypasses the sequence check entirely and is never coerced to zero.
//! 3. Pressure collapse must pass: a collapsed overflow batch's high watermark is
//!    non-decreasing, so the gate must never reject an overflow/full-resync sequence -- modeled
//!    here by `requires_full_resync` bypassing the comparison the same way the seeded-replay
//!    guard does in the Swift source.
//!
//! `generationGap` is this crate's flagged minimal interpretation of an underspecified contract
//! line -- see `fallback::InventoryRejectionReason::GenerationGap`'s doc comment.

use super::fallback::InventoryRejectionReason;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct IngressGateState {
    last_applied_watermark: Option<u64>,
}

impl IngressGateState {
    #[must_use]
    pub const fn new() -> Self {
        Self {
            last_applied_watermark: None,
        }
    }

    /// Checks (and, on acceptance, updates) the watermark sequence. Returns `Ok(())` if the
    /// publication is admissible, `Err(reason)` if it must be rejected as stale.
    ///
    /// `requires_full_resync` bypasses the comparison entirely (rule 3): a full resync
    /// re-establishes the baseline and is definitionally not stale. When it carries a watermark,
    /// that watermark still advances the tracked baseline (via `max`, matching the pressure
    /// collapse's `max(high)` fold) so a later steady-state delta compares against it correctly.
    pub fn admit_watermark(
        &mut self,
        watcher_accepted_watermark: Option<u64>,
        requires_full_resync: bool,
    ) -> Result<(), InventoryRejectionReason> {
        if requires_full_resync {
            if let Some(watermark) = watcher_accepted_watermark {
                self.last_applied_watermark = Some(
                    self.last_applied_watermark
                        .map_or(watermark, |last| last.max(watermark)),
                );
            }
            return Ok(());
        }
        match watcher_accepted_watermark {
            None => Ok(()), // rule 2: nil bypasses the sequence check entirely
            Some(watermark) => match self.last_applied_watermark {
                Some(last) if watermark < last => Err(InventoryRejectionReason::StaleWatermark {
                    expected: last,
                    actual: watermark,
                }),
                _ => {
                    self.last_applied_watermark = Some(watermark); // rule 1: non-strict >=
                    Ok(())
                }
            },
        }
    }

    #[must_use]
    pub const fn last_applied_watermark(&self) -> Option<u64> {
        self.last_applied_watermark
    }
}

/// Checks the flagged `generationGap` interpretation: if the caller states an expected prior
/// applied-index generation, it must match the root's actual last-applied generation.
/// `requires_full_resync` bypasses this check the same way it bypasses the watermark gate --
/// a full resync is not built on top of any prior generation.
pub fn check_generation_gap(
    expected_applied_index_generation: Option<u64>,
    actual_last_applied_index_generation: u64,
    requires_full_resync: bool,
) -> Result<(), InventoryRejectionReason> {
    if requires_full_resync {
        return Ok(());
    }
    match expected_applied_index_generation {
        None => Ok(()),
        Some(expected) if expected == actual_last_applied_index_generation => Ok(()),
        Some(expected) => Err(InventoryRejectionReason::GenerationGap {
            expected: actual_last_applied_index_generation,
            actual: expected,
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nil_watermark_bypasses_sequence_check() {
        let mut gate = IngressGateState::new();
        assert_eq!(gate.admit_watermark(Some(10), false), Ok(()));
        // A nil watermark after a high one is admitted unconditionally (rule 2), and does not
        // move the tracked baseline backward.
        assert_eq!(gate.admit_watermark(None, false), Ok(()));
        assert_eq!(gate.last_applied_watermark(), Some(10));
    }

    #[test]
    fn equal_watermark_is_admitted_non_strict() {
        let mut gate = IngressGateState::new();
        assert_eq!(gate.admit_watermark(Some(5), false), Ok(()));
        assert_eq!(gate.admit_watermark(Some(5), false), Ok(()));
    }

    #[test]
    fn lower_watermark_is_rejected_as_stale() {
        let mut gate = IngressGateState::new();
        assert_eq!(gate.admit_watermark(Some(10), false), Ok(()));
        assert_eq!(
            gate.admit_watermark(Some(9), false),
            Err(InventoryRejectionReason::StaleWatermark {
                expected: 10,
                actual: 9
            })
        );
    }

    #[test]
    fn full_resync_bypasses_watermark_check_and_advances_baseline_via_max() {
        let mut gate = IngressGateState::new();
        assert_eq!(gate.admit_watermark(Some(10), false), Ok(()));
        // A collapsed overflow publication carrying a lower watermark than the current baseline
        // must still be admitted when it is a full resync (pressure collapse must pass, rule 3).
        assert_eq!(gate.admit_watermark(Some(3), true), Ok(()));
        assert_eq!(gate.last_applied_watermark(), Some(10)); // max(10, 3) == 10
        // A subsequent steady-state delta compares against the max-preserved baseline.
        assert_eq!(
            gate.admit_watermark(Some(9), false),
            Err(InventoryRejectionReason::StaleWatermark {
                expected: 10,
                actual: 9
            })
        );
    }

    #[test]
    fn generation_gap_matches_expected_generation() {
        assert_eq!(check_generation_gap(None, 5, false), Ok(()));
        assert_eq!(check_generation_gap(Some(5), 5, false), Ok(()));
        assert_eq!(
            check_generation_gap(Some(3), 5, false),
            Err(InventoryRejectionReason::GenerationGap {
                expected: 5,
                actual: 3
            })
        );
    }

    #[test]
    fn generation_gap_check_bypassed_on_full_resync() {
        assert_eq!(check_generation_gap(Some(3), 5, true), Ok(()));
    }
}
