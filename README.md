# TokenDock

TokenDock is a native macOS menu bar app for Codex usage visibility.

It keeps the information developers care about one click away: Codex official 5h/7d quota percentages, local token totals from this Mac, the latest session event, and a reserved API Tokens area for future OpenAI/Anthropic/API usage sources.

TokenDock is intentionally read-only. It parses local Codex session logs under `~/.codex/sessions/**/rollout-*.jsonl`, displays the latest `rate_limits` and `token_count` events, and does not modify Codex configuration or call private web endpoints.

## 中文简介

TokenDock 是一个原生 macOS 菜单栏工具，用来快速查看 Codex 用量。它会把 Codex 官方 5 时/7 天额度、本机 token 统计、最近会话事件和未来 API Tokens 区域放到一个紧凑菜单里。

TokenDock 只读解析本机 `~/.codex/sessions/**/rollout-*.jsonl` 日志，不修改 Codex 配置，也不调用私有网页接口。当前菜单已中文化，并将低频诊断信息收进 `详细信息` 二级菜单，减少下拉面板长度。

## Why TokenDock?

Codex usage information is useful, but checking it through settings panels is slow and easy to forget. Existing menu bar or island-style tools may show ambiguous numbers, mix different accounting methods, or fail to explain where the data comes from.

TokenDock focuses on a clear source-of-truth split:

- Official quota percentages come from Codex `rate_limits`.
- Local token totals come from this Mac's Codex logs.
- API token usage is prepared as a separate section, so future API data can be shown without mixing it with Codex app usage.

## Features

- Show Codex 5h and 7d official usage percentages in the macOS menu bar.
- Show Codex official 5h and 7d quota as progress bars in the dropdown.
- Show local token usage from `~/.codex/sessions/**/rollout-*.jsonl`.
- Summarize latest event, today, last 5 hours, and last 7 days.
- Reserve an API Tokens section for future API usage sources.
- Stay read-only: no Codex config edits, no private web scraping.

## Menu Overview

The dropdown is organized into color-coded sections:

- `Official quota` - Codex 5h/7d used and left percentages with progress bars.
- `API Tokens` - reserved API usage area, currently showing placeholders until a data source is connected.
- `Latest event` - the most recent Codex token event, including input, cached input, output, reasoning, and session total.
- `Local token totals` - today, last 5 hours, and last 7 days from local Codex logs.
- `Source` - the latest rollout JSONL file used for the snapshot.

## Local Development

Print a one-shot snapshot:

```bash
swift run TokenDock --snapshot
```

Build a local app bundle:

```bash
./scripts/build-app.sh
```

Install and launch locally:

```bash
./scripts/install-local.sh
```

## Repository Layout

- `Sources/TokenDock/` - Swift/AppKit source code.
- `scripts/` - local build, install, and verification scripts.
- `docs/` - implementation notes and status.
- `dist/` - generated local app bundle output. Not committed.

## Data Source

TokenDock will parse local Codex session logs:

```text
~/.codex/sessions/**/rollout-*.jsonl
```

The official percentage comes from Codex `rate_limits`. Local token totals come from `token_count` events.

## License

MIT
