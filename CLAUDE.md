# CLAUDE.md

## Project Overview

**Consolent** — macOS 네이티브 앱. AI 코딩 CLI 도구(Claude Code, Gemini CLI, Codex)를 헤드리스 터미널(PTY)에서 구동하고, OpenAI 호환 HTTP/WebSocket API로 노출한다.

- Bundle ID: `com.consolent.app`
- macOS 14.0+, Swift 5.10
- 빌드: XcodeGen (`project.yml`) + SPM (Vapor, SwiftTerm)
- 버전: `project.yml`의 `MARKETING_VERSION` (현재 v0.2.1)
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
│   ├── Session.swift             # PTY + 헤드리스 터미널 + 파서 + 스트리밍 + SDK 모드
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
├── Messenger/
│   ├── MessengerServer.swift        # 메신저 웹훅/폴링 Vapor 서버 (독립, port 8800)
│   ├── MessengerChannel.swift       # 채널 프로토콜 + 메시지 타입 + 팩토리
│   ├── MessageDispatcher.swift      # actor — 큐, 세션 라우팅, typing indicator
│   ├── ConversationStore.swift      # SQLite 대화 히스토리 영속화 (싱글턴)
│   ├── MessengerConfig.swift        # 봇 설정 모델 (messenger.json)
│   └── Channels/
│       └── TelegramChannel.swift    # Telegram Bot API (polling + webhook)
├── Views/
│   ├── ContentView.swift            # 메인 윈도우 (사이드바 + 터미널 + 상태바)
│   ├── SettingsView.swift           # 설정 (일반/서버/터미널/브릿지/메신저 탭)
│   ├── TerminalView.swift           # SwiftTerm 기반 NSViewRepresentable
│   └── ConversationHistoryView.swift # 대화 히스토리 뷰어 (필터/검색)
└── Config/
    └── AppConfig.swift              # JSON 영속화 설정 (자동 저장)
```

### 테스트 파일

```
ConsolentTests/
├── ClaudeCodeAdapterTests.swift  # Claude Code 어댑터 단위 테스트
├── GeminiAdapterTests.swift      # Gemini 어댑터 단위 테스트
├── CodexAdapterTests.swift       # Codex 어댑터 단위 테스트
├── SessionNameTests.swift        # 세션 이름 관리 22개 테스트
├── StreamingTests.swift          # 스트리밍 델타/노이즈 필터링 테스트
├── CloudflareManagerTests.swift  # Cloudflare 터널 테스트
└── SDKSessionTests.swift         # SDK 모드 단위 테스트

tests/
└── api_test.sh                   # 통합 테스트 (멀티 CLI 타입, bash 3.x 호환)

tools/
└── sdk-bridge/
    ├── sdk_bridge.py             # Python SDK 브릿지 서버 (OpenAI 호환 API)
    └── requirements.txt          # Python 의존성 (claude-agent-sdk, aiohttp)
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

### SDK 모드 (Agent SDK 기반)

PTY/TUI 파싱 없이 Claude Agent SDK를 사용하여 안정적인 세션을 제공한다.

1. Consolent이 Python SDK 브릿지 서버(`tools/sdk-bridge/sdk_bridge.py`)를 서브프로세스로 실행
2. 브릿지 서버가 `ClaudeSDKClient`를 사용하여 Claude Code CLI와 stdin/stdout JSON-lines 통신
3. OpenAI 호환 API(`/v1/chat/completions`)를 `http://localhost:<sdkPort>`에서 제공
4. 유저 앱(Cursor 등)이 직접 SDK 서버에 요청 → 빠른 경로 (스트리밍, 이미지 지원)
5. Consolent 터미널에는 요청/응답 로그를 실시간 표시 (기존 UX 유지)
6. Channel 모드와 동일하게 `/v1/chat/completions`에서 410 Gone으로 SDK 서버 URL 안내

**Config 필드**: `sdkEnabled`, `sdkPort`(기본 8788), `sdkModel`, `sdkPermissionMode`

### 메신저 봇 채널

API 서버를 거치지 않고 **MessengerServer가 SessionManager에 직접 연결**하여 메신저 봇 메시지를 처리한다.

```
Telegram (polling/webhook) → MessengerServer (port 8800)
    → MessageDispatcher (actor, chatId별 직렬 큐)
    → SessionManager.shared.getSession(name:)
    → session.sendMessage() 직접 호출 (HTTP 없음)
```

- **MessengerServer**: APIServer와 독립된 Vapor 인스턴스. 봇별 채널 인스턴스 관리.
- **MessageDispatcher**: chatId별 직렬 큐, busy 세션 대기, typing indicator 주기적 갱신.
- **MessengerChannel 프로토콜**: `configure()`, `registerRoutes()`, `parseWebhook()`, `sendReply()`, `startPolling()`, `stopPolling()`
- **다중 봇**: 같은 플랫폼에서 여러 봇 등록 가능 (각각 고유 botId).
- **허용 사용자**: `allowedUserIds`로 화이트리스트 (빈 목록 = 전체 허용).
- **Telegram**: 기본 polling 모드 (터널 불필요), webhook은 옵션.
- **봇↔세션 연결**: `MessengerBotConfig.targetSessionName`으로 봇 설정에서 관리.
- **Config 파일**: `~/Library/Application Support/Consolent/messenger.json`

### 대화 히스토리

모든 세션 대화를 SQLite로 영속화한다.

- **DB 경로**: `~/Library/Application Support/Consolent/conversations.sqlite`
- **저장 경로**: API, MCP, Messenger, SDK 터미널 뷰 (PTY 터미널 직접 입력 제외)
- **source 태그**: 각 메시지에 요청 경로(api/mcp/messenger) 기록
- **ConversationStore**: 싱글턴, `addTurn()`, `getMessages()`, `searchWithFilter()`, `allConversations()`
- **뷰어**: View 메뉴 → "대화 히스토리" (Cmd+Shift+H)
  - 좌측: 대화 목록 + DB 크기 표시
  - 우측: 메시지 목록 (더블 클릭 펼침, 텍스트 선택 복사)
  - 필터: 키워드 + 소스(API/MCP/Messenger) + 역할(사용자/어시스턴트) + 기간

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
4. **PTY 세션 전환 시 스크롤 위치** — alternate buffer 사용 CLI에서 세션 전환 후 스크롤 최상단 이동 현상. PTY resize 시그널로 CLI 리프레시 시도 중.
5. **메신저 플랫폼 확장** — 현재 Telegram만 구현. WhatsApp, LINE, KakaoTalk, iMessage는 `MessengerChannel` 프로토콜 구현체 추가 필요.

## 릴리즈 절차

GitHub 릴리즈 생성 시 **반드시 DMG 파일을 빌드하여 첨부**한다.

```bash
# 1. 버전 업데이트 (project.yml MARKETING_VERSION + CLAUDE.md)

# 2. Release 빌드 + 아카이브
xcodebuild archive \
  -project Consolent.xcodeproj \
  -scheme Consolent \
  -destination 'platform=macOS,arch=arm64' \
  -archivePath build/Consolent.xcarchive

# 3. .app 추출
cp -R build/Consolent.xcarchive/Products/Applications/Consolent.app build/

# 4. DMG 생성
hdiutil create -volname Consolent -srcfolder build/Consolent.app \
  -ov -format UDZO build/Consolent.dmg

# 5. 태그 + 릴리즈 (DMG 첨부)
git tag vX.Y.Z && git push origin vX.Y.Z
gh release create vX.Y.Z build/Consolent.dmg --title "vX.Y.Z" --notes "릴리즈 노트"

# 6. 정리
rm -rf build/
```

## 릴리즈 히스토리

| 버전 | 주요 변경 |
|------|----------|
| v0.2.1 | Gemini 브릿지 system prompt echo 버그 수정, user 입력 echo 필터링 |
| v0.2.0 | MCP 서버 내장 (19개 도구, Streamable HTTP), README 전면 재구성 |
| v0.1.9 | Agent SDK / Gemini Stream / Codex 브릿지 지원, 세션 영속화, 포트 충돌 감지, 자동 강제 복구, 브릿지 인증 강화 |
| v0.1.8 | TUI 노이즈 필터링 강화, 로그 기반 회귀 테스트 인프라, fixture 라이프사이클 관리 |
| v0.1.7 | 모델 기반 세션 라우팅, 터미널 렌더링 수정, UI/UX 개선, CLI별 작업 디렉토리 |
| v0.1.6 | 멀티 어댑터 스트리밍 품질 개선, 응답 파싱 버그 수정 |
| v0.1.5 | SSE 스트리밍 구현, 띄어쓰기 버그 수정, 긴 응답 잘림 수정 |
| v0.1.4 | Cloudflare Quick Tunnel, API 에러 처리 개선 |
