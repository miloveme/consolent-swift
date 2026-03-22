import AppKit
import Combine

/// 메뉴바 아이콘과 드롭다운 메뉴를 관리한다.
/// SessionManager를 구독하여 세션 목록을 실시간 반영한다.
/// 서버-세션 간 색상 매핑으로 시각적 연결을 제공한다.
final class StatusBarController: NSObject, NSMenuDelegate {

    private var statusItem: NSStatusItem
    private let menu = NSMenu()
    private weak var appDelegate: AppDelegate?

    /// API 서버 색상 (고정)
    private let apiServerColor = NSColor.systemBlue

    /// 채널 서버 색상 팔레트 (순환 할당)
    private let channelColors: [NSColor] = [
        .systemGreen, .systemOrange, .systemPurple,
        .systemTeal, .systemPink, .systemYellow
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

    /// 메뉴가 열릴 때마다 최신 상태로 재구성
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

        let channelSessions = activeSessions.filter { $0.isChannelMode }

        // 채널 세션 ID → 색상 매핑 (생성 순서대로 색상 할당)
        var channelColorMap: [String: NSColor] = [:]
        for (index, session) in channelSessions.enumerated() {
            channelColorMap[session.id] = channelColors[index % channelColors.count]
        }

        // ── API Server ──
        addSectionHeader("API Server", font: sectionFont)

        let apiUrl = "http://\(config.apiBind):\(config.apiPort)"
        addColoredItem("  \(apiUrl)", color: apiServerColor, font: itemFont,
                       action: #selector(copyToPasteboard(_:)), representedObject: apiUrl,
                       toolTip: "클릭하여 복사")

        // ── Channel Server (URL만 표시, 세션명 제거) ──
        if !channelSessions.isEmpty {
            menu.addItem(NSMenuItem.separator())
            addSectionHeader("Channel Server", font: sectionFont)

            for session in channelSessions {
                guard let url = session.channelServerURL else { continue }
                let color = channelColorMap[session.id] ?? .secondaryLabelColor
                addColoredItem("  \(url)", color: color, font: itemFont,
                               action: #selector(copyToPasteboard(_:)), representedObject: url,
                               toolTip: "클릭하여 복사")
            }
        }

        // ── API Key ──
        menu.addItem(NSMenuItem.separator())

        // Consolent API Key (API Server 색상)
        let keyItem = NSMenuItem(title: "", action: #selector(copyApiKey), keyEquivalent: "")
        keyItem.target = self
        keyItem.image = NSImage(systemSymbolName: "key", accessibilityDescription: nil)
        keyItem.attributedTitle = NSAttributedString(string: "API Key", attributes: [
            .font: itemFont,
            .foregroundColor: apiServerColor
        ])
        keyItem.toolTip = "Consolent API Key 복사"
        menu.addItem(keyItem)

        // 채널 서버별 API Key (각 채널 색상, Consolent 키와 다른 경우만 표시)
        let channelKeys = readChannelApiKeys()
        let consolentKey = config.apiKey
        for session in channelSessions {
            let serverName = session.config.channelServerName
            guard let channelKey = channelKeys[serverName],
                  !channelKey.isEmpty,
                  channelKey != consolentKey else { continue }

            let color = channelColorMap[session.id] ?? .secondaryLabelColor
            let item = NSMenuItem(title: "", action: #selector(copyToPasteboard(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = channelKey
            item.image = NSImage(systemSymbolName: "key", accessibilityDescription: nil)
            item.attributedTitle = NSAttributedString(string: "\(session.name) Key", attributes: [
                .font: itemFont,
                .foregroundColor: color
            ])
            item.toolTip = "채널 서버 API Key 복사"
            menu.addItem(item)
        }

        // ── 세션 목록 (서버 색상으로 구분) ──
        menu.addItem(NSMenuItem.separator())

        if activeSessions.isEmpty {
            let emptyItem = NSMenuItem(title: "세션 없음", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            addSectionHeader("Sessions (\(activeSessions.count))", font: sectionFont)

            for session in activeSessions {
                let statusDot: String
                switch session.status {
                case .ready:       statusDot = session.isChannelMode ? "⚡" : "●"
                case .busy:        statusDot = "◉"
                case .initializing: statusDot = "○"
                case .error:       statusDot = "✕"
                case .waitingApproval: statusDot = "⏸"
                case .terminated:  statusDot = "◌"
                }

                let title = "  \(statusDot) \(session.name)  [\(session.status.rawValue)]"

                // 채널 세션 → 해당 채널 색상, 일반 세션 → API 서버 색상
                let color = channelColorMap[session.id] ?? apiServerColor

                let item = NSMenuItem(title: title, action: #selector(selectSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = session.id
                item.attributedTitle = NSAttributedString(string: title, attributes: [
                    .font: itemFont,
                    .foregroundColor: color
                ])

                // 서브메뉴: 세션 닫기
                let sub = NSMenu()
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

    // MARK: - 메뉴 헬퍼

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

    private func addColoredItem(_ title: String, color: NSColor, font: NSFont,
                                action: Selector, representedObject: Any?, toolTip: String?) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        item.toolTip = toolTip
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: color
        ])
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

    /// ~/.claude.json에서 MCP 서버별 OPENAI_COMPAT_API_KEY를 읽는다.
    /// 반환: [서버이름: API키]
    private func readChannelApiKeys() -> [String: String] {
        let path = NSHomeDirectory() + "/.claude.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcpServers = json["mcpServers"] as? [String: Any] else {
            return [:]
        }

        var result: [String: String] = [:]
        for (name, value) in mcpServers {
            guard let serverConfig = value as? [String: Any],
                  let env = serverConfig["env"] as? [String: Any],
                  let apiKey = env["OPENAI_COMPAT_API_KEY"] as? String else { continue }
            result[name] = apiKey
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

    @objc private func closeSession(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }

        let alert = NSAlert()
        alert.messageText = "세션 종료"
        alert.informativeText = "세션을 종료하시겠습니까?\n이 작업은 실행중인 CLI 프로세스도 함께 종료합니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "종료")
        alert.addButton(withTitle: "취소")
        // "종료" 버튼을 빨간색으로
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
        // 메인 윈도우 없이 설정 윈도우만 열기, 메뉴바 근처 배치
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: AppDelegate.openSettingsRequested, object: "menubar")
    }

    @objc private func quitApp() {
        appDelegate?.reallyQuit()
    }
}
