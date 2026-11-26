import Foundation
import RepoPromptRemoteProtocol

enum RemoteTranscriptLoadState: Equatable {
    case idle
    case loading
    case failed(String)
}

enum RemoteTranscriptLoadKind {
    case initial
    case latest
    case older
}

/// Per-session transcript state. The value owns ordering, identity-based merges,
/// paging metadata, revision state, and generation guards; networking remains in
/// `RemoteAppModel`.
struct RemoteTranscriptTimelineState: Equatable {
    private(set) var orderedItems: [RemoteTranscriptItem] = []
    private(set) var itemsByID: [UUID: RemoteTranscriptItem] = [:]
    private(set) var olderCursor: RemoteTranscriptCursor?
    private(set) var hasOlder = false
    private(set) var pagingMode: RemoteTranscriptPagingMode?
    private(set) var loadedRevision: UInt64?
    private(set) var loadedRevisionEpoch: UUID?
    private(set) var chatConfiguration: RemoteChatConfiguration?
    private(set) var initialLoadState: RemoteTranscriptLoadState = .idle
    private(set) var latestRefreshState: RemoteTranscriptLoadState = .idle
    private(set) var olderPageState: RemoteTranscriptLoadState = .idle
    private(set) var legacyNextSequenceIndex: Int?

    /// One authoritative mutation generation prevents any older initial/latest/
    /// older response from replacing state produced by a newer operation.
    private var mutationGeneration: UInt64 = 0

    var isLegacyPaging: Bool {
        pagingMode == .legacyForward
    }

    /// CE's legacy contract returns rows with `sequenceIndex > after`, so the
    /// maximum loaded sequence itself is the resume cursor (not max + 1).
    var legacyRefreshSequenceIndex: Int? {
        legacyNextSequenceIndex ?? orderedItems.map(\.sequenceIndex).max()
    }

    var latestCursor: RemoteTranscriptCursor? {
        orderedItems.last.map(Self.cursor(for:))
    }

    mutating func begin(_ kind: RemoteTranscriptLoadKind) -> UInt64 {
        mutationGeneration &+= 1
        if initialLoadState == .loading { initialLoadState = .idle }
        if latestRefreshState == .loading { latestRefreshState = .idle }
        if olderPageState == .loading { olderPageState = .idle }
        switch kind {
        case .initial: initialLoadState = .loading
        case .latest: latestRefreshState = .loading
        case .older: olderPageState = .loading
        }
        return mutationGeneration
    }

    @discardableResult
    mutating func apply(
        _ page: RemoteTranscriptPage,
        kind: RemoteTranscriptLoadKind,
        generation: UInt64,
        requestedRevision: UInt64? = nil
    ) -> Bool {
        guard generationIsCurrent(generation, for: kind) else { return false }

        if kind != .older, let configuration = page.chatConfiguration {
            chatConfiguration = configuration
        }
        let pageMode = page.pagingMode ?? .legacyForward
        let sortedPageItems = Self.sorted(page.items)
        let hadItems = !orderedItems.isEmpty

        switch kind {
        case .initial:
            if hadItems {
                // Re-entering a transcript or reconnecting fetches the recent page
                // again. Merge it so already-loaded older rows and their paging
                // boundary remain stable instead of replacing the visible timeline.
                merge(sortedPageItems)
                if pagingMode == nil { pagingMode = pageMode }
            } else {
                itemsByID = sortedPageItems.reduce(into: [:]) { $0[$1.id] = $1 }
                pagingMode = pageMode
                updatePagingMetadata(from: page, mode: pageMode)
            }
            initialLoadState = .idle
        case .latest:
            merge(sortedPageItems)
            if !hadItems {
                pagingMode = pageMode
                updatePagingMetadata(from: page, mode: pageMode)
            } else if pagingMode == .legacyForward, pageMode == .legacyForward {
                updatePagingMetadata(from: page, mode: pageMode)
            } else if pagingMode == nil {
                pagingMode = pageMode
            }
            latestRefreshState = .idle
        case .older:
            merge(sortedPageItems)
            pagingMode = pageMode
            updatePagingMetadata(from: page, mode: pageMode)
            olderPageState = .idle
        }

        orderedItems = Self.sorted(Array(itemsByID.values))
        if let pageEpoch = page.transcriptRevisionEpoch {
            if let loadedRevisionEpoch, loadedRevisionEpoch != pageEpoch {
                loadedRevision = nil
            }
            loadedRevisionEpoch = pageEpoch
        }
        if let revision = page.transcriptRevision ?? requestedRevision {
            loadedRevision = max(loadedRevision ?? 0, revision)
        }
        return true
    }

    @discardableResult
    mutating func fail(
        _ message: String,
        kind: RemoteTranscriptLoadKind,
        generation: UInt64
    ) -> Bool {
        guard generationIsCurrent(generation, for: kind) else { return false }
        switch kind {
        case .initial: initialLoadState = .failed(message)
        case .latest: latestRefreshState = .failed(message)
        case .older: olderPageState = .failed(message)
        }
        return true
    }

    mutating func mergeDetails(from detailedItem: RemoteTranscriptItem, resort: Bool = true) {
        guard let current = itemsByID[detailedItem.id] else { return }
        itemsByID[detailedItem.id] = RemoteTranscriptItem(
            id: current.id,
            turnID: current.turnID,
            timestamp: current.timestamp,
            sequenceIndex: current.sequenceIndex,
            kind: current.kind,
            semanticKind: current.semanticKind,
            role: current.role,
            text: current.text,
            toolName: current.toolName,
            toolStatus: current.toolStatus,
            summaryOnly: current.summaryOnly,
            detailAvailable: detailedItem.detailAvailable,
            detailText: detailedItem.detailText,
            detail: detailedItem.detail,
            attachments: detailedItem.attachments ?? current.attachments,
            diffSummary: current.diffSummary ?? detailedItem.diffSummary
        )
        if resort { orderedItems = Self.sorted(Array(itemsByID.values)) }
    }

    mutating func resetRevisionEpoch() {
        loadedRevision = nil
        loadedRevisionEpoch = nil
        chatConfiguration = nil
    }

    private mutating func merge(_ items: [RemoteTranscriptItem]) {
        for item in items {
            if let cached = itemsByID[item.id],
               cached.text == item.text, cached.toolStatus == item.toolStatus,
               cached.detailAvailable == item.detailAvailable,
               cached.diffSummary == item.diffSummary,
               cached.attachments?.map(\.id) == item.attachments?.map(\.id),
               cached.detail != nil || cached.detailText != nil
            {
                itemsByID[item.id] = item
                mergeDetails(from: cached, resort: false)
            } else {
                itemsByID[item.id] = item
            }
        }
    }

    private mutating func updatePagingMetadata(
        from page: RemoteTranscriptPage,
        mode: RemoteTranscriptPagingMode
    ) {
        switch mode {
        case .recentBackward:
            olderCursor = page.olderCursor
            hasOlder = page.hasOlder ?? false
            legacyNextSequenceIndex = nil
        case .legacyForward:
            olderCursor = nil
            hasOlder = page.hasMore
            legacyNextSequenceIndex = page.nextSequenceIndex
        }
    }

    private func generationIsCurrent(
        _ generation: UInt64,
        for _: RemoteTranscriptLoadKind
    ) -> Bool {
        generation == mutationGeneration
    }

    private static func cursor(for item: RemoteTranscriptItem) -> RemoteTranscriptCursor {
        RemoteTranscriptCursor(
            sequenceIndex: item.sequenceIndex,
            timestamp: item.timestamp,
            itemID: item.id
        )
    }

    private static func sorted(_ items: [RemoteTranscriptItem]) -> [RemoteTranscriptItem] {
        items.sorted { cursor(for: $0) < cursor(for: $1) }
    }
}

/// Collects a newest-to-older refresh without mutating the visible timeline.
/// The batch becomes applicable only after it overlaps the existing tail or
/// reaches the beginning of the authoritative transcript.
struct RemoteTranscriptRecentRefreshBatch {
    private let existingItemIDs: Set<UUID>
    private let existingTail: RemoteTranscriptCursor?
    private var fetchedByID: [UUID: RemoteTranscriptItem] = [:]
    private var lastPage: RemoteTranscriptPage?

    init(existingItems: [RemoteTranscriptItem]) {
        existingItemIDs = Set(existingItems.map(\.id))
        existingTail = existingItems.last.map(Self.cursor(for:))
    }

    mutating func append(_ page: RemoteTranscriptPage) -> Bool {
        for item in page.items { fetchedByID[item.id] = item }
        lastPage = page
        guard existingTail != nil else { return true }
        if !existingItemIDs.isDisjoint(with: page.items.map(\.id)) { return true }
        if let oldestFetched = fetchedByID.values.map(Self.cursor(for:)).min(),
           let existingTail,
           oldestFetched <= existingTail
        {
            return true
        }
        return page.hasOlder == false
    }

    var nextOlderCursor: RemoteTranscriptCursor? {
        guard lastPage?.hasOlder == true else { return nil }
        return lastPage?.olderCursor
    }

    func combinedPage(requestedRevision: UInt64?) throws -> RemoteTranscriptPage {
        guard let lastPage else { throw RemoteGatewayError.invalidResponse }
        return RemoteTranscriptPage(
            sessionID: lastPage.sessionID,
            items: Array(fetchedByID.values),
            hasMore: false,
            eventCursor: lastPage.eventCursor,
            pagingMode: .recentBackward,
            olderCursor: lastPage.olderCursor,
            hasOlder: lastPage.hasOlder,
            transcriptRevision: lastPage.transcriptRevision ?? requestedRevision,
            transcriptRevisionEpoch: lastPage.transcriptRevisionEpoch
        )
    }

    private static func cursor(for item: RemoteTranscriptItem) -> RemoteTranscriptCursor {
        RemoteTranscriptCursor(
            sequenceIndex: item.sequenceIndex,
            timestamp: item.timestamp,
            itemID: item.id
        )
    }
}
