import SwiftUI
import WidgetKit

@main
struct StartVoiceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RepoPromptRemote.StartVoice", provider: StartVoiceTimelineProvider()) { _ in
            StartVoiceWidgetView()
                .widgetURL(WorkspaceVoiceLaunchLink.url)
                .containerBackground(for: .widget) {
                    Color(red: 0.12, green: 0.12, blue: 0.11)
                }
        }
        .configurationDisplayName("Start Voice")
        .description("Talk to any chat in your selected RepoPrompt workspace.")
        .supportedFamilies([.systemSmall])
    }
}

private struct StartVoiceEntry: TimelineEntry {
    let date: Date
}

private struct StartVoiceTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> StartVoiceEntry {
        .init(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (StartVoiceEntry) -> Void) {
        completion(.init(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StartVoiceEntry>) -> Void) {
        completion(Timeline(entries: [StartVoiceEntry(date: .now)], policy: .never))
    }
}

private struct StartVoiceWidgetView: View {
    private let orange = Color(red: 0.91, green: 0.38, blue: 0.13)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(orange)
                .frame(width: 36, height: 36)
                .background(orange.opacity(0.17), in: Circle())
                .widgetAccentable()
                .accessibilityHidden(true)

            Spacer(minLength: 0)

            Text("Start Voice")
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Label("Selected workspace", systemImage: "folder")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}
