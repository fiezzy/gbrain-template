# Agent policy

Paste the block below into each project's `CLAUDE.md` / `AGENTS.md`, replacing
`<BRAIN_ID>` and the repo list. Without it, agents will not use the brain —
and worse, they will use it wrongly and conclude it is empty.

The one line that matters most is the `source_id: "__all__"` rule. An
unqualified query scopes to a single source; since the MCP wrapper points
writes at the inbox, an agent that omits it searches the notes, finds nothing,
and reports that the knowledge base doesn't know. See `docs/TRAPS.md`.

---

```markdown
## Knowledge base (gbrain MCP) — search it FIRST

This workspace has an indexed knowledge base covering <N> repositories
(<repo-a>, <repo-b>, ...) on their integration branches, plus the team's
written notes. It is exposed as the `<BRAIN_ID>` MCP server.

- **Before** grepping across repos, spawning search agents, or answering any
  "how does X work in our system" question: call `query` with
  `source_id: "__all__"`. This is MANDATORY — without it the search covers
  only the notes, not the code. Questions in any language work; the embedder
  is cross-lingual.
- `code_def` / `code_refs`: sub-100ms symbol lookup across every indexed repo.
  Use these instead of ripgrep when you want a definition or call sites.
- **When two versions of the same thing are indexed** (for example `<id>-v1` and
  `<id>-v2` of one repository on two branches), an unscoped search returns both,
  and they look nearly identical. Always check the `source_id` on a result
  before quoting it, and when you already know which version the task concerns,
  scope the query to it: `source_id: "<id>-v2"`. Never mix contract versions in
  one answer without saying which is which.
- The index covers **integration branches only** and may lag your checkout.
  For symbol-precise work on the CURRENT branch, read local files as usual.
  The index answers "how does this system work", not "what does my working
  tree say right now".
- When a session produces a decision, a non-obvious finding, or a piece of
  hard-won context: save it with `put_page`. It lands in the git-versioned
  inbox and every future session can find it. Write it properly — with the
  keywords someone would search for. Terse notes lose to code chunks in
  ranking and are effectively invisible.
- Never write into a code source. Those are derived caches of git; the next
  sync discards anything written there. The inbox is the only writable place.
```

---

## Notes on wording

**Say "FIRST", not "consider".** Agents that treat the brain as one option
among many will grep instead, because grepping is familiar. The instruction has
to establish an order.

**Say what the brain is bad at.** The bullet about the index lagging the
working tree prevents the failure where an agent trusts a stale indexed version
of a file it could have just read. An agent that knows the boundary uses the
tool better than one told the tool is great.

**Explain why notes must be substantial.** Retrieval ranks a three-line note
against thousands of code chunks. "Fixed the thing" will never surface. This is
worth spelling out, because the natural instinct when writing a note is to be
brief.
