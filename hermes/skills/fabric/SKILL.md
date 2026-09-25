---
name: fabric
description: "Use to run a Fabric prompt pattern (summarize, extract_wisdom, explain_code, analyze_claims, …) on text via the homelab Fabric server."
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
required_environment_variables:
  - name: FABRIC_URL
    prompt: "Fabric server URL (https://<CUSTOM_DOMAIN> from fabric/.env)"
  - name: FABRIC_API_KEY
    prompt: "Fabric server API key (FABRIC_API_KEY from fabric/.env)"
    help: "Sent as the X-API-Key header"
metadata:
  hermes:
    tags: [Fabric, Summarize, Patterns, Writing, Analysis]
---

# Fabric patterns

The homelab runs a [Fabric](https://github.com/danielmiessler/fabric) server
at `$FABRIC_URL` (tailnet only). A pattern is a curated system
prompt for one job. Running text through a pattern gives a consistent,
structured result: headed sections, bullet lists, fixed lengths.

Use it when the user names a pattern or asks for "fabric", or when a pattern
clearly fits a long input: summarizing an article or transcript, extracting
insights, explaining code, rating an argument. For short or conversational
requests, answer directly. Calling Fabric costs a separate model call.

## Run a pattern

```bash
python3 scripts/fabric.py summarize --file /path/to/article.md
python3 scripts/fabric.py extract_wisdom --text "…"
some_command | python3 scripts/fabric.py summarize_git_diff
```

The result is printed as Markdown. Pass it to the user as-is, or edit it down
if they asked for something shorter. Say that it came from the Fabric pattern.

Fabric uses its configured default model. Add `--vendor` and `--model` only if
the user asks for a specific one.

## Find a pattern

```bash
python3 scripts/fabric.py --list            # all ~255
python3 scripts/fabric.py --list summar     # filter by substring
```

Common ones:

| Job | Pattern |
|---|---|
| Summary of any text | `summarize`, `create_summary` |
| Ideas, quotes, habits, recommendations | `extract_wisdom` |
| Article-specific insights | `extract_article_wisdom` |
| Explain or review code | `explain_code`, `review_code` |
| Summarize a diff / write a commit message | `summarize_git_diff`, `create_git_diff_commit` |
| Fact-check an argument | `analyze_claims` |
| Clean up prose | `improve_writing` |

## Getting input

- **Web page:** fetch it with the web tools first, then pass the text with
  `--file`. Fabric does not fetch URLs.
- **Large input:** write it to a file under the workspace and use `--file`,
  rather than putting it on the command line.

## Errors

- `FABRIC_URL and FABRIC_API_KEY must both be set`: one is missing from
  Hermes's `.env`.
- `HTTP 401`: the key doesn't match `FABRIC_API_KEY` in the Fabric project.
- `cannot reach`: Fabric is down, or the Docker host is off the tailnet.
  Report it to the user; there is no fallback server.
