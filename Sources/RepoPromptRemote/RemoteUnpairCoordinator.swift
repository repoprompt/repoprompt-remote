import RepoPromptRemoteNetworking
import Foundation

struct RemoteUnpairAttempt {
    let transportDescription: String
    let run: @MainActor () async throws -> Void
    let cancel: @MainActor () -> Void

    init(
        transportDescription: String,
        run: @escaping @MainActor () async throws -> Void,
        cancel: @escaping @MainActor () -> Void = {}
    ) {
        self.transportDescription = transportDescription
        self.run = run
        self.cancel = cancel
    }
}

enum RemoteUnpairRemoteOutcome: Equatable {
    case revoked
    case alreadyRevoked
    case noTransport
    case failed
    case timedOut
    case cancelled
}

@MainActor
struct RemoteUnpairWork {
    let task: Task<Void, Never>
    private let cancelAction: () -> Void

    init(task: Task<Void, Never>, cancel: @escaping () -> Void) {
        self.task = task
        cancelAction = cancel
    }

    func cancel() {
        cancelAction()
    }
}

@MainActor
private final class RemoteUnpairRunState {
    var isTerminal = false
}

enum RemoteUnpairCoordinator {
    /// Starts a short best-effort remote revocation window, then performs local
    /// cleanup synchronously before returning. Remote completion is diagnostic
    /// only and can never restore or otherwise mutate the cleared pairing state.
    @MainActor
    static func startBestEffort(
        attempts: [RemoteUnpairAttempt],
        timeout: Duration,
        localCleanup: () -> Void,
        onAttempt: @escaping (String) -> Void = { _ in },
        onAttemptFailure: @escaping (String, String) -> Void = { _, _ in },
        onCompletion: @escaping @MainActor (RemoteUnpairRemoteOutcome) -> Void = { _ in }
    ) -> RemoteUnpairWork {
        let state = RemoteUnpairRunState()
        var operationTask: Task<Void, Never>!

        operationTask = Task { @MainActor in
            guard !attempts.isEmpty else {
                state.isTerminal = true
                onCompletion(.noTransport)
                return
            }

            let deadlineTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                guard !state.isTerminal else { return }
                state.isTerminal = true
                attempts.forEach { $0.cancel() }
                onCompletion(.timedOut)
            }
            defer {
                deadlineTask.cancel()
                attempts.forEach { $0.cancel() }
            }

            for attempt in attempts {
                guard !state.isTerminal else { return }
                guard !Task.isCancelled else {
                    state.isTerminal = true
                    onCompletion(.cancelled)
                    return
                }
                onAttempt(attempt.transportDescription)
                do {
                    try await attempt.run()
                    guard !state.isTerminal else { return }
                    state.isTerminal = true
                    onCompletion(.revoked)
                    return
                } catch RemoteGatewayError.credentialRejected {
                    guard !state.isTerminal else { return }
                    state.isTerminal = true
                    onCompletion(.alreadyRevoked)
                    return
                } catch is CancellationError {
                    guard !state.isTerminal else { return }
                    state.isTerminal = true
                    onCompletion(.cancelled)
                    return
                } catch {
                    guard !state.isTerminal else { return }
                    onAttemptFailure(attempt.transportDescription, error.localizedDescription)
                }
            }

            guard !state.isTerminal else { return }
            state.isTerminal = true
            onCompletion(.failed)
        }

        localCleanup()

        return RemoteUnpairWork(task: operationTask) {
            guard !state.isTerminal else { return }
            state.isTerminal = true
            attempts.forEach { $0.cancel() }
            operationTask.cancel()
            onCompletion(.cancelled)
        }
    }
}
