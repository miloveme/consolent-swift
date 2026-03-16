import SwiftUI
import AppKit
import SwiftTerm

/// SwiftTerm의 TerminalView를 SwiftUI에서 사용하기 위한 래퍼.
/// PTY 출력을 렌더링하고, 키보드 입력을 PTY에 전달한다.
///
/// 중요: LocalProcessTerminalView가 아닌 base TerminalView를 사용한다.
/// LocalProcessTerminalView는 자체 PTY를 관리하므로
/// 우리가 별도로 PTY를 관리하는 구조와 충돌한다.
struct TerminalViewWrapper: NSViewRepresentable {

    let session: Session

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let terminalView = TerminalView(frame: .zero)
        let config = AppConfig.shared

        // 폰트 설정
        if let font = NSFont(name: config.fontFamily, size: CGFloat(config.fontSize)) {
            terminalView.font = font
        } else {
            terminalView.font = NSFont.monospacedSystemFont(ofSize: CGFloat(config.fontSize), weight: .regular)
        }

        // 터미널 색상 (다크 테마)
        terminalView.nativeBackgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
        terminalView.nativeForegroundColor = NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)

        // 스크롤 기록 설정
        terminalView.getTerminal().changeHistorySize(config.scrollbackLines)

        // 커서
        terminalView.cursorStyleChanged(source: terminalView.getTerminal(), newStyle: .blinkBlock)

        // 코디네이터를 delegate로 설정
        context.coordinator.terminalView = terminalView
        context.coordinator.session = session
        terminalView.terminalDelegate = context.coordinator

        // 세션의 터미널 출력을 TerminalView에 연결
        let existingCallback = session.onTerminalOutput
        session.onTerminalOutput = { [weak terminalView] data in
            existingCallback?(data)
            DispatchQueue.main.async {
                let bytes = [UInt8](data)
                terminalView?.feed(byteArray: ArraySlice(bytes))
            }
        }

        // 이미 있는 출력 버퍼 표시
        if !session.outputBuffer.isEmpty {
            let bytes = [UInt8](session.outputBuffer)
            terminalView.feed(byteArray: ArraySlice(bytes))
        }

        return terminalView
    }

    func updateNSView(_ nsView: SwiftTerm.TerminalView, context: Context) {
        // 세션 변경 시 업데이트
        context.coordinator.session = session
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, TerminalViewDelegate {
        weak var terminalView: SwiftTerm.TerminalView?
        var session: Session?

        // 키보드 입력이 발생하면 우리의 PTY에 전달
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard let session else { return }
            let dataObj = Data(data)
            try? session.ptyProcess.write(dataObj)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            session?.ptyProcess.resize(cols: UInt16(newCols), rows: UInt16(newRows))
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            // 터미널 타이틀 변경 (선택적)
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // 디렉토리 변경 알림
        }

        func scrolled(source: TerminalView, position: Double) {
            // 스크롤 위치 변경
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            // OSC 52 클립보드 복사
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(content, forType: .string)
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
            // iTerm2 OSC 1337 (사용 안 함)
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
            // 시각적 변경 알림
        }
    }
}

/// 세션이 없을 때 보여주는 빈 상태 뷰
struct EmptyTerminalView: View {
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.blue.opacity(0.3), Color.blue.opacity(0.1)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)
                    .blur(radius: 10)

                Image(systemName: "terminal.fill")
                    .font(.system(size: 40))
                    .symbolRenderingMode(.multicolor)
                    .foregroundColor(Color.blue)
                    .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 3)
            }

            VStack(spacing: 8) {
                Text("활성화된 세션 없음")
                    .font(.title)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Text("+ 버튼이나 Cmd+T를 눌러 세션 생성")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(nsColor: NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)),
                    Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1.0))
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}
