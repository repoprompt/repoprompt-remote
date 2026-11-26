import Foundation
import RepoPromptRemoteProtocol
import XCTest
@testable import RepoPromptRemote

final class RemoteTranscriptPresentationTests: XCTestCase {
    func testLegacySemanticFallbackPreservesAssistantNarrative() {
        XCTAssertEqual(
            RemoteTranscriptPresentation.semanticKind(for: item(kind: .request, role: "user")),
            .userRequest
        )
        XCTAssertEqual(
            RemoteTranscriptPresentation.semanticKind(for: item(kind: .activity, role: "assistant")),
            .assistantPreamble
        )
        XCTAssertEqual(
            RemoteTranscriptPresentation.semanticKind(for: item(kind: .conclusion, role: "assistant")),
            .assistantAnswer
        )
        XCTAssertEqual(
            RemoteTranscriptPresentation.semanticKind(for: item(kind: .activity, role: "assistant", tool: "read_file")),
            .compactActivity
        )
    }

    func testReadAndSearchResultsShowContentsAndRanges() throws {
        let read = try XCTUnwrap(RemoteToolDetailPresentation(
            kind: .read,
            detail: .init(resultJSON: #"{"structuredContent":{"display_path":"Sources/A.swift","first_line":4,"last_line":6,"content":"let value = 4"}}"#),
            summaryOnly: false
        ))
        XCTAssertEqual(read.metadata, ["Lines 4–6"])
        XCTAssertEqual(read.sections.map(\.text), ["Sources/A.swift", "let value = 4"])
        let search = try XCTUnwrap(RemoteToolDetailPresentation(
            kind: .search,
            detail: .init(
                argumentsJSON: #"{"pattern":"value"}"#,
                resultJSON: #"{"total_matches":1,"size_limit_hit":true,"content_match_groups":[{"path":"Sources/A.swift","lines":[{"line_number":4,"line_text":"let value = 4"}]}]}"#
            ),
            summaryOnly: false
        ))
        XCTAssertEqual(search.metadata, ["1 match"])
        XCTAssertEqual(search.sections.map(\.text), ["value", "Sources/A.swift:4: let value = 4"])
        XCTAssertTrue(search.isPartial)
    }

    func testShellResultShowsCommandOutputAndExitCode() throws {
        XCTAssertEqual(RemoteToolCardKind("functions.exec_command"), .shell)
        let shell = try XCTUnwrap(RemoteToolDetailPresentation(
            kind: .shell,
            detail: .init(resultJSON: #"{"command":"swift build","status":"failed","aggregatedOutput":"Build failed","exitCode":1}"#),
            summaryOnly: false
        ))
        XCTAssertEqual(shell.sections.map(\.text), ["swift build", "Build failed"])
        XCTAssertEqual(shell.exitCode, 1)
    }

    func testEditResultShowsPerFileDiffAndFallsBackOnTruncatedJSON() throws {
        let patch = try XCTUnwrap(RemoteToolDetailPresentation(
            kind: .edit,
            detail: .init(resultJSON: #"{"changes":[{"path":"Sources/A.swift","diff":"--- a/A.swift\n+++ b/A.swift\n@@ -1 +1 @@\n-old\n+new"}]}"#),
            summaryOnly: false
        ))
        XCTAssertEqual(patch.metadata, ["+1 −1 lines"])
        XCTAssertEqual(patch.sections.first?.title, "Sources/A.swift")
        XCTAssertEqual(patch.sections.first?.isDiff, true)
        XCTAssertNil(RemoteToolDetailPresentation(
            kind: .edit, detail: .init(resultJSON: #"{"changes":["#), summaryOnly: true
        ))
        XCTAssertNil(RemoteToolCardKind("unknown_external_tool"))
    }

    func testOrdinaryActivityGroupsBetweenNarrativeRows() {
        let request = item(kind: .request, role: "user", semantic: .userRequest)
        let firstTool = item(kind: .activity, role: "tool", semantic: .compactActivity, tool: "read_file")
        let secondTool = item(kind: .activity, role: "tool", semantic: .compactActivity, tool: "file_search")
        let answer = item(kind: .conclusion, role: "assistant", semantic: .assistantAnswer)

        let elements = RemoteTranscriptPresentation.elements(from: [request, firstTool, secondTool, answer])
        XCTAssertEqual(elements.count, 3)
        guard case let .activityGroup(items, exceptional) = elements[1] else {
            return XCTFail("Expected an activity group")
        }
        XCTAssertEqual(items.map(\.id), [firstTool.id, secondTool.id])
        XCTAssertFalse(exceptional)
    }

    func testExceptionalActivityIsSeparatedAndExposed() {
        let successful = item(
            kind: .activity,
            role: "tool",
            semantic: .compactActivity,
            tool: "read_file",
            status: "completed"
        )
        let failed = item(
            kind: .activity,
            role: "tool",
            semantic: .compactActivity,
            tool: "apply_edits",
            status: "failed"
        )

        let elements = RemoteTranscriptPresentation.elements(from: [successful, failed])
        XCTAssertEqual(elements.count, 2)
        guard case let .activityGroup(items, exceptional) = elements[1] else {
            return XCTFail("Expected exceptional activity")
        }
        XCTAssertEqual(items, [failed])
        XCTAssertTrue(exceptional)
    }

    func testExplicitQuestionAndApprovalAreNeverCollapsedIntoOrdinaryTools() {
        let question = item(kind: .activity, role: "system", semantic: .question)
        let approval = item(kind: .activity, role: "system", semantic: .approval)
        let elements = RemoteTranscriptPresentation.elements(from: [question, approval])

        XCTAssertEqual(elements.count, 2)
        for element in elements {
            guard case let .activityGroup(_, exceptional) = element else {
                return XCTFail("Expected exceptional interaction activity")
            }
            XCTAssertTrue(exceptional)
        }
    }

    func testMarkdownParserSeparatesHeadingsParagraphsAndLists() {
        let markdown = """
        # Status

        First **paragraph**.

        Second paragraph
        continues.

        1. First
        2. Second
          - Nested
        """

        XCTAssertEqual(RemoteMarkdownDocumentParser.parse(markdown), [
            .heading(level: 1, text: "Status"),
            .paragraph("First **paragraph**."),
            .paragraph("Second paragraph continues."),
            .list([
                RemoteMarkdownListItem(marker: .ordered(1), depth: 0, text: "First"),
                RemoteMarkdownListItem(marker: .ordered(2), depth: 0, text: "Second"),
                RemoteMarkdownListItem(marker: .bullet, depth: 1, text: "Nested")
            ])
        ])
    }

    func testMarkdownParserPreservesHardBreaksAndBlockContent() {
        let markdown = """
        Alternate heading
        -----------------

        First line\\
        second line\\
        third line

        > Quoted **text**
        > continues

        ```swift
        let value = 42
        print(value)
        ```

        ---
        """

        XCTAssertEqual(RemoteMarkdownDocumentParser.parse(markdown), [
            .heading(level: 2, text: "Alternate heading"),
            .paragraph("First line\nsecond line\nthird line"),
            .blockQuote("Quoted **text** continues"),
            .codeBlock(language: "swift", code: "let value = 42\nprint(value)"),
            .thematicBreak
        ])
    }

    func testMarkdownParserKeepsIndentedAndNestedCodeAsBlocks() {
        let markdown = """
            # literal heading
            - literal list

        - Run this:
          ```sh
          make test
          ```
        """

        XCTAssertEqual(RemoteMarkdownDocumentParser.parse(markdown), [
            .codeBlock(language: nil, code: "# literal heading\n- literal list"),
            .list([
                RemoteMarkdownListItem(marker: .bullet, depth: 0, text: "Run this:")
            ]),
            .codeBlock(language: "sh", code: "make test")
        ])
    }

    func testMarkdownParserDistinguishesSpacedDividerAndPreservesTables() {
        let markdown = """
        Paragraph
        - - -

        | Name | Result |
        | :--- | ---: |
        | Build | **Passed** |
        | Tests |
        """

        XCTAssertEqual(RemoteMarkdownDocumentParser.parse(markdown), [
            .paragraph("Paragraph"),
            .thematicBreak,
            .table(RemoteMarkdownTable(
                header: ["Name", "Result"],
                rows: [
                    ["Build", "**Passed**"],
                    ["Tests"]
                ]
            ))
        ])
    }

    func testMarkdownParserHandlesEmptyAndUnmatchedFenceInput() {
        XCTAssertEqual(RemoteMarkdownDocumentParser.parse(""), [])
        XCTAssertEqual(RemoteMarkdownDocumentParser.parse("```\nunfinished"), [
            .codeBlock(language: nil, code: "unfinished")
        ])
    }

    func testToolStateDistinguishesPendingRunningCompletedAndUnknown() {
        let queued = item(kind: .activity, role: "tool", tool: "exec", status: "pending")
        let running = item(kind: .activity, role: "tool", tool: "exec", status: "running")
        let complete = item(kind: .activity, role: "tool", tool: "exec", status: "success")
        let unknown = item(kind: .activity, role: "tool", tool: "exec", status: "unknown")
        let cancelled = item(kind: .activity, role: "tool", tool: "exec", status: "cancelled")
        XCTAssertEqual(RemoteToolActivityState(queued), .pending)
        XCTAssertEqual(RemoteToolActivityState(unknown), .unknown)
        XCTAssertEqual(RemoteToolActivityState(cancelled), .cancelled)
        XCTAssertEqual(RemoteToolActivityState.aggregate([complete, running, queued]), .running)
        XCTAssertEqual(RemoteToolActivityState.aggregate([complete]), .completed)
    }

    func testMarkdownImageRequiresHTTPSAndPreservesItsPosition() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/preview.png"))
        XCTAssertEqual(RemoteMarkdownDocumentParser.parse("""
        Above
        ![Build output](https://example.test/preview.png)
        Below
        """), [.paragraph("Above"), .image(alt: "Build output", url: url), .paragraph("Below")])
        let local = "![Local](file:///tmp/image.png)"
        XCTAssertEqual(RemoteMarkdownDocumentParser.parse(local), [.paragraph(local)])
    }

    private func item(
        kind: RemoteTranscriptItemKind,
        role: String,
        semantic: RemoteTranscriptSemanticKind? = nil,
        tool: String? = nil,
        status: String? = nil
    ) -> RemoteTranscriptItem {
        RemoteTranscriptItem(
            id: UUID(),
            turnID: UUID(),
            timestamp: Date(),
            sequenceIndex: 0,
            kind: kind,
            semanticKind: semantic,
            role: role,
            text: "Visible text",
            toolName: tool,
            toolStatus: status,
            detailAvailable: tool != nil
        )
    }
}

final class RemoteCommandActivityStateTests: XCTestCase {
    func testOverlappingCommandsRemainIndependent() {
        let firstID = UUID()
        let secondID = UUID()
        var state = RemoteCommandActivityState()

        state.begin(firstID)
        state.begin(secondID)
        state.end(firstID)
        state.record(RemoteCommandCompletion(
            commandID: firstID,
            operation: .respond,
            outcome: .failed
        ))

        XCTAssertFalse(state.inFlightIDs.contains(firstID))
        XCTAssertTrue(state.inFlightIDs.contains(secondID))
        XCTAssertEqual(state.completion(for: firstID)?.outcome, .failed)
        XCTAssertNil(state.completion(for: secondID))
    }
}

final class RemotePendingSessionRouteResolverTests: XCTestCase {
    func testPendingRouteBecomesResolvableFromLaterHistory() {
        let sessionID = UUID()
        XCTAssertNil(RemotePendingSessionRouteResolver.workspaceID(
            for: sessionID,
            provisionalRoutes: [],
            sessions: [],
            historyEntries: []
        ))

        let history = RemoteHistoryEntry(
            id: sessionID,
            workspaceID: "workspace-history",
            sessionName: "Saved chat",
            lastActivityAt: Date()
        )
        XCTAssertEqual(
            RemotePendingSessionRouteResolver.workspaceID(
                for: sessionID,
                provisionalRoutes: [],
                sessions: [],
                historyEntries: [history]
            ),
            "workspace-history"
        )
    }

    func testAcceptedProvisionalRouteWinsUntilAuthoritativeStateArrives() {
        let sessionID = UUID()
        let provisional = RemoteProvisionalSessionRoute(
            sessionID: sessionID,
            workspaceID: "workspace-provisional",
            title: "New chat",
            runState: .opening,
            createdAt: Date()
        )
        let history = RemoteHistoryEntry(
            id: sessionID,
            workspaceID: "workspace-history",
            sessionName: "Persisted later",
            lastActivityAt: Date()
        )
        XCTAssertEqual(
            RemotePendingSessionRouteResolver.workspaceID(
                for: sessionID,
                provisionalRoutes: [provisional],
                sessions: [],
                historyEntries: [history]
            ),
            "workspace-provisional"
        )
    }
}
