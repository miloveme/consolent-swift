import Vapor

/// Bearer 토큰 인증 미들웨어.
/// Consolent API 자체의 접근 통제 (Claude 인증과 무관).
struct APIAuthMiddleware: AsyncMiddleware {

    let apiKey: String

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        // Authorization: Bearer <key>
        guard let authHeader = request.headers[.authorization].first else {
            throw Abort(.unauthorized, reason: "Missing Authorization header")
        }

        let parts = authHeader.split(separator: " ", maxSplits: 1)
        guard parts.count == 2,
              parts[0].lowercased() == "bearer",
              String(parts[1]) == apiKey else {
            throw Abort(.unauthorized, reason: "Invalid API key")
        }

        return try await next.respond(to: request)
    }
}
