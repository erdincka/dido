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
- **Retrieval:** top-k vector search with citations; a scope smaller than the model's context budget is sent whole, in order.
- **Settings** is a native Settings scene; open it with `SettingsLink` in views or `AppState.openSettings()` elsewhere, which performs the app menu's own ⌘, item because the selector differs between OS versions.
- **Apple Intelligence** is the default answer source when available; the on-device model has a small context window, so its budget is kept around 7,000 characters.

See `PLAN.md` for the roadmap and what is done.
