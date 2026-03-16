import Foundation
import Darwin

/// PTY 기반 프로세스 관리자.
/// forkpty()로 가상 터미널을 생성하고 claude CLI를 실행한다.
/// Claude Code 입장에서는 사람이 타이핑하는 것과 100% 동일하게 보인다.
final class PTYProcess: @unchecked Sendable {

    // MARK: - Types

    enum State: Sendable {
        case idle
        case running
        case terminated(Int32)  // exit code
    }

    // MARK: - Properties

    private(set) var pid: pid_t = -1
    private(set) var masterFd: Int32 = -1
    private(set) var state: State = .idle

    var onOutput: ((Data) -> Void)?
    var onStateChange: ((State) -> Void)?

    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.consolent.pty", qos: .userInteractive)
    private var waitSource: DispatchSourceProcess?

    // MARK: - Lifecycle

    /// PTY를 생성하고 프로세스를 시작한다.
    /// - Parameters:
    ///   - executable: 실행할 프로그램 경로 (e.g. "/bin/zsh")
    ///   - args: 프로그램 인자
    ///   - cwd: 작업 디렉토리
    ///   - env: 환경 변수 (nil이면 현재 환경 상속)
    ///   - cols: 터미널 컬럼 수
    ///   - rows: 터미널 행 수
    func start(
        executable: String,
        args: [String],
        cwd: String,
        env: [String: String]? = nil,
        cols: UInt16 = 120,
        rows: UInt16 = 40
    ) throws {
        guard case .idle = state else {
            throw PTYError.alreadyRunning
        }

        var winSize = winsize(
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        // fork 전에 환경 변수와 인자를 준비 (Foundation API는 fork 후 자식에서 사용 불가)
        let cEnviron = buildEnvironment(base: env)
        let cArgs = buildCArgs(executable: executable, args: args)

        var masterFd: Int32 = 0
        let pid = forkpty(&masterFd, nil, nil, &winSize)

        if pid < 0 {
            // fork 실패 시 메모리 정리
            cArgs.forEach { $0?.deallocate() }
            cEnviron.forEach { $0?.deallocate() }
            throw PTYError.forkFailed(errno: errno)
        }

        if pid == 0 {
            // ── Child process ──
            // chdir
            if chdir(cwd) != 0 {
                _exit(1)
            }

            execve(executable, cArgs, cEnviron)
            // execve가 실패한 경우
            _exit(127)
        }

        // ── Parent process ── 메모리 정리 (execve 성공 시 자식은 이미 교체됨)
        cArgs.forEach { $0?.deallocate() }
        cEnviron.forEach { $0?.deallocate() }

        // ── Parent process ──
        self.pid = pid
        self.masterFd = masterFd
        self.state = .running
        onStateChange?(.running)

        // PTY 출력 읽기 시작
        startReading()

        // 프로세스 종료 감시
        startWaiting()
    }

    /// PTY에 데이터를 쓴다 (키보드 입력 시뮬레이션).
    func write(_ data: Data) throws {
        guard case .running = state else {
            throw PTYError.notRunning
        }
        try data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            let written = Darwin.write(masterFd, ptr, data.count)
            if written < 0 {
                throw PTYError.writeFailed(errno: errno)
            }
        }
    }

    /// 문자열을 PTY에 쓴다.
    func write(_ string: String) throws {
        guard let data = string.data(using: .utf8) else { return }
        try write(data)
    }

    /// 터미널 크기를 변경한다.
    func resize(cols: UInt16, rows: UInt16) {
        guard case .running = state else { return }
        var winSize = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFd, TIOCSWINSZ, &winSize)
    }

    /// 프로세스를 종료한다.
    func terminate() {
        guard case .running = state else { return }

        // 먼저 SIGTERM
        kill(pid, SIGTERM)

        // 1초 후에도 살아있으면 SIGKILL
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, case .running = self.state else { return }
            kill(self.pid, SIGKILL)
        }
    }

    /// 시그널을 보낸다 (e.g. SIGINT for Ctrl+C).
    func sendSignal(_ signal: Int32) {
        guard case .running = state else { return }
        kill(pid, signal)
    }

    deinit {
        readSource?.cancel()
        waitSource?.cancel()
        if masterFd >= 0 {
            close(masterFd)
        }
    }

    // MARK: - Private

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFd, queue: queue)

        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let bytesRead = read(self.masterFd, &buffer, buffer.count)

            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                DispatchQueue.main.async {
                    self.onOutput?(data)
                }
            } else if bytesRead <= 0 {
                source.cancel()
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.masterFd >= 0 {
                close(self.masterFd)
                self.masterFd = -1
            }
        }

        source.resume()
        self.readSource = source
    }

    private func startWaiting() {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)

        source.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(self.pid, &status, 0)
            let exited = (status & 0x7f) == 0
            let exitCode: Int32 = exited ? ((status >> 8) & 0xff) : -1

            DispatchQueue.main.async {
                self.state = .terminated(exitCode)
                self.onStateChange?(.terminated(exitCode))
            }
            source.cancel()
        }

        source.resume()
        self.waitSource = source
    }

    private func buildCArgs(executable: String, args: [String]) -> [UnsafeMutablePointer<CChar>?] {
        var cArgs: [UnsafeMutablePointer<CChar>?] = []
        cArgs.append(strdup(executable))
        for arg in args {
            cArgs.append(strdup(arg))
        }
        cArgs.append(nil)
        return cArgs
    }

    private func buildEnvironment(base: [String: String]?) -> [UnsafeMutablePointer<CChar>?] {
        var envDict: [String: String] = [:]

        // login shell의 전체 환경 캡처 (캐시된 결과 사용)
        let loginEnv = Self.captureLoginShellEnvironment()
        if !loginEnv.isEmpty {
            envDict = loginEnv
        } else {
            // 폴백: 현재 프로세스 환경 복사
            var current = environ
            while let envp = current.pointee {
                let str = String(cString: envp)
                if let eqIdx = str.firstIndex(of: "=") {
                    let key = String(str[str.startIndex..<eqIdx])
                    let value = String(str[str.index(after: eqIdx)...])
                    envDict[key] = value
                }
                current = current.advanced(by: 1)
            }
        }

        // 기본 터미널 설정
        envDict["TERM"] = "xterm-256color"
        envDict["COLORTERM"] = "truecolor"
        envDict["LANG"] = envDict["LANG"] ?? "en_US.UTF-8"

        // 사용자 지정 환경 변수 오버라이드
        if let base {
            for (key, value) in base {
                envDict[key] = value
            }
        }

        var cEnv: [UnsafeMutablePointer<CChar>?] = []
        for (key, value) in envDict {
            cEnv.append(strdup("\(key)=\(value)"))
        }
        cEnv.append(nil)
        return cEnv
    }

    /// 사용자 login shell의 전체 환경 변수를 캡처한다.
    /// macOS 앱(.app)은 최소 환경으로 시작되므로, login shell을 한 번 실행하여
    /// nvm, Homebrew 등 사용자 환경을 가져온다. 결과를 캐시.
    private static var cachedLoginEnv: [String: String]?
    private static let envLock = NSLock()

    private static func captureLoginShellEnvironment() -> [String: String] {
        envLock.lock()
        defer { envLock.unlock() }

        if let cached = cachedLoginEnv {
            return cached
        }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: shell)
        // -li: login + interactive. interactive 플래그가 있어야 .zshrc가 소스되어
        // nvm, Homebrew 등 사용자 PATH 설정을 모두 캡처할 수 있다.
        // (macOS에서 많은 사용자가 PATH를 .zshrc에 설정)
        process.arguments = ["-li", "-c", "env"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8),
                  process.terminationStatus == 0 else {
                cachedLoginEnv = [:]
                return [:]
            }

            var envDict: [String: String] = [:]
            for line in output.components(separatedBy: "\n") {
                if let eqIdx = line.firstIndex(of: "=") {
                    let key = String(line[line.startIndex..<eqIdx])
                    let value = String(line[line.index(after: eqIdx)...])
                    envDict[key] = value
                }
            }

            cachedLoginEnv = envDict
            return envDict
        } catch {
            cachedLoginEnv = [:]
            return [:]
        }
    }
}

// MARK: - Errors

enum PTYError: LocalizedError {
    case alreadyRunning
    case notRunning
    case forkFailed(errno: Int32)
    case writeFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "Process is already running"
        case .notRunning: return "Process is not running"
        case .forkFailed(let e): return "forkpty() failed: \(String(cString: strerror(e)))"
        case .writeFailed(let e): return "write() failed: \(String(cString: strerror(e)))"
        }
    }
}
