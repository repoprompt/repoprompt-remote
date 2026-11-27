import ImageIO
import SwiftUI
import UIKit
import RepoPromptRemoteProtocol

private let transcriptBubbleRadius: CGFloat = 15

enum RemoteTranscriptViewportUpdate: Equatable {
    case initial
    case preserve
    case tailUpdated
    case newActivity

    static func classify(
        oldItems: [RemoteTranscriptItem],
        newItems: [RemoteTranscriptItem]
    ) -> Self {
        guard !oldItems.isEmpty else { return .initial }
        guard let oldTail = oldItems.last,
              let tailIndex = newItems.firstIndex(where: { $0.id == oldTail.id })
        else { return .preserve }

        let oldIDs = Set(oldItems.map(\.id))
        let hasAppendedItem = newItems.index(after: tailIndex) < newItems.endIndex
            && newItems[newItems.index(after: tailIndex)...].contains { !oldIDs.contains($0.id) }
        let updatedTail = newItems[tailIndex]
        if hasAppendedItem || hasNewContent(in: updatedTail, after: oldTail) {
            return .newActivity
        }
        return sameActivityContent(oldTail, updatedTail) ? .preserve : .tailUpdated
    }

    private static func hasNewContent(in item: RemoteTranscriptItem, after previous: RemoteTranscriptItem) -> Bool {
        if let text = item.text, !text.isEmpty, text != previous.text { return true }
        let previousAttachments = Set(previous.attachments?.map(\.id) ?? [])
        return item.attachments?.contains { !previousAttachments.contains($0.id) } == true
    }

    private static func sameActivityContent(
        _ lhs: RemoteTranscriptItem,
        _ rhs: RemoteTranscriptItem
    ) -> Bool {
        lhs.turnID == rhs.turnID
            && lhs.timestamp == rhs.timestamp
            && lhs.sequenceIndex == rhs.sequenceIndex
            && lhs.kind == rhs.kind
            && lhs.semanticKind == rhs.semanticKind
            && lhs.role == rhs.role
            && lhs.text == rhs.text
            && lhs.toolName == rhs.toolName
            && lhs.toolStatus == rhs.toolStatus
            && lhs.summaryOnly == rhs.summaryOnly
            && lhs.attachments?.map(\.id) == rhs.attachments?.map(\.id)
    }
}

struct RemoteTranscriptFollowState: Equatable {
    static let bottomTolerance: CGFloat = 60

    private(set) var followsLatest = true
    private(set) var showsNewActivity = false

    mutating func updatePosition(isNearBottom: Bool, duringUserScroll: Bool) {
        if isNearBottom {
            resumeFollowing()
        } else if duringUserScroll {
            followsLatest = false
        }
    }

    /// Returns whether an update should advance the viewport.
    mutating func receive(_ update: RemoteTranscriptViewportUpdate) -> Bool {
        guard update == .newActivity || update == .tailUpdated else { return false }
        if followsLatest { return true }
        if update == .newActivity { showsNewActivity = true }
        return false
    }

    mutating func resumeFollowing() {
        followsLatest = true
        showsNewActivity = false
    }
}

private struct RemoteTranscriptBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat?

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue()
    }
}

private struct RemoteTranscriptViewportBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

@available(iOS 18.0, *)
private struct RemoteTranscriptScrollMetrics: Equatable {
    let isNearBottom: Bool
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    let bottomInset: CGFloat

    init(_ geometry: ScrollGeometry) {
        contentHeight = geometry.contentSize.height
        viewportHeight = geometry.containerSize.height
        bottomInset = geometry.contentInsets.bottom
        // The visible rect spans the full scroll view, including the composer inset.
        isNearBottom = contentHeight + bottomInset - geometry.visibleRect.maxY <= RemoteTranscriptFollowState.bottomTolerance
    }
}

struct RemoteChatView: View {
    private static let transcriptBottomSpacing = RemoteChatComposer.transcriptFadeHeight + 8

    @EnvironmentObject private var model: RemoteAppModel

    let sessionID: UUID
    let workspaceID: String
    let title: String
    let initialRunState: RemoteRunState?

    @State private var expandedGroupIDs: Set<String> = []
    @State private var expandedDetailIDs: Set<UUID> = []
    @State private var visibleItemIDs: Set<UUID> = []
    @State private var didInitialScroll = false
    @State private var follow = RemoteTranscriptFollowState()
    @State private var isUserScrolling = false
    @State private var wantsFollowAfterScroll = false
    @GestureState private var isTrackingDrag = false
    @State private var prependAnchorID: UUID?
    @State private var itemCountBeforePrepend = 0
    @State private var viewportBottom: CGFloat = 0
    @State private var transcriptBottom: CGFloat?

    init(
        sessionID: UUID,
        workspaceID: String,
        title: String,
        initialRunState: RemoteRunState?
    ) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.title = title
        self.initialRunState = initialRunState
    }

    private var session: SessionRow? {
        model.sessions.first(where: { $0.id == sessionID })
    }

    private var items: [RemoteTranscriptItem] {
        model.transcriptItemsBySessionID[sessionID] ?? []
    }

    private var presentation: [RemoteTranscriptPresentationElement] {
        RemoteTranscriptPresentation.elements(from: items)
    }

    private var runState: RemoteRunState {
        session?.runState ?? initialRunState ?? .idle
    }

    private var runNoticeState: RemoteRunState? {
        guard session?.pendingInteraction == nil else { return nil }
        switch runState {
        case .opening, .working, .waitingForInput, .blocked, .cancelled:
            return runState
        case .failed:
            let latestTurn = items.last?.turnID
            return items.reversed().prefix { $0.turnID == latestTurn }
                .contains { $0.role == "error" } ? nil : .failed
        case .completed, .idle:
            return nil
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            trackScrolling(ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    olderPageControl(proxy: proxy)

                    if items.isEmpty {
                        emptyTranscript
                    } else {
                        ForEach(presentation) { element in
                            presentationView(element)
                        }
                    }

                    if let runNoticeState {
                        RemoteRunNotice(state: runNoticeState, activity: session?.latestMeaningfulActivity)
                        .id("run-notice")
                    }

                    if let session, let interaction = session.pendingInteraction {
                        RemoteInteractionCard(session: session, interaction: interaction)
                            .environmentObject(model)
                            .id("pending-interaction-\(interaction.id)")
                    }

                    Color.clear
                        .frame(height: 1)
                        .background {
                            if #unavailable(iOS 18.0) {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: RemoteTranscriptBottomPreferenceKey.self,
                                        value: geometry.frame(in: .named("transcript-scroll-space")).maxY
                                    )
                                }
                            }
                        }
                        .accessibilityHidden(true)
                        .id("transcript-bottom")
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }, proxy: proxy)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: items) { oldItems, newItems in
                handleItemsChanged(oldItems: oldItems, newItems: newItems, proxy: proxy)
            }
            .onChange(of: runNoticeState) { _, _ in
                followLatest(using: proxy)
            }
            .onChange(of: session?.pendingInteraction?.id) { _, interactionID in
                if interactionID != nil {
                    if follow.receive(.newActivity) { followLatest(using: proxy) }
                } else {
                    followLatest(using: proxy)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: Self.transcriptBottomSpacing)
                        .overlay(alignment: .topTrailing) {
                            if follow.showsNewActivity {
                                Button {
                                    follow.resumeFollowing()
                                    wantsFollowAfterScroll = false
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                                    }
                                } label: {
                                    Label("New activity", systemImage: "arrow.down")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .padding(.trailing, 14)
                            }
                        }

                    RemoteChatComposer(workspaceID: workspaceID, destination: .session(sessionID, runState))
                }
                .background {
                    if #unavailable(iOS 18.0) {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: RemoteTranscriptViewportBottomPreferenceKey.self,
                                value: geometry.frame(in: .named("transcript-scroll-space")).minY
                            )
                        }
                    }
                }
            }
            .coordinateSpace(name: "transcript-scroll-space")
            .onPreferenceChange(RemoteTranscriptViewportBottomPreferenceKey.self) { bottom in
                guard bottom > 0, abs(viewportBottom - bottom) > 0.5 else { return }
                viewportBottom = bottom
                followLatest(using: proxy)
            }
            .task(id: sessionID) {
                didInitialScroll = false
                follow.resumeFollowing()
                wantsFollowAfterScroll = false
                prependAnchorID = nil
                visibleItemIDs = []
                if !items.isEmpty {
                    didInitialScroll = true
                    await Task.yield()
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
                model.loadTranscript(for: sessionID)
            }
        }
        .background(Color.remoteChatBackground.ignoresSafeArea())
        .navigationTitle(session?.title ?? title)
    }

    @ViewBuilder
    private func trackScrolling<Content: View>(_ content: Content, proxy: ScrollViewProxy) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: RemoteTranscriptScrollMetrics.self, of: RemoteTranscriptScrollMetrics.init) { old, new in
                    if old.isNearBottom != new.isNearBottom {
                        follow.updatePosition(isNearBottom: new.isNearBottom, duringUserScroll: isUserScrolling)
                    }
                    if old.contentHeight != new.contentHeight || old.viewportHeight != new.viewportHeight || old.bottomInset != new.bottomInset {
                        followLatest(using: proxy)
                    }
                }
                .onScrollPhaseChange { previous, current, context in
                    isUserScrolling = current == .interacting || current == .decelerating
                    if previous == .interacting || previous == .decelerating {
                        follow.updatePosition(isNearBottom: RemoteTranscriptScrollMetrics(context.geometry).isNearBottom, duringUserScroll: true)
                        if !isUserScrolling, wantsFollowAfterScroll {
                            wantsFollowAfterScroll = false
                            followLatest(using: proxy)
                        }
                    }
                }
        } else {
            content
                .onPreferenceChange(RemoteTranscriptBottomPreferenceKey.self) { bottom in
                    transcriptBottom = bottom
                    updatePositionDuringDrag(isDragging: isTrackingDrag)
                }
                .simultaneousGesture(
                    DragGesture()
                        .updating($isTrackingDrag) { _, isDragging, _ in isDragging = true }
                        .onEnded { _ in updatePositionDuringDrag(isDragging: true) }
                )
        }
    }

    private func updatePositionDuringDrag(isDragging: Bool) {
        guard viewportBottom > 0 else { return }
        let nearBottom = transcriptBottom.map { $0 - viewportBottom <= RemoteTranscriptFollowState.bottomTolerance } ?? false
        follow.updatePosition(isNearBottom: nearBottom, duringUserScroll: isDragging)
    }

    private func followLatest(using proxy: ScrollViewProxy) {
        guard follow.followsLatest, !isTrackingDrag else { return }
        if isUserScrolling {
            wantsFollowAfterScroll = true
            return
        }
        DispatchQueue.main.async {
            guard follow.followsLatest, !isUserScrolling, !isTrackingDrag else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo("transcript-bottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func olderPageControl(proxy: ScrollViewProxy) -> some View {
        if model.transcriptHasMore(for: sessionID) {
            Button {
                let visibleAnchor = items.first(where: { visibleItemIDs.contains($0.id) })?.id
                prependAnchorID = visibleAnchor ?? items.first?.id
                itemCountBeforePrepend = items.count
                model.loadMoreTranscript(for: sessionID)
            } label: {
                Label("Load earlier", systemImage: "arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Keeps the current message in place while older messages are inserted above it.")
        } else if case .loading = model.transcriptTimelinesBySessionID[sessionID]?.olderPageState {
            ProgressView("Loading earlier activity…")
                .frame(maxWidth: .infinity)
        }
    }

    private var transcriptState: RemoteTranscriptPresentationState {
        let timeline = model.transcriptTimelinesBySessionID[sessionID] ?? RemoteTranscriptTimelineState()
        return timeline.presentationState(
            isConnected: model.connectionState == .connected,
            isRecovering: model.isRecovering
        )
    }

    private var emptyTranscript: some View {
        Group {
            switch transcriptState {
            case .messages:
                EmptyView()
            case .loading:
                ProgressView("Loading conversation…")
            case .waitingForMac:
                ProgressView("Waiting for Mac…")
            case .reconnect:
                ContentUnavailableView {
                    Label("Mac is offline", systemImage: "wifi.slash")
                } actions: {
                    Button("Reconnect", action: model.retryConnection)
                }
            case let .failed(message):
                ContentUnavailableView {
                    Label("Conversation unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { model.retryTranscript(for: sessionID) }
                }
            case .empty:
                ContentUnavailableView(
                    "No messages yet",
                    systemImage: "text.bubble",
                    description: Text("The conversation will appear as the Mac reports it.")
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    @ViewBuilder
    private func presentationView(_ element: RemoteTranscriptPresentationElement) -> some View {
        switch element {
        case let .narrative(item, semantic):
            RemoteNarrativeRow(sessionID: sessionID, item: item, semantic: semantic)
                .id(item.id)
                .onAppear { visibleItemIDs.insert(item.id) }
                .onDisappear { visibleItemIDs.remove(item.id) }
        case let .activityGroup(groupItems, exceptional):
            RemoteActivityGroupView(
                sessionID: sessionID,
                items: groupItems,
                exceptional: exceptional,
                isExpanded: exceptional != expandedGroupIDs.contains(element.id),
                expandedDetailIDs: $expandedDetailIDs,
                onToggleGroup: {
                    if expandedGroupIDs.contains(element.id) {
                        expandedGroupIDs.remove(element.id)
                    } else {
                        expandedGroupIDs.insert(element.id)
                    }
                },
                onToggleDetails: { item in
                    if expandedDetailIDs.contains(item.id) {
                        expandedDetailIDs.remove(item.id)
                    } else {
                        expandedDetailIDs.insert(item.id)
                        if item.detail?.diffPreview == nil {
                            model.loadTranscriptDetails(for: sessionID, itemID: item.id)
                        }
                    }
                },
                onLoadDetails: { item in model.loadTranscriptDetails(for: sessionID, itemID: item.id) }
            )
            .id(groupItems.first?.id)
            .onAppear { groupItems.forEach { visibleItemIDs.insert($0.id) } }
            .onDisappear { groupItems.forEach { visibleItemIDs.remove($0.id) } }
        }
    }

    private func handleItemsChanged(
        oldItems: [RemoteTranscriptItem],
        newItems: [RemoteTranscriptItem],
        proxy: ScrollViewProxy
    ) {
        guard !newItems.isEmpty else { return }
        if let anchor = prependAnchorID, newItems.count > itemCountBeforePrepend {
            DispatchQueue.main.async {
                proxy.scrollTo(anchor, anchor: .top)
                prependAnchorID = nil
            }
            return
        }
        if !didInitialScroll {
            didInitialScroll = true
            DispatchQueue.main.async { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
            return
        }

        let update = RemoteTranscriptViewportUpdate.classify(oldItems: oldItems, newItems: newItems)
        if follow.receive(update) { followLatest(using: proxy) }
    }
}

private struct RemoteNarrativeRow: View {
    let sessionID: UUID
    let item: RemoteTranscriptItem
    let semantic: RemoteTranscriptSemanticKind

    private var isUser: Bool { semantic == .userRequest }
    private var isSummary: Bool { semantic == .summary }
    private var isPreamble: Bool { semantic == .assistantPreamble }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 36) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
                if isUser || isSummary {
                    HStack(spacing: 6) {
                        if isSummary {
                            Image(systemName: "text.append")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.remoteWarmOrange)
                        }
                        Text(isUser ? "You" : "Conversation summary")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }

                if let text = item.text, !text.isEmpty {
                    RemoteMarkdownText(
                        markdown: text,
                        textColor: UIColor.white.withAlphaComponent(isUser ? 1 : (isPreamble ? 0.68 : 0.92))
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        isUser ? Color.remoteUserBubble : Color.remoteChatBackground,
                        in: RoundedRectangle(cornerRadius: transcriptBubbleRadius, style: .continuous)
                    )
                }

                RemoteTranscriptAttachments(sessionID: sessionID, item: item, alignment: isUser ? .trailing : .leading)
                Text(item.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !isUser { Spacer(minLength: 18) }
        }
    }
}

private struct RemoteTranscriptAttachments: View {
    let sessionID: UUID
    let item: RemoteTranscriptItem
    var alignment: Alignment = .leading

    var body: some View {
        ForEach(item.attachments ?? []) { attachment in
            if attachment.isImage {
                RemoteTranscriptPhoto(sessionID: sessionID, itemID: item.id, attachment: attachment, alignment: alignment)
            } else {
                Label(attachment.name, systemImage: "doc")
                    .padding(7)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .font(.caption)
    }
}

private struct RemoteTranscriptPhoto: View {
    @EnvironmentObject private var model: RemoteAppModel
    let sessionID: UUID
    let itemID: UUID
    let attachment: RemoteTranscriptAttachment
    let alignment: Alignment
    @State private var thumbnail: UIImage?
    @State private var failed = false
    @State private var retry = 0
    @State private var showsOriginal = false

    private let thumbnailBounds = CGSize(width: 204, height: 144)

    var body: some View {
        Group {
            if let thumbnail {
                let aspectFit = min(thumbnailBounds.width / thumbnail.size.width, thumbnailBounds.height / thumbnail.size.height)
                Button {
                    showsOriginal = true
                } label: {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .frame(width: thumbnail.size.width * aspectFit, height: thumbnail.size.height * aspectFit)
                        .clipShape(.rect(cornerRadius: transcriptBubbleRadius))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(attachment.name)
                .accessibilityHint("Opens the image")
            } else {
                Group {
                    if failed {
                        Button {
                            failed = false
                            retry += 1
                        } label: {
                            Label("Retry preview", systemImage: "arrow.clockwise")
                        }
                        .accessibilityHint(attachment.name)
                    } else {
                        ProgressView()
                            .accessibilityLabel("Loading \(attachment.name)")
                    }
                }
                .frame(width: thumbnailBounds.width, height: thumbnailBounds.height)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: transcriptBubbleRadius))
            }
        }
        .frame(height: thumbnailBounds.height, alignment: alignment)
        .task(id: LoadIdentity(connection: model.connectionState, retry: retry)) {
            await loadThumbnail()
        }
        .fullScreenCover(isPresented: $showsOriginal) {
            RemoteFullImageViewer(
                attachment: attachment, thumbnail: thumbnail,
                load: { try await model.originalImage(sessionID: sessionID, itemID: itemID, attachmentID: attachment.id) }
            )
        }
    }

    private func loadThumbnail() async {
        guard thumbnail == nil else { return }
        guard model.connectionState == .connected else { return }
        failed = false
        do {
            let data = try await model.imageThumbnail(sessionID: sessionID, itemID: itemID, attachmentID: attachment.id)
            try Task.checkCancellation()
            guard let image = UIImage(data: data) else { throw RemoteGatewayError.invalidResponse }
            thumbnail = image
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }

    private struct LoadIdentity: Equatable {
        let connection: RemoteAppModel.ConnectionState
        let retry: Int
    }
}

private struct RemoteFullImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: RemoteTranscriptAttachment
    let thumbnail: UIImage?
    let load: () async throws -> Data
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var retry = 0
    @State private var zoom: CGFloat = 1
    @GestureState private var magnification: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    Color.black.ignoresSafeArea()
                    if let image {
                        let scale = min(max(zoom * magnification, 1), 5)
                        ScrollView([.horizontal, .vertical], showsIndicators: false) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .clipShape(.rect(cornerRadius: transcriptBubbleRadius))
                                .frame(width: geometry.size.width * scale, height: geometry.size.height * scale)
                                .accessibilityLabel(attachment.name)
                        }
                        .defaultScrollAnchor(.center)
                        .simultaneousGesture(MagnifyGesture()
                            .updating($magnification) { gesture, value, _ in value = gesture.magnification }
                            .onEnded { gesture in zoom = min(max(zoom * gesture.magnification, 1), 5) })
                    } else {
                        if let thumbnail {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .scaledToFit()
                                .clipShape(.rect(cornerRadius: transcriptBubbleRadius))
                                .padding(12)
                                .accessibilityHidden(true)
                        }
                        VStack {
                            if let failure {
                                Text(failure).multilineTextAlignment(.center)
                                Button("Retry") { retry += 1 }.buttonStyle(.borderedProminent)
                            } else {
                                ProgressView("Loading full image…")
                            }
                        }
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: transcriptBubbleRadius))
                    }
                }
            }
            .navigationTitle(attachment.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: retry) {
            failure = nil
            do {
                let bytes = try await load()
                let worker = Task.detached(priority: .userInitiated) { Self.decodedImage(bytes) }
                let decoded = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let decoded else { throw RemoteGatewayError.invalidResponse }
                image = decoded
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
        }
    }

    private nonisolated static func decodedImage(_ bytes: Data) -> UIImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096
              ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: pixels)
    }
}

struct RemoteMarkdownText: View {
    let markdown: String
    var textStyle: UIFont.TextStyle = .subheadline
    var textColor: UIColor = .label
    @Environment(\.dynamicTypeSize) private var typeSize

    private enum Section {
        case prose([RemoteMarkdownBlock])
        case rich(RemoteMarkdownBlock)
    }

    private var sections: [Section] {
        var sections: [Section] = []
        var prose: [RemoteMarkdownBlock] = []
        for block in RemoteMarkdownDocumentParser.parse(markdown) {
            switch block {
            case .paragraph, .heading, .list:
                prose.append(block)
            case .blockQuote, .codeBlock, .table, .image, .thematicBreak:
                if !prose.isEmpty {
                    sections.append(.prose(prose))
                    prose.removeAll()
                }
                sections.append(.rich(block))
            }
        }
        if !prose.isEmpty { sections.append(.prose(prose)) }
        return sections
    }

    private var traits: UITraitCollection {
        UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                switch section {
                case let .prose(blocks):
                    RemoteSelectableText(content: prose(blocks))
                case let .rich(block):
                    richBlock(block)
                }
            }
        }
    }

    private func prose(_ blocks: [RemoteMarkdownBlock]) -> NSAttributedString {
        let text = NSMutableAttributedString(string: "")
        let font = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits)
        for block in blocks {
            if text.length > 0 {
                text.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
            switch block {
            case let .paragraph(content):
                appendInline(content, font: font, spacing: 10, to: text)
            case let .heading(level, content):
                let headingStyle: UIFont.TextStyle = switch level {
                case 1: .title2
                case 2: .title3
                case 3: .headline
                default: .subheadline
                }
                let heading = UIFont.preferredFont(forTextStyle: headingStyle, compatibleWith: traits)
                appendInline(
                    content, font: RemoteSelectableText.styled(heading, traits: .traitBold),
                    spacing: 10, headingLevel: level, to: text
                )
            case let .list(items):
                for (index, item) in items.enumerated() {
                    if index > 0 { text.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
                    let marker = switch item.marker {
                    case .bullet: "•"
                    case let .ordered(number): "\(number)."
                    }
                    appendInline(
                        "\(marker)\t\(item.text)", font: font,
                        spacing: index == items.count - 1 ? 10 : 5,
                        listIndent: CGFloat(item.depth) * 16, to: text
                    )
                }
            default:
                break
            }
        }
        return text
    }

    private func appendInline(
        _ markdown: String, font: UIFont, spacing: CGFloat, listIndent: CGFloat? = nil,
        headingLevel: Int? = nil, to text: NSMutableAttributedString
    ) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacing
        if let listIndent {
            style.firstLineHeadIndent = listIndent
            style.headIndent = listIndent + 22
            style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent)]
        }
        let content = NSMutableAttributedString(attributedString: RemoteSelectableText.markdown(markdown, font: font, color: textColor))
        let range = NSRange(location: 0, length: content.length)
        content.addAttribute(.paragraphStyle, value: style, range: range)
        if let headingLevel {
            content.addAttribute(.accessibilityTextHeadingLevel, value: headingLevel, range: range)
        }
        text.append(content)
    }

    private func inline(_ markdown: String, color: UIColor? = nil, bold: Bool = false, wraps: Bool = true) -> RemoteSelectableText {
        let font = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits)
        return RemoteSelectableText(
            content: RemoteSelectableText.markdown(
                markdown, font: bold ? RemoteSelectableText.styled(font, traits: .traitBold) : font,
                color: color ?? textColor
            ),
            wraps: wraps
        )
    }

    @ViewBuilder
    private func richBlock(_ block: RemoteMarkdownBlock) -> some View {
        switch block {
        case let .blockQuote(text):
            inline(text, color: .secondaryLabel)
            .padding(.leading, 9)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.remoteWarmOrange.opacity(0.65))
                    .frame(width: 3)
                    .allowsHitTesting(false)
            }
        case let .codeBlock(language, code):
            RemoteCodeBlock(language: language, code: code)
        case let .table(table):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        ForEach(Array(table.header.enumerated()), id: \.offset) { _, cell in
                            inline(cell, bold: true, wraps: false)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inline(cell, wraps: false)
                            }
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
        case let .image(alt, url):
            RemoteMarkdownImage(alt: alt, url: url)
        case .thematicBreak:
            Divider()
                .overlay(Color.white.opacity(0.16))
        default:
            EmptyView()
        }
    }
}

private struct RemoteCodeBlock: View {
    let language: String?
    let code: String
    var isDiff = false
    @State private var copied = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(language ?? "Code")
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 34, minHeight: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied" : (isDiff ? "Copy diff preview" : "Copy code"))
            }
            ScrollView(.horizontal) {
                let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
                let size = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits).pointSize
                RemoteSelectableText(
                    content: attributedCode(size: size),
                    wraps: false
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
        .onChange(of: code) { _, _ in copied = false }
    }

    private func attributedCode(size: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(string: code, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: UIColor.label
        ])
        guard isDiff else { return result }
        var location = 0
        var isInHunk = false
        for line in code.components(separatedBy: "\n") {
            let length = line.utf16.count
            let range = NSRange(location: location, length: length)
            if line.hasPrefix("diff --git ") { isInHunk = false }
            if line.hasPrefix("@@") {
                isInHunk = true
                result.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: range)
            } else if isInHunk, line.hasPrefix("+") || line.hasPrefix("-") {
                let color: UIColor = line.hasPrefix("+") ? .systemGreen : .systemRed
                result.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.17), range: range)
            } else if !isInHunk || line.hasPrefix("\\ No newline") {
                result.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
            }
            location += length + 1
        }
        return result
    }
}

private struct RemoteMarkdownImage: View {
    let alt: String
    let url: URL
    @State private var loadImage = false

    private var label: String { alt.isEmpty ? "Image" : alt }

    var body: some View {
        if loadImage {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFit()
                        .clipShape(.rect(cornerRadius: transcriptBubbleRadius))
                        .accessibilityLabel(label)
                case .failure:
                    Label("Image unavailable", systemImage: "photo").accessibilityHint(label)
                default:
                    ProgressView(label)
                }
            }
            .frame(maxHeight: 320)
        } else {
            Button { loadImage = true } label: {
                Label(label, systemImage: "photo")
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Loads the image from its source")
        }
    }
}

/// A read-only text view gives the transcript iOS selection handles and the native editing menu.
struct RemoteSelectableText: UIViewRepresentable {
    let content: NSAttributedString
    var wraps = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.linkTextAttributes = [.foregroundColor: UIColor.link, .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let paragraphTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectParagraph(_:)))
        paragraphTap.numberOfTapsRequired = 3
        paragraphTap.delegate = context.coordinator
        view.addGestureRecognizer(paragraphTap)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard view.attributedText != content else { return }
        let range = view.selectedRange
        let previous = view.attributedText?.string as NSString?
        let next = content.string as NSString
        view.attributedText = content
        if range.length > 0, let previous, NSMaxRange(range) <= previous.length, NSMaxRange(range) <= next.length,
           previous.substring(with: range) == next.substring(with: range) {
            view.selectedRange = range
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        if content.length == 0 { return .zero }
        let proposedWidth = proposal.width
        let widthLimit = wraps ? (proposedWidth ?? .greatestFiniteMagnitude) : .greatestFiniteMagnitude
        let bounds = content.boundingRect(
            with: CGSize(width: widthLimit, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let width = max(1, min(widthLimit, ceil(bounds.width) + 1))
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let otherTap = otherGestureRecognizer as? UITapGestureRecognizer else { return false }
            return otherTap.view === gestureRecognizer.view && otherTap.numberOfTapsRequired == 2
        }

        @objc func selectParagraph(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? UITextView else { return }
            let point = gesture.location(in: view)
            guard let position = view.closestPosition(to: point),
                  let range = RemoteSelectableText.paragraphRange(
                      in: view.text, at: view.offset(from: view.beginningOfDocument, to: position)
                  )
            else { return }

            if !view.isFirstResponder { view.becomeFirstResponder() }
            view.selectedRange = range
            if let menu = view.interactions.first(where: { $0 is UIEditMenuInteraction }) as? UIEditMenuInteraction {
                menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
            }
        }
    }

    static func paragraphRange(in text: String, at offset: Int) -> NSRange? {
        let text = text as NSString
        guard offset >= 0, offset <= text.length, text.length > 0 else { return nil }
        var start = 0
        var contentEnd = 0
        text.getParagraphStart(&start, end: nil, contentsEnd: &contentEnd, for: NSRange(location: offset, length: 0))
        guard contentEnd > start else { return nil }
        return NSRange(location: start, length: contentEnd - start)
    }

    static func markdown(_ markdown: String, font: UIFont, color: UIColor) -> NSAttributedString {
        let attributed = (try? AttributedString(markdown: markdown, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        ))) ?? AttributedString(markdown)
        let result = NSMutableAttributedString(string: "")
        for run in attributed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var traits: UIFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            let base = intent.contains(.code) ? UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) : font
            var attributes: [NSAttributedString.Key: Any] = [.font: styled(base, traits: traits), .foregroundColor: color]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(attributed[run.range].characters), attributes: attributes))
        }
        return result
    }

    static func styled(_ font: UIFont, traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let combined = font.fontDescriptor.symbolicTraits.union(traits)
        guard !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(combined) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }
}

private struct RemoteRunNotice: View {
    let state: RemoteRunState
    let activity: String?

    private var isWorking: Bool { state == .opening || state == .working }

    private var title: String {
        switch state {
        case .opening: "Starting…"
        case .working: "Thinking…"
        case .waitingForInput: "Waiting for input"
        case .blocked: "Run blocked"
        case .failed: "Run failed"
        default: "Run cancelled"
        }
    }

    private var noticeIcon: String {
        switch state {
        case .waitingForInput: "clock"
        case .cancelled: "stop.circle"
        default: "exclamationmark.circle"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if isWorking {
                ProgressView().controlSize(.small).tint(Color.remoteWarmOrange)
            } else {
                Image(systemName: noticeIcon)
            }
            // The desktop's latest activity already contains the useful status while running.
            Text((isWorking || state == .waitingForInput) ? activity ?? title : title)
        }
        .font(.footnote)
        .foregroundStyle(state == .failed ? Color.red : .secondary)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
    }
}

private struct RemoteActivityGroupView: View {
    let sessionID: UUID
    let items: [RemoteTranscriptItem]
    let exceptional: Bool
    let isExpanded: Bool
    @Binding var expandedDetailIDs: Set<UUID>
    let onToggleGroup: () -> Void
    let onToggleDetails: (RemoteTranscriptItem) -> Void
    let onLoadDetails: (RemoteTranscriptItem) -> Void

    private var toolNames: [String] {
        Array(Set(items.compactMap(\.toolName))).sorted()
    }

    private var isRecordedQuestion: Bool {
        items.count == 1 && RemoteTranscriptPresentation.isAskUserTool(items.first?.toolName)
    }

    private var diffSummary: RemoteTranscriptDiffSummary? {
        items.count == 1 ? items.first?.diffSummary : nil
    }

    private var accent: Color {
        if isRecordedQuestion, aggregateStatus != .failed { return .remoteWarmOrange }
        return exceptional ? .red : .secondary
    }

    private var singleTool: RemoteTranscriptItem? {
        guard items.count == 1, let first = items.first,
              isRecordedQuestion || diffSummary != nil || RemoteToolCardKind(first.toolName) != nil
        else { return nil }
        return first
    }

    private var singleToolKind: RemoteToolCardKind? { RemoteToolCardKind(singleTool?.toolName) }

    private var expanded: Bool {
        singleTool.map { expandedDetailIDs.contains($0.id) } ?? isExpanded
    }

    private var aggregateStatus: RemoteToolActivityState? {
        RemoteToolActivityState.aggregate(items)
    }

    private var title: String {
        if isRecordedQuestion { return "Question" }
        if let singleToolKind { return singleToolKind.title }
        if diffSummary != nil { return "Git diff" }
        if exceptional {
            let semantic = items.first.map(RemoteTranscriptPresentation.semanticKind(for:))
            switch semantic {
            case .permission?: return "Permission required"
            case .question?: return "Question"
            case .approval?: return "Approval required"
            default: return "Activity needs attention"
            }
        }
        if items.count == 1, let toolName = items.first?.toolName { return toolName }
        let count = items.filter { $0.toolName != nil }.count
        if count == items.count { return "\(count) tool calls" }
        return "\(items.count) activities"
    }

    private var icon: String {
        if isRecordedQuestion { return "questionmark.circle.fill" }
        if let singleToolKind { return singleToolKind.icon }
        if diffSummary != nil { return "arrow.left.arrow.right" }
        return exceptional ? "exclamationmark.triangle.fill" : "wrench.and.screwdriver"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if let singleTool { onToggleDetails(singleTool) }
                else { onToggleGroup() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accent)
                        .frame(width: 28, height: 28)
                        .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.footnote.weight(.semibold))
                        if isRecordedQuestion, let singleTool {
                            let preview = RemoteTranscriptPresentation.recordedQuestionPreview(for: singleTool)
                            if let preview {
                                Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            } else if aggregateStatus == .completed {
                                Text("No recorded answer").font(.caption).foregroundStyle(.secondary)
                            }
                        } else if let diffSummary {
                            Text(RemoteTranscriptPresentation.diffSummaryText(diffSummary))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        } else if let singleTool, let singleToolKind {
                            if let summary = singleToolKind.summary(for: singleTool), !summary.isEmpty {
                                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        } else if !toolNames.isEmpty, toolNames != [title] {
                            Text(toolNames.prefix(3).joined(separator: " · "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if let text = items.first?.text, !text.isEmpty {
                            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        if let aggregateStatus, !isRecordedQuestion || aggregateStatus == .failed {
                            Text(aggregateStatus.label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(aggregateStatus.tint)
                        }
                        if singleTool.map(\.canExpandToolDetails) ?? true {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
            }
            .buttonStyle(.plain)
            .disabled(singleTool.map { !$0.canExpandToolDetails } ?? false)

            if let singleTool {
                if expanded {
                    RemoteActivityDetailsView(item: singleTool, onLoadDetails: { onLoadDetails(singleTool) })
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
                RemoteTranscriptAttachments(sessionID: sessionID, item: singleTool)
            } else if expanded {
                VStack(spacing: 8) {
                    ForEach(items) { item in
                        RemoteActivityItemView(
                            sessionID: sessionID,
                            item: item,
                            isExpanded: expandedDetailIDs.contains(item.id),
                            onToggleDetails: { onToggleDetails(item) },
                            onLoadDetails: { onLoadDetails(item) }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background(accent.opacity(exceptional ? 0.075 : 0.045), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(exceptional ? 0.28 : 0.12), lineWidth: 1)
        }
    }

}

private extension RemoteTranscriptItem {
    var canExpandToolDetails: Bool {
        detailAvailable || detail != nil || detailText?.isEmpty == false
    }
}

private struct RemoteActivityItemView: View {
    let sessionID: UUID
    let item: RemoteTranscriptItem
    let isExpanded: Bool
    let onToggleDetails: () -> Void
    let onLoadDetails: () -> Void

    private var state: RemoteToolActivityState? { RemoteToolActivityState(item) }
    private var kind: RemoteToolCardKind? { RemoteToolCardKind(item.toolName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                if let state {
                    Image(systemName: state.icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(state.tint)
                        .accessibilityLabel(state.label)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind?.title ?? item.toolName ?? item.role.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption.weight(.semibold))
                    if let kind, let summary = kind.summary(for: item) {
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    } else if kind == nil, let text = item.text, !text.isEmpty {
                        RemoteMarkdownText(markdown: text, textStyle: .caption1, textColor: .secondaryLabel)
                    }
                }
                Spacer()
                if item.canExpandToolDetails {
                    Button(action: onToggleDetails) {
                        Image(systemName: isExpanded ? "eye.slash" : "info.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Hide tool details" : "Show tool details")
                }
            }
            RemoteTranscriptAttachments(sessionID: sessionID, item: item)
            if isExpanded {
                RemoteActivityDetailsView(item: item, onLoadDetails: onLoadDetails)
            }
        }
        .padding(9)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct RemoteActivityDetailsView: View {
    @EnvironmentObject private var model: RemoteAppModel
    let item: RemoteTranscriptItem
    let onLoadDetails: () -> Void

    var body: some View {
        if let exchange = item.detail?.questionExchange {
            RemoteRecordedQuestionDetails(exchange: exchange)
        } else if let detail = item.detail, let preview = detail.diffPreview {
            RemoteToolDiffPreviewView(preview: preview, detail: detail)
        } else if RemoteTranscriptPresentation.isAskUserTool(item.toolName),
                  RemoteToolActivityState(item) == .completed,
                  item.detail != nil || item.detailText != nil
        {
            Text("Question and answer details are unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let detail = item.detail {
            RemoteToolDetails(detail: detail, kind: RemoteToolCardKind(item.toolName),
                              showsSummary: item.text == nil, summaryOnly: item.summaryOnly)
        } else if let text = item.detailText, !text.isEmpty {
            RemoteCodeBlock(language: nil, code: text)
        } else {
            switch model.transcriptDetailStates[item.id] {
            case .failed?:
                Button("Retry loading details", action: onLoadDetails).font(.caption)
            case .loaded?:
                Text("No additional details").font(.caption).foregroundStyle(.secondary)
            default:
                ProgressView("Loading details…").font(.caption)
            }
        }
    }
}

private struct RemoteToolDiffPreviewView: View {
    let preview: RemoteTranscriptDiffPreview
    let detail: RemoteTranscriptDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if preview.isTruncated {
                Label("Partial diff preview", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            if !preview.files.contains(where: { $0.patch != nil }) {
                Text("No patch preview available.").foregroundStyle(.secondary)
            }
            ForEach(preview.files.indices, id: \.self) { index in
                let file = preview.files[index]
                if let patch = file.patch {
                    RemoteCodeBlock(language: file.path, code: patch, isDiff: true)
                } else {
                    LabeledContent(file.path) {
                        if let additions = file.additions, let deletions = file.deletions {
                            Text("+\(additions) −\(deletions)").monospacedDigit()
                        }
                    }
                }
            }
            if detail.resultJSON != nil {
                DisclosureGroup("Raw result") {
                    RemoteToolDetails(detail: detail, kind: nil, showsSummary: false, summaryOnly: false)
                }
            }
        }
        .font(.caption)
    }
}

private struct RemoteRecordedQuestionDetails: View {
    let exchange: RemoteRecordedQuestionExchange

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = exchange.title {
                Text(title).font(.subheadline.weight(.semibold))
            }
            ForEach(exchange.questions.indices, id: \.self) { index in
                let question = exchange.questions[index]
                VStack(alignment: .leading, spacing: 5) {
                    Text(exchange.questions.count == 1 ? "Question" : "Question \(index + 1)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    RemoteMarkdownText(markdown: question.prompt, textStyle: .footnote)
                    Text("Answer")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(verbatim: answer(for: question))
                        .font(.footnote)
                        .foregroundStyle(question.answer == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answer(for question: RemoteRecordedQuestionExchange.Question) -> String {
        if question.skipped { return "Skipped" }
        if let answer = question.answer { return answer }
        return exchange.outcome == .timedOut ? "Timed out" : "No answer recorded"
    }
}

private extension RemoteToolActivityState {
    var tint: Color {
        switch self {
        case .running, .warning: .orange
        case .completed: .green
        case .failed: .red
        case .pending, .cancelled, .unknown: .secondary
        }
    }

    var icon: String {
        switch self {
        case .running: "arrow.clockwise"
        case .pending: "clock"
        case .completed: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .failed: "xmark.circle"
        case .cancelled: "stop.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

private struct RemoteToolDetails: View {
    let detail: RemoteTranscriptDetail
    let kind: RemoteToolCardKind?
    let showsSummary: Bool
    let summaryOnly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsSummary, let summary = detail.summaryText {
                RemoteMarkdownText(markdown: summary, textStyle: .caption1)
            }
            if let kind, let presentation = RemoteToolDetailPresentation(kind: kind, detail: detail, summaryOnly: summaryOnly) {
                if !presentation.metadata.isEmpty || presentation.isPartial {
                    let metadata = presentation.metadata + (presentation.isPartial ? ["Partial result"] : [])
                    Text(metadata.joined(separator: " · ")).foregroundStyle(.secondary)
                }
                ForEach(presentation.sections.indices, id: \.self) { index in
                    let section = presentation.sections[index]
                    RemoteCodeBlock(language: section.title, code: section.text, isDiff: section.isDiff)
                }
                if let exitCode = presentation.exitCode {
                    LabeledContent("Exit code", value: String(exitCode))
                }
            } else {
                payload("Arguments", detail.argumentsJSON)
                payload("Result", detail.resultJSON)
                if !detail.keyPaths.isEmpty {
                    RemoteCodeBlock(language: "Files", code: detail.keyPaths.joined(separator: "\n"))
                }
                if let exitCode = detail.exitCode { LabeledContent("Exit code", value: String(exitCode)) }
            }
            if let processID = detail.processID { LabeledContent("Process", value: processID) }
            if let thinking = detail.reasoning, !thinking.isEmpty {
                Text("Reasoning").font(.caption.weight(.semibold))
                RemoteMarkdownText(markdown: thinking, textStyle: .caption1)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private func payload(_ title: String, _ raw: String?) -> some View {
        if let raw, !raw.isEmpty {
            let value = RemoteTranscriptPresentation.formattedToolPayload(raw)
            RemoteCodeBlock(language: title, code: value)
        }
    }
}

extension View {
    func remoteChatComposer(workspaceID: String, destination: RemoteChatComposer.Destination) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            RemoteChatComposer(workspaceID: workspaceID, destination: destination)
        }
    }
}

struct RemoteChatComposer: View {
    fileprivate static let buttonHeight: CGFloat = 33
    fileprivate static let transcriptFadeHeight: CGFloat = 22

    enum Destination {
        case newChat(workflowID: String?, interviewFirst: Bool)
        case session(UUID, RemoteRunState)
    }

    @EnvironmentObject private var model: RemoteAppModel
    let workspaceID: String
    let destination: Destination

    @FocusState private var isInputFocused: Bool
    @State private var message = ""
    @StateObject private var attachments = RemoteAttachmentDraft()
    @State private var pendingSend: (id: UUID, draft: String)?
    @State private var pendingCancelID: UUID?
    @State private var pendingConfigurationID: UUID?
    @State private var draftSelection: RemoteAgentSelection?

    private var pendingCommandID: UUID? { pendingSend?.id }

    private var sessionID: UUID? {
        guard case let .session(id, _) = destination else { return nil }
        return id
    }

    private var session: SessionRow? {
        guard let sessionID else { return nil }
        return model.sessions.first { $0.id == sessionID }
    }

    private var policy: RemoteComposerPolicy {
        switch destination {
        case .newChat: .newChat
        case let .session(_, runState): .resolve(runState: runState, pendingInteraction: session?.pendingInteraction)
        }
    }

    private var canSend: Bool {
        let hasText = !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return model.canControlChat && policy.primaryOperation != nil
            && (hasText || !attachments.files.isEmpty)
            && (attachments.files.isEmpty || (policy.canAttach && model.canSendAttachments))
            && !attachments.isLoading
            && pendingCommandID == nil
            && pendingConfigurationID == nil
    }

    private var savedConfiguration: RemoteChatConfiguration? {
        sessionID.flatMap { model.transcriptTimelinesBySessionID[$0]?.chatConfiguration }
    }

    private var configurationControls: RemoteSessionConfigurationControls? {
        guard model.agentCatalogMetadata?.supportsSessionConfiguration == true else { return nil }
        if let controls = session?.configurationControls { return controls }
        guard let savedConfiguration,
              savedConfiguration.selection.agentID == selection?.agentID,
              savedConfiguration.selection.modelID == selection?.modelID
        else { return nil }
        return savedConfiguration.controls
    }

    private var selection: RemoteAgentSelection? {
        if let sessionID {
            if let override = model.selectionOverridesBySessionID[sessionID] { return override }
            if let session, let agent = session.agent, let model = session.model {
                return RemoteAgentSelection(agentID: agent, modelID: model, reasoningEffort: session.reasoningEffort)
            }
            return savedConfiguration?.selection
        }
        return RemoteLaunchSelection.resolve(
            draft: draftSelection,
            desktopDefault: model.agentCatalogMetadata?.defaultSelection,
            agents: model.agentCatalog
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if policy.isInteractionBlocking {
                Label("Respond to the request above", systemImage: "arrow.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if !attachments.files.isEmpty {
                RemoteAttachmentDraftStrip(draft: attachments, isSending: pendingCommandID != nil)
            }

            TextField("Send a Message...", text: $message, axis: .vertical)
                .lineLimit(1...7)
                .textFieldStyle(.plain)
                .font(.body)
                .multilineTextAlignment(.leading)
                .focused($isInputFocused)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .submitLabel(.send)
                .onSubmit(send)
                .disabled(!model.canControlChat || policy.primaryOperation == nil)

            HStack(spacing: 5) {
                RemoteAttachmentPicker(
                    draft: attachments,
                    buttonHeight: Self.buttonHeight,
                    isEnabled: policy.canAttach && model.canSendAttachments && pendingCommandID == nil,
                    onError: model.presentError
                )

                selectionBar

                Spacer(minLength: 0)

                if let sessionID, policy.canCancel && model.canControlChat {
                    Button {
                        guard pendingCancelID == nil else { return }
                        pendingCancelID = model.cancel(sessionID: sessionID, workspaceID: workspaceID)
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.red)
                            .frame(width: 30, height: Self.buttonHeight)
                    }
                    .buttonStyle(.plain)
                    .disabled(pendingCancelID != nil)
                    .accessibilityLabel("Cancel run")
                }

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(canSend ? Color.black : Color.secondary)
                        .frame(width: Self.buttonHeight, height: Self.buttonHeight)
                        .background(canSend ? Color.remoteWarmOrange : Color.primary.opacity(0.09), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel(policy.canCancel ? policy.primaryLabel : "Send")
            }
        }
        .padding(EdgeInsets(top: 14, leading: 10, bottom: 10, trailing: 10))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15).strokeBorder(.quaternary, lineWidth: 1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background {
            if sessionID != nil {
                Rectangle()
                    .fill(.regularMaterial)
                    .overlay(alignment: .bottom) {
                        Color.remoteChatBackground.opacity(0.45)
                    }
                    .mask {
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.70)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .padding(.top, -Self.transcriptFadeHeight)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .allowsHitTesting(false)
            } else {
                Color.remoteChatBackground.ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .onChange(of: model.commandActivity) { _, activity in
            if let pendingSend, let completion = activity.completion(for: pendingSend.id) {
                self.pendingSend = nil
                if completion.outcome == .accepted {
                    if message == pendingSend.draft { message = "" }
                    attachments.clear()
                }
            }
            if activity.completion(for: pendingCancelID) != nil { pendingCancelID = nil }
            if activity.completion(for: pendingConfigurationID) != nil { pendingConfigurationID = nil }
        }
    }

    private var selectionBar: some View {
        let controls = configurationControls
        let selection = self.selection
        let supported = sessionID == nil && model.agentCatalogMetadata?.supportsStartSelection == true
        let locksSession = sessionID != nil && policy.canCancel
        let isPending = pendingCommandID != nil || pendingConfigurationID != nil
        let toolCatalog = model.agentCatalogMetadata?.toolCatalog
        return RemoteAgentSelectionBar(
            agents: model.agentCatalog,
            selectedAgentID: selection?.agentID,
            selectedModelID: selection?.modelID,
            selectedReasoningEffortID: selection?.reasoningEffort,
            allowedAgentIDs: controls.map { Set($0.agent.allowedValueIDs) },
            allowedModelIDs: controls.map { Set($0.model.allowedValueIDs) },
            allowedReasoningEffortIDs: controls.map { Set($0.reasoningEffort.allowedValueIDs) },
            allowsAgentSwitch: supported || controls?.agent.isMutable == true,
            isModelMutable: model.canControlChat && !locksSession && (controls?.model.isMutable ?? supported),
            isEffortMutable: model.canControlChat && !locksSession && (controls?.reasoningEffort.isMutable ?? supported),
            isPending: isPending,
            toolCatalog: toolCatalog?.providerID == selection?.agentID ? toolCatalog : nil,
            canEditTools: model.canControlChat,
            onSelectModel: configureModel,
            onSelectReasoningEffort: configureReasoningEffort,
            onToggleTool: { setting, revision in
                guard model.canControlChat, pendingConfigurationID == nil, pendingCommandID == nil else { return }
                pendingConfigurationID = model.configureTool(
                    workspaceID: workspaceID,
                    sessionID: sessionID,
                    settingID: setting.id,
                    enabled: !setting.isEnabled,
                    expectedRevision: revision
                )
            }
        )
    }

    private func send() {
        guard canSend else { return }
        let draft = message
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isInputFocused = false
        let commandID: UUID
        switch destination {
        case let .newChat(workflowID, interviewFirst):
            let selection = model.agentCatalogMetadata?.supportsStartSelection == true ? self.selection : nil
            commandID = model.startRun(
                in: workspaceID,
                message: trimmed,
                workflowID: workflowID,
                agentID: selection?.agentID,
                modelID: selection?.modelID,
                reasoningEffort: selection?.reasoningEffort,
                interviewFirst: interviewFirst,
                attachments: attachments.files
            )
        case let .session(sessionID, runState):
            commandID = model.continueChat(
                sessionID: sessionID,
                workspaceID: workspaceID,
                message: trimmed,
                runState: runState,
                attachments: attachments.files
            )
        }
        pendingSend = (commandID, draft)
    }

    private func configureModel(agentID: String, modelID: String) {
        guard model.canControlChat, pendingConfigurationID == nil, pendingCommandID == nil else { return }
        if let sessionID {
            pendingConfigurationID = model.configureSession(
                sessionID: sessionID,
                workspaceID: workspaceID,
                agentID: agentID,
                modelID: modelID
            )
        } else {
            draftSelection = RemoteAgentSelection(agentID: agentID, modelID: modelID, reasoningEffort: nil)
        }
    }

    private func configureReasoningEffort(_ reasoningEffortID: String) {
        guard model.canControlChat, pendingConfigurationID == nil, pendingCommandID == nil else { return }
        if let sessionID {
            pendingConfigurationID = model.configureSession(
                sessionID: sessionID,
                workspaceID: workspaceID,
                reasoningEffort: reasoningEffortID
            )
        } else if let selection {
            draftSelection = RemoteAgentSelection(
                agentID: selection.agentID,
                modelID: selection.modelID,
                reasoningEffort: reasoningEffortID
            )
        }
    }
}

private struct RemoteAgentSelectionBar: View {
    let agents: [RemoteAgentDescriptor]
    let selectedAgentID: String?
    let selectedModelID: String?
    let selectedReasoningEffortID: String?
    let allowedAgentIDs: Set<String>?
    let allowedModelIDs: Set<String>?
    let allowedReasoningEffortIDs: Set<String>?
    let allowsAgentSwitch: Bool
    let isModelMutable: Bool
    let isEffortMutable: Bool
    let isPending: Bool
    let toolCatalog: RemoteToolCatalog?
    let canEditTools: Bool
    let onSelectModel: (_ agentID: String, _ modelID: String) -> Void
    let onSelectReasoningEffort: (_ reasoningEffortID: String) -> Void
    let onToggleTool: (_ setting: RemoteToolSettingDescriptor, _ revision: Int) -> Void

    @State private var showsModelPicker = false
    private var selectedModel: RemoteModelDescriptor? {
        agents.first(where: { $0.id == selectedAgentID })?.modelDescriptors?.first(where: { $0.id == selectedModelID })
    }

    private var hasSelectableModel: Bool {
        agents.contains { agent in
            agent.isAvailable && agent.modelDescriptors?.contains {
                $0.isAvailable && canSelectModel($0.id, for: agent.id)
            } == true
        }
    }

    private var effortOptions: [RemoteReasoningEffortDescriptor] {
        selectedModel?.reasoningEfforts ?? []
    }

    private func canSelectModel(_ modelID: String, for agentID: String) -> Bool {
        isModelMutable && !isPending
            && (allowsAgentSwitch || agentID == selectedAgentID)
            && (allowedAgentIDs?.contains(agentID) ?? true)
            && (agentID != selectedAgentID || (allowedModelIDs?.contains(modelID) ?? true))
    }

    private func canSelectEffort(_ effortID: String) -> Bool {
        isEffortMutable && !isPending && (allowedReasoningEffortIDs?.contains(effortID) ?? true)
    }

    var body: some View {
        HStack(spacing: 4) {
            modelPickerButton
            reasoningMenu.layoutPriority(1)
            RemoteToolsButton(catalog: toolCatalog, isPending: isPending, canEdit: canEditTools, onToggle: onToggleTool)
                .layoutPriority(1)
        }
        .accessibilityElement(children: .contain)
    }

    private var modelPickerButton: some View {
        Button {
            showsModelPicker = true
        } label: {
            RemoteComposerControlLabel(title: modelLabel)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model")
        .accessibilityValue(modelLabel)
        .disabled(!hasSelectableModel)
        .sheet(isPresented: $showsModelPicker) {
            modelPicker
        }
    }

    private var modelPicker: some View {
        NavigationStack {
            List {
                ForEach(agents.filter(\.isAvailable), id: \.id) { agent in
                    Section(agent.displayName) {
                        ForEach((agent.modelDescriptors ?? []).filter(\.isAvailable), id: \.id) { candidate in
                            modelPickerRow(candidate, for: agent.id)
                        }
                    }
                }
            }
            .navigationTitle("Model")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showsModelPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func modelPickerRow(_ candidate: RemoteModelDescriptor, for agentID: String) -> some View {
        Button {
            onSelectModel(agentID, candidate.id)
            showsModelPicker = false
        } label: {
            HStack {
                Text(RemoteLaunchSelection.modelLabel(candidate.displayName))
                Spacer()
                if agentID == selectedAgentID, candidate.id == selectedModelID {
                    Image(systemName: "checkmark")
                }
            }
        }
        .disabled(!canSelectModel(candidate.id, for: agentID))
    }

    private var reasoningMenu: some View {
        Menu {
            ForEach(effortOptions, id: \.id) { effort in
                Button {
                    onSelectReasoningEffort(effort.id)
                } label: {
                    HStack {
                        Text(effort.displayName)
                        if effort.id == selectedReasoningEffortID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(!canSelectEffort(effort.id))
            }
        } label: {
            RemoteComposerControlLabel(title: effortLabel)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reasoning level")
        .accessibilityValue(effortLabel)
        .disabled(!effortOptions.contains { canSelectEffort($0.id) })
    }

    private var modelLabel: String {
        RemoteLaunchSelection.modelLabel(selectedModel?.displayName ?? selectedModelID ?? "Model")
    }

    private var effortLabel: String {
        effortOptions.first(where: { $0.id == selectedReasoningEffortID })?.displayName
            ?? selectedReasoningEffortID?.capitalized
            ?? "Reasoning"
    }
}

private struct RemoteToolsButton: View {
    let catalog: RemoteToolCatalog?
    let isPending: Bool
    let canEdit: Bool
    let onToggle: (RemoteToolSettingDescriptor, Int) -> Void
    @State private var presentedCatalog: RemoteToolCatalog?

    var body: some View {
        Button {
            presentedCatalog = catalog
        } label: {
            RemoteComposerControlLabel(title: "Tools")
        }
        .buttonStyle(.plain)
        .disabled(isPending || catalog == nil)
        .sheet(isPresented: Binding(
            get: { presentedCatalog != nil },
            set: { if !$0 { presentedCatalog = nil } }
        )) {
            if let snapshot = presentedCatalog {
                NavigationStack {
                    Form {
                        ForEach(["tools", "mcp_servers"], id: \.self) { category in
                            let settings = snapshot.settings.filter { $0.category == category }
                            if !settings.isEmpty {
                                Section(category == "tools" ? "Tools" : "MCP Servers") {
                                    ForEach(settings) { setting in
                                        Toggle(setting.displayName, isOn: Binding(
                                            get: { setting.isEnabled },
                                            set: { enabled in
                                                onToggle(setting, snapshot.revision)
                                                presentedCatalog = nil
                                            }
                                        ))
                                        .disabled(!canEdit || !snapshot.isMutable || !setting.isMutable || setting.isRequired)
                                    }
                                }
                            }
                        }
                        if let reason = snapshot.unavailableReason {
                            Text(reason).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle("Codex Tools")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { presentedCatalog = nil }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }
}

private struct RemoteComposerControlLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .lineLimit(1)
                .foregroundStyle(Color.primary)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.remoteWarmOrange)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 7)
        .frame(minHeight: RemoteChatComposer.buttonHeight)
        .contentShape(Rectangle())
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        }
    }
}
