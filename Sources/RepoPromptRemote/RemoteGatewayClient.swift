import Foundation
import RepoPromptRemoteProtocol

enum RemoteGatewayError: LocalizedError {
    case invalidResponse
    case attachmentRejected(String)
    case imageUnavailable
    case requestRejected(RemoteErrorResponse)
    case protocolMismatch(Int)
    case snapshotRequired
    case credentialRejected

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The Mac returned an invalid response."
        case let .attachmentRejected(message): message
        case .imageUnavailable: "The image is unavailable on the Mac."
        case let .requestRejected(error): error.message
        case let .protocolMismatch(version): "This Mac requires an unsupported remote protocol version (\(version))."
        case .snapshotRequired: "The saved event cursor is no longer available; a fresh snapshot is required."
        case .credentialRejected: "The paired Mac rejected this credential; re-pairing is required."
        }
    }
}

struct RemoteImageDownload {
    private(set) var bytes = Data()
    private(set) var revision: String?
    private var totalBytes: Int?

    var isComplete: Bool { totalBytes == bytes.count }

    mutating func append(_ chunk: RemoteImageAttachmentChunk) throws {
        guard chunk.offset == bytes.count,
              (1 ... RemoteAttachmentLimits.maxFileBytes).contains(chunk.totalBytes),
              chunk.offset < chunk.totalBytes,
              chunk.bytes.count == min(RemoteImageAttachmentRequest.chunkBytes, chunk.totalBytes - chunk.offset),
              let revision = chunk.revision, !revision.isEmpty, revision.utf8.count <= 128,
              self.revision == nil || self.revision == revision,
              totalBytes == nil || totalBytes == chunk.totalBytes
        else { throw RemoteGatewayError.invalidResponse }

        self.revision = revision
        totalBytes = chunk.totalBytes
        bytes.append(chunk.bytes)
    }
}

protocol RemoteGatewayTransport: AnyObject {
    var irohPath: RemoteIrohPathKind? { get }

    func unpair() async throws
    func snapshot() async throws -> RemoteSnapshot
    func diagnostics() async throws -> RemoteDiagnostics
    func workspaces() async throws -> [RemoteWorkspaceSummary]
    func sessions() async throws -> [RemoteSessionSummary]
    func agents() async throws -> [RemoteAgentDescriptor]
    func workflows() async throws -> [RemoteWorkflowDescriptor]
    func contextBuilder(_ request: RemoteCommandRequest) async throws -> RemoteCommandResponse
    func command(_ request: RemoteCommandRequest) async throws -> RemoteCommandResponse
    func history(_ request: RemoteHistoryRPCRequest) async throws -> RemoteHistoryPage
    func imageAttachment(_ request: RemoteImageAttachmentRequest) async throws -> RemoteImageAttachmentChunk
    func transcript(
        sessionID: UUID,
        afterSequenceIndex: Int?,
        itemID: UUID?,
        limit: Int,
        includeDetails: Bool
    ) async throws -> RemoteTranscriptPage
    func recentTranscript(
        sessionID: UUID,
        before cursor: RemoteTranscriptCursor?,
        limit: Int
    ) async throws -> RemoteTranscriptPage
    func events(after cursor: UInt64) -> AsyncThrowingStream<RemoteEvent, Error>
    func close()
}

protocol RemoteConnectionCandidate: RemoteGatewayTransport {
    var refreshedServerAddress: RemoteIrohEndpointAddress? { get }
    func confirmPairing(attemptID: UUID) async throws
    func authenticate() async throws
    func firstSnapshot(diagnostics: inout RemoteReconnectDiagnostics.Attempt) async throws -> RemoteSnapshot
}

extension RemoteConnectionCandidate {
    var refreshedServerAddress: RemoteIrohEndpointAddress? { nil }
}

extension RemoteGatewayTransport {
    var irohPath: RemoteIrohPathKind? { nil }
    func close() {}

    func transcript(
        sessionID: UUID,
        afterSequenceIndex: Int,
        limit: Int = 100,
        includeDetails: Bool = false
    ) async throws -> RemoteTranscriptPage {
        try await transcript(
            sessionID: sessionID,
            afterSequenceIndex: afterSequenceIndex,
            itemID: nil,
            limit: limit,
            includeDetails: includeDetails
        )
    }

    func transcript(
        sessionID: UUID,
        itemID: UUID,
        limit: Int,
        includeDetails: Bool
    ) async throws -> RemoteTranscriptPage {
        try await transcript(
            sessionID: sessionID,
            afterSequenceIndex: nil,
            itemID: itemID,
            limit: limit,
            includeDetails: includeDetails
        )
    }

    func recentTranscript(
        sessionID: UUID,
        before cursor: RemoteTranscriptCursor? = nil
    ) async throws -> RemoteTranscriptPage {
        try await recentTranscript(sessionID: sessionID, before: cursor, limit: 100)
    }
}
