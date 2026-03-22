import AppKit
import Combine

/// 앱 라이프사이클 관리.
/// - Cmd+Q: 윈도우만 숨기고 메뉴바에 유지 (실제 종료는 메뉴바 "종료"에서만)
/// - 메인 윈도우 닫기(빨간 X): 숨기기로 대체 (윈도우 파괴 방지)
/// - 윈도우 숨김 시 .accessory (Dock 제거), 표시 시 .regular (Dock 복원)
/// - TerminalView 비활성화/활성화는 윈도우 가시성에 연동
final class AppDelegate: NSObject, NSApplicationDelegate {

    var statusBarController: StatusBarController?

    /// 메뉴바 "종료"에서만 true로 설정
    var shouldReallyQuit = false

    /// 윈도우 가시성 변화 알림용
    static let windowVisibilityChanged = Notification.Name("ConsolentWindowVisibilityChanged")
    /// 메뉴바에서 "새 세션" 요청
    static let showNewSessionRequested = Notification.Name("ConsolentShowNewSessionRequested")
    /// 메뉴바에서 "설정" 요청
    static let openSettingsRequested = Notification.Name("ConsolentOpenSettingsRequested")

    /// 메인 윈도우 참조 (닫기 방지 + 재표시용)
    private weak var mainWindow: NSWindow?
    /// 메인 윈도우 delegate 프록시 (닫기 → 숨기기 변환, retain 필요)
    private var windowDelegateProxy: MainWindowDelegateProxy?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController(appDelegate: self)

        // 메인 윈도우 캡처 (SwiftUI 윈도우 생성 후)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.captureMainWindow()
        }

        // 메뉴바 모드로 시작 설정 시 윈도우 숨김
        if AppConfig.shared.launchToMenuBar {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.hideWindow()
            }
        }
    }

    /// 메인 윈도우를 찾아 닫기 동작을 숨김으로 변환하는 프록시 설치
    private func captureMainWindow() {
        guard let window = NSApp.windows.first(where: {
            $0.canBecomeMain && !($0 is NSPanel)
        }) else { return }

        mainWindow = window
        // SwiftUI의 기존 delegate를 보존하면서 닫기 동작만 가로채기
        let proxy = MainWindowDelegateProxy()
        proxy.appDelegate = self
        proxy.originalDelegate = window.delegate
        proxy.mainWindow = window
        windowDelegateProxy = proxy
        window.delegate = proxy
    }

    /// Cmd+Q 후킹: 실제 종료 플래그가 없으면 윈도우만 숨긴다.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shouldReallyQuit {
            // 모든 세션 종료
            SessionManager.shared.deleteAllSessions()
            return .terminateNow
        }

        // 윈도우만 숨기고 종료 취소
        hideWindow()
        return .terminateCancel
    }

    /// 실제 종료 (메뉴바 "종료" 메뉴에서 호출)
    func reallyQuit() {
        shouldReallyQuit = true
        NSApp.terminate(nil)
    }

    // MARK: - 윈도우 관리

    func showWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)

        if let window = mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.orderFrontRegardless()
            window.makeKey()
        }

        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.post(name: Self.windowVisibilityChanged, object: true)
    }

    func hideWindow() {
        // 메인 윈도우만 숨기기 (설정 윈도우 등은 건드리지 않음)
        mainWindow?.orderOut(nil)

        // 다른 표시 가능한 메인 윈도우가 없으면 Dock에서 제거
        let hasVisibleMainWindow = NSApp.windows.contains {
            $0.canBecomeMain && $0.isVisible && $0 !== mainWindow
        }
        if !hasVisibleMainWindow {
            NSApp.setActivationPolicy(.accessory)
        }

        NotificationCenter.default.post(name: Self.windowVisibilityChanged, object: false)
    }

    /// 메뉴바에서 "새 세션" 클릭 시
    func showNewSession() {
        showWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: Self.showNewSessionRequested, object: nil)
        }
    }

    /// 메뉴바에서 세션 선택 시
    func selectSession(id: String) {
        SessionManager.shared.selectedSessionId = id
        showWindow()
    }
}

// MARK: - 메인 윈도우 Delegate 프록시

/// SwiftUI의 원본 window delegate를 보존하면서 닫기 동작만 가로챈다.
/// 그 외 모든 delegate 메서드는 원본으로 자동 전달된다.
private final class MainWindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var appDelegate: AppDelegate?
    weak var originalDelegate: NSWindowDelegate?
    weak var mainWindow: NSWindow?

    /// 메인 윈도우 닫기 → 숨기기로 대체 (윈도우 파괴 방지)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === mainWindow {
            appDelegate?.hideWindow()
            return false
        }
        return originalDelegate?.windowShouldClose?(sender) ?? true
    }

    /// 원본 delegate가 응답하는 selector도 프록시가 응답하도록
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return originalDelegate?.responds(to: aSelector) ?? false
    }

    /// 직접 구현하지 않은 메서드는 원본 delegate로 전달
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original = originalDelegate,
           (original as AnyObject).responds(to: aSelector) {
            return original
        }
        return super.forwardingTarget(for: aSelector)
    }
}
