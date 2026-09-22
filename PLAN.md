# Dido roadmap

Agreed 2026-09-22 after a full review. Tick items as they land.

## Phase 1: Foundations (done 2026-09-22)

Fix what is broken before adding anything.

- [x] SwiftData store at `~/Library/Application Support/Dido/index.store`; surface container errors
      as a notification instead of a silent `print`.
- [x] Parser, chunker and indexer become actors; inserts go through a `ModelActor`; progress and
      cancellation are exposed to the UI. No file I/O on the main actor.
- [x] Sidebar loads directory children lazily on expand, off the main actor.
- [x] Chat sends proper role-based history (system, user, assistant turns) and the question once.
- [x] Streaming responses with a Stop button.
- [x] Full Markdown rendering for assistant messages (swift-markdown-ui).
- [x] Copy and delete appear on hover; Home link works; index size is the real file size.
- [x] Stale security-scoped bookmarks are regenerated.
- [x] Chat history moves out of `UserDefaults` into SwiftData; unbounded growth stops.
- [x] Remove `Dido.dmg` from git, ignore `*.dmg`, rewrite the README to match the code.

## Phase 2: Local-first AI (done 2026-09-22)

- [x] `EmbeddingProvider` protocol: on-device `NLContextualEmbedding` (default) and OpenAI-compatible
      `/embeddings` with the Authorization header and a configurable model.
- [x] Each document records the embedding model and dimension so vectors are never mixed.
- [x] `LLMProvider` protocol: Apple Foundation Models on macOS 26 (default when available) and
      OpenAI-compatible chat completions (Ollama or OpenAI). Availability shown in the status bar.
- [x] Sentence-aware chunking with `NLTokenizer`, sized for the local model's context window.
- [x] Real retrieval: in-memory vector index built from SwiftData at launch, batch cosine via
      Accelerate, top-k with a score threshold, plus keyword boosting.
- [x] Citations: chunks carry path and offsets; answers cite `[n]`; a sources list opens the file.
- [x] Open a cited passage at its offset in the preview pane (needs the Phase 3 preview).

## Phase 3: Knowledge scan (done 2026-09-22)

- [x] Ask across the whole library, a folder, or a single file.
- [x] Background index of the root at launch and a file-system watcher for incremental updates.
- [x] Index dashboard: per-file status with reasons, reindex, clear.
- [x] Robust `markitdown`: find `uvx` on PATH or a configured path, warm it once, time out, and
      report a clear error when missing.
- [x] OCR for scanned PDFs and images with the Vision framework.
- [x] Preview pane beside the chat: Markdown, PDF and Quick Look.
- [x] Content search in the sidebar, not just file names.

## Phase 4: Polish (done 2026-09-22)

- [x] Native `Settings` scene with General, AI and Index tabs.
- [x] Keyboard shortcuts and a menu bar quick-ask window.
- [x] `MARKETING_VERSION` in `project.yml`; a release build script.

## Recommended next steps (2026-09-23)

Ordered by expected value for a personal knowledge-scan tool. None is started.

### Retrieval quality
- [ ] Rewrite follow-up questions into standalone queries using the recent turns before searching,
      so "and what was the restore time?" retrieves as well as the first question did.
- [ ] Hybrid retrieval: a SQLite FTS5 full-text index beside the vectors, merged by reciprocal rank,
      so exact names, codes and numbers are never missed by the embedding.
- [ ] Merge adjacent passages from the same file before sending them, and dedupe near-identical ones,
      so ten citations from one document become two or three coherent extracts.
- [ ] Metadata boosts and filters: recently modified files first, restrict to a folder or file type,
      exclude patterns (a `.didoignore` file or Settings list).
- [ ] Row-aware chunking for CSV and XLSX, keeping the header row with every chunk.
- [ ] Force citations from Apple Intelligence with guided generation (a `@Generable` answer with a
      citation list) instead of relying on the model writing `[n]`.

### Scale and performance
- [ ] Persist the vector index as a compact binary file loaded with mmap, instead of rebuilding it
      from SwiftData at launch (about 3 to 6 seconds for 18,000 passages today).
- [ ] Approximate nearest-neighbour search (HNSW) once libraries pass roughly 100,000 passages.
- [ ] Priority queue for the indexer so the open file and folder are indexed before the background
      scan continues; cap OCR pages and skip files above a size limit with a clear status.
- [ ] Notify (menu bar badge or system notification) when a background scan finishes or fails.

### Chat and answers
- [ ] Regenerate, edit-and-resend, and pin or rename threads.
- [ ] Export an answer with its sources as Markdown, and copy with citations resolved to file names.
- [ ] A "compare documents" mode that answers per file and shows a table of differences.
- [ ] Streaming for the on-device model with token deltas rather than cumulative snapshots.

### Preview and library
- [ ] Highlight the cited range inside rendered Markdown, not only the raw text.
- [ ] Page thumbnails and a mini-map for long PDFs; jump between all cited ranges in a document.
- [ ] Pin favourite folders and show file modification dates in the sidebar.

### Robustness and product
- [ ] An evaluation harness: a folder of sample documents with questions and expected answers, run
      through the debug launch flags after each change, with retrieval hit rate and answer checks.
- [ ] Unit tests for the chunker, offsets, citation parsing and the vector index (currently no test
      target by decision; revisit once the retrieval code settles).
- [ ] First-launch onboarding: choose the folder, check Apple Intelligence, pick a server if needed.
- [ ] Signing, notarisation and Sparkle updates if the app is shared beyond this Mac.
- [ ] Per-tab sizing of the Settings window; keyboard navigation of sources and passages.
- [ ] Encrypt the store or place it in a user-chosen location for sensitive libraries.

## Later (earlier notes, kept)

- [x] Highlight the exact cited range in text files and PDF pages (2026-09-23).
- [ ] Per-tab sizing of the Settings window.
- [ ] Signing and notarisation, if the app is ever shared beyond this Mac.
- [x] A "why this answer" view showing the retrieved passages and their scores (2026-09-23).
- [ ] Show the on-device index load time in the dashboard for large libraries.
