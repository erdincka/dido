# Dido - PKM Assistant (macOS)

Dido is a native macOS application designed as an intelligent Personal Knowledge Management (PKM) assistant. It leverages Retrieval-Augmented Generation (RAG) to allow you to index local documents and query them using Large Language Models (LLMs) like Ollama or OpenAI-compatible APIs, all while maintaining a premium, native user experience.

## 🚀 Features

- **Native macOS Experience:** Built with SwiftUI for a sleek, responsive, and energy-efficient desktop application.
- **Local Indexing & RAG:** Seamlessly indexes your local PKM directory (Markdown, PDF, RTF, etc.) and uses vector search to provide context to your LLM queries.
- **Top-Tier Security:** 
    - **App Sandboxing:** Fully sandboxed for secure operation.
    - **Keychain Integration:** Sensitive API tokens are stored securely in the macOS Keychain.
    - **Security-Scoped Bookmarks:** Remembers your PKM root folder across restarts without compromising system security.
- **Swift 6 & Modern Concurrency:** Fully aligned with Swift 6's strict concurrency requirements for a crash-free, thread-safe experience.
- **Flexible AI Endpoints:** Support for local Ollama instances and OpenAI-compatible APIs (planned).

## 🛠 Tech Stack

- **Language:** Swift 6.0+
- **Framework:** SwiftUI
- **Database:** SwiftData (for document metadata and indexing)
- **Project Management:** [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- **Build System:** xcodebuild / Xcode

## 📋 Requirements

- **macOS:** 14.0 (Sonoma) or newer.
- **Xcode:** 15.3 or newer.
- **XcodeGen:** Required to generate the project file.
- **Ollama:** (Optional) For local LLM inference.

## 🔨 Build Instructions

Dido uses `XcodeGen` to manage its project structure. Follow these steps to build the app from source:

1. **Install XcodeGen:**
   ```bash
   brew install xcodegen
   ```

2. **Generate the Xcode Project:**
   Navigate to the repository root and run:
   ```bash
   xcodegen generate
   ```

3. **Open the Project:**
   ```bash
   open Dido.xcodeproj
   ```

4. **Build & Run:**
   Select the **Dido** scheme and target **My Mac**. Press `Cmd + R` to build and run.

### Command Line Build
To build a release version (unsigned) for Apple Silicon:
```bash
xcodebuild -project Dido.xcodeproj -scheme Dido -configuration Release -derivedDataPath build_output clean build CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -sdk macosx ARCHS="arm64"
```

## 🤝 Contributing

We welcome contributions from the community! To maintain high code quality and consistency, please follow these guidelines:

1. **Fork & Branch:** Fork the repository and create a feature branch (`feature/my-new-feature`).
2. **Coding Standards:**
   - Follow [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
   - Ensure all new code is **Swift 6 Concurrency-safe**.
   - Keep views modular and under 200 lines where possible.
3. **Pull Requests:** Provide a clear description of changes, screenshots for UI modifications, and ensure the project builds correctly.
4. **Best Practices:** Prefer `struct` over `class`, use `@Observable` for state, and avoid force unwrapping (`!`).

## ⚖️ License

**Non-Commercial Use Only.**
Copyright (c) 2026 Dido. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files, to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, or distribute copies of the Software, provided that such use is for **non-commercial purposes only**.

Commercial use, including but not limited to selling the software or using it as part of a for-profit service, is strictly prohibited without prior written consent from the author.

---
*Built with ❤️ for the macOS community.*
