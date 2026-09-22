# Dido

Dido is a personal macOS app for asking questions about the documents in a folder. Point it at a
library folder, pick a file or folder in the sidebar, and chat about it with a local or remote
language model. Answers stream in and every conversation is kept per file.

Personal, non-commercial use only. Not an HPE product.

## What it does

- Browses a library folder in a sidebar, loading folders as you expand them. Recent chats sit
  above the library, and both sections collapse and stay collapsed between launches. The search field
  matches file names and file contents, and a passage result opens the file with that passage
  highlighted.
- Indexes the whole library in the background at launch and watches it for changes, so new,
  edited and deleted files are reflected within seconds. An index dashboard lists every file with
  its status and reason, and offers reindex, remove-missing and clear.
- Extracts text from Markdown, plain text, code, CSV, JSON, HTML, PDF and RTF natively; from
  docx, pptx, xlsx and epub through [markitdown](https://github.com/microsoft/markitdown) when
  `uv` is installed (with a timeout and a clear message when it is missing); and from images and
  scanned PDFs with Apple's Vision OCR.
- Answers questions about a file, a folder or the whole library. Apple Intelligence is used on
  macOS 26 when available, otherwise any OpenAI-compatible chat server: Ollama (the default, at
  `http://localhost:11434/v1`), LM Studio, LiteLLM or OpenAI. Tokens are stored in the Keychain.
- Embeds every passage on device with Apple's contextual embedding model (no server needed), or
  through a server's `/embeddings` endpoint if you prefer.
- Finds the passages relevant to each question with vector search plus a keyword boost, sends
  small scopes whole, and cites passages as [1], [2]. Each citation and the sources row under an
  answer open a preview pane showing the passage highlighted among its neighbours, or the
  document itself with the exact cited range highlighted (text and Markdown) or selected (PDF).
- "Why this answer" under every reply shows which model answered, the scope, whether the scope
  was sent whole or ranked, every passage that was sent with its similarity score, and which of
  them the reply cited.
- Sends page images to vision-capable server models for PDFs and images.
- Renders replies as Markdown; copy or delete any message; chat history is kept per file, folder
  or library, capped at 200 messages each.
- Lives in the menu bar too: the sparkles item asks the whole library from anywhere and keeps the
  exchange in the library chat. Turn it off in Settings › General.
- Keyboard: ⌘, Settings · ⇧⌘H Home · ⇧⌘L Ask the whole library · ⌘F Search · ⌥⌘P Toggle preview ·
  ⌘R Index current item again · ⇧⌘I Index dashboard · ⌘. Stop generating.

Indexed text and embeddings live in a SwiftData store under `~/Library/Application Support/Dido`.

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

The app is not sandboxed and not signed; it is meant to be built and run locally. To produce a
DMG of a Release build under `dist/`:

```bash
scripts/release.sh
```

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
