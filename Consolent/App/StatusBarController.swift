import AppKit
import Combine

/// 메뉴바 아이콘과 드롭다운 메뉴를 관리한다.
/// SessionManager를 구독하여 세션 목록을 실시간 반영한다.
///
/// 색상 규칙:
///   타입별 팔레트 안에서 순환 (같은 타입 내 구별).
///   타입 간 팔레트는 색상 계열이 달라 겹치지 않음:
///     채널  → 초록 계열
///     SDK   → 청록/파랑 계열
///     Gemini→ 보라/분홍 계열
///     Codex → 주황/갈색 계열
///     PTY   → 파랑 (API 서버 색상 고정)
///
///   색상이 겹치더라도 서버 아이템에 세션명을 함께 표시하므로
///   이름으로 명확히 구별 가능.
///
/// 서브메뉴 규칙:
///   서버 아이템 hover → 연결된 세션 목록 서브메뉴
///   세션 아이템 hover → 연결된 서버 정보 + URL 복사 + 세션 닫기
final class StatusBarController: NSObject, NSMenuDelegate {

    private var statusItem: NSStatusItem
    private let menu = NSMenu()
    private weak var appDelegate: AppDelegate?

    // MARK: - 타입별 색상 팔레트 (계열 구분)

    private let apiServerColor = NSColor.systemBlue

    /// 초록 계열 — 채널 세션 전용
    private let channelPalette: [NSColor] = [
        .systemGreen,
        NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1), // 연초록
        .systemMint,
        NSColor(red: 0.05, green: 0.55, blue: 0.25, alpha: 1), // 진초록
        NSColor(red: 0.55, green: 0.85, blue: 0.10, alpha: 1), // 황록
        NSColor(red: 0.00, green: 0.65, blue: 0.55, alpha: 1), // 청록
    ]

    /// 청록/파랑 계열 — SDK(Agent) 세션 전용
    private let sdkPalette: [NSColor] = [
        .systemCyan,
        NSColor(red: 0.10, green: 0.60, blue: 0.90, alpha: 1), // 하늘
        NSColor(red: 0.00, green: 0.75, blue: 0.85, alpha: 1), // 진청록
        .systemTeal,
        NSColor(red: 0.30, green: 0.80, blue: 1.00, alpha: 1), // 밝은 하늘
        .systemBlue,
    ]

    /// 보라/분홍 계열 — Gemini 세션 전용
    private let geminiPalette: [NSColor] = [
        .systemPurple,
        .systemPink,
        NSColor(red: 0.75, green: 0.20, blue: 0.85, alpha: 1), // 자주
        NSColor(red: 0.90, green: 0.40, blue: 0.65, alpha: 1), // 핫핑크
        NSColor(red: 0.55, green: 0.10, blue: 0.70, alpha: 1), // 진보라
        NSColor(red: 0.85, green: 0.55, blue: 0.90, alpha: 1), // 연보라
    ]

    /// 주황/갈색 계열 — Codex 세션 전용
    private let codexPalette: [NSColor] = [
        .systemOrange,
        NSColor(red: 0.90, green: 0.60, blue: 0.10, alpha: 1), // 황금
        .systemYellow,
        .systemBrown,
        NSColor(red: 0.85, green: 0.35, blue: 0.10, alpha: 1), // 적갈
        NSColor(red: 0.95, green: 0.70, blue: 0.30, alpha: 1), // 살구
    ]

    // MARK: - Init

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "Consolent")
            button.image?.size = NSSize(width: 16, height: 16)
        }

        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    // MARK: - 메뉴 구성

    private func rebuildMenu() {
        menu.removeAllItems()

        let config = AppConfig.shared
        let sessionManager = SessionManager.shared
        let sectionFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let itemFont = NSFont.systemFont(ofSize: 13)

        let activeSessions = sessionManager.sessions.values
            .filter { $0.status != .terminated }
            .sorted { $0.createdAt < $1.createdAt }

        // 타입별 세션 분류
        let ptySessions            = activeSessions.filter { !$0.isChannelMode && !$0.isBridgeMode }
        let channelSessions        = activeSessions.filter { $0.isChannelMode }
        let sdkSessions            = activeSessions.filter { $0.isSDKMode }
        let geminiStreamSessions   = activeSessions.filter { $0.isGeminiStreamMode }
        let codexAppServerSessions = activeSessions.filter { $0.isCodexAppServerMode }
        let agentSessions          = sdkSessions + geminiStreamSessions + codexAppServerSessions

        // 세션 ID → 색상 (타입별 팔레트 순환)
        var sessionColorMap: [String: NSColor] = [:]
        for s in ptySessions            { sessionColorMap[s.id] = apiServerColor }
        for (i, s) in channelSessions.enumerated()        { sessionColorMap[s.id] = channelPalette[i % channelPalette.count] }
        for (i, s) in sdkSessions.enumerated()            { sessionColorMap[s.id] = sdkPalette[i % sdkPalette.count] }
        for (i, s) in geminiStreamSessions.enumerated()   { sessionColorMap[s.id] = geminiPalette[i % geminiPalette.count] }
        for (i, s) in codexAppServerSessions.enumerated() { sessionColorMap[s.id] = codexPalette[i % codexPalette.count] }

        // ── API Server ──
        addSectionHeader("API Server", font: sectionFont)

        let apiUrl = "http://\(config.apiBind):\(config.apiPort)"
        let apiItem = makeServerItem(title: "  \(apiUrl)", color: apiServerColor,
                                     font: itemFont, copyValue: apiUrl,
                                     toolTip: "클릭하여 복사")
        // 서브메뉴: 연결된 PTY 세션들
        let apiSub = NSMenu()
        let apiSubHeader = makeDisabledItem("연결된 세션", font: .systemFont(ofSize: 11, weight: .semibold))
        apiSub.addItem(apiSubHeader)
        if ptySessions.isEmpty {
            apiSub.addItem(makeDisabledItem("  (없음)", font: .systemFont(ofSize: 11)))
        } else {
            for s in ptySessions {
                let dot = sessionStatusDot(s)
                let sub = makeSessionInfoItem(
                    title: "  \(dot) \(s.name)  [\(s.status.rawValue)]",
                    color: apiServerColor, font: .systemFont(ofSize: 12),
                    sessionId: s.id
                )
                apiSub.addItem(sub)
            }
        }
        apiItem.submenu = apiSub
        menu.addItem(apiItem)

        // ── Channel Server ──
        if !channelSessions.isEmpty {
            menu.addItem(NSMenuItem.separator())
            addSectionHeader("Channel Server (\(channelSessions.count))", font: sectionFont)

            for session in channelSessions {
                guard let url = session.channelServerURL else { continue }
                let color = sessionColorMap[session.id] ?? channelPalette[0]
                let item = makeServerItem(title: "  \(url)", color: color,
                                          font: itemFont, copyValue: url,
                                          toolTip: "클릭하여 복사")
                item.submenu = makeSessionSubmenu(for: [session], colorMap: sessionColorMap)
                menu.addItem(item)
            }
        }

        // ── Agent Server (SDK + Gemini + Codex 통합) ──
        if !agentSessions.isEmpty {
            menu.addItem(NSMenuItem.separator())
            addSectionHeader("Agent Server (\(agentSessions.count))", font: sectionFont)

            // SDK 세션
            for session in sdkSessions {
                guard let url = session.sdkServerURL else { continue }
                let color = sessionColorMap[session.id] ?? sdkPalette[0]
                let item = makeServerItem(title: "  \(url)", color: color,
                                          font: itemFont, copyValue: url,
                                          toolTip: "클릭하여 복사")
                item.submenu = makeSessionSubmenu(for: [session], colorMap: sessionColorMap)
                menu.addItem(item)
            }

            // Gemini 브릿지 세션
            for session in geminiStreamSessions {
                guard let url = session.geminiStreamServerURL else { continue }
                let color = sessionColorMap[session.id] ?? geminiPalette[0]
                let item = makeServerItem(title: "  \(url)", color: color,
                                          font: itemFont, copyValue: url,
                                          toolTip: "클릭하여 복사")
                item.submenu = makeSessionSubmenu(for: [session], colorMap: sessionColorMap)
                menu.addItem(item)
            }

            // Codex 브릿지 세션
            for session in codexAppServerSessions {
                guard let url = session.codexAppServerURL else { continue }
                let color = sessionColorMap[session.id] ?? codexPalette[0]
                let item = makeServerItem(title: "  \(url)", color: color,
                                          font: itemFont, copyValue: url,
                                          toolTip: "클릭하여 복사")
                item.submenu = makeSessionSubmenu(for: [session], colorMap: sessionColorMap)
                menu.addItem(item)
            }
        }

        // ── API Key ──
        menu.addItem(NSMenuItem.separator())

        let keyItem = NSMenuItem(title: "", action: #selector(copyApiKey), keyEquivalent: "")
        keyItem.target = self
        keyItem.image = NSImage(systemSymbolName: "key", accessibilityDescription: nil)
        keyItem.attributedTitle = NSAttributedString(string: "API Key", attributes: [
            .font: itemFont,
            .foregroundColor: apiServerColor
        ])
        keyItem.toolTip = "Consolent API Key 복사"
        menu.addItem(keyItem)

        // 채널 서버 API Key (Consolent 키와 다른 경우만)
        let channelKeys = readChannelApiKeys()
        let consolentKey = config.apiKey
        for session in channelSessions {
            let serverName = session.config.channelServerName
            guard let channelKey = channelKeys[serverName],
                  !channelKey.isEmpty,
                  channelKey != consolentKey else { continue }

            let item = NSMenuItem(title: "", action: #selector(copyToPasteboard(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = channelKey
            item.image = NSImage(systemSymbolName: "key", accessibilityDescription: nil)
            item.attributedTitle = NSAttributedString(string: "\(session.name) Key", attributes: [
                .font: itemFont,
                .foregroundColor: sessionColorMap[session.id] ?? channelPalette[0]
            ])
            item.toolTip = "채널 서버 API Key 복사"
            menu.addItem(item)
        }

        // ── 세션 목록 ──
        menu.addItem(NSMenuItem.separator())

        if activeSessions.isEmpty {
            let emptyItem = NSMenuItem(title: "세션 없음", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            addSectionHeader("Sessions (\(activeSessions.count))", font: sectionFont)

            for session in activeSessions {
                let dot = sessionStatusDot(session)
                let title = "  \(dot) \(session.name)  [\(session.status.rawValue)]"
                let color = sessionColorMap[session.id] ?? apiServerColor

                let item = NSMenuItem(title: title, action: #selector(selectSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = session.id
                item.attributedTitle = NSAttributedString(string: title, attributes: [
                    .font: itemFont,
                    .foregroundColor: color
                ])

                // 서브메뉴: 연결된 서버 정보 + 세션 닫기
                let sub = NSMenu()

                // 서버 정보 헤더
                let serverLabel = serverInfoLabel(for: session)
                let serverHeader = makeDisabledItem(serverLabel, font: .systemFont(ofSize: 11, weight: .semibold))
                sub.addItem(serverHeader)

                // 서버 URL 표시 (클릭하면 복사)
                if let serverUrl = serverURLForSession(session, config: config) {
                    let copyServerItem = NSMenuItem(title: "  \(serverUrl)", action: #selector(copyToPasteboard(_:)), keyEquivalent: "")
                    copyServerItem.target = self
                    copyServerItem.representedObject = serverUrl
                    copyServerItem.toolTip = "클릭하여 복사"
                    copyServerItem.attributedTitle = NSAttributedString(
                        string: "  \(serverUrl)",
                        attributes: [
                            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                            .foregroundColor: color
                        ]
                    )
                    sub.addItem(copyServerItem)
                }

                sub.addItem(NSMenuItem.separator())

                // 세션 시작/중지 토글
                let isStoppable = session.status == .ready || session.status == .busy || session.status == .waitingApproval
                // .stopped: 명시적 연결 끊기, .error: 시작 실패 — 둘 다 재연결 가능
                let isStartable = session.status == .stopped || session.status == .error

                if isStoppable {
                    let stopItem = NSMenuItem(title: "연결 끊기", action: #selector(stopSession(_:)), keyEquivalent: "")
                    stopItem.representedObject = session.id
                    stopItem.target = self
                    stopItem.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
                    sub.addItem(stopItem)
                } else if isStartable {
                    let startItem = NSMenuItem(title: "연결하기", action: #selector(startSession(_:)), keyEquivalent: "")
                    startItem.representedObject = session.id
                    startItem.target = self
                    startItem.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: nil)
                    sub.addItem(startItem)
                }

                sub.addItem(NSMenuItem.separator())

                // 세션 닫기
                let closeItem = NSMenuItem(title: "세션 닫기", action: #selector(closeSession(_:)), keyEquivalent: "")
                closeItem.target = self
                closeItem.representedObject = session.id
                closeItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
                sub.addItem(closeItem)

                item.submenu = sub
                menu.addItem(item)
            }
        }

        // ── 하단 액션 ──
        menu.addItem(NSMenuItem.separator())

        let newSessionItem = NSMenuItem(title: "새 세션...", action: #selector(newSession), keyEquivalent: "t")
        newSessionItem.target = self
        newSessionItem.keyEquivalentModifierMask = .command
        menu.addItem(newSessionItem)

        let openWindowItem = NSMenuItem(title: "윈도우 열기", action: #selector(openWindow), keyEquivalent: "o")
        openWindowItem.target = self
        openWindowItem.keyEquivalentModifierMask = .command
        menu.addItem(openWindowItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "설정...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "종료", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)
    }

    // MARK: - 헬퍼: 서브메뉴 빌더

    /// 세션 목록을 담은 서버 서브메뉴를 만든다.
    private func makeSessionSubmenu(for sessions: [Session],
                                    colorMap: [String: NSColor]) -> NSMenu {
        let sub = NSMenu()
        let header = makeDisabledItem("연결된 세션", font: .systemFont(ofSize: 11, weight: .semibold))
        sub.addItem(header)

        if sessions.isEmpty {
            sub.addItem(makeDisabledItem("  (없음)", font: .systemFont(ofSize: 11)))
        } else {
            for s in sessions {
                let dot = sessionStatusDot(s)
                let color = colorMap[s.id] ?? .labelColor
                let item = makeSessionInfoItem(
                    title: "  \(dot) \(s.name)  [\(s.status.rawValue)]",
                    color: color,
                    font: .systemFont(ofSize: 12),
                    sessionId: s.id
                )
                sub.addItem(item)
            }
        }
        return sub
    }

    /// 세션에 연결된 서버 레이블 문자열 반환
    private func serverInfoLabel(for session: Session) -> String {
        if session.isSDKMode       { return "Agent Server (SDK)" }
        if session.isGeminiStreamMode { return "Agent Server (Gemini)" }
        if session.isCodexAppServerMode { return "Agent Server (Codex)" }
        if session.isChannelMode   { return "Channel Server" }
        return "API Server"
    }

    /// 세션에 연결된 서버 URL 반환 (복사용)
    private func serverURLForSession(_ session: Session, config: AppConfig) -> String? {
        if session.isSDKMode, let url = session.sdkServerURL { return url }
        if session.isGeminiStreamMode, let url = session.geminiStreamServerURL { return url }
        if session.isCodexAppServerMode, let url = session.codexAppServerURL { return url }
        if session.isChannelMode, let url = session.channelServerURL { return url }
        return "http://\(config.apiBind):\(config.apiPort)"
    }

    /// 세션 상태에 따른 아이콘 문자
    private func sessionStatusDot(_ session: Session) -> String {
        switch session.status {
        case .ready:
            if session.isChannelMode        { return "⚡" }
            if session.isSDKMode            { return "✦" }
            if session.isGeminiStreamMode   { return "◈" }
            if session.isCodexAppServerMode { return "⬡" }
            return "●"
        case .busy:            return "◉"
        case .initializing:    return "○"
        case .stopped:         return "⏹"
        case .error:           return "✕"
        case .waitingApproval: return "⏸"
        case .terminated:      return "◌"
        }
    }

    // MARK: - 헬퍼: 메뉴 아이템 팩토리

    /// 클릭하면 복사되는 서버 URL 아이템 (서브메뉴 포함 가능)
    private func makeServerItem(title: String, color: NSColor, font: NSFont,
                                 copyValue: String, toolTip: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(copyToPasteboard(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = copyValue
        item.toolTip = toolTip
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: color
        ])
        return item
    }

    /// 클릭하면 세션을 선택하는 세션 아이템
    private func makeSessionInfoItem(title: String, color: NSColor, font: NSFont,
                                      sessionId: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(selectSession(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = sessionId
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: color
        ])
        return item
    }

    /// 클릭 불가 레이블 아이템
    private func makeDisabledItem(_ title: String, font: NSFont) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        return item
    }

    private func addSectionHeader(_ title: String, font: NSFont) {
        let item = NSMenuItem()
        let label = NSTextField(labelWithString: title)
        label.font = font
        label.textColor = .white
        label.sizeToFit()

        let container = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.width + 28, height: label.frame.height + 8))
        label.frame.origin = NSPoint(x: 14, y: 4)
        container.addSubview(label)

        item.view = container
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func copyToPasteboard(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopyFeedback()
    }

    @objc private func copyApiKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppConfig.shared.apiKey, forType: .string)
        showCopyFeedback()
    }

    /// MCP 설정 파일에서 서버별 OPENAI_COMPAT_API_KEY를 읽는다.
    /// 신규 포맷(~/.mcp.json)과 레거시(~/.claude.json) 양쪽 모두 확인.
    private func readChannelApiKeys() -> [String: String] {
        var result: [String: String] = [:]

        // 양쪽 파일에서 읽기 (신규 포맷 우선)
        let paths = [
            NSHomeDirectory() + "/.mcp.json",
            NSHomeDirectory() + "/.claude.json"
        ]

        for path in paths {
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mcpServers = json["mcpServers"] as? [String: Any] else {
                continue
            }

            for (name, value) in mcpServers {
                guard let serverConfig = value as? [String: Any],
                      let env = serverConfig["env"] as? [String: Any],
                      let apiKey = env["OPENAI_COMPAT_API_KEY"] as? String,
                      result[name] == nil else { continue }  // 중복 방지 (신규 포맷 우선)
                result[name] = apiKey
            }
        }

        return result
    }

    /// 메뉴바 아이콘 근처에 말풍선 팝오버로 복사 피드백 표시
    private func showCopyFeedback() {
        guard let button = statusItem.button else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let label = NSTextField(labelWithString: "✓ 복사 완료")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center

        let vc = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 28))
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        vc.view = container
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 100, height: 28)

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            popover.performClose(nil)
        }
    }

    @objc private func selectSession(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        appDelegate?.selectSession(id: sessionId)
    }

    @objc private func stopSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        SessionManager.shared.stopSession(id: id)
    }

    @objc private func startSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Task { try? await SessionManager.shared.startSession(id: id) }
    }

    @objc private func closeSession(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }

        let alert = NSAlert()
        alert.messageText = "세션 종료"
        alert.informativeText = "세션을 종료하시겠습니까?\n이 작업은 실행중인 CLI 프로세스도 함께 종료합니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "종료")
        alert.addButton(withTitle: "취소")
        alert.buttons.first?.hasDestructiveAction = true

        if alert.runModal() == .alertFirstButtonReturn {
            SessionManager.shared.deleteSession(id: sessionId)
        }
    }

    @objc private func newSession() {
        appDelegate?.showNewSession()
    }

    @objc private func openWindow() {
        appDelegate?.showWindow()
    }

    @objc private func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: AppDelegate.openSettingsRequested, object: "menubar")
    }

    @objc private func quitApp() {
        appDelegate?.reallyQuit()
    }
}
