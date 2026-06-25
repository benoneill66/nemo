# Plan 11 — Retrieval-augmented "Hey Nemo"

**Theme:** Reach · **Effort:** M · **Depends on:** 01 (embedding index), helped by 05 (provenance)

## Goal

Make "Hey Nemo, …" answer from *your own history first*. "What did I say I'd send Sarah?" should
retrieve the relevant memories/transcript and answer from them — that's the unique value over
plain Claude, which today is all the wake flow uses.

## Why

`answer()` (AppState.swift:500) currently forwards the spoken question straight to
`claudeOneShot` with a generic voice-assistant system prompt and web search — it knows nothing
about the user's memory graph. So Nemo can tell you the weather but not what you decided in
yesterday's meeting. Grounding answers in retrieved memory turns Nemo from "a voice frontend to
Claude" into "a voice interface to your life", which is the whole point of building the memory
graph.

## Current state

- `answer(_ question:)` (AppState.swift:500) → `AssistantRunner.claudeOneShot(prompt:system:model:)`
  with a fixed spoken-style system prompt; result spoken via `Speaker`.
- Wake detection (`wakeQuestion`, AppState.swift:151) extracts the question text after "hey nemo".
- Plan 01 gives `EmbeddingIndex.search(query, limit:)`; `Surfacer.rankHybrid` ranks memories.
- Plan 05 gives `sourceSegments(for:)` for grounding/citation.

## Design

### 1. Retrieve

On a wake question, before calling the CLI, build a context block:
- `embeddings.search(question, limit: 8)` ∪ `Surfacer.rank(recent: question, …)` → top memories
  (union of semantic + lexical, dedup by id, keep ~6).
- Optionally pull each hit's `sourceSegments` (plan 05) for verbatim grounding when the question is
  specific ("what exactly did I say…").
- Also include the recent live transcript window (already assembled for surfacing) so follow-ups
  ("what about the other one?") have conversational context.

### 2. Ground the prompt

Construct a memory-aware system + user prompt:

```
System: You are Nemo, the user's personal memory assistant, answering out loud. Answer from
the user's MEMORIES below when they're relevant; say so plainly if the memories don't cover it,
then you may use web search for general/current facts. One to three spoken sentences, no markdown.

User:
MEMORIES:
- [Decisions] "Q3 deadline" — moved to Oct 15 (updated 3 days ago)
- [Action Items] "Send Sarah the deck" — owed to Sarah, due Friday
...
RECENT CONVERSATION: <window>
QUESTION: <the spoken question>
```

Keep web search available (the existing `runClaude` system prompt enables it) so general questions
still work, but instruct memory-first. Route through `claudeOneShot` (or the streaming `run` for
faster spoken playback).

### 3. Distinguish memory questions from general ones (optional, cheap)

Not every wake question is about memory ("what's the weather"). Two options:
- **Always include memories**, let the model decide relevance (simplest, robust — recommended v1).
- A cheap pre-classify (gate-style Haiku) only if including memories noticeably hurts general
  answers in testing.

### 4. Reinforce + cite

- Memories used in an answer get a reinforcement bump (plan 02) and `lastSurfaced` update — being
  *asked about* is a strong relevance signal.
- Optionally set `lastAnswer` plus a small "based on N memories" note in the UI; tapping shows
  which memories (provenance, plan 05) for trust.

## Files touched

- `Sources/Nemo/AppState.swift` — `answer()` builds retrieval context; reinforce used memories.
- **New (or extend Assistants.swift):** a `memoryAnswer(question:context:)` helper that assembles
  the grounded prompt (keep prompt-building out of `AppState`).
- `Sources/Nemo/EmbeddingIndex.swift` (plan 01) — reuse `search`.
- `Sources/Nemo/Config.swift` — `memoryGroundedAnswers` (default true), `answerMemoryK`.

## Edge cases

- **No relevant memories:** the model should fall back to general/web answer gracefully (prompt
  instructs this) — never refuse with "I don't have that in memory" when it's a general question.
- **Stale/ superseded memories** (plan 04): exclude `superseded` from retrieval so answers use the
  current fact.
- **Privacy:** retrieved memory text *is* sent to the CLI — same trust boundary as consolidation,
  which already sends transcripts. Honour redaction (plan 06). Note it in docs.
- **Latency:** retrieval is on-device and fast; the CLI call dominates as today. No regression.

## Testing (see plan 07)

- Unit: retrieval context builder dedups semantic+lexical hits, caps to K, excludes superseded.
- Unit: prompt assembly includes memories and the question in the expected structure.
- Manual: store a decision, then ask about it by paraphrase; confirm the spoken answer reflects the
  memory (and the right, post-supersede version), and that "what's the weather" still works.

## Risks / open questions

- Over-stuffing the prompt with marginally-relevant memories can degrade answers — keep K small and
  rely on the hybrid ranking's quality (tune alongside plan 01).
- Deciding when to prefer memory vs web for ambiguous questions ("what's my next meeting" — memory;
  "what's the score" — web). The memory-first instruction + the model's judgement handles most;
  revisit with a classifier only if testing shows misses.
