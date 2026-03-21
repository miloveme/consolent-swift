# CLAUDE.md

## Project Overview

**Consolent** — macOS 네이티브 앱. AI 코딩 CLI 도구(Claude Code, Gemini CLI, Codex)를 헤드리스 터미널(PTY)에서 구동하고, OpenAI 호환 HTTP/WebSocket API로 노출한다.

- Bundle ID: `com.consolent.app`
- macOS 14.0+, Swift 5.10
- 빌드: XcodeGen (`project.yml`) + SPM (Vapor, SwiftTerm)
- 버전: `project.yml`의 `MARKETING_VERSION` (현재 v0.1.7)
- GitHub: `miloveme/consolent-swift`

## Build & Test

```bash
# 프로젝트 생성 (최초 1회)
./setup.sh

# 빌드
xcodebuild build -project Consolent.xcodeproj -scheme Consolent -destination 'platform=macOS,arch=arm64'

# 유닛 테스트
xcodebuild test -project Consolent.xcodeproj -scheme Consolent -destination 'platform=macOS,arch=arm64'

# 통합 테스트 (앱 실행 상태에서, 모든 활성 CLI 타입 자동 테스트)
./tests/api_test.sh
```

## Architecture

```
Consolent/
├── App/
│   └── ConsolentApp.swift        # SwiftUI 진입점, API 서버 초기화
├── Core/
│   ├── CLIAdapter.swift          # CLI 어댑터 프로토콜 + CLIType enum
│   ├── Session.swift             # PTY + 헤드리스 터미널 + 파서 + 스트리밍
│   ├── SessionManager.swift      # 전체 세션 관리 (싱글턴, 이름 기반 조회)
│   ├── OutputParser.swift        # ANSI 파싱, 완료 감지 (흐름만)
│   ├── PTYProcess.swift          # forkpty() 래퍼
│   ├── CloudflareManager.swift   # Cloudflare Quick Tunnel (세션별)
│   ├── CJKSpacingFix.swift       # CJK wide char 패딩 보정
│   └── Adapters/
│       ├── ClaudeCodeAdapter.swift  # Claude Code TUI 패턴
│       ├── GeminiAdapter.swift      # Gemini CLI TUI 패턴
│       └── CodexAdapter.swift       # Codex TUI 패턴
├── API/
│   ├── APIServer.swift           # Vapor HTTP/WebSocket + OpenAI 호환 API
│   └── APIAuthMiddleware.swift   # Bearer 토큰 인증
├── Views/
│   ├── ContentView.swift         # 메인 윈도우 (사이드바 + 터미널 + 상태바)
│   ├── SettingsView.swift        # 설정 (일반/API/터미널 탭)
│   └── TerminalView.swift        # SwiftTerm 기반 NSViewRepresentable
└── Config/
    └── AppConfig.swift           # JSON 영속화 설정 (자동 저장)
```

### 테스트 파일

```
ConsolentTests/
├── ClaudeCodeAdapterTests.swift  # Claude Code 어댑터 단위 테스트
├── GeminiAdapterTests.swift      # Gemini 어댑터 단위 테스트
├── CodexAdapterTests.swift       # Codex 어댑터 단위 테스트
├── SessionNameTests.swift        # 세션 이름 관리 22개 테스트
├── StreamingTests.swift          # 스트리밍 델타/노이즈 필터링 테스트
└── CloudflareManagerTests.swift  # Cloudflare 터널 테스트

tests/
└── api_test.sh                   # 통합 테스트 (멀티 CLI 타입, bash 3.x 호환)
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

### 스트리밍 아키텍처

`sendMessageStreaming()` → 200ms 폴링으로 `pollStreamingDelta()` 호출:

1. **Baseline 추적**: 메시지 전송 시 `streamBaselineText`에 이전 턴 응답을 저장 → 이전 응답이 새 스트리밍 델타로 유출되는 것 방지
2. **Delta 계산**: 현재 cleanResponse를 이전 스냅샷과 비교하여 새로 추가된 부분만 전송
3. **노이즈 필터링**: `filterStreamingNoise()` — ⎿ 도구 출력, 스피너, thinking 인디케이터 제거
4. **어댑터별 이슈 처리**:
   - **Gemini**: 같은 턴 내 ✦ 멀티 섹션(도구 사용 전후) 누적, ▀▀▀/▄▄▄ 블록바로 새 턴 리셋
   - **Codex**: `backupProcessingDetected` 플래그로 빠른 응답 시 이전 응답 복원 방지

### 모델 기반 세션 라우팅 (v0.1.6+)

OpenAI API `model` 필드로 세션을 이름 매칭:

1. 세션에 `name` 부여 (기본값: CLI 타입명 — "claude-code", "gemini", "codex")
2. `POST /v1/chat/completions`의 `model` 필드 → `resolveSession(model:)` → 이름 매칭
3. 매칭 실패 시 기존 defaultSession 폴백 (하위 호환)
4. `GET /v1/models` → 활성 세션 이름 목록 반환
5. 이름 중복 처리: 기본 이름은 자동 번호 부여 (`claude-code-2`), 명시적 이름은 에러

### CLIAdapter 프로토콜 핵심 메서드

| 메서드 | 역할 |
|--------|------|
| `readySignal` | CLI 준비 상태 문자열 |
| `processingSignal` | 처리 중 표시 (regex) |
| `hasProcessingStarted(screenBuffer:)` | 처리 시작 여부 판단 |
| `isResponseComplete(screenBuffer:)` | 응답 완료 여부 판단 |
| `cleanResponse(_:)` | 화면 텍스트에서 응답 본문 추출 |
| `detectError(_:)` | TUI chrome에 가려진 에러 메시지 복구 |
| `approvalPatterns` | 승인 프롬프트 regex 패턴 |

### 터미널 렌더링

- **헤드리스 터미널**: API용 500행 scrollback 터미널 (ANSI 파싱 전용, UI와 분리)
- **UI 터미널**: SwiftTerm TerminalView (세션 전환 시 `outputBuffer` 재주입)
- **suppressSendToPTY**: 버퍼 재주입 시 DA(Device Attributes) 응답이 PTY로 전달되는 것 방지
- **세션 전환 시 빈 화면 방지**: `DispatchQueue.main.async` 지연 + `setNeedsDisplay` 강제 호출

## API 엔드포인트 요약

### Consolent 전용
| 메서드 | 경로 | 설명 |
|--------|------|------|
| POST | `/sessions` | 세션 생성 (name, cliType, cwd, autoApprove) |
| GET | `/sessions` | 전체 세션 목록 |
| GET | `/sessions/:id` | 세션 상태 |
| PATCH | `/sessions/:id` | 세션 이름 변경 |
| DELETE | `/sessions/:id` | 세션 삭제 |
| POST | `/sessions/:id/message` | 동기 메시지 전송 |
| POST | `/sessions/:id/input` | 원시 입력 주입 |
| GET | `/sessions/:id/output` | 버퍼 스냅샷 |
| GET | `/sessions/:id/pending` | 승인 대기 목록 |
| POST | `/sessions/:id/approve/:approvalId` | 승인/거부 |
| WS | `/sessions/:id/stream` | 실시간 출력 스트림 |

### OpenAI 호환
| 메서드 | 경로 | 설명 |
|--------|------|------|
| GET | `/v1/models` | 활성 세션 이름 또는 CLI 타입 목록 |
| POST | `/v1/chat/completions` | 채팅 완성 (model → 세션 이름 매칭, stream 지원) |

## 설정 (AppConfig)

JSON 영속화: `~/Library/Application Support/Consolent/config.json`

- **CLI별 작업 디렉토리**: `cwdPerCliType` — CLI 타입별 독립 디렉토리 설정
- **자동 저장**: `objectWillChange.debounce(500ms)` — 설정 변경 시 자동 저장
- **세션 생성 기본값**: 자동 승인 ON

## Conventions

- 코드 주석/커밋 메시지: 한국어
- 새 CLI 지원 = 새 어댑터 파일 1개 (`Adapters/` 아래)
- 테스트 파일: `ConsolentTests/{AdapterName}Tests.swift`
- Co-Authored-By는 요청 시에만 커밋 메시지에 추가
- 세션 이름 = OpenAI API model ID로 사용

## 알려진 이슈 / 미완료 작업

1. **스트리밍 TUI chrome 노이즈 필터링 강화** — thinking indicator, transient text 등의 필터링 개선 필요. `isThinkingIndicator()`, `matchesTUIChrome()` 확장 계획 있음
2. **긴 응답 스트리밍 조기 종료** — 매우 긴 응답에서 스트리밍이 완료 전에 끊기는 현상
3. **SF Symbol 경고** — `terminal.badge.plus` 시스템 심볼 없음 (빌드 경고)

## 릴리즈 히스토리

| 버전 | 주요 변경 |
|------|----------|
| v0.1.7 | 모델 기반 세션 라우팅, 터미널 렌더링 수정, UI/UX 개선, CLI별 작업 디렉토리 |
| v0.1.6 | 멀티 어댑터 스트리밍 품질 개선, 응답 파싱 버그 수정 |
| v0.1.5 | SSE 스트리밍 구현, 띄어쓰기 버그 수정, 긴 응답 잘림 수정 |
| v0.1.4 | Cloudflare Quick Tunnel, API 에러 처리 개선 |
