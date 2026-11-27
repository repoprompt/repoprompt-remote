import SwiftUI
import UIKit

enum RemoteAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "remoteAppearance"

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

struct RemoteWindowAppearance: UIViewRepresentable {
    @AppStorage(RemoteAppearance.storageKey) private var appearance = RemoteAppearance.system

    func makeUIView(context: Context) -> WindowAppearanceView {
        let view = WindowAppearanceView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: WindowAppearanceView, context: Context) {
        view.interfaceStyle = appearance.interfaceStyle
    }

    final class WindowAppearanceView: UIView {
        var interfaceStyle: UIUserInterfaceStyle = .unspecified {
            didSet { applyAppearance() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyAppearance()
        }

        private func applyAppearance() {
            // Apply at the window so an already presented sheet updates with the chat.
            guard let window, window.overrideUserInterfaceStyle != interfaceStyle else { return }
            window.overrideUserInterfaceStyle = interfaceStyle
        }
    }
}

extension View {
    func remoteInputPrompt(_ title: LocalizedStringKey, isEmpty: Bool, leadingPadding: CGFloat = 0) -> some View {
        overlay(alignment: .leading) {
            if isEmpty {
                Text(title)
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .lineLimit(1)
                    .padding(.leading, leadingPadding)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(Text(title))
    }
}

extension Color {
    static let remoteWarmOrange = Color(uiColor: .remoteAdaptive(light: 0xA1420D, dark: 0xFF9A57))
    static let remoteOrangeFill = Color(red: 1, green: 0.60, blue: 0.34)
    static let remoteFailure = Color(uiColor: .remoteAdaptive(light: 0xA82524, dark: 0xFF7776))
    static let remoteSuccess = Color(uiColor: .remoteAdaptive(light: 0x176838, dark: 0x72D997))
    static let remoteChatBackground = Color(uiColor: .systemBackground)
    static let remoteUserBubble = Color(uiColor: .remoteAdaptive(light: 0xDCEEFF, dark: 0x234761))
}

extension UIColor {
    static let remoteLink = UIColor.remoteAdaptive(light: 0x004B98, dark: 0x9BD3FF)

    fileprivate static func remoteAdaptive(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}
