import Foundation

/// Runs `operation` and fails with a "timed out" error when it takes longer than `seconds`.
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw LLMServiceError.apiError(statusCode: 0, body: "timed out")
        }
        guard let result = try await group.next() else { throw LLMServiceError.decodingError }
        group.cancelAll()
        return result
    }
}
