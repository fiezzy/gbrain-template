---
type: note
title: How this inbox works
---

# How this inbox works

This directory is the brain's only **writable** source. Everything else in the
index is a derived cache of a git repository: a page written into a code source
is discarded by the next sync. Notes live here, in git, in plain markdown.

Agents write here through the `put_page` MCP tool — the MCP wrapper sets
`GBRAIN_SOURCE=inbox` so writes land in this directory rather than the seeded
`default` source. You can also just create a `.md` file by hand; the next
`refresh.sh` picks it up.

## What belongs here

Decisions and their reasoning. Non-obvious findings that cost someone an
afternoon. Context that is true about the system but written down nowhere in
the code: why a service is structured the way it is, which of two similar
modules is the live one, what a past migration actually did.

## What does not

Anything the code already says. A note restating a function's behaviour is
worse than nothing — it competes with the real thing in search results and goes
stale silently.

## Write them properly

Retrieval ranks a note against thousands of code chunks. A three-line note will
never surface, no matter how true it is. Include the words someone would search
for: service names, symbol names, error strings, the ticket id. State the
conclusion in the title.

Optional frontmatter, useful for filtering later:

```markdown
---
type: note
title: Why the payment retry lives in the worker, not the API
tags: [payments, architecture]
---
```
