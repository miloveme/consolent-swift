# CLAUDE.md

## Project Overview

**Consolent** — macOS 네이티브 앱. AI 코딩 CLI 도구(Claude Code, Gemini CLI, Codex)를 헤드리스 터미널(PTY)에서 구동하고, OpenAI 호환 HTTP/WebSocket API로 노출한다.

- Bundle ID: `com.consolent.app`
- macOS 14.0+, Swift 5.10
- 빌드: XcodeGen (`project.yml`) + SPM (Vapor, SwiftTerm)
- 버전: `project.yml`의 `MARKETING_VERSION`

## Build & Test

```bash
# 프로젝트 생성 (최초 1회)
./setup.sh

# 빌드
xcodebuild build -project Consolent.xcodeproj -scheme Consolent -destination 'platform=macOS,arch=arm64'

# 유닛 테스트
xcodebuild test -project Consolent.xcodeproj -scheme Consolent -destination 'platform=macOS,arch=arm64'

# 통합 테스트 (앱 실행 상태에서)
./tests/api_test.sh
```

## Architecture

```
Consolent/
├── App/              # SwiftUI 진입점
├── Core/
│   ├── CLIAdapter.swift      # CLI 어댑터 프로토콜 + CLIType enum
│   ├── Session.swift         # PTY + 헤드리스 터미널 + 파서 관리
│   ├── SessionManager.swift  # 전체 세션 관리 (싱글턴)
│   ├── OutputParser.swift    # ANSI 파싱, 완료 감지 (흐름만)
│   ├── PTYProcess.swift      # forkpty() 래퍼
│   ├── CJKSpacingFix.swift   # CJK wide char 패딩 보정
│   └── Adapters/
│       ├── ClaudeCodeAdapter.swift  # Claude Code TUI 패턴
│       ├── GeminiAdapter.swift      # Gemini CLI TUI 패턴
│       └── CodexAdapter.swift       # Codex (stub)
├── API/
│   ├── APIServer.swift          # Vapor HTTP/WebSocket 서버
│   └── APIAuthMiddleware.swift  # Bearer 토큰 인증
├── Views/            # SwiftUI 뷰
└── Config/           # AppConfig (JSON 영속화)
```

## Key Design Principles

### CLI 어댑터 격리 (중요)

각 CLI(Claude Code, Gemini, Codex)의 터미널 출력은 완전히 다르다. **판단 로직은 반드시 각 어댑터 내부에서 처리**한다.

- `OutputParser`는 **흐름(flow)만** 관리: idle timer → `adapter.isResponseComplete()` 호출
- **화면 내용 판단**은 각 `CLIAdapter` 구현체가 담당
- 한 CLI 수정 시 **다른 CLI 코드를 절대 건드리지 않는다**
- 공용 코드(OutputParser, Session 등) 변경 시 모든 CLI 테스트 통과 확인 필수

### 완료 감지 흐름

1. 메시지 전송 → `startMonitoring()`
2. PTY 출력마다 → idle timer 리셋 (처리 중이면 TUI 스피너가 출력을 계속 생성)
3. 출력 멈춤 (idle 2초) → `adapter.isResponseComplete(screenBuffer:)` 확인
4. 완료면 → 응답 수집, 아니면 → timer 재시작
5. 안전망: 600초 절대 타임아웃

### CLIAdapter 프로토콜 핵심 메서드

| 메서드 | 역할 |
|--------|------|
| `readySignal` | CLI 준비 상태 문자열 |
| `processingSignal` | 처리 중 표시 (regex) |
| `hasProcessingStarted(screenBuffer:)` | 처리 시작 여부 판단 |
| `isResponseComplete(screenBuffer:)` | 응답 완료 여부 판단 |
| `cleanResponse(_:)` | 화면 텍스트에서 응답 본문 추출 |
| `approvalPatterns` | 승인 프롬프트 regex 패턴 |

## Conventions

- 코드 주석/커밋 메시지: 한국어
- 새 CLI 지원 = 새 어댑터 파일 1개 (`Adapters/` 아래)
- 테스트 파일: `ConsolentTests/{AdapterName}Tests.swift`
