import RepoPromptRemoteNetworking
import Foundation
import RepoPromptRemoteProtocol
import SwiftUI
import UIKit
import XCTest
@testable import RepoPromptRemote

@MainActor
final class RemoteSelectableTextTests: XCTestCase {
    func testTripleTapRangeUsesParagraphBoundariesAndUTF16Offsets() throws {
        let message = "First sentence. Still first.\r\n🐈 Second sentence. Still second.\nThird."
        let text = message as NSString
        let offset = text.range(of: "Still second").location
        let range = try XCTUnwrap(RemoteSelectableText.paragraphRange(in: message, at: offset))
        XCTAssertEqual(text.substring(with: range), "🐈 Second sentence. Still second.")
        XCTAssertNil(RemoteSelectableText.paragraphRange(in: "", at: 0))
    }

    func testProseUsesOneReadOnlyNativeTextViewWithSelectableRanges() throws {
        let view = RemoteMarkdownText(markdown: """
        First **paragraph**.

        Second [paragraph](https://example.com).
        """)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()

        let nativeViews = textViews(in: host.view)
        XCTAssertEqual(nativeViews.count, 1)
        let textView = try XCTUnwrap(nativeViews.first)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.isEditable)
        XCTAssertFalse(textView.isScrollEnabled)
        XCTAssertEqual(textView.text, "First paragraph.\nSecond paragraph.")

        let text = try XCTUnwrap(textView.text) as NSString
        let range = text.range(of: "paragraph.\nSecond")
        XCTAssertNotEqual(range.location, NSNotFound)
        textView.selectedRange = range
        XCTAssertEqual(text.substring(with: textView.selectedRange), "paragraph.\nSecond")

        let finalWord = text.range(of: "paragraph", options: .backwards)
        let link = textView.attributedText.attribute(.link, at: finalWord.location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "https://example.com")
    }

    private func textViews(in view: UIView) -> [UITextView] {
        if let textView = view as? UITextView { return [textView] }
        return view.subviews.flatMap(textViews(in:))
    }
}

final class RemoteImageDownloadTests: XCTestCase {
    func testDownloadsOnlyContiguousChunksFromTheSameImageRevision() throws {
        let chunkSize = RemoteImageAttachmentRequest.chunkBytes
        let first = Data(repeating: 1, count: chunkSize)
        let tail = Data([2, 3])
        var image = RemoteImageDownload()
        try image.append(.init(offset: 0, totalBytes: chunkSize + 2, revision: "first", bytes: first))
        XCTAssertFalse(image.isComplete)
        XCTAssertThrowsError(try image.append(.init(offset: chunkSize, totalBytes: chunkSize + 2, revision: "other", bytes: tail)))
        XCTAssertThrowsError(try image.append(.init(offset: chunkSize + 1, totalBytes: chunkSize + 2, revision: "first", bytes: tail)))
        try image.append(.init(offset: chunkSize, totalBytes: chunkSize + 2, revision: "first", bytes: tail))
        XCTAssertTrue(image.isComplete)
        XCTAssertEqual(image.bytes, first + tail)
    }
}

final class RemoteTranscriptTimelineTests: XCTestCase {
    func testRecentInitialOlderAndLatestPagesMergeByIdentity() {
        let sessionID = UUID()
        var timeline = RemoteTranscriptTimelineState()

        let initialGeneration = timeline.begin(.initial)
        XCTAssertTrue(timeline.apply(
            page(sessionID: sessionID, indexes: [4, 5], hasOlder: true, revision: 5),
            kind: .initial,
            generation: initialGeneration
        ))
        XCTAssertEqual(timeline.orderedItems.map(\.sequenceIndex), [4, 5])
        XCTAssertEqual(timeline.loadedRevision, 5)
        XCTAssertEqual(timeline.pagingMode, .recentBackward)

        let originalOlderCursor = cursor(index: 2)
        let olderGeneration = timeline.begin(.older)
        let overlap = item(index: 4, text: "updated four")
        let olderPage = RemoteTranscriptPage(
            sessionID: sessionID,
            items: [item(index: 2), item(index: 3), overlap],
            pagingMode: .recentBackward,
            olderCursor: originalOlderCursor,
            hasOlder: true,
            transcriptRevision: 5
        )
        XCTAssertTrue(timeline.apply(olderPage, kind: .older, generation: olderGeneration))
        XCTAssertEqual(timeline.orderedItems.map(\.sequenceIndex), [2, 3, 4, 5])
        XCTAssertEqual(timeline.itemsByID[overlap.id]?.text, "updated four")

        let latestGeneration = timeline.begin(.latest)
        XCTAssertTrue(timeline.apply(
            page(sessionID: sessionID, indexes: [4, 5, 6], hasOlder: true, revision: 6),
            kind: .latest,
            generation: latestGeneration
        ))
        XCTAssertEqual(timeline.orderedItems.map(\.sequenceIndex), [2, 3, 4, 5, 6])
        XCTAssertEqual(timeline.olderCursor, originalOlderCursor, "Latest refresh must not discard the existing backward-page boundary")
        XCTAssertEqual(timeline.loadedRevision, 6)
    }

    func testRecentInitialRefreshPreservesLoadedOlderRowsAndPagingAnchor() {
        let sessionID = UUID()
        var timeline = RemoteTranscriptTimelineState()

        let initial = timeline.begin(.initial)
        XCTAssertTrue(timeline.apply(
            page(sessionID: sessionID, indexes: [4, 5], hasOlder: true, revision: 5),
            kind: .initial,
            generation: initial
        ))
        let older = timeline.begin(.older)
        XCTAssertTrue(timeline.apply(
            page(sessionID: sessionID, indexes: [2, 3, 4], hasOlder: true, revision: 5),
            kind: .older,
            generation: older
        ))
        let loadedOlderCursor = timeline.olderCursor

        let reconnect = timeline.begin(.initial)
        XCTAssertTrue(timeline.apply(
            page(sessionID: sessionID, indexes: [5, 6], hasOlder: true, revision: 6),
            kind: .initial,
            generation: reconnect
        ))

        XCTAssertEqual(timeline.orderedItems.map(\.sequenceIndex), [2, 3, 4, 5, 6])
        XCTAssertEqual(timeline.olderCursor, loadedOlderCursor)
        XCTAssertEqual(timeline.loadedRevision, 6)
    }

    func testViewportUpdateClassificationOnlyTreatsLiveTailChangesAsActivity() {
        let oldItems = [item(index: 2), item(index: 3)]
        XCTAssertEqual(
            RemoteTranscriptViewportUpdate.classify(oldItems: [], newItems: oldItems),
            .initial
        )
        XCTAssertEqual(
            RemoteTranscriptViewportUpdate.classify(
                oldItems: oldItems,
                newItems: [item(index: 1)] + oldItems
            ),
            .preserve
        )

        let detailOnlyTail = RemoteTranscriptItem(
            id: uuid(3),
            turnID: uuid(1003),
            timestamp: Date(timeIntervalSince1970: 3),
            sequenceIndex: 3,
            kind: .activity,
            semanticKind: .assistantPreamble,
            role: "assistant",
            text: "item 3",
            detailAvailable: true,
            detailText: "hydrated detail"
        )
        XCTAssertEqual(
            RemoteTranscriptViewportUpdate.classify(
                oldItems: oldItems,
                newItems: [item(index: 2), detailOnlyTail]
            ),
            .preserve
        )
        XCTAssertEqual(
            RemoteTranscriptViewportUpdate.classify(
                oldItems: oldItems,
                newItems: oldItems + [item(index: 4)]
            ),
            .newActivity
        )
        XCTAssertEqual(
            RemoteTranscriptViewportUpdate.classify(
                oldItems: oldItems,
                newItems: [item(index: 2), item(index: 3, text: "streamed tail")]
            ),
            .newActivity
        )
        let refreshedTail = RemoteTranscriptItem(
            id: uuid(3),
            turnID: uuid(1003),
            timestamp: Date(timeIntervalSince1970: 4),
            sequenceIndex: 3,
            kind: .activity,
            semanticKind: .assistantPreamble,
            role: "assistant",
            text: "item 3",
            toolStatus: "completed"
        )
        XCTAssertEqual(
            RemoteTranscriptViewportUpdate.classify(
                oldItems: oldItems,
                newItems: [item(index: 2), refreshedTail]
            ),
            .tailUpdated
        )
        XCTAssertEqual(
            RemoteTranscriptViewportUpdate.classify(
                oldItems: oldItems,
                newItems: [item(index: 20), item(index: 21)]
            ),
            .preserve
        )
    }

    func testLiveOutputKeepsFollowingThroughLayoutChanges() {
        var follow = RemoteTranscriptFollowState()
        follow.updatePosition(isNearBottom: false, duringUserScroll: false)
        XCTAssertTrue(follow.receive(.newActivity))
        XCTAssertTrue(follow.receive(.tailUpdated))
        XCTAssertTrue(follow.followsLatest)
        XCTAssertFalse(follow.showsNewActivity)
    }

    func testReadingEarlierKeepsPositionUntilReturningNearTheBottom() {
        var follow = RemoteTranscriptFollowState()
        follow.updatePosition(isNearBottom: false, duringUserScroll: true)
        XCTAssertFalse(follow.receive(.tailUpdated))
        XCTAssertFalse(follow.showsNewActivity)
        XCTAssertFalse(follow.receive(.newActivity))
        XCTAssertTrue(follow.showsNewActivity)

        follow.updatePosition(isNearBottom: true, duringUserScroll: true)
        XCTAssertTrue(follow.followsLatest)
        XCTAssertFalse(follow.showsNewActivity)
        XCTAssertTrue(follow.receive(.newActivity))
    }

    func testDuplicateRowsAndStaleTaskCompletionAreNoOps() {
        let sessionID = UUID()
        var timeline = RemoteTranscriptTimelineState()
        let first = timeline.begin(.initial)
        let duplicate = item(index: 1)
        XCTAssertTrue(timeline.apply(
            RemoteTranscriptPage(
                sessionID: sessionID,
                items: [duplicate, duplicate],
                pagingMode: .recentBackward,
                hasOlder: false,
                transcriptRevision: 1
            ),
            kind: .initial,
            generation: first
        ))
        XCTAssertEqual(timeline.orderedItems.count, 1)

        let stale = timeline.begin(.latest)
        let current = timeline.begin(.latest)
        XCTAssertTrue(timeline.apply(
            page(sessionID: sessionID, indexes: [1, 2], revision: 2),
            kind: .latest,
            generation: current
        ))
        let acceptedState = timeline
        XCTAssertFalse(timeline.apply(
            page(sessionID: sessionID, indexes: [1], revision: 1),
            kind: .latest,
            generation: stale
        ))
        XCTAssertEqual(timeline, acceptedState)
    }

    func testLegacyPageFallbackUsesForwardCursorWithoutLosingRows() {
        let sessionID = UUID()
        var timeline = RemoteTranscriptTimelineState()
        let initial = timeline.begin(.initial)
        XCTAssertTrue(timeline.apply(
            RemoteTranscriptPage(
                sessionID: sessionID,
                items: [item(index: 0), item(index: 1)],
                nextSequenceIndex: 1,
                hasMore: true
            ),
            kind: .initial,
            generation: initial
        ))
        XCTAssertTrue(timeline.isLegacyPaging)
        XCTAssertEqual(timeline.legacyNextSequenceIndex, 1)
        XCTAssertTrue(timeline.hasOlder)

        let next = timeline.begin(.older)
        XCTAssertTrue(timeline.apply(
            RemoteTranscriptPage(
                sessionID: sessionID,
                items: [item(index: 2)],
                hasMore: false
            ),
            kind: .older,
            generation: next
        ))
        XCTAssertEqual(timeline.orderedItems.map(\.sequenceIndex), [0, 1, 2])
        XCTAssertFalse(timeline.hasOlder)
    }

    func testLegacyLatestRefreshDrainsForwardBeforeRecordingRevision() {
        let sessionID = UUID()
        var timeline = RemoteTranscriptTimelineState()
        let initial = timeline.begin(.initial)
        XCTAssertTrue(timeline.apply(
            RemoteTranscriptPage(
                sessionID: sessionID,
                items: [item(index: 0), item(index: 1)],
                nextSequenceIndex: 1,
                hasMore: true
            ),
            kind: .initial,
            generation: initial
        ))
        XCTAssertEqual(timeline.legacyRefreshSequenceIndex, 1)

        let refresh = timeline.begin(.latest)
        XCTAssertTrue(timeline.apply(
            RemoteTranscriptPage(
                sessionID: sessionID,
                items: [item(index: 2), item(index: 3), item(index: 4)],
                hasMore: false
            ),
            kind: .latest,
            generation: refresh,
            requestedRevision: 9
        ))
        XCTAssertEqual(timeline.orderedItems.map(\.sequenceIndex), [0, 1, 2, 3, 4])
        XCTAssertEqual(timeline.loadedRevision, 9)
        XCTAssertFalse(timeline.hasOlder)
    }

    func testOneMutationGenerationRejectsSlowInitialAfterLatestRefresh() {
        let sessionID = UUID()
        var timeline = RemoteTranscriptTimelineState()
        let slowInitial = timeline.begin(.initial)
        let latest = timeline.begin(.latest)
        XCTAssertTrue(timeline.apply(
            page(sessionID: sessionID, indexes: [4, 5], revision: 5),
            kind: .latest,
            generation: latest
        ))
        let acceptedState = timeline

        XCTAssertFalse(timeline.apply(
            page(sessionID: sessionID, indexes: [0, 1], revision: 1),
            kind: .initial,
            generation: slowInitial
        ))
        XCTAssertEqual(timeline, acceptedState)
    }

    func testRecentRefreshBatchWalksMultiplePagesUntilContinuityAndAppliesAtomically() throws {
        let sessionID = UUID()
        var timeline = RemoteTranscriptTimelineState()
        let initial = timeline.begin(.initial)
        XCTAssertTrue(timeline.apply(
            page(sessionID: sessionID, indexes: [0, 1], revision: 1),
            kind: .initial,
            generation: initial
        ))
        let beforeRefresh = timeline
        var batch = RemoteTranscriptRecentRefreshBatch(existingItems: timeline.orderedItems)

        XCTAssertFalse(batch.append(page(sessionID: sessionID, indexes: [5, 6], hasOlder: true, revision: 6)))
        XCTAssertFalse(batch.append(page(sessionID: sessionID, indexes: [3, 4], hasOlder: true, revision: 6)))
        XCTAssertEqual(timeline, beforeRefresh, "Partial pages must not mutate the visible timeline")
        XCTAssertTrue(batch.append(page(sessionID: sessionID, indexes: [1, 2], hasOlder: true, revision: 6)))

        let refresh = timeline.begin(.latest)
        XCTAssertTrue(timeline.apply(
            try batch.combinedPage(requestedRevision: 6),
            kind: .latest,
            generation: refresh
        ))
        XCTAssertEqual(timeline.orderedItems.map(\.sequenceIndex), [0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(timeline.loadedRevision, 6)
    }

    func testSavedChatConfigurationSurvivesLoadingOlderMessages() {
        let sessionID = UUID()
        let selection = RemoteAgentSelection(agentID: "codexExec", modelID: "gpt-5.6-sol", reasoningEffort: "high")
        let configuration = RemoteChatConfiguration(selection: selection)
        var timeline = RemoteTranscriptTimelineState()
        let initial = timeline.begin(.initial)
        XCTAssertTrue(timeline.apply(
            RemoteTranscriptPage(sessionID: sessionID, items: [], chatConfiguration: configuration),
            kind: .initial, generation: initial
        ))

        let older = timeline.begin(.older)
        XCTAssertTrue(timeline.apply(
            RemoteTranscriptPage(sessionID: sessionID, items: []), kind: .older, generation: older
        ))
        XCTAssertEqual(timeline.chatConfiguration, configuration)
    }

    func testLateDetailResponseCannotOverwriteNewerVisibleTranscriptFields() {
        let sessionID = UUID()
        var timeline = RemoteTranscriptTimelineState()
        let initial = timeline.begin(.initial)
        XCTAssertTrue(timeline.apply(
            RemoteTranscriptPage(
                sessionID: sessionID,
                items: [item(index: 1, text: "new streaming text")],
                pagingMode: .recentBackward,
                hasOlder: false,
                transcriptRevision: 2
            ),
            kind: .initial,
            generation: initial
        ))
        let staleDetailed = RemoteTranscriptItem(
            id: uuid(1),
            turnID: uuid(1001),
            timestamp: Date(timeIntervalSince1970: 1),
            sequenceIndex: 1,
            kind: .activity,
            semanticKind: .compactActivity,
            role: "tool",
            text: "stale text",
            toolStatus: "running",
            detailAvailable: true,
            detailText: "Arguments: {}",
            detail: RemoteTranscriptDetail(argumentsJSON: "{}")
        )

        timeline.mergeDetails(from: staleDetailed)

        XCTAssertEqual(timeline.itemsByID[uuid(1)]?.text, "new streaming text")
        XCTAssertEqual(timeline.itemsByID[uuid(1)]?.semanticKind, .assistantPreamble)
        XCTAssertEqual(timeline.itemsByID[uuid(1)]?.detailText, "Arguments: {}")
        XCTAssertEqual(timeline.itemsByID[uuid(1)]?.detail?.argumentsJSON, "{}")
    }

    func testFailedRefreshRetainsLastCompleteTimeline() {
        let sessionID = UUID()
        var timeline = RemoteTranscriptTimelineState()
        let initial = timeline.begin(.initial)
        XCTAssertTrue(timeline.apply(
            page(sessionID: sessionID, indexes: [1, 2], revision: 2),
            kind: .initial,
            generation: initial
        ))
        let items = timeline.orderedItems
        let refresh = timeline.begin(.latest)
        XCTAssertTrue(timeline.fail("offline", kind: .latest, generation: refresh))
        XCTAssertEqual(timeline.orderedItems, items)
        XCTAssertEqual(timeline.latestRefreshState, .failed("offline"))
    }

    private func page(
        sessionID: UUID,
        indexes: [Int],
        hasOlder: Bool = false,
        revision: UInt64? = nil
    ) -> RemoteTranscriptPage {
        RemoteTranscriptPage(
            sessionID: sessionID,
            items: indexes.map { item(index: $0) },
            pagingMode: .recentBackward,
            olderCursor: indexes.first.map(cursor(index:)),
            hasOlder: hasOlder,
            transcriptRevision: revision
        )
    }

    private func item(index: Int, text: String? = nil) -> RemoteTranscriptItem {
        RemoteTranscriptItem(
            id: uuid(index),
            turnID: uuid(index + 1000),
            timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
            sequenceIndex: index,
            kind: .activity,
            semanticKind: .assistantPreamble,
            role: "assistant",
            text: text ?? "item \(index)"
        )
    }

    private func cursor(index: Int) -> RemoteTranscriptCursor {
        RemoteTranscriptCursor(
            sequenceIndex: index,
            timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
            itemID: uuid(index)
        )
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}

final class RemoteSessionNavigationProjectionTests: XCTestCase {
    func testSwitchingWorkspacesLeavesTheChatListSelectedWhenHistoryArrives() {
        let latest = UUID()
        XCTAssertNil(RemoteSessionNavigationProjection.selectionID(
            current: nil, chatIDs: [], allowsInitialSelection: false
        ))
        XCTAssertNil(RemoteSessionNavigationProjection.selectionID(
            current: nil, chatIDs: [latest], allowsInitialSelection: false
        ))
        XCTAssertEqual(RemoteSessionNavigationProjection.selectionID(
            current: nil, chatIDs: [latest], allowsInitialSelection: true
        ), latest)
    }

    func testHierarchyIsDepthFirstAndRootsUseNewestSubtreeActivity() {
        let rootA = uuid(1)
        let childA = uuid(2)
        let rootB = uuid(3)
        let items = [
            chat(rootA, activity: 10),
            chat(childA, activity: 100),
            chat(rootB, activity: 50)
        ]
        let sessions = [
            session(rootA, state: .idle, updated: 10),
            session(childA, parent: rootA, state: .completed, updated: 100),
            session(rootB, state: .working, updated: 50)
        ]
        let unseen = [
            childA: RemoteSessionUnseenState(attentionRunState: .completed, hasUnreadNarrative: true)
        ]

        let rows = RemoteSessionNavigationProjection.project(
            items: items,
            sessions: sessions,
            selectedSessionID: rootB,
            unseenBySessionID: unseen
        )
        XCTAssertEqual(rows.map(\.id), [rootA, childA, rootB])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 0])
        XCTAssertTrue(rows[0].hasChildren)
        XCTAssertEqual(rows[0].unseenDescendantCount, 1)
        XCTAssertEqual(rows[1].validParentID, rootA)
        XCTAssertEqual(rows[1].status, .completed(unseen: true))
        XCTAssertEqual(rows[2].status, .working)
        XCTAssertEqual(RemoteSessionNavigationProjection.selectionID(current: rootB, chatIDs: rows.map(\.id), allowsInitialSelection: false), rootB)
    }

    func testMalformedParentsAndEveryDescendantWhoseAncestorWalkReachesCycleBecomeRoots() {
        let a = uuid(10)
        let b = uuid(11)
        let selfLinked = uuid(12)
        let missing = uuid(13)
        let childOfCycleMember = uuid(14)
        let absentParent = uuid(99)
        let items = [a, b, selfLinked, missing, childOfCycleMember].map { chat($0, activity: Double($0.uuidString.suffix(2)) ?? 0) }
        let sessions = [
            session(a, parent: b),
            session(b, parent: a),
            session(selfLinked, parent: selfLinked),
            session(missing, parent: absentParent),
            session(childOfCycleMember, parent: a)
        ]

        let rows = RemoteSessionNavigationProjection.project(
            items: items,
            sessions: sessions,
            selectedSessionID: a,
            unseenBySessionID: [:]
        )
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertNil(byID[a]?.validParentID)
        XCTAssertNil(byID[b]?.validParentID)
        XCTAssertNil(byID[selfLinked]?.validParentID)
        XCTAssertNil(byID[missing]?.validParentID)
        XCTAssertNil(byID[childOfCycleMember]?.validParentID)
        XCTAssertEqual(byID[childOfCycleMember]?.depth, 0)
    }

    func testWorkingStateOverridesStaleAttentionAndNarrativeHasLowestAttentionPrecedence() {
        let working = uuid(20)
        let waiting = uuid(21)
        let narrative = uuid(22)
        let rows = RemoteSessionNavigationProjection.project(
            items: [chat(working), chat(waiting), chat(narrative)],
            sessions: [
                session(working, state: .working),
                session(waiting, state: .waitingForInput),
                session(narrative, state: .idle)
            ],
            selectedSessionID: working,
            unseenBySessionID: [
                working: RemoteSessionUnseenState(attentionRunState: .completed, hasUnreadNarrative: true),
                waiting: RemoteSessionUnseenState(attentionRunState: .waitingForInput, hasUnreadNarrative: true),
                narrative: RemoteSessionUnseenState(hasUnreadNarrative: true)
            ]
        )
        let status = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.status) })
        XCTAssertEqual(status[working], .working)
        XCTAssertEqual(status[waiting], .waiting(unseen: true))
        XCTAssertEqual(status[narrative], .unreadNarrative)
    }

    func testSelectionDoesNotChangeWhenOrderingChanges() {
        let selected = uuid(30)
        let other = uuid(31)
        let first = RemoteSessionNavigationProjection.project(
            items: [chat(selected, activity: 10), chat(other, activity: 5)],
            sessions: [session(selected), session(other)],
            selectedSessionID: selected,
            unseenBySessionID: [:]
        )
        let reordered = RemoteSessionNavigationProjection.project(
            items: [chat(selected, activity: 10), chat(other, activity: 50)],
            sessions: [session(selected), session(other)],
            selectedSessionID: selected,
            unseenBySessionID: [:]
        )
        XCTAssertNotEqual(first.map(\.id), reordered.map(\.id))
        XCTAssertEqual(RemoteSessionNavigationProjection.selectionID(current: selected, chatIDs: reordered.map(\.id), allowsInitialSelection: false), selected)
    }

    private func chat(_ id: UUID, activity: Double = 0) -> RemoteChatListItem {
        RemoteChatListItem(
            id: id,
            workspaceID: "workspace",
            title: id.uuidString,
            runState: .idle,
            lastActivityAt: Date(timeIntervalSince1970: activity)
        )
    }

    private func session(
        _ id: UUID,
        parent: UUID? = nil,
        state: RemoteRunState = .idle,
        updated: Double = 0
    ) -> RemoteSessionSummary {
        RemoteSessionSummary(
            sessionID: id,
            workspaceID: "workspace",
            parentSessionID: parent,
            runState: state,
            lastUpdatedAt: Date(timeIntervalSince1970: updated),
            isLive: true
        )
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}

final class RemoteUnseenAndRevisionProjectionTests: XCTestCase {
    func testFirstSnapshotDoesNotManufactureHistoricalUnseenState() {
        let id = UUID()
        let result = RemoteSessionUnseenProjection.reconcileRunTransitions(
            previous: [],
            current: [session(id, state: .completed)],
            existing: [:],
            visibleSessionID: nil,
            isInitial: true
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testBackgroundAttentionCanBeAcknowledgedAndMarkedAgain() {
        let id = UUID()
        let working = session(id, state: .working)
        let completed = session(id, state: .completed)
        let marked = RemoteSessionUnseenProjection.reconcileRunTransitions(
            previous: [working],
            current: [completed],
            existing: [:],
            visibleSessionID: nil,
            isInitial: false
        )
        XCTAssertEqual(marked[id]?.attentionRunState, .completed)
        let acknowledged = RemoteSessionUnseenProjection.acknowledging(sessionID: id, in: marked)
        XCTAssertNil(acknowledged[id])
        let markedAgain = RemoteSessionUnseenProjection.reconcileRunTransitions(
            previous: [working],
            current: [completed],
            existing: acknowledged,
            visibleSessionID: nil,
            isInitial: false
        )
        XCTAssertEqual(markedAgain[id]?.attentionRunState, .completed)
    }

    func testVisibleAndNonAttentionTransitionsDoNotMarkUnseen() {
        let id = UUID()
        XCTAssertTrue(RemoteSessionUnseenProjection.reconcileRunTransitions(
            previous: [session(id, state: .working)],
            current: [session(id, state: .failed)],
            existing: [:],
            visibleSessionID: id,
            isInitial: false
        ).isEmpty)
        XCTAssertTrue(RemoteSessionUnseenProjection.reconcileRunTransitions(
            previous: [session(id, state: .working)],
            current: [session(id, state: .cancelled)],
            existing: [:],
            visibleSessionID: nil,
            isInitial: false
        ).isEmpty)
    }

    func testRevisionDispositionDeduplicatesAndSeparatesVisibleFromBackground() {
        XCTAssertEqual(RemoteTranscriptRevisionReconciliation.disposition(
            incomingRevision: 4,
            knownRevision: 4,
            loadedRevision: nil,
            isVisible: false
        ), .ignore)
        XCTAssertEqual(RemoteTranscriptRevisionReconciliation.disposition(
            incomingRevision: 5,
            knownRevision: 4,
            loadedRevision: nil,
            isVisible: false
        ), .markUnread)
        XCTAssertEqual(RemoteTranscriptRevisionReconciliation.disposition(
            incomingRevision: 5,
            knownRevision: 4,
            loadedRevision: 4,
            isVisible: true
        ), .refreshLatest)
        XCTAssertEqual(RemoteTranscriptRevisionReconciliation.disposition(
            incomingRevision: 5,
            knownRevision: 4,
            loadedRevision: 5,
            isVisible: true
        ), .recordOnly)
    }

    func testEpochResetUsesGatewayEpochDesktopIdentityCursorOrLegacyRevisionRegression() {
        let sessionID = UUID()
        let epochA = UUID()
        let epochB = UUID()
        let old = snapshot(desktopID: "desktop", cursor: 10, epoch: epochA)
        XCTAssertFalse(RemoteTranscriptRevisionReconciliation.isEpochReset(
            previous: old,
            current: snapshot(desktopID: "desktop", cursor: 11, epoch: epochA)
        ))
        XCTAssertTrue(RemoteTranscriptRevisionReconciliation.isEpochReset(
            previous: old,
            current: snapshot(desktopID: "desktop", cursor: 1, epoch: epochA)
        ))
        XCTAssertTrue(RemoteTranscriptRevisionReconciliation.isEpochReset(
            previous: old,
            current: snapshot(desktopID: "new-desktop", cursor: 11, epoch: epochA)
        ))
        XCTAssertTrue(RemoteTranscriptRevisionReconciliation.isEpochReset(
            previous: old,
            current: snapshot(desktopID: "desktop", cursor: 11, epoch: epochB)
        ))
        XCTAssertTrue(RemoteTranscriptRevisionReconciliation.isEpochReset(
            previous: snapshot(
                desktopID: "desktop",
                cursor: 10,
                sessions: [session(sessionID, state: .working, revision: 9)]
            ),
            current: snapshot(
                desktopID: "desktop",
                cursor: 11,
                sessions: [session(sessionID, state: .working, revision: 1)]
            )
        ))
    }

    private func session(
        _ id: UUID,
        state: RemoteRunState,
        revision: UInt64? = nil
    ) -> RemoteSessionSummary {
        RemoteSessionSummary(
            sessionID: id,
            workspaceID: "workspace",
            transcriptRevision: revision,
            runState: state,
            isLive: true
        )
    }

    private func snapshot(
        desktopID: String,
        cursor: UInt64,
        epoch: UUID? = nil,
        sessions: [RemoteSessionSummary] = []
    ) -> RemoteSnapshot {
        RemoteSnapshot(
            desktop: RemoteDesktopSummary(
                instanceID: desktopID,
                displayName: "Mac",
                appVersion: "test",
                isAvailable: true
            ),
            connection: RemoteConnectionSummary(state: .connected),
            authorization: RemoteAuthorizationState(),
            sessions: sessions,
            eventCursor: cursor,
            transcriptRevisionEpoch: epoch
        )
    }
}

final class RemoteWorkflowLaunchPolicyTests: XCTestCase {
    func testLegacyCatalogOrderIsPreservedAndNoWorkflowIsImplicitlySelected() {
        let workflows = [
            RemoteWorkflowDescriptor(id: "z", displayName: "Zulu", isBuiltIn: true),
            RemoteWorkflowDescriptor(id: "a", displayName: "Alpha", isBuiltIn: true)
        ]

        XCTAssertEqual(RemoteWorkflowCatalogOrdering.ordered(workflows).map(\.id), ["z", "a"])
        XCTAssertNil(RemoteWorkflowCatalogOrdering.reconciledSelection(nil, in: workflows))
    }

    func testFeaturedRanksLeadWhileUnrankedCatalogOrderRemainsStable() {
        let workflows = [
            RemoteWorkflowDescriptor(id: "custom-1", displayName: "Custom One", isBuiltIn: false),
            RemoteWorkflowDescriptor(id: "rank-1", displayName: "Second", isBuiltIn: true, featuredRank: 1),
            RemoteWorkflowDescriptor(id: "rank-0", displayName: "First", isBuiltIn: true, featuredRank: 0),
            RemoteWorkflowDescriptor(id: "custom-2", displayName: "Custom Two", isBuiltIn: false)
        ]

        XCTAssertEqual(
            RemoteWorkflowCatalogOrdering.ordered(workflows).map(\.id),
            ["rank-0", "rank-1", "custom-1", "custom-2"]
        )
        XCTAssertEqual(
            RemoteWorkflowCatalogOrdering.reconciledSelection("custom-1", in: workflows),
            "custom-1"
        )
    }
}

final class RemoteWorkspaceHistoryTests: XCTestCase {
    func testLoadsAllScopedPagesAndKeepsOneCopyPerSession() async throws {
        let workspaceID = UUID()
        let newer = entry(in: workspaceID, time: 3)
        let older = entry(in: workspaceID, time: 2)
        let cursor = RemoteHistoryCursor(lastActivityAt: newer.lastActivityAt, sessionID: newer.id)
        var cursors: [RemoteHistoryCursor?] = []

        let result = try await RemoteWorkspaceHistory.load(workspaceID: workspaceID) { request in
            XCTAssertEqual(request.workspaceID, workspaceID)
            cursors.append(request.before)
            if request.before == nil {
                return RemoteHistoryPage(entries: [newer], hasMore: true, workspaceID: workspaceID, olderCursor: cursor)
            }
            return RemoteHistoryPage(entries: [newer, older], workspaceID: workspaceID)
        }

        XCTAssertEqual(cursors, [nil, cursor])
        XCTAssertEqual(result.entries, [newer, older])
        XCTAssertEqual(result.phase, .loaded)
    }

    func testLegacyGlobalPageIsFilteredAndReportsWhenItIsIncomplete() async throws {
        let workspaceID = UUID()
        let matching = entry(in: workspaceID, time: 1)
        let other = entry(in: UUID(), time: 2)
        let result = try await RemoteWorkspaceHistory.load(workspaceID: workspaceID) { _ in
            RemoteHistoryPage(entries: [other, matching], hasMore: true)
        }
        XCTAssertEqual(result.entries, [matching])
        XCTAssertEqual(result.phase, .limited)
    }

    func testRepeatedCursorFailsInsteadOfContinuingToFetch() async {
        let workspaceID = UUID()
        let item = entry(in: workspaceID, time: 1)
        let cursor = RemoteHistoryCursor(lastActivityAt: item.lastActivityAt, sessionID: item.id)
        do {
            _ = try await RemoteWorkspaceHistory.load(workspaceID: workspaceID) { _ in
                RemoteHistoryPage(entries: [item], hasMore: true, workspaceID: workspaceID, olderCursor: cursor)
            }
            XCTFail("A repeated history cursor must stop the page loop.")
        } catch RemoteGatewayError.invalidResponse {
        } catch {
            XCTFail("Unexpected history failure: \(error)")
        }
    }

    private func entry(in workspaceID: UUID, time: TimeInterval) -> RemoteHistoryEntry {
        RemoteHistoryEntry(
            id: UUID(), workspaceID: workspaceID.uuidString, sessionName: "Saved chat",
            lastActivityAt: Date(timeIntervalSinceReferenceDate: time)
        )
    }
}

final class RemoteComposerPolicyTests: XCTestCase {
    func testProviderSwitchDoesNotCarryUnsupportedReasoningEffort() {
        let model = RemoteModelDescriptor(id: "other-model", displayName: "Other", defaultReasoningEffortID: "medium")
        let agent = RemoteAgentDescriptor(
            id: "other", displayName: "Other", models: [model.id], isAvailable: true, modelDescriptors: [model]
        )
        let draft = RemoteAgentSelection(agentID: agent.id, modelID: model.id, reasoningEffort: "high")
        XCTAssertEqual(
            RemoteLaunchSelection.resolve(draft: draft, desktopDefault: nil, agents: [agent]),
            RemoteAgentSelection(agentID: agent.id, modelID: model.id, reasoningEffort: nil)
        )
        XCTAssertEqual(RemoteLaunchSelection.modelLabel("GPT-5.6 Sol"), "GPT-5.6 SOL")
    }

    func testNewChatUsesOrdinaryComposerControlsAndRetainsTheResolvedEffort() {
        XCTAssertEqual(RemoteComposerPolicy.newChat.primaryOperation, .startRun)
        XCTAssertTrue(RemoteComposerPolicy.newChat.canAttach)
        XCTAssertFalse(RemoteComposerPolicy.newChat.canCancel)

        let selection = RemoteAgentSelection(agentID: "codex", modelID: "default", reasoningEffort: "high")
        let model = RemoteModelDescriptor(
            id: "default", displayName: "Default",
            reasoningEfforts: [
                .init(id: "medium", displayName: "Medium"),
                .init(id: "high", displayName: "High")
            ],
            defaultReasoningEffortID: "medium"
        )
        let agent = RemoteAgentDescriptor(
            id: "codex", displayName: "Codex", models: ["default"], isAvailable: true, modelDescriptors: [model]
        )
        XCTAssertEqual(RemoteLaunchSelection.resolve(draft: nil, desktopDefault: selection, agents: [agent]), selection)
        let stale = RemoteAgentSelection(agentID: "old", modelID: "removed")
        XCTAssertEqual(RemoteLaunchSelection.resolve(draft: stale, desktopDefault: selection, agents: [agent]), selection)
    }

    func testCompleteComposerMatrix() {
        assertPolicy(.opening, operation: .steer, canCancel: true, label: "Steer")
        assertPolicy(.working, operation: .steer, canCancel: true, label: "Steer")
        assertPolicy(.waitingForInput, operation: .followUp, canCancel: true, label: "Reply")
        assertPolicy(.blocked, operation: .followUp, canCancel: true, label: "Reply")
        assertPolicy(.idle, operation: .followUp, canCancel: false, label: "Reply")
        assertPolicy(.completed, operation: .resume, canCancel: false, label: "Resume")
        assertPolicy(.failed, operation: .resume, canCancel: false, label: "Resume")
        assertPolicy(.cancelled, operation: .resume, canCancel: false, label: "Resume")
    }

    func testPendingInteractionAlwaysBlocksOrdinaryComposerText() {
        let interaction = RemoteInteractionSummary(
            id: UUID().uuidString,
            kind: .secretInput,
            prompt: "Token",
            requiresSecureEntry: true
        )
        for state in [RemoteRunState.opening, .working, .waitingForInput, .blocked, .completed, .failed, .cancelled, .idle] {
            let policy = RemoteComposerPolicy.resolve(runState: state, pendingInteraction: interaction)
            XCTAssertNil(policy.primaryOperation)
            XCTAssertTrue(policy.isInteractionBlocking)
            XCTAssertEqual(policy.canCancel, [.opening, .working, .waitingForInput, .blocked].contains(state))
        }
    }

    private func assertPolicy(
        _ state: RemoteRunState,
        operation: RemoteCommandOperation,
        canCancel: Bool,
        label: String
    ) {
        let policy = RemoteComposerPolicy.resolve(runState: state, pendingInteraction: nil)
        XCTAssertEqual(policy.primaryOperation, operation)
        XCTAssertEqual(policy.canCancel, canCancel)
        XCTAssertEqual(policy.primaryLabel, label)
        XCTAssertFalse(policy.isInteractionBlocking)
    }
}

final class RemoteCommandAndGatewayProjectionTests: XCTestCase {
    func testAcceptedCommandCompletionCannotBeDowngradedByReconciliationFailure() {
        let commandID = UUID()
        var activity = RemoteCommandActivityState()
        activity.record(RemoteCommandCompletion(
            commandID: commandID,
            operation: .followUp,
            outcome: .accepted
        ))
        activity.record(RemoteCommandCompletion(
            commandID: commandID,
            operation: .followUp,
            outcome: .failed
        ))

        XCTAssertEqual(activity.completion(for: commandID)?.outcome, .accepted)
    }

    func testAcceptedStartUsesReturnedSessionIDAndCreatesProvisionalRoute() {
        let returnedID = UUID()
        let request = RemoteCommandRequest(
            commandID: UUID(),
            operation: .startRun,
            workspaceID: "workspace",
            message: "private request content",
            workflowID: "orchestrate"
        )
        let response = RemoteCommandResponse(
            commandID: request.commandID,
            accepted: true,
            workspaceID: "authoritative-workspace",
            sessionID: returnedID,
            runState: .opening
        )
        let accepted = RemoteAcceptedCommand(response: response, operation: request.operation)
        let route = RemoteProvisionalSessionRoute.acceptedStart(response: response, request: request)

        XCTAssertEqual(accepted.sessionID, returnedID)
        XCTAssertEqual(accepted.workspaceID, "authoritative-workspace")
        XCTAssertEqual(route?.sessionID, returnedID)
        XCTAssertEqual(route?.workspaceID, "authoritative-workspace")
        XCTAssertEqual(route?.runState, .opening)
    }

    func testRejectedOrMissingReturnedSessionNeverCreatesProvisionalSelection() {
        let request = RemoteCommandRequest(operation: .startRun, workspaceID: "workspace", message: "start")
        XCTAssertNil(RemoteProvisionalSessionRoute.acceptedStart(
            response: RemoteCommandResponse(commandID: request.commandID, accepted: false, sessionID: UUID()),
            request: request
        ))
        XCTAssertNil(RemoteProvisionalSessionRoute.acceptedStart(
            response: RemoteCommandResponse(commandID: request.commandID, accepted: true),
            request: request
        ))
    }
}
