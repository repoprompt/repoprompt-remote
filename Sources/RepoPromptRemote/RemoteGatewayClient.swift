import Foundation
import RepoPromptRemoteNetworking
import RepoPromptRemoteProtocol

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
