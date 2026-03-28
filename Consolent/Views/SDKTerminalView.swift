import SwiftUI
import UniformTypeIdentifiers

/// SDK 모드 세션의 채팅 버블 뷰.
/// 유저 메시지는 오른쪽, Claude 응답은 왼쪽에 말풍선 형태로 표시한다.
struct SDKTerminalView: View {
    @ObservedObject var session: Session
    @State private var inputText: String = ""
    @State private var isSending: Bool = false
    @State private var attachedFiles: [AttachedFile] = []
    @State private var isFilePickerPresented = false
    @State private var isDropTargeted = false
    @FocusState private var inputFocused: Bool

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic"]

    var body: some View {
        VStack(spacing: 0) {
            // 채팅 영역
            chatArea

            // 하단 입력 패널
            inputPanel
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .padding(.top, 10)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.06).cornerRadius(12))
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.down.doc")
                                .font(.system(size: 32))
                            Text("파일을 여기에 놓으세요")
                                .font(.headline)
                        }
                        .foregroundColor(.accentColor)
                    }
                    .allowsHitTesting(false)
                    .padding(8)
            }
        }
    }

    // MARK: - 채팅 영역

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if session.chatMessages.isEmpty {
                        statusView
                    } else {
                        ForEach(session.chatMessages) { msg in
                            ChatBubbleView(message: msg)
                                .id(msg.id)
                        }
                        // 에러 상태면 메시지 아래에 재시작 버튼 추가
                        if session.status == .error {
                            retryButton
                                .id("retry")
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 12)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: session.chatMessages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: session.status) { _, newStatus in
                if newStatus == .error {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    /// 메시지 없을 때 상태별 중앙 표시
    @ViewBuilder
    private var statusView: some View {
        switch session.status {
        case .error:
            errorView
        case .initializing:
            placeholderText("브릿지 서버 시작 대기 중...")
        case .ready:
            placeholderText("메시지를 입력하세요")
        default:
            placeholderText("준비 중...")
        }
    }

    private func placeholderText(_ text: String) -> some View {
        HStack {
            Spacer()
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.top, 40)
    }

    /// 에러 상태 뷰 (chatMessages가 비어 있을 때)
    private var errorView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(.orange)

            Text("브릿지 서버 시작 실패")
                .font(.headline)
                .foregroundColor(.primary)

            if let msg = session.bridgeError {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            retryButton
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }

    /// 재시작 버튼
    private var retryButton: some View {
        HStack {
            Spacer()
            Button {
                Task { await session.restartBridge() }
            } label: {
                Label("재시작", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(session.status == .initializing)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    // MARK: - 입력 패널

    private var inputPanel: some View {
        VStack(spacing: 0) {
            // 첨부 파일 칩
            if !attachedFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachedFiles) { file in
                            attachmentChip(file: file)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                }
            }

            // 텍스트 입력
            TextField("무엇이든 부탁하세요", text: $inputText, axis: .vertical)
                .lineLimit(1...10)
                .font(.body)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.top, attachedFiles.isEmpty ? 14 : 6)
                .padding(.bottom, 8)
                .onKeyPress(.return) {
                    if NSEvent.modifierFlags.contains(.shift) {
                        inputText += "\n"
                        return .handled
                    }
                    submitMessage()
                    return .handled
                }
                .disabled(isSending || session.status != .ready)

            // 하단 버튼 바
            HStack(spacing: 4) {
                Button(action: { isFilePickerPresented = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isSending)
                .help("파일/이미지 첨부 (또는 드래그 앤 드롭)")
                .fileImporter(
                    isPresented: $isFilePickerPresented,
                    allowedContentTypes: [.item],
                    allowsMultipleSelection: true
                ) { result in
                    if case .success(let urls) = result { addFiles(urls) }
                }

                Spacer()

                Button(action: submitMessage) {
                    if isSending {
                        ProgressView()
                            .scaleEffect(0.75)
                            .frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                            .background(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                            .clipShape(Circle())
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend || isSending)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private func attachmentChip(file: AttachedFile) -> some View {
        HStack(spacing: 4) {
            Image(systemName: file.isImage ? "photo" : "doc.text")
                .font(.system(size: 11))
                .foregroundColor(file.isImage ? .blue : .secondary)
            Text(file.name)
                .font(.system(size: 12))
                .lineLimit(1)
            Button {
                attachedFiles.removeAll { $0.id == file.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    // MARK: - 로직

    private var canSend: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !attachedFiles.isEmpty) && session.status == .ready
    }

    private func addFiles(_ urls: [URL]) {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard !attachedFiles.contains(where: { $0.url == url }) else { continue }
            attachedFiles.append(AttachedFile(url: url))
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let urlStr = String(data: data, encoding: .utf8),
                          let url = URL(string: urlStr) else { return }
                    DispatchQueue.main.async { self.addFiles([url]) }
                }
                handled = true
            }
        }
        return handled
    }

    private func submitMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !attachedFiles.isEmpty),
              session.status == .ready, !isSending else { return }

        var fullText = text
        for file in attachedFiles {
            fullText += "\n\(file.url.path)"
        }

        inputText = ""
        attachedFiles = []
        isSending = true

        Task {
            defer {
                Task { @MainActor in
                    isSending = false
                    inputFocused = true   // 응답 완료 후 입력창 포커스 복원
                }
            }
            _ = try? await session.sendMessage(text: fullText.trimmingCharacters(in: .newlines))
        }
    }
}

// MARK: - 채팅 버블

struct ChatBubbleView: View {
    let message: Session.ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            assistantBubble
        case .system:
            systemLine
        }
    }

    // 유저: 오른쪽 정렬
    private var userBubble: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 80)
            Text(message.text)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(BubbleShape(isLeading: false))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // 어시스턴트: 왼쪽 정렬 (마크다운 렌더링)
    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 10) {
            // Claude 아이콘
            ZStack {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 28, height: 28)
                Image(systemName: "sparkle")
                    .font(.system(size: 13))
                    .foregroundColor(.accentColor)
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 0) {
                MarkdownView(text: message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(BubbleShape(isLeading: true))
            }
            Spacer(minLength: 60)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // 시스템 메시지: 왼쪽 정렬 작은 텍스트
    private var systemLine: some View {
        HStack {
            Text(message.text)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                .cornerRadius(8)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

// MARK: - 말풍선 모양

struct BubbleShape: Shape {
    let isLeading: Bool
    private let r: CGFloat = 16
    private let tail: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let minX = rect.minX, maxX = rect.maxX
        let minY = rect.minY, maxY = rect.maxY

        if isLeading {
            // 왼쪽 말풍선: 좌상단 꼬리 없음, 우측 둥근 모서리
            p.move(to: CGPoint(x: minX + r, y: minY))
            p.addLine(to: CGPoint(x: maxX - r, y: minY))
            p.addQuadCurve(to: CGPoint(x: maxX, y: minY + r), control: CGPoint(x: maxX, y: minY))
            p.addLine(to: CGPoint(x: maxX, y: maxY - r))
            p.addQuadCurve(to: CGPoint(x: maxX - r, y: maxY), control: CGPoint(x: maxX, y: maxY))
            p.addLine(to: CGPoint(x: minX + r, y: maxY))
            p.addQuadCurve(to: CGPoint(x: minX, y: maxY - r), control: CGPoint(x: minX, y: maxY))
            p.addLine(to: CGPoint(x: minX, y: minY + r))
            p.addQuadCurve(to: CGPoint(x: minX + r, y: minY), control: CGPoint(x: minX, y: minY))
        } else {
            // 오른쪽 말풍선
            p.move(to: CGPoint(x: minX + r, y: minY))
            p.addLine(to: CGPoint(x: maxX - r, y: minY))
            p.addQuadCurve(to: CGPoint(x: maxX, y: minY + r), control: CGPoint(x: maxX, y: minY))
            p.addLine(to: CGPoint(x: maxX, y: maxY - r))
            p.addQuadCurve(to: CGPoint(x: maxX - r, y: maxY), control: CGPoint(x: maxX, y: maxY))
            p.addLine(to: CGPoint(x: minX + r, y: maxY))
            p.addQuadCurve(to: CGPoint(x: minX, y: maxY - r), control: CGPoint(x: minX, y: maxY))
            p.addLine(to: CGPoint(x: minX, y: minY + r))
            p.addQuadCurve(to: CGPoint(x: minX + r, y: minY), control: CGPoint(x: minX, y: minY))
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - 마크다운 렌더러

/// 기본 마크다운을 AttributedString으로 렌더링한다.
/// 코드 블록(```)은 별도 배경으로 표시한다.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(segments, id: \.id) { seg in
                if seg.isCode {
                    Text(seg.content)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(Color(nsColor: .textColor))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)
                } else {
                    if let attr = try? AttributedString(
                        markdown: seg.content,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                    ) {
                        Text(attr)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(seg.content).font(.body)
                    }
                }
            }
        }
    }

    private struct Segment: Identifiable {
        let id = UUID()
        let content: String
        let isCode: Bool
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var remaining = text
        while !remaining.isEmpty {
            if let codeStart = remaining.range(of: "```") {
                let before = String(remaining[remaining.startIndex..<codeStart.lowerBound])
                if !before.isEmpty { result.append(Segment(content: before, isCode: false)) }
                let afterOpen = remaining[codeStart.upperBound...]
                // 언어 힌트 라인 스킵
                let body: Substring
                if let nl = afterOpen.firstIndex(of: "\n") {
                    body = afterOpen[afterOpen.index(after: nl)...]
                } else {
                    body = afterOpen
                }
                if let codeEnd = body.range(of: "```") {
                    let code = String(body[body.startIndex..<codeEnd.lowerBound])
                    result.append(Segment(content: code, isCode: true))
                    remaining = String(body[codeEnd.upperBound...])
                } else {
                    result.append(Segment(content: String(body), isCode: true))
                    break
                }
            } else {
                result.append(Segment(content: remaining, isCode: false))
                break
            }
        }
        return result
    }
}

// MARK: - AttachedFile 모델

struct AttachedFile: Identifiable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    var isImage: Bool {
        SDKTerminalView.imageExtensions.contains(url.pathExtension.lowercased())
    }
}
