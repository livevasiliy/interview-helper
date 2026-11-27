import AppKit
import InterviewCore
import SwiftUI

/// Plain values the overlay renders. Keeping the view free of the coordinator makes it previewable.
struct OverlayContent: Equatable {
    var state: SessionState = .idle
    var lines: [TranscriptLine] = []
    var question: String?
    var answer = ""
    var answerError: String?
    var isAnswering = false
    var warnings: [String] = []
}

/// Text size shared between Settings and the overlay so changes apply live.
@MainActor
final class OverlayAppearance: ObservableObject {
    @Published var textSize: Double = AppSettings.defaultOverlayTextSize
    /// Changing it makes the overlay redraw, so its texts follow a language switch immediately.
    @Published var language: AppLanguage = L10n.language
}

/// Live wrapper: observes the coordinator and feeds `OverlayView`.
struct LiveOverlayView: View {
    @ObservedObject var session: SessionCoordinator
    @ObservedObject var appearance: OverlayAppearance
    var onHide: () -> Void

    var body: some View {
        OverlayView(
            content: session.content,
            textSize: CGFloat(appearance.textSize),
            onCopy: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.answer, forType: .string)
            },
            onAnswerNow: { session.askNow() },
            onHide: onHide
        )
    }
}

struct OverlayView: View {
    let content: OverlayContent
    /// Font size of the answer text in points; every other size scales from it.
    let textSize: CGFloat
    @State private var showTranscript: Bool
    var onCopy: () -> Void
    var onAnswerNow: () -> Void
    var onHide: () -> Void

    init(
        content: OverlayContent,
        textSize: CGFloat = CGFloat(AppSettings.defaultOverlayTextSize),
        showTranscript: Bool = false,
        onCopy: @escaping () -> Void = {},
        onAnswerNow: @escaping () -> Void = {},
        onHide: @escaping () -> Void = {}
    ) {
        self.content = content
        self.textSize = textSize
        _showTranscript = State(initialValue: showTranscript)
        self.onCopy = onCopy
        self.onAnswerNow = onAnswerNow
        self.onHide = onHide
    }

    // MARK: Type scale (all derived from the user's chosen size)

    private var headerFont: Font { .system(size: max(13, textSize * 0.72), weight: .medium) }
    private var labelFont: Font { .system(size: max(12, textSize * 0.62), weight: .medium) }
    private var questionFont: Font { .system(size: textSize * 0.86) }
    private var answerFont: Font { .system(size: textSize) }
    private var smallFont: Font { .system(size: max(12, textSize * 0.7)) }
    private var hintFont: Font { .system(size: max(11, textSize * 0.55)) }
    private var iconSize: CGFloat { max(13, textSize * 0.72) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    problems
                    questionBlock
                    answerBlock
                    if showTranscript { transcriptBlock }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            hints
        }
        .padding(16)
        .frame(minWidth: 340, minHeight: 220)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 9, height: 9)
            Text(statusText)
                .font(headerFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            iconButton("bolt.fill", help: tr("Answer now (%@)", Shortcut.answerNow.symbols), action: onAnswerNow)
                .disabled(content.state != .running)
            iconButton("text.bubble", help: showTranscript ? tr("Hide transcript") : tr("Show transcript")) { showTranscript.toggle() }
                .opacity(showTranscript ? 1 : 0.6)
            iconButton("doc.on.doc", help: tr("Copy answer"), action: onCopy)
                .disabled(content.answer.isEmpty)
            iconButton("xmark", help: tr("Hide overlay (%@)", Shortcut.toggleOverlay.symbols), action: onHide)
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize))
                .frame(width: iconSize + 10, height: iconSize + 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var statusColor: Color {
        switch content.state {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .failed: return .red
        case .idle: return .gray
        }
    }

    private var statusText: String {
        switch content.state {
        case .idle: return tr("Not listening · %@ to start", Shortcut.startStop.symbols)
        case .starting: return tr("Starting…")
        case .running: return tr("Listening")
        case .stopping: return tr("Stopping…")
        case .failed: return tr("Session stopped")
        }
    }

    // MARK: Hotkey hints

    /// Always-visible reminder of the shortcuts, so nobody has to remember them mid-interview.
    private var hints: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: max(150, textSize * 7.5)), spacing: 12, alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(Shortcut.allCases, id: \.self) { shortcut in
                HStack(spacing: 5) {
                    Text(shortcut.symbols)
                        .font(hintFont.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    Text(shortcut.shortTitle).font(hintFont).foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
        }
    }

    // MARK: Body

    @ViewBuilder private var problems: some View {
        if case .failed(let message) = content.state {
            notice(message, color: .red)
        }
        if let error = content.answerError {
            notice(tr("Answer failed: %@", error), color: .red)
        }
        ForEach(Array(content.warnings.suffix(2).enumerated()), id: \.offset) { _, warning in
            notice(warning, color: .orange)
        }
    }

    private func notice(_ text: String, color: Color) -> some View {
        Text(text)
            .font(smallFont)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var questionBlock: some View {
        if let question = content.question {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Question")).font(labelFont).foregroundStyle(.secondary)
                Text(question).font(questionFont).fixedSize(horizontal: false, vertical: true)
            }
        } else if content.state == .running {
            Text(tr("Waiting for the first question…")).font(questionFont).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var answerBlock: some View {
        if content.question != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Suggested answer")).font(labelFont).foregroundStyle(.secondary)
                if content.answer.isEmpty {
                    Text(content.isAnswering ? tr("Thinking…") : "—").font(answerFont).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: textSize * 0.3) {
                        ForEach(Array(Self.answerLines(content.answer).enumerated()), id: \.offset) { _, line in
                            if line.isBullet {
                                HStack(alignment: .firstTextBaseline, spacing: textSize * 0.4) {
                                    Text("•").foregroundStyle(.secondary)
                                    Text(Self.formatted(line.text)).fixedSize(horizontal: false, vertical: true)
                                }
                            } else {
                                Text(Self.formatted(line.text)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .font(answerFont)
                }
            }
        }
    }

    private var transcriptBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(tr("Transcript")).font(labelFont).foregroundStyle(.secondary)
            if content.lines.isEmpty {
                Text(tr("Nothing heard yet.")).font(smallFont).foregroundStyle(.secondary)
            }
            ForEach(content.lines.suffix(8)) { line in
                (Text(line.speaker == .interviewer ? tr("Interviewer: ") : tr("You: ")).bold() + Text(line.text))
                    .font(smallFont)
                    .foregroundStyle(line.isFinal ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    struct AnswerLine: Equatable {
        let text: String
        let isBullet: Bool
    }

    /// Splits the answer into lines, turning `- `, `* ` and `• ` prefixes into bullet rows.
    static func answerLines(_ answer: String) -> [AnswerLine] {
        answer.split(separator: "\n", omittingEmptySubsequences: true).map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            for prefix in ["- ", "* ", "• "] where line.hasPrefix(prefix) {
                return AnswerLine(text: String(line.dropFirst(prefix.count)), isBullet: true)
            }
            return AnswerLine(text: line, isBullet: false)
        }
    }

    /// Renders light Markdown (bold, bullets) from the model; partial markup mid-stream falls back to plain text.
    static func formatted(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
