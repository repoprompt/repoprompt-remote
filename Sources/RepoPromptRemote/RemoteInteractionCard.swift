import SwiftUI
import RepoPromptRemoteProtocol

struct RemoteInteractionCard: View {
    @EnvironmentObject private var model: RemoteAppModel

    let session: SessionRow
    let interaction: RemoteInteractionSummary

    @State private var response = ""
    @State private var pendingCommandID: UUID?
    @State private var awaitingRefresh = false

    private var isApproval: Bool { interaction.kind == .approval }
    private var isSecure: Bool {
        interaction.requiresSecureEntry || interaction.kind == .secretInput
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                interaction.title ?? (isApproval ? "Approval required" : "Your response is needed"),
                systemImage: isApproval ? "hand.raised.fill" : (isSecure ? "lock.fill" : "questionmark.circle.fill")
            )
            .font(.headline)
            .foregroundStyle(Color.remoteWarmOrange)

            if interaction.questionnaire == nil, let prompt = interaction.prompt, !prompt.isEmpty {
                RemoteMarkdownText(markdown: prompt)
            }

            if let reason = interaction.responseUnavailableReason {
                Label(reason, systemImage: "desktopcomputer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if isApproval {
                HStack {
                    Button("Decline", role: .destructive) { submit(decision: "decline") }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Approve") { submit(decision: "approve") }
                        .buttonStyle(.borderedProminent)
                }
            } else if let questionnaire = interaction.questionnaire, !questionnaire.questions.isEmpty {
                RemoteQuestionnaireView(questionnaire: questionnaire, onSubmit: submitAnswers)
            } else {
                Group {
                    if isSecure {
                        SecureField("Secure response", text: $response)
                            .privacySensitive()
                            .accessibilityHint("The value is sent once and is not stored in the app transcript.")
                    } else {
                        TextField("Response", text: $response, axis: .vertical)
                            .lineLimit(1...5)
                    }
                }
                .textFieldStyle(.roundedBorder)

                HStack {
                    if isSecure {
                        Label("Sent once; never added to chat", systemImage: "lock.shield")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .privacySensitive()
                    }
                    Spacer()
                    Button("Send") { submit() }
                        .buttonStyle(.borderedProminent)
                        .disabled(response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(14)
        .background(Color.remoteWarmOrange.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.remoteWarmOrange.opacity(0.35), lineWidth: 1)
        }
        .disabled(pendingCommandID != nil || awaitingRefresh)
        .opacity(pendingCommandID != nil || awaitingRefresh ? 0.65 : 1)
        .onChange(of: model.commandActivity) { _, activity in
            guard let completion = activity.completion(for: pendingCommandID) else { return }
            pendingCommandID = nil
            awaitingRefresh = completion.outcome == .accepted && interaction.questionnaire != nil
            if completion.outcome == .accepted || isSecure { response = "" }
        }
    }

    private func submit(decision: String? = nil) {
        guard pendingCommandID == nil, let interactionID = UUID(uuidString: interaction.id) else { return }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingCommandID = model.respond(
            sessionID: session.id,
            workspaceID: session.workspaceID,
            interactionID: interactionID,
            decision: decision,
            message: !isApproval && !isSecure ? trimmed : nil,
            secret: !isApproval && isSecure ? response : nil
        )
    }

    private func submitAnswers(_ answers: [String: RemoteQuestionAnswer]) {
        guard pendingCommandID == nil, !awaitingRefresh, let interactionID = UUID(uuidString: interaction.id) else { return }
        pendingCommandID = model.respond(
            sessionID: session.id, workspaceID: session.workspaceID,
            interactionID: interactionID, questionAnswers: answers
        )
    }
}

private struct RemoteQuestionnaireView: View {
    let questionnaire: RemoteQuestionnaire
    let onSubmit: ([String: RemoteQuestionAnswer]) -> Void

    @State private var index = 0
    @State private var answers: [String: RemoteQuestionAnswer] = [:]
    @FocusState private var isAnswerFocused: Bool

    private var question: RemoteQuestionField { questionnaire.questions[index] }
    private var answer: RemoteQuestionAnswer { answers[question.id] ?? .init() }
    private var isLastQuestion: Bool { index == questionnaire.questions.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if questionnaire.questions.count > 1 {
                Text("Question \(index + 1) of \(questionnaire.questions.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }

            if index == 0, let context = questionnaire.context, !context.isEmpty {
                RemoteMarkdownText(markdown: context)
            }
            if let header = question.header, !header.isEmpty {
                Text(header).font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            RemoteMarkdownText(markdown: question.prompt)
            if let context = question.context, context != questionnaire.context, !context.isEmpty {
                RemoteMarkdownText(markdown: context)
            }

            ForEach(question.options.indices, id: \.self) { optionIndex in
                optionButton(optionIndex)
            }

            if question.allowsCustom {
                customEntry
            }

            if answer.skipped {
                Text("Skipped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if index > 0 {
                    Button("Back") { move(by: -1) }
                        .buttonStyle(.bordered)
                }

                Spacer()

                if question.allowsSkip {
                    Button("Skip") {
                        answers[question.id] = .init(skipped: true)
                        advance()
                    }
                    .buttonStyle(.bordered)
                }

                Button(isLastQuestion ? "Submit" : "Next") { advance() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!question.accepts(answer))
            }
        }
    }

    private func optionButton(_ optionIndex: Int) -> some View {
        let option = question.options[optionIndex]
        let selected = answer.selectedOptionIndices.contains(optionIndex)
        let icon = question.allowsMultiple
            ? (selected ? "checkmark.square.fill" : "square")
            : (selected ? "largecircle.fill.circle" : "circle")
        return Button {
            var indices = answer.selectedOptionIndices
            if selected {
                indices.removeAll { $0 == optionIndex }
            } else if question.allowsMultiple {
                indices.append(optionIndex)
            } else {
                indices = [optionIndex]
            }
            let keepsText = question.allowsMultiple || question.allowsNote || indices.isEmpty
            answers[question.id] = .init(selectedOptionIndices: indices, text: keepsText ? answer.text : nil)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(selected ? Color.remoteWarmOrange : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label).fontWeight(.medium)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(.primary.opacity(selected ? 0.10 : 0.04), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var customEntry: some View {
        let placeholder = question.isSecret ? "Secure response" : (
            question.allowsNote ? "Your answer or additional details" : "Type your answer"
        )
        let binding = Binding(
            get: { answer.text ?? "" },
            set: { text in
                let keepsOptions = question.allowsMultiple || question.allowsNote
                answers[question.id] = .init(
                    selectedOptionIndices: keepsOptions ? answer.selectedOptionIndices : [], text: text
                )
            }
        )
        return Group {
            if question.isSecret {
                SecureField(placeholder, text: binding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
            } else {
                TextField(placeholder, text: binding, axis: .vertical).lineLimit(1...4)
            }
        }
        .textFieldStyle(.roundedBorder)
        .focused($isAnswerFocused)
    }

    private func move(by offset: Int) {
        isAnswerFocused = false
        index += offset
    }

    private func advance() {
        if !isLastQuestion {
            move(by: 1)
            return
        }
        isAnswerFocused = false
        // After a rejected submission, return to the first incomplete field.
        if let incomplete = questionnaire.questions.firstIndex(where: {
            !$0.accepts(answers[$0.id] ?? .init())
        }) {
            index = incomplete
            return
        }
        onSubmit(answers)
        for question in questionnaire.questions where question.isSecret {
            answers.removeValue(forKey: question.id)
        }
    }
}
