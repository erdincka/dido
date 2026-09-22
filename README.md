# Dido

Dido is a personal macOS app for asking questions about the documents in a folder. Point it at a
library folder, pick a file or folder in the sidebar, and chat about it with a local or remote
language model. Answers stream in and every conversation is kept per file.

Personal, non-commercial use only. Not an HPE product.

## What it does

- Browses a library folder in a sidebar, loading folders as you expand them, with file-name search.
- Extracts text from Markdown, plain text, code, CSV, JSON, HTML, PDF and RTF natively, and from
  docx, pptx, xlsx and epub through [markitdown](https://github.com/microsoft/markitdown) when
  `uv` is installed.
- Indexes files on demand, or a whole folder from the context menu or Settings, with progress and
  cancel. Indexed text lives in a SwiftData store under `~/Library/Application Support/Dido`.
- Answers with Apple Intelligence on macOS 26 when it is available, otherwise with any
  OpenAI-compatible chat server: Ollama (the default, at `http://localhost:11434/v1`), LM Studio,
  LiteLLM or OpenAI. Tokens are stored in the Keychain.
- Embeds every passage on device with Apple's contextual embedding model (no server needed), or
  through a server's `/embeddings` endpoint if you prefer.
- Finds the passages relevant to each question with vector search plus a keyword boost, sends
  small files whole, and cites passages as [1], [2] with a clickable sources row under each answer.
- Sends page images to vision-capable server models for PDFs and images.
- Renders replies as Markdown; copy or delete any message; chat history is kept per file or
  folder, capped at 200 messages each.

## Requirements

- macOS 14 Sonoma or newer, Apple silicon or Intel.
- Xcode 16 or newer and [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build.
- Optional: [Ollama](https://ollama.com) for local models; [uv](https://docs.astral.sh/uv/) for
  Office and EPUB files (`brew install uv`).

## Build

```bash
brew install xcodegen
xcodegen generate
open Dido.xcodeproj
```

Select the Dido scheme and run. From the command line:

```bash
xcodebuild -project Dido.xcodeproj -scheme Dido -configuration Release build CODE_SIGNING_ALLOWED=NO
```

The app is not sandboxed and not signed; it is meant to be built and run locally.

## Project layout

- `Dido/Dido/Models` — SwiftData models and the value types used by the UI.
- `Dido/Dido/Services` — parser, chunker, indexer, file scanner, API client and stores. Heavy work
  runs on actors, never on the main thread.
- `Dido/Dido/Views` — SwiftUI views, each under about 200 lines.
- `CLAUDE.md` — conventions and recorded decisions. `PLAN.md` — the roadmap.

## Licence

Copyright (c) 2026 Dido. Free for non-commercial use: you may use, copy, modify and share the
software provided it is not sold or used as part of a for-profit service without the author's
written consent. No warranty of any kind.
