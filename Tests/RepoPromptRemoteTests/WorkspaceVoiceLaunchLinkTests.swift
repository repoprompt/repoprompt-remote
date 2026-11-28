import Foundation
import XCTest
@testable import RepoPromptRemote

final class WorkspaceVoiceLaunchLinkTests: XCTestCase {
    func testWidgetURLUsesTheAppsSelectedWorkspaceRoute() throws {
        let url = try XCTUnwrap(URL(string: "rpremote://voice"))
        XCTAssertEqual(WorkspaceVoiceLaunchLink.url, url)
        XCTAssertTrue(WorkspaceVoiceLaunchLink.matches(WorkspaceVoiceLaunchLink.url))
    }

    func testVoiceDoesNotClaimOtherLinksOrWorkspaceOverrides() throws {
        let invalid = [
            "rpremote://pair",
            "rpremote://voice/path",
            "rpremote://voice?workspace=\(UUID())",
            "rpremote://voice#fragment",
            "rpremote://guest@voice",
            "rpremote://voice:25",
            "https://voice"
        ]
        for value in invalid {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertFalse(WorkspaceVoiceLaunchLink.matches(url), value)
        }
    }
}
