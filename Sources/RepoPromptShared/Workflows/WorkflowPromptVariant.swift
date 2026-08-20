import Foundation

/// Variant for tool invocation examples in prompts.
public enum WorkflowPromptVariant: Sendable {
    case mcp // JSON-style MCP tool calls
    case cli // agentry-cli command line
    case agent // Agent mode – MCP syntax, auto-mapped workspace, uses ask_oracle

    var preamble: String {
        switch self {
        case .mcp, .agent:
            ""
        case .cli:
            """
            ## Using agentry-cli

            This workflow uses **agentry-cli** (RepoPrompt CLI) instead of MCP tool calls. Run commands via:

            ```bash
            agentry-cli -e '<command>'
            ```

            **Quick reference:**

            | MCP Tool | CLI Command |
            |----------|-------------|
            | `get_file_tree` | `agentry-cli -e 'tree'` |
            | `file_search` | `agentry-cli -e 'search "pattern"'` |
            | `get_code_structure` | `agentry-cli -e 'structure path/'` |
            | `read_file` | `agentry-cli -e 'read path/file.swift'` |
            | `manage_selection` | `agentry-cli -e 'select add path/'` |
            | `context_builder` | `agentry-cli -e 'builder "instructions" --response-type plan'` |
            | `oracle_send` | `agentry-cli -e 'chat "message" --mode plan'` |
            | `apply_edits` | `agentry-cli -e 'call apply_edits {"path":"...","search":"...","replace":"..."}'` |
            | `file_actions` | `agentry-cli -e 'call file_actions {"action":"create","path":"..."}'` |

            Chain commands with `&&`:
            ```bash
            agentry-cli -e 'select set src/ && context'
            ```

            Use `agentry-cli -e 'describe <tool>'` for help on a specific tool, `agentry-cli --tools-schema` for machine-readable JSON schemas, or `agentry-cli --help` for CLI usage.

            JSON args (`-j`) accept inline JSON, file paths (`.json` auto-detected), `@file`, or `@-` (stdin). Raw newlines in strings are auto-repaired.

            **⚠️ TIMEOUT WARNING:** The `builder` and `chat` commands can take several minutes to complete. When invoking agentry-cli, **set your command timeout to at least 2700 seconds (45 minutes)** to avoid premature termination.

            ---

            """
        }
    }

    var frontmatterVariantName: String {
        switch self {
        case .cli: "cli"
        case .agent: "agent"
        case .mcp: "mcp"
        }
    }
}
