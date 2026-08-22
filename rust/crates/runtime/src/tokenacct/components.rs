//! Pure port of `TokenCalculationService.calculateComponentBreakdown`.

use super::estimate::estimate_tokens;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ComponentInput<'a> {
    pub prompt_text: &'a str,
    pub selected_instructions_text: &'a str,
    pub file_tree_text: &'a str,
    /// Mirrors Swift's `gitDiffText: String?` -- `nil` and `Some("")` are behaviorally identical
    /// here (`estimateTokens(for: "")` is always `0`), so callers pass `""` for `nil`.
    pub git_diff_text: &'a str,
    /// Mirrors Swift's `metadataText: String?` -- same `nil`/`Some("")` equivalence as above.
    pub metadata_text: &'a str,
    pub duplicate_user_instructions_at_top: bool,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ComponentBreakdown {
    pub prompt: u64,
    pub duplicate_prompt: u64,
    pub instructions: u64,
    pub file_tree: u64,
    pub git_diff: u64,
    pub metadata: u64,
}

/// Mirrors `TokenCalculationService.calculateComponentBreakdown` exactly, including the
/// `fileTreeText.isEmpty` short-circuit (which happens to be a no-op given `estimateTokens("")
/// == 0`, but is replicated for direct correspondence with the Swift source).
#[must_use]
pub fn compute_component_breakdown(input: &ComponentInput<'_>) -> ComponentBreakdown {
    let prompt = estimate_tokens(input.prompt_text);
    let duplicate_prompt = if input.duplicate_user_instructions_at_top { prompt } else { 0 };
    let instructions = estimate_tokens(input.selected_instructions_text);
    let file_tree = if input.file_tree_text.is_empty() {
        0
    } else {
        estimate_tokens(input.file_tree_text)
    };
    let git_diff = estimate_tokens(input.git_diff_text);
    let metadata = estimate_tokens(input.metadata_text);
    ComponentBreakdown {
        prompt,
        duplicate_prompt,
        instructions,
        file_tree,
        git_diff,
        metadata,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn duplicate_prompt_mirrors_prompt_only_when_flagged() {
        let breakdown = compute_component_breakdown(&ComponentInput {
            prompt_text: "hello world",
            duplicate_user_instructions_at_top: true,
            ..Default::default()
        });
        assert_eq!(breakdown.prompt, breakdown.duplicate_prompt);
        assert!(breakdown.prompt > 0);

        let breakdown = compute_component_breakdown(&ComponentInput {
            prompt_text: "hello world",
            duplicate_user_instructions_at_top: false,
            ..Default::default()
        });
        assert_eq!(breakdown.duplicate_prompt, 0);
    }

    #[test]
    fn empty_inputs_produce_all_zero_breakdown() {
        let breakdown = compute_component_breakdown(&ComponentInput::default());
        assert_eq!(breakdown, ComponentBreakdown::default());
    }
}
