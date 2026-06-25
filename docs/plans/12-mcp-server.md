# Plan 12 — Local MCP memory server

**Theme:** Reach · **Effort:** M · **Depends on:** — (richer with 01's semantic search)

## Goal

Expose Nemo's memory graph as a local MCP (Model Context Protocol) server so Claude Code, Claude
Desktop, and other MCP clients can read the user's real-world spoken context — turning Nemo into a
context provider for the user's whole AI workflow.

## Why

Nemo accumulates a uniquely valuable corpus: the user's decisions, action items, people, and
preferences, captured passively. Today that's locked inside the app. Exposing it over MCP means
when the user asks Claude Code to "draft the follow-up email from yesterday's planning meeting",
Claude can actually *retrieve* what was said. This is a strong differentiator and a natural fit —
Nemo already shells out to the Claude CLI; an MCP server is the inverse, letting Claude reach back
in.

## Current state

- Data is in `~/.config/nemo/data/*.json` (Store.swift), owned at runtime by `AppState`.
- The app already manages subprocesses and JSON; an MCP stdio server is well within its wheelhouse.
- No external read/query interface exists.

## Design

### Shape: a separate stdio executable, sharing the data layer

MCP servers are typically launched on demand by the client over stdio. So add a **second
executable target** `nemo-mcp` that reads the same `~/.config/nemo/data` store (read-only by
default) and speaks MCP over stdin/stdout. This decouples it from the GUI app's lifecycle (the
client starts it when needed) while sharing `Store`/`Models` code.

```swift
// Package.swift
.executableTarget(name: "NemoMCP", path: "Sources/NemoMCP")
// shares Models/Store via a small common library target, or includes the files.
```

Refactor the pure data types (`Memory`, `Session`, `TranscriptSegment`, `Store` read paths,
`Surfacer`, `EmbeddingIndex`) into a `NemoCore` library target that both `Nemo` (app) and
`NemoMCP` depend on. (This library extraction also helps plan 07's `@testable` story.)

### Tools exposed

- `search_memories(query, limit)` — hybrid lexical+semantic search (plan 01), returns
  title/content/category/importance/entities/links.
- `get_memory(id)` — full memory + linked memories + provenance segments (plan 05).
- `list_recent(category?, since?)` — recent or category-filtered memories.
- `search_transcript(query, since?)` — FTS over retained segments (great once plan 10 lands; until
  then a scan).
- `list_action_items(open_only)` — convenience over the Action Items category.
- (Optional, gated) `add_memory(title, content, category)` — write path, off by default; requires
  explicit opt-in in config because it lets a client mutate the user's memory.

Implement MCP framing by hand (JSON-RPC 2.0 over stdio: `initialize`, `tools/list`, `tools/call`)
— small and dependency-free, consistent with the project's ethos. The protocol surface needed is
modest.

### Discovery / install

- Ship a `claude mcp add` snippet / `.mcp.json` example in the README pointing at the built
  `nemo-mcp` binary.
- Respect a config flag so the user explicitly enables exposure.

## Files touched

- `Package.swift` — extract `NemoCore` library; add `NemoMCP` executable target.
- **New:** `Sources/NemoMCP/main.swift` (+ a small `MCPServer.swift` for JSON-RPC framing,
  `Tools.swift` for the tool implementations).
- Move shared types into `Sources/NemoCore/` (Models, Store read API, Surfacer, EmbeddingIndex).
- `Sources/Nemo/` and `Sources/NemoMCP/` both depend on `NemoCore`.
- README — install + config instructions.
- `Config` — `mcpEnabled`, `mcpAllowWrite` (default false).

## Edge cases

- **Read/write race with the running app:** the GUI app holds the working set in memory and writes
  files; the MCP server reading the same files sees the last flushed state — acceptable for reads.
  Writes (if enabled) must go through atomic file writes and the app should reload on external
  change (watch the file or reload on focus). Keep write off by default to sidestep this initially.
- **Privacy:** this exposes memory to whatever MCP client is configured — must be explicit opt-in,
  clearly documented, local-only (stdio, no network listener).
- **Stale embeddings:** the MCP server can compute query embeddings itself (NLEmbedding is
  available to any process); reuse the cached memory vectors from `embeddings.json`.

## Testing (see plan 07)

- Unit (in `NemoCore`): the query/tool logic (search, list_action_items filtering) independent of
  the JSON-RPC transport.
- Integration: drive `nemo-mcp` with canned JSON-RPC requests over a pipe; assert `tools/list` and
  a `tools/call search_memories` response shape.
- Manual: register with `claude mcp add`, ask Claude Code to find an action item, confirm retrieval.

## Risks / open questions

- The library extraction (`NemoCore`) is the main structural change; do it carefully so the GUI app
  keeps building (CI covers this). It's a healthy refactor regardless.
- Hand-rolled MCP framing must track the spec's required methods; scope to the minimum
  (`initialize`, `tools/list`, `tools/call`) and expand as needed.
- Decide whether to ship `nemo-mcp` in the `.app` bundle (so the path is stable) or as a separate
  binary; bundling is cleaner for `claude mcp add` instructions.
