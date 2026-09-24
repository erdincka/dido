# Dido

Personal, non-commercial macOS app for scanning a folder of documents and asking questions about them
with an LLM. Not an HPE project: keep the native macOS look and feel, not HPE branding.

## Stack

- Swift 6 with strict concurrency, SwiftUI, SwiftData, `@Observable`.
- Project is generated from `project.yml` with XcodeGen (`brew install xcodegen && xcodegen generate`).
  `Dido.xcodeproj` is git-ignored; never hand-edit it.
- Deployment target macOS 14. Newer APIs (Foundation Models on macOS 26) are gated with `#available`.
- Command-line build:
  `xcodebuild -project Dido.xcodeproj -scheme Dido -configuration Debug build CODE_SIGNING_ALLOWED=NO`

## Conventions

- Swift API Design Guidelines. No force unwraps. `struct` for data, `@Observable` classes for state.
- Views under 200 lines; extract subviews. `MARK: -` sections. `///` doc comments on public methods.
- `async/await` and actors, never completion handlers or Combine.
- Logging through `os.Logger` (subsystem `com.dido`), never `print()`.
- Secrets in the Keychain only. Everything else in `UserDefaults` or SwiftData.
- Heavy work (parsing, chunking, embedding, directory walks) runs off the main actor.
- en_GB for user-facing text.
- No test target. Verify by building and running the app. A Debug build captures its own window
  without Screen Recording permission:
  `Dido.app/Contents/MacOS/Dido -DidoScreenshot out.png -DidoAppearance dark -DidoOpen /file -DidoAsk "question" -DidoScreenshotDelay 30`
  Other flags: `-DidoOpen library`, `-DidoSearch text`, `-DidoShowSettings YES`, `-DidoShowDashboard YES`,
  `-DidoOpenFirstSource YES`, `-DidoQuickAsk "question"` (menu bar path, headless),
  `-DidoDebugLog /path.log` (step log from the hook and the quick-ask model). Launch with
  `open -n Dido.app --args …`, not by executing the binary: after the Mac sleeps, a shell's launch
  context goes stale and SwiftUI opens no windows. When the screen is locked the hook falls back to
  rendering the view hierarchy, which omits sidebar vibrancy and can be stale. Launch-argument overrides such as
  `-pkmRootPath /folder -selectedModel name -answerSource server` are not persisted, but test
  chats and indexed files do land in the real store and must be removed afterwards.

## Decisions (2026-09-22)

- **Purpose:** knowledge scan and retrieval over a chosen root folder. Not a note editor.
- **Local first:** on-device embeddings and Apple Foundation Models are the default. An
  OpenAI-compatible endpoint (Ollama, OpenAI) is optional and configured in Settings.
- **Not sandboxed:** personal use only. The app may launch helper processes.
- **Formats:** md, txt and code, pdf, rtf stay native. docx, pptx, xlsx and epub go through
  `markitdown` via `uvx`, located on PATH with a configurable override.
- **Dependencies:** a Markdown rendering package is allowed. Ask before adding anything else.
- **Library scope:** the whole-library chat relies on the background index and never indexes on demand.
- **Chunking:** whole sentences packed to about 900 characters with a 150-character overlap. The profile is stored on each document, so changing it re-chunks files on the next scan. Older stored defaults (500/50, 600/80) are migrated on launch.
- **Default prompt:** `LLMService.defaultSystemPrompt`; a stored copy of an earlier default is replaced on launch, a user's own prompt is kept.
- **Retrieval:** hybrid. `VectorIndex` (unit vectors in a flat matrix, one vDSP matrix-vector product per query, persisted to `vectors.index`) and `FullTextIndex` (SQLite FTS5 in `fulltext.sqlite`, system libsqlite3) fused by reciprocal rank; follow-ups are rewritten into standalone queries by the answer provider; adjacent passages merge into extracts. A scope smaller than the model's context budget is sent whole, in order. Approximate nearest-neighbour search is deliberately not implemented: the matrix product handles hundreds of thousands of passages in milliseconds.
- **Ignore rules:** `.didoignore` in the root plus the Exclude list in Settings, glob-matched against paths relative to the root, applied by `FileSystemScanner` to the sidebar, scans and watcher events.
- **Settings** is a native Settings scene; open it with `SettingsLink` in views or `AppState.openSettings()` elsewhere, which performs the app menu's own ⌘, item because the selector differs between OS versions.
- **Apple Intelligence** is the default answer source when available; the on-device model has a small context window, so its budget is kept around 7,000 characters.
- **Latest-version questions (2026-09-24):** each passage header carries its document's date (from the file name, else the modification date). When a question asks for the latest (`DocumentVersions.recencySignals`), older versions of same-name documents (differing only by date stamp, copy number or version tag) are left out, retrieval is then narrowed to the matching documents dated within 3 days of the newest, their opening passages are added, and extracts go in document order. For such questions and for corrections ("this is not the latest"), earlier assistant answers are dropped from the history and from the follow-up rewrite, because small models copy them. What was left out is listed in "Why this answer".
- **Vector index file:** saves always compact removed rows (the file has no liveness flags). On load, a file with more rows than the store's chunks is rebuilt from the store.
- **Sub-tasks (2026-09-23):** library and folder questions are routed by `AgentPlanner.shouldPlan`: questions without a planning signal word (latest, folder, how many, list, each…) go straight to one retrieval pass, the rest are classified by one short model call; a plain lookup stays one retrieval pass; browsing, dates, counting or several places become a plan of 2 to 6 steps. The user reviews the plan before it runs and can edit, add, remove, skip, stop, re-run and steer (a hint re-plans the steps not yet run) while it runs; `askUser` steps pause for a reply. `AgentRunner` (main actor) runs steps one after another, then writes one answer from the findings with citations renumbered across steps. Tools (`AgentToolbox`) are read-only and confined to the library root: `listFolder`, `search` (the existing `ContextBuilder`), `readFile`, `shell` and `askUser`. `LibraryShell` runs one allow-listed command (ls, find, grep, cat, head, tail, wc, stat, du, file, sort, uniq) through `Process` without a shell: no pipes, redirection or variables, write and exec options blocked, every path checked against the root, 20 s timeout, 12,000-character cap. The planning prompt (listing, history) is sized to the provider's context budget. The trace is stored with the reply (`traceJSON`). The live plan card and the streaming row need distinct `.id`s in the transcript's lazy stack, otherwise the stale row keeps showing. Settings › AI has toggles for planning and for shell steps. Debug flags: `-DidoPlan YES` forces a plan, `-DidoAutoRun YES` skips the review, `-DidoStoreDirectory /folder` uses a separate store.

See `PLAN.md` for the roadmap and what is done.
