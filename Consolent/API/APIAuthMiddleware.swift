import Vapor

/// Bearer 토큰 인증 미들웨어.
/// Consolent API 자체의 접근 통제 (Claude 인증과 무관).
struct APIAuthMiddleware: AsyncMiddleware {

    let apiKey: String

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        print("[Auth] \(request.method) \(request.url.path)")
        // Authorization: Bearer <key>
        guard let authHeader = request.headers[.authorization].first else {
            print("[Auth] ❌ Authorization 헤더 없음")
            throw Abort(.unauthorized, reason: "Missing Authorization header")
        }

        let parts = authHeader.split(separator: " ", maxSplits: 1)
        guard parts.count == 2,
              parts[0].lowercased() == "bearer",
              String(parts[1]) == apiKey else {
            print("[Auth] ❌ API 키 불일치 (받은 키: \(authHeader.prefix(20))...)")
            throw Abort(.unauthorized, reason: "Invalid API key")
        }

        print("[Auth] ✅ 인증 통과")
        return try await next.respond(to: request)
    }
}
