# Platform team subagents

Claude Code custom subagents you can call by platform-team name, e.g.
`python-team` and `rust-team`.

## Invoking them

In a Claude Code session, just reference the agent by name:

- "Ask **python-team** to add retry/backoff to the order-execution path."
- "Have **rust-team** review the websocket feed handler for latency."

Claude can also delegate to them automatically when a task clearly matches an
agent's `description`.

## Making them available "everywhere"

Subagents are discovered from two locations:

| Location                      | Availability                          | Persistence                        |
| ----------------------------- | ------------------------------------- | ---------------------------------- |
| `<repo>/.claude/agents/`      | That repo's sessions only             | Version-controlled (committed)     |
| `~/.claude/agents/`           | **Every** project on that machine     | Local user config (not in git)     |

To make these available in another repo (e.g. `polymarket-strategy-lab` or
`polymarket-reversal-sniper`), copy the `.md` files into that repo's
`.claude/agents/` and commit:

```bash
mkdir -p .claude/agents
cp /path/to/python-team.md /path/to/rust-team.md .claude/agents/
git add .claude/agents && git commit -m "Add platform-team subagents"
```

To make them available in *every* local project at once, copy them into your
user-level config instead:

```bash
mkdir -p ~/.claude/agents
cp python-team.md rust-team.md ~/.claude/agents/
```

> Note: in the Claude Code web/remote environment, `~/.claude/` is ephemeral
> (reclaimed when the container is recycled), so for durable "everywhere"
> coverage, commit the agents into each repo that needs them.

## Adding more teams

Copy an existing file and edit the `name` + `description` + body, e.g.
`go-team.md`, `ts-team.md`. The `name` field is what you call it by.
