import Foundation

enum WorkspaceVoiceLaunchLink {
    static let url = URL(string: "rpremote://voice")!

    static func matches(_ url: URL) -> Bool {
        url.scheme == Self.url.scheme && url.host == Self.url.host && url.path.isEmpty
            && url.query == nil && url.fragment == nil && url.user == nil && url.password == nil && url.port == nil
    }
}
