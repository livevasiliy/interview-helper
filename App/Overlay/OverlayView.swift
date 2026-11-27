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
            onAnalyzeScreen: { session.analyzeScreen() },
            onAskTyped: { session.ask(typed: $0) },
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
    var onAnalyzeScreen: () -> Void
    var onAskTyped: (String) -> Void
    var onHide: () -> Void

    init(
        content: OverlayContent,
        textSize: CGFloat = CGFloat(AppSettings.defaultOverlayTextSize),
        showTranscript: Bool = false,
        onCopy: @escaping () -> Void = {},
        onAnswerNow: @escaping () -> Void = {},
        onAnalyzeScreen: @escaping () -> Void = {},
        onAskTyped: @escaping (String) -> Void = { _ in },
        onHide: @escaping () -> Void = {}
    ) {
        self.content = content
        self.textSize = textSize
        _showTranscript = State(initialValue: showTranscript)
        self.onCopy = onCopy
        self.onAnswerNow = onAnswerNow
        self.onAnalyzeScreen = onAnalyzeScreen
        self.onAskTyped = onAskTyped
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
            typedQuestion
            Divider()
            hints
        }
        .padding(16)
        .frame(minWidth: 340, minHeight: 220)
    }

    // MARK: Header

    /// Icons with short captions when the panel is wide enough; icons alone (with tooltips) when it is not.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(labeled: true)
            headerRow(labeled: false)
        }
    }

    private func headerRow(labeled: Bool) -> some View {
        HStack(spacing: labeled ? 6 : 10) {
            Circle().fill(statusColor).frame(width: 9, height: 9).accessibilityHidden(true)
            Text(statusText)
                .font(headerFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: labeled, vertical: false)
                .accessibilityIdentifier("overlay-status")
            Spacer(minLength: 8)
            iconButton("bolt.fill", caption: labeled ? tr("answer") : nil,
                       id: "overlay-answer-now", help: tr("Answer now (%@)", Shortcut.answerNow.symbols), action: onAnswerNow)
                .disabled(content.state != .running)
            iconButton("camera.viewfinder", caption: labeled ? tr("screen") : nil,
                       id: "overlay-screen", help: tr("Analyze the screen (%@)", Shortcut.analyzeScreen.symbols), action: onAnalyzeScreen)
                .disabled(content.state != .running)
            iconButton("text.bubble", caption: labeled ? tr("transcript") : nil,
                       id: "overlay-transcript", help: showTranscript ? tr("Hide transcript") : tr("Show transcript")) { showTranscript.toggle() }
                .opacity(showTranscript ? 1 : 0.6)
            iconButton("doc.on.doc", caption: labeled ? tr("copy") : nil, id: "overlay-copy", help: tr("Copy answer"), action: onCopy)
                .disabled(content.answer.isEmpty)
            iconButton("xmark", caption: nil, id: "overlay-hide", help: tr("Hide overlay (%@)", Shortcut.toggleOverlay.symbols), action: onHide)
        }
    }

    private func iconButton(_ symbol: String, caption: String?, id: String = "", help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: iconSize))
                if let caption { Text(caption).font(hintFont).lineLimit(1).fixedSize() }
            }
            .padding(.horizontal, caption == nil ? 0 : 6)
            .frame(minWidth: max(28, iconSize + 12), minHeight: max(28, iconSize + 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(id)
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

    // MARK: Typed question

    private var typedQuestion: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard").foregroundStyle(.secondary).accessibilityHidden(true)
            TypedQuestionField(placeholder: tr("Type a question and press Return"), fontSize: smallFontSize, onSubmit: onAskTyped)
                .frame(height: smallFontSize + 8)
            Image(systemName: "return").foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .opacity(content.state == .running ? 1 : 0.55)
    }

    private var smallFontSize: CGFloat { max(13, textSize * 0.7) }

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
            .accessibilityIdentifier("overlay-notice")
    }

    @ViewBuilder private var questionBlock: some View {
        if let question = content.question {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Question")).font(labelFont).foregroundStyle(.secondary)
                Text(question).font(questionFont).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("overlay-question")
            }
        } else if content.state == .running {
            Text(tr("Waiting for the first question…")).font(questionFont).foregroundStyle(.secondary)
                .accessibilityIdentifier("overlay-waiting")
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
                        ForEach(Array(Self.answerBlocks(content.answer).enumerated()), id: \.offset) { _, block in
                            switch block {
                            case .text(let line):
                                if line.isBullet {
                                    HStack(alignment: .firstTextBaseline, spacing: textSize * 0.4) {
                                        Text("•").foregroundStyle(.secondary)
                                        Text(Self.formatted(line.text)).fixedSize(horizontal: false, vertical: true)
                                            .accessibilityIdentifier("overlay-answer-line")
                                    }
                                } else {
                                    Text(Self.formatted(line.text)).fixedSize(horizontal: false, vertical: true)
                                        .accessibilityIdentifier("overlay-answer-line")
                                }
                            case .code(let language, let code):
                                codeBlock(language: language, code: code)
                            }
                        }
                    }
                    .font(answerFont)
                }
            }
        }
    }

    /// Code is wrapped, not scrolled: the overlay never takes the mouse, so a horizontal scroll bar
    /// could not be used. Leading spaces keep the indentation readable.
    private func codeBlock(language: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !language.isEmpty {
                Text(language).font(smallFont).foregroundStyle(.secondary)
            }
            Text(code)
                .font(.system(size: textSize * 0.8, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("overlay-code")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
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

    enum AnswerBlock: Equatable {
        case text(AnswerLine)
        /// A fenced code block; one that is still streaming (no closing fence yet) is included as it stands.
        case code(language: String, code: String)
    }

    /// Splits the answer into text lines and fenced code blocks (indentation inside code is kept).
    static func answerBlocks(_ answer: String) -> [AnswerBlock] {
        var blocks: [AnswerBlock] = []
        var prose: [String] = []
        var code: [String] = []
        var language = ""
        var inCode = false
        func flushProse() {
            blocks += answerLines(prose.joined(separator: "\n")).map(AnswerBlock.text)
            prose = []
        }
        for raw in answer.components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    blocks.append(.code(language: language, code: code.joined(separator: "\n")))
                    code = []
                } else {
                    flushProse()
                    language = raw.trimmingCharacters(in: .whitespaces).dropFirst(3).trimmingCharacters(in: .whitespaces)
                }
                inCode.toggle()
            } else if inCode {
                code.append(raw)
            } else {
                prose.append(raw)
            }
        }
        if inCode { blocks.append(.code(language: language, code: code.joined(separator: "\n"))) } else { flushProse() }
        return blocks
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
