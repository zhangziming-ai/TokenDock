# TokenDock

TokenDock is a native macOS menu bar utility built for Codex users. It brings Codex official 5-hour and 7-day quota percentages, local token usage, recent session activity, and a reserved API Tokens section into one clean and polished dropdown, so essential usage information is always one click away.

TokenDock is designed to be clear, lightweight, and practical. It reads local Codex session logs, separates official quota percentages from local token totals, and presents them with compact progress bars and visually distinct sections. This makes it easy to understand your current usage at a glance without opening settings pages or relying on ambiguous indicators.

All data is parsed locally in read-only mode. TokenDock does not modify Codex configuration and does not call private web endpoints. Whether you are coding daily, maintaining open-source projects, or tracking AI-assisted development usage, TokenDock gives you a convenient, reliable, and visually refined way to stay aware of your Codex consumption.

## 中文简介

TokenDock 是一款原生 macOS 菜单栏工具，专为 Codex 使用者打造。它将 Codex 官方 5 小时 / 7 天额度、本机 token 消耗、最近会话状态以及未来 API Tokens 用量入口集中在一个简洁美观的菜单中，让关键用量信息无需打开设置页面即可随手查看。

TokenDock 注重清晰、轻量和实用性。它会自动读取本机 Codex 会话日志，区分官方额度百分比与本机 token 统计，并用紧凑的进度条和分区布局呈现，让你一眼就能判断当前额度使用情况。所有数据均来自本地日志，只读解析，不修改 Codex 配置，也不依赖私有网页接口。

无论是日常编码、长时间维护项目，还是追踪 AI 辅助开发过程中的 token 消耗，TokenDock 都能提供一个常驻、直观、可靠的用量入口。

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
