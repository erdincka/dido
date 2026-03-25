# Project Intelligence Guide: [Dido PKM Assistant]

## 🛠 Tech Stack & Architecture

* **Primary Language:** Swift 6.0+ (Strict Concurrency enabled)
* **UI Framework:** SwiftUI (Prefer native components over `UIViewRepresentable`)
* **Architecture:** MVVM-C (Model-View-ViewModel + Coordinator for navigation)
* **Concurrency:** Use `async/await` and `Task`. Avoid `CompletionHandlers` and `Combine` unless maintaining legacy code.
* **Dependency Injection:** Use a simple `@Environment` or initializer-based injection. No heavy third-party DI frameworks.

## 📝 Coding Standards

* **Naming:** Follow [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
* **Safety:** - No force unwrapping (`!`). Use `guard let` or `if let`.
* Prefer `struct` over `class` for data models.


* **Style:** - Keep Views under 200 lines. Extract subviews into separate computed properties or smaller structs.
* Use `MARK: -` to organize code sections.


* **Documentation:** Use Triple-slash (`///`) for public-facing methods and include a "Parameters" and "Returns" section.

## 🤖 MCP Bridge Instructions

When using the Xcode MCP bridge, follow this workflow:

1. **Error Analysis:** If a build fails, call `get_build_errors` before suggesting a fix.
2. **Context Awareness:** Always check `get_active_file_context` to ensure new code matches the existing indentation and style (2 spaces vs 4 spaces).
3. **Testing:** After modifying logic, call `run_tests` to verify no regressions were introduced.
4. **File Operations:** If you need to create a new file, suggest the file path and content clearly so I can approve the write.

## 🚫 Restricted Patterns

* Do not use `Storyboard` or `XIB` files.
* Do not use `UserDefaults` for sensitive data; use `Keychain`.
* Avoid `Any` or `AnyObject` unless strictly necessary for type erasure.
* Do not write tests unless explicitly requested.

