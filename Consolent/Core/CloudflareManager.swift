import Foundation

/// Cloudflare Quick Tunnel 관리자.
/// cloudflared를 백그라운드로 실행해 로컬 API 서버를 외부에 노출한다.
final class CloudflareManager: ObservableObject {

    enum TunnelState: Equatable {
        case idle
        case installing
        case starting
        case running(url: String)
        case error(String)
    }

    @Published private(set) var tunnelState: TunnelState = .idle

    #if DEBUG
    func setTunnelStateForTesting(_ state: TunnelState) { tunnelState = state }
    #endif

    var tunnelURL: String? {
        if case .running(let url) = tunnelState { return url }
        return nil
    }

    private var process: Process?

    // MARK: - Public

    func start(port: Int) async {
        guard case .idle = tunnelState else { return }
        setMainState(.starting)

        do {
            let cfPath = try await ensureInstalled()
            startProcess(executablePath: cfPath, port: port)
        } catch {
            setMainState(.error(error.localizedDescription))
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        setMainState(.idle)
        print("[Cloudflare] 터널 중지됨")
    }

    // MARK: - Private

    private func setMainState(_ state: TunnelState) {
        if Thread.isMainThread {
            tunnelState = state
        } else {
            DispatchQueue.main.async { self.tunnelState = state }
        }
    }

    private func ensureInstalled() async throws -> String {
        let candidates = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        // which 로 찾기
        let found = (try? await shellOutput("/usr/bin/which", ["cloudflared"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !found.isEmpty { return found }

        // Homebrew로 설치
        setMainState(.installing)
        print("[Cloudflare] cloudflared 미설치 → brew install cloudflared 실행 중...")

        let brew = try findBrew()
        try await shellWait(brew, ["install", "cloudflared"])

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw CloudflareError.installFailed
    }

    private func findBrew() throws -> String {
        let paths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw CloudflareError.brewNotFound
    }

    private func startProcess(executablePath: String, port: Int) {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: executablePath)
        p.arguments = ["tunnel", "--no-autoupdate", "--url", "http://localhost:\(port)"]
        p.standardOutput = pipe
        p.standardError = pipe
        process = p

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            if let url = Self.parseTunnelURL(from: text) {
                self.setMainState(.running(url: url))
                print("[Cloudflare] 터널 URL 획득: \(url)")
            }
        }

        p.terminationHandler = { [weak self] _ in
            self?.setMainState(.idle)
            self?.process = nil
        }

        do {
            try p.run()
            print("[Cloudflare] 프로세스 시작 (→ http://localhost:\(port))")
        } catch {
            setMainState(.error("실행 실패: \(error.localizedDescription)"))
        }
    }

    static func parseTunnelURL(from text: String) -> String? {
        let pattern = #"https://[a-z0-9\-]+\.trycloudflare\.com"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }

    // MARK: - Shell 헬퍼

    private func shellOutput(_ path: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            let out = Pipe()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardOutput = out
            p.standardError = Pipe()
            p.terminationHandler = { _ in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    private func shellWait(_ path: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            p.terminationHandler = { proc in
                proc.terminationStatus == 0
                    ? cont.resume()
                    : cont.resume(throwing: CloudflareError.installFailed)
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

// MARK: - 에러 타입

enum CloudflareError: LocalizedError {
    case brewNotFound
    case installFailed

    var errorDescription: String? {
        switch self {
        case .brewNotFound:
            return "Homebrew가 설치되어 있지 않습니다. https://brew.sh 에서 설치 후 재시도하세요."
        case .installFailed:
            return "cloudflared 설치에 실패했습니다."
        }
    }
}
