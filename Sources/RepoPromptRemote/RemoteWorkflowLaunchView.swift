import SwiftUI
import RepoPromptRemoteProtocol

private enum RemoteWorkflowCardHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum RemoteWorkflowCatalogOrdering {
    static func ordered(_ workflows: [RemoteWorkflowDescriptor]) -> [RemoteWorkflowDescriptor] {
        guard workflows.contains(where: { $0.featuredRank != nil }) else {
            return workflows
        }
        return workflows.enumerated().sorted { lhs, rhs in
            switch (lhs.element.featuredRank, rhs.element.featuredRank) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    static func reconciledSelection(
        _ selectedWorkflowID: String?,
        in workflows: [RemoteWorkflowDescriptor]
    ) -> String? {
        guard let selectedWorkflowID else { return nil }
        return workflows.contains(where: { $0.id == selectedWorkflowID }) ? selectedWorkflowID : nil
    }
}

struct RemoteWorkflowLaunchView: View {
    @EnvironmentObject private var model: RemoteAppModel

    let workspace: RemoteWorkspaceSummary
    let onCancel: () -> Void

    @State private var selectedWorkflowID: String?
    @State private var showsAllWorkflows = false
    @State private var workflowCardHeight: CGFloat = 0

    private let workflowCardMinimumHeight: CGFloat = 112

    private var orderedWorkflows: [RemoteWorkflowDescriptor] {
        RemoteWorkflowCatalogOrdering.ordered(model.workflowCatalog)
    }

    private var featuredWorkflows: [RemoteWorkflowDescriptor] {
        orderedWorkflows.filter { $0.featuredRank != nil }
    }

    private var primaryWorkflows: [RemoteWorkflowDescriptor] {
        featuredWorkflows.isEmpty ? orderedWorkflows : featuredWorkflows
    }

    private var remainingWorkflows: [RemoteWorkflowDescriptor] {
        guard !featuredWorkflows.isEmpty else { return [] }
        return orderedWorkflows.filter { $0.featuredRank == nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("What are we building?")
                        .font(.largeTitle.bold())
                }

                if orderedWorkflows.isEmpty {
                    fallbackCard
                } else {
                    defaultWorkflowCard

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(primaryWorkflows, id: \.id) { workflow in
                            workflowCard(workflow)
                        }
                    }

                    if !remainingWorkflows.isEmpty {
                        DisclosureGroup("All workflows", isExpanded: $showsAllWorkflows) {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(remainingWorkflows, id: \.id) { workflow in
                                    workflowCard(workflow)
                                }
                            }
                            .padding(.top, 12)
                        }
                        .font(.headline)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 18)
        }
        .scrollDismissesKeyboard(.interactively)
        .remoteChatComposer(
            workspaceID: workspace.workspaceID,
            destination: .newChat(workflowID: selectedWorkflowID)
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel", action: onCancel)
            }
        }
        .onPreferenceChange(RemoteWorkflowCardHeightPreferenceKey.self) { height in
            guard height > 0, abs(workflowCardHeight - height) > 0.5 else { return }
            workflowCardHeight = height
        }
        .onChange(of: model.workflowCatalog) { _, catalog in
            selectedWorkflowID = RemoteWorkflowCatalogOrdering.reconciledSelection(
                selectedWorkflowID,
                in: catalog
            )
        }
    }

    private var fallbackCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No workflow")
                .font(.headline)
            Text("This Mac does not publish workflow details. Your prompt will be sent without a workflow.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var defaultWorkflowCard: some View {
        Button {
            selectedWorkflowID = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("No workflow")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Send your prompt without applying a workflow.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selectedWorkflowID == nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.remoteWarmOrange)
                }
            }
            .padding(14)
            .background(
                selectedWorkflowID == nil ? Color.remoteWarmOrange.opacity(0.15) : Color.secondary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        selectedWorkflowID == nil ? Color.remoteWarmOrange.opacity(0.72) : Color.secondary.opacity(0.15),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(selectedWorkflowID == nil ? "Selected" : "Not selected")
    }

    @ViewBuilder
    private func workflowCard(_ workflow: RemoteWorkflowDescriptor) -> some View {
        let accent = Color(remoteHex: workflow.accentColorHex) ?? .remoteWarmOrange
        let hasAuthoritativeVisuals = workflow.iconName != nil
            || workflow.accentColorHex != nil
            || workflow.descriptionText != nil
        Button {
            selectedWorkflowID = workflow.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: workflow.iconName ?? "sparkles")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(hasAuthoritativeVisuals ? accent : .secondary)
                    .frame(width: 42, height: 42)
                    .background(
                        (hasAuthoritativeVisuals ? accent : Color.secondary).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(workflow.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let description = workflow.descriptionText, !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Group {
                    if selectedWorkflowID == workflow.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(accent)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 20, height: 20)
            }
            .padding(14)
            .frame(
                maxWidth: .infinity,
                minHeight: max(workflowCardHeight, workflowCardMinimumHeight),
                alignment: .topLeading
            )
            .background(
                selectedWorkflowID == workflow.id ? accent.opacity(0.13) : Color.secondary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        selectedWorkflowID == workflow.id ? accent.opacity(0.65) : Color.secondary.opacity(0.15),
                        lineWidth: 1
                    )
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: RemoteWorkflowCardHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(workflow.displayName) workflow")
        .accessibilityValue(selectedWorkflowID == workflow.id ? "Selected" : "Not selected")
    }
}

extension Color {
    init?(remoteHex value: String?) {
        guard var value else { return nil }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255,
            opacity: 1
        )
    }
}
