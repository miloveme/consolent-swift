import XCTest
@testable import Consolent

final class CloudflareManagerTests: XCTestCase {

    // MARK: - TunnelState

    func testTunnelState_initiallyIdle() {
        let manager = CloudflareManager()
        XCTAssertEqual(manager.tunnelState, .idle)
    }

    func testTunnelURL_nilWhenIdle() {
        let manager = CloudflareManager()
        XCTAssertNil(manager.tunnelURL)
    }

    func testTunnelURL_returnsURLWhenRunning() {
        let manager = CloudflareManager()
        manager.setTunnelStateForTesting(.running(url: "https://test-abc.trycloudflare.com"))
        XCTAssertEqual(manager.tunnelURL, "https://test-abc.trycloudflare.com")
    }

    func testTunnelURL_nilWhenError() {
        let manager = CloudflareManager()
        manager.setTunnelStateForTesting(.error("something failed"))
        XCTAssertNil(manager.tunnelURL)
    }

    func testTunnelURL_nilWhenStarting() {
        let manager = CloudflareManager()
        manager.setTunnelStateForTesting(.starting)
        XCTAssertNil(manager.tunnelURL)
    }

    func testTunnelURL_nilWhenInstalling() {
        let manager = CloudflareManager()
        manager.setTunnelStateForTesting(.installing)
        XCTAssertNil(manager.tunnelURL)
    }

    // MARK: - Stop

    func testStop_resetsToIdle() {
        let manager = CloudflareManager()
        manager.setTunnelStateForTesting(.running(url: "https://x.trycloudflare.com"))
        manager.stop()
        XCTAssertEqual(manager.tunnelState, .idle)
        XCTAssertNil(manager.tunnelURL)
    }

    func testStop_idempotent() {
        let manager = CloudflareManager()
        manager.stop()
        manager.stop()
        XCTAssertEqual(manager.tunnelState, .idle)
    }

    // MARK: - parseTunnelURL

    func testParseTunnelURL_validOutput() {
        let output = """
        2024/01/01 00:00:00 INF +---------------------------------------------------+
        2024/01/01 00:00:00 INF |  Your quick Tunnel has been created! Visit it at  |
        2024/01/01 00:00:00 INF |  https://my-cool-tunnel.trycloudflare.com          |
        2024/01/01 00:00:00 INF +---------------------------------------------------+
        """
        let url = CloudflareManager.parseTunnelURL(from: output)
        XCTAssertEqual(url, "https://my-cool-tunnel.trycloudflare.com")
    }

    func testParseTunnelURL_realWorldFormat() {
        let output = "2026-03-16T23:06:08Z INF Registered tunnel connection url=https://considering-cotton-seafood-peninsula.trycloudflare.com"
        let url = CloudflareManager.parseTunnelURL(from: output)
        XCTAssertEqual(url, "https://considering-cotton-seafood-peninsula.trycloudflare.com")
    }

    func testParseTunnelURL_noURL() {
        let output = "2024/01/01 Starting cloudflared..."
        XCTAssertNil(CloudflareManager.parseTunnelURL(from: output))
    }

    func testParseTunnelURL_emptyString() {
        XCTAssertNil(CloudflareManager.parseTunnelURL(from: ""))
    }

    func testParseTunnelURL_nonTrycloudflareURL() {
        let output = "https://example.com is not a tunnel"
        XCTAssertNil(CloudflareManager.parseTunnelURL(from: output))
    }

    func testParseTunnelURL_multipleURLs_returnsFirst() {
        let output = """
        https://first-tunnel.trycloudflare.com
        https://second-tunnel.trycloudflare.com
        """
        let url = CloudflareManager.parseTunnelURL(from: output)
        XCTAssertEqual(url, "https://first-tunnel.trycloudflare.com")
    }

    // MARK: - TunnelState Equatable

    func testTunnelState_equality() {
        XCTAssertEqual(CloudflareManager.TunnelState.idle, .idle)
        XCTAssertEqual(CloudflareManager.TunnelState.installing, .installing)
        XCTAssertEqual(CloudflareManager.TunnelState.starting, .starting)
        XCTAssertEqual(
            CloudflareManager.TunnelState.running(url: "https://a.trycloudflare.com"),
            .running(url: "https://a.trycloudflare.com")
        )
        XCTAssertEqual(
            CloudflareManager.TunnelState.error("x"),
            .error("x")
        )
        XCTAssertNotEqual(CloudflareManager.TunnelState.idle, .starting)
        XCTAssertNotEqual(
            CloudflareManager.TunnelState.running(url: "https://a.trycloudflare.com"),
            .running(url: "https://b.trycloudflare.com")
        )
    }

    // MARK: - CloudflareError

    func testCloudflareError_descriptions() {
        XCTAssertNotNil(CloudflareError.brewNotFound.errorDescription)
        XCTAssertNotNil(CloudflareError.installFailed.errorDescription)
        XCTAssertTrue(CloudflareError.brewNotFound.errorDescription!.contains("Homebrew"))
        XCTAssertTrue(CloudflareError.installFailed.errorDescription!.contains("cloudflared"))
    }
}
