# PRD: Consolent — AI Coding CLI PTY API Gateway

> AI 코딩 CLI 도구(Claude Code, Codex, Gemini CLI)를 사람이 타이핑하듯 API로 조작하는 macOS 터미널 앱
> CLI 도구 입장에서는 100% 사람이 쓰는 것과 동일하게 동작한다.

---

## 1. 배경 및 동기

Claude Code, Codex CLI, Gemini CLI 등 터미널 기반 AI 코딩 에이전트는 파일 읽기/쓰기, git, bash 실행 등 에이전트 기능이 통합되어 있어 단순 LLM API 호출과는 차원이 다르다.

**문제:** 이 도구들을 사용하려면 반드시 사람이 터미널 앞에 앉아서 직접 타이핑해야 한다.

**해결:** Consolent은 CLI 도구를 PTY(가상 터미널)에 띄우고, API 요청이 오면 키보드 타이핑처럼 PTY에 입력을 주입한다. 출력은 PTY에서 읽어서 API 응답으로 반환한다. "Playwright for Terminals" — 웹사이트 대신 터미널 TUI를 자동화한다.

### 왜 PTY 방식인가 (SDK가 아닌 이유)

| 항목 | PTY 방식 | SDK 방식 |
|------|----------|----------|
| CLI 도구 관점 | 사람이 쓰는 것과 동일 | 프로그래밍 호출 |
| 과금 | 기존 구독 그대로 | 별도 API 과금 가능성 |
| 기능 범위 | CLI 전체 기능 | SDK가 노출하는 범위만 |
| 인증 | 이미 로그인된 상태 사용 | 별도 API key 필요 |
| 업데이트 대응 | CLI만 업데이트하면 됨 | SDK 버전 호환 관리 필요 |
| 확장성 | Adapter 추가로 새 CLI 지원 | SDK별 개별 통합 필요 |

---

## 2. 제품 정의

**Product Name:** Consolent
**Platform:** macOS native app (SwiftUI + AppKit)
**Target User:** AI 코딩 CLI를 자동화/웹앱/봇에서 사용하려는 개발자

### 핵심 가치
- 코드 변경 없이 AI 코딩 CLI를 OpenAI-호환 API로 노출
- 기존 CLI 구독/인증을 그대로 사용
- 사람이 직접 개입할 수 있는 하이브리드 UX
- 하나의 앱에서 여러 CLI 도구를 동시 운영 (CLIAdapter 패턴)

### 지원 CLI 도구

| CLI 도구 | Adapter | PTY 모드 | 브릿지 모드 |
|----------|---------|---------|------------|
| Claude Code | `ClaudeCodeAdapter` | 완전 구현 | Agent 모드 (`sdk_bridge.py`, Claude Agent SDK) |
| Codex CLI | `CodexAdapter` | 완전 구현 | Codex 브릿지 (`codex_bridge.py`, JSON-RPC) |
| Gemini CLI | `GeminiAdapter` | 완전 구현 | Gemini 브릿지 (`gemini_bridge.py`, `-p` 모드) |

새 CLI 지원 = `CLIAdapter` 프로토콜 구현 1개 추가. 브릿지 모드는 각 CLI의 프로그래밍 인터페이스(SDK/서버 모드)가 있을 때 선택적으로 사용.

---

## 3. 아키텍처

```
외부 클라이언트                     Consolent.app (macOS)
─────────────                  ┌──────────────────────────────────────────┐
                               │                                          │
  웹앱 ──┐                     │  ┌───────────┐    ┌──────────────┐      │
         │    HTTP/WebSocket   │  │ API Server │───▶│ Session Mgr  │      │
  봇   ──┼───────────────────▶ │  │ (Vapor)    │    │              │      │
         │                     │  │            │    └──────┬───────┘      │
  OpenAI │  /v1/chat/          │  │ OpenAI API │          │              │
  Client─┘  completions        │  └───────────┘          │              │
                               │                          │              │
                               │    ┌─────────────────────┼─────┐       │
                               │    │ Session A            │     │       │
                               │    │  ┌──────┐  ┌────────▼──┐ │       │
                               │    │  │ PTY  │──│ claude    │ │       │
                               │    │  └──┬───┘  └───────────┘ │       │
                               │    │     │                      │       │
                               │    │  ┌──▼───────────────────┐ │       │
                               │    │  │ Headless Terminal    │ │       │
                               │    │  │ (SwiftTerm)          │ │       │
                               │    │  │ ANSI 해석 + 버퍼     │ │       │
                               │    │  └──────────┬──────────┘ │       │
                               │    │             │             │       │
                               │    │  ┌──────────▼──────────┐ │       │
                               │    │  │ OutputParser        │ │       │
                               │    │  │ + CLIAdapter        │ │       │
                               │    │  │ (완료감지/파싱/정리) │ │       │
                               │    │  └─────────────────────┘ │       │
                               │    └───────────────────────────┘       │
                               │                                          │
                               │    ┌───────────────────────────┐       │
                               │    │ Session B (codex)          │       │
                               │    │  PTY → codex → Terminal   │       │
                               │    │  + CodexAdapter            │       │
                               │    └───────────────────────────┘       │
                               │                                          │
                               │    ┌──────────────────────────────────┐   │
                               │    │ Session C (claude/agent mode)    │   │
                               │    │  sdk_bridge.py (subprocess)      │   │
                               │    │  Claude Agent SDK ←→ claude CLI  │   │
                               │    │  OpenAI API @ localhost:8788     │   │
                               │    └──────────────────────────────────┘   │
                               │                                            │
                               │    ┌──────────────────────────────────┐   │
                               │    │ Session D (gemini/bridge mode)   │   │
                               │    │  gemini_bridge.py (subprocess)   │   │
                               │    │  gemini -p <prompt>              │   │
                               │    │  OpenAI API @ localhost:<port>   │   │
                               │    └──────────────────────────────────┘   │
                               │                                            │
                               │  ┌─────────────────────────────────┐   │
                               │  │ Terminal UI (모니터링/개입)       │   │
                               │  │ PTY 세션: SwiftTerm 터미널 뷰    │   │
                               │  │ Agent/Bridge 세션: 채팅 버블 UI  │   │
                               │  │ 세션별 사이드바 / CLI 타입별 뱃지 │   │
                               │  └─────────────────────────────────┘   │
                               └──────────────────────────────────────────┘
```

### CLIAdapter 패턴

```swift
protocol CLIAdapter {
    var name: String { get }              // "Claude Code", "Codex", "Gemini"
    var modelId: String { get }           // "claude-code", "codex", "gemini"

    // 바이너리 검색 & 실행
    var defaultBinaryPaths: [String] { get }
    var defaultBinaryName: String { get }
    func findBinaryPath() -> String
    func buildCommand(binaryPath: String, args: [String], autoApprove: Bool) -> String

    // 종료
    var exitCommand: String { get }       // "/exit", "exit", etc.

    // 완료 감지 — CLI TUI별 신호
    var readySignal: String { get }       // "? for shortcuts", ">", etc.
    var processingSignal: String? { get } // "esc to interrupt", etc. (regex)
    func isResponseComplete(screenBuffer: String) -> Bool

    // 응답 텍스트 정리 — CLI TUI 크롬 제거
    func cleanResponse(_ screenText: String) -> String
}
```

**핵심:** 각 CLI 도구의 TUI는 고유한 UI 크롬, 상태 신호, 명령 형식을 가진다. Adapter가 이 차이를 추상화하여 Session/OutputParser는 CLI 종류에 무관하게 동작한다.

### 데이터 흐름 (PTY 모드)

```
1. API 요청 수신
   POST /v1/chat/completions { "messages": [...], "model": "claude-code" }

2. 세션 선택/생성
   → 모델 ID로 적절한 CLIAdapter를 가진 세션 매칭
   → 없으면 자동 생성 또는 에러

3. PTY 입력 주입
   → PTY에 메시지 바이트 쓰기
   → CLI 도구는 키보드 입력으로 인식

4. 헤드리스 터미널 + 완료 감지
   ← PTY 출력 → SwiftTerm 헤드리스 터미널로 ANSI 해석
   ← 스크린 버퍼에서 adapter.readySignal 체크 (빠른 경로)
   ← idle 타이머에서 adapter.isResponseComplete() 체크 (안전 경로)

5. 응답 정리 및 반환
   → adapter.cleanResponse()로 TUI 크롬 제거
   → OpenAI-호환 JSON으로 반환
```

### 데이터 흐름 (Agent / Bridge 모드)

```
1. Consolent이 Python 브릿지 서버를 서브프로세스로 실행
   - Claude Code: sdk_bridge.py --port 8788 --cwd <dir>
   - Gemini: gemini_bridge.py --port <port> --cwd <dir>
   - Codex: codex_bridge.py --port <port> --cwd <dir>

2. 브릿지 서버가 HTTP 먼저 바인딩 → /health = "initializing"
   → CLI 도구 시작 (SDK/subprocess/JSON-RPC)
   → /health = "ready"

3. Consolent이 /health 폴링으로 ready 대기 (최대 30초)

4. 외부 클라이언트가 브릿지 서버에 직접 요청
   POST http://localhost:8788/v1/chat/completions

5. 브릿지 서버가 CLI 도구에 요청 전달 → 응답 수신
   → SSE 스트리밍 또는 JSON 응답 반환

6. 브릿지 서버가 @@CONSOLENT@@{JSON} 프로토콜로 stdout에 이벤트 출력
   → Consolent이 파싱 → SDKTerminalView에 채팅 버블 표시

7. Consolent API로의 요청은 410 Gone + 브릿지 URL 안내
```

### 응답 완료 감지 (2단계 전략)

가장 핵심적인 기술 과제. CLI TUI가 "응답을 다 했는지" 정확히 판단해야 한다.

| 단계 | 시점 | 체크 방법 | 목적 |
|------|------|----------|------|
| Fast Path | 매 PTY 출력 도착 시 | `screenBuffer.contains(readySignal)` | 빠른 완료 감지 |
| Safe Path | idle 1~10초 후 | `adapter.isResponseComplete(screenBuffer)` | 안정적 감지 |
| Timeout | 600초 | 강제 완료 | 안전망 |

**주의:** Fast path에서 `isResponseComplete()` 전체를 호출하면 안 된다. 메시지 전송 직후 readySignal과 processingSignal 모두 없는 전환 구간에서 `!hasProcessing = true`로 오탐이 발생한다. readySignal만 체크해야 한다.

---

## 4. 보안 모델

### 핵심 원칙: Consolent은 중개자가 아니다

```
일반 API 서비스:    Client → API Key → 서비스 서버 → Cloud LLM
Consolent:         Client → Consolent Key → PTY → CLI 도구 → 원격 서버
                                             │
                                    이미 로그인된 로컬 프로세스
```

| 항목 | 설명 |
|------|------|
| CLI 인증 | 불필요. 로컬에서 이미 로그인된 CLI를 그대로 사용 |
| API Key 노출 위험 | 없음. 원격 API key가 통과하지 않음 |
| 과금 | 기존 구독 그대로 (Max, Pro 등) |
| 데이터 경로 | 로컬 → 원격 서버 직통. Consolent은 터미널 I/O만 중계 |
| 권한 범위 | CLI가 접근 가능한 범위 = Consolent 접근 범위 (추가 권한 없음) |
| 네트워크 바인딩 | 기본 127.0.0.1. 외부 노출 없음 |
| Consolent API 인증 | 로컬 생성 Bearer token (`cst_` prefix). 앱 설정에서 관리 |

---

## 5. API 명세

### 5.1 OpenAI-호환 API (Primary)

외부 도구(Cursor, Continue, 커스텀 클라이언트)와의 호환성을 위한 OpenAI 형식 API.

#### 모델 목록
```
GET /v1/models
Authorization: Bearer <consolent-key>

Response: 200
{
  "object": "list",
  "data": [
    {"id": "claude-code", "object": "model", "created": 1710403200, "owned_by": "consolent"},
    {"id": "codex", "object": "model", "created": 1710403200, "owned_by": "consolent"},
    {"id": "gemini", "object": "model", "created": 1710403200, "owned_by": "consolent"}
  ]
}
```

각 등록된 CLIAdapter가 하나의 모델로 노출된다.

#### Chat Completions
```
POST /v1/chat/completions
Authorization: Bearer <consolent-key>

Request:
{
  "messages": [
    {"role": "user", "content": "src/auth.ts 코드 리뷰해줘"}
  ],
  "model": "claude-code",               // CLIAdapter modelId
  "timeout": 300                         // optional, 초. default: 300
}

Response: 200
{
  "id": "chatcmpl-m_x1y2z3",
  "object": "chat.completion",
  "created": 1710403200,
  "model": "claude-code",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "src/auth.ts를 분석해봤습니다..."
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 0,
    "completion_tokens": 0,
    "total_tokens": 0
  }
}
```

**세션 자동 관리 로직:**
1. 기본 세션 ID가 설정되어 있고 해당 세션이 ready → 재사용
2. 앱에서 선택된 세션이 ready → 사용
3. 아무 ready 세션 → 사용
4. 없으면 → 503 Service Unavailable

세션을 재사용하므로 대화 컨텍스트가 유지된다 (stateful).

### 5.2 세션 관리

#### 세션 생성
```
POST /sessions
Authorization: Bearer <consolent-key>

Request:
{
  "working_directory": "/Users/jun/myproject",
  "shell": "/bin/zsh",                          // optional, default: 사용자 기본 셸
  "cli_type": "claude-code",                    // optional, "claude-code" | "codex" | "gemini"
  "cli_args": [],                               // optional, CLI 추가 인자
  "claude_args": [],                            // optional, 하위 호환용 (cli_args 우선)
  "auto_approve": false,                        // optional, Y/n 자동 승인
  "idle_timeout": 3600,                         // optional, 초. 0=무제한
  "env": {"KEY": "value"}                       // optional, 추가 환경변수
}

Response: 201
{
  "session_id": "s_a1b2c3",
  "status": "initializing",
  "created_at": "2026-03-14T10:00:00Z"
}
```

세션 생성 시 내부 동작:
1. `CLIType`에서 `CLIAdapter` 생성
2. `adapter.findBinaryPath()`로 CLI 바이너리 탐색
3. PTY 할당 (`forkpty()`)
4. `adapter.buildCommand()`로 실행 명령 구성
5. 지정된 shell에서 CLI 실행
6. 초기화 완료 대기 (`readySignal` 감지)
7. status → `"ready"`

#### 세션 목록
```
GET /sessions

Response: 200
{
  "sessions": [
    {
      "id": "s_a1b2c3",
      "status": "ready",
      "cli_type": "claude-code",
      "working_directory": "/Users/jun/myproject",
      "created_at": "2026-03-14T10:00:00Z",
      "last_activity": "2026-03-14T10:05:30Z",
      "message_count": 12
    }
  ]
}
```

#### 세션 상태
```
GET /sessions/:id

Response: 200
{
  "id": "s_a1b2c3",
  "status": "ready",
  "cli_type": "claude-code",
  "working_directory": "/Users/jun/myproject",
  "pending_approval": null,
  "stats": {
    "messages_sent": 12,
    "uptime_seconds": 3600
  }
}
```

#### 세션 종료
```
DELETE /sessions/:id

Response: 204
```
→ CLI 프로세스에 `adapter.exitCommand` 입력 후 SIGTERM → SIGKILL

### 5.3 메시지 전송

#### 동기 방식 (응답 완료까지 대기)
```
POST /sessions/:id/message
Authorization: Bearer <consolent-key>

Request:
{
  "text": "src/auth.ts 코드 리뷰해줘. 보안 이슈 중심으로",
  "timeout": 120                                // optional, 초. default: 300
}

Response: 200
{
  "message_id": "m_x1y2z3",
  "response": {
    "text": "src/auth.ts를 분석해봤습니다...",     // TUI 크롬 제거된 순수 텍스트
    "raw": "\u001b[1m분석 결과\u001b[0m...",       // ANSI 포함 원본 (설정에 따라)
    "files_changed": ["src/auth.ts"],            // 감지된 변경 파일 (best-effort)
    "duration_ms": 4500
  }
}
```

**동작 방식:**
1. PTY에 `text + "\n"` 쓰기
2. CLI 도구가 응답 출력 시작
3. 헤드리스 터미널에서 ANSI 해석
4. 완료 감지 (2단계: fast path + safe path)
5. `adapter.cleanResponse()`로 TUI 크롬 제거
6. 수집된 출력을 파싱하여 반환

### 5.4 WebSocket 스트리밍

```
WS /sessions/:id/stream
(연결 시 Authorization header 또는 ?token= query param)

Client → Server (입력):
{ "type": "input", "text": "이 파일 분석해줘" }

Server → Client (실시간 출력):
{ "type": "output", "text": "파일을 읽어보겠습니다..." }
{ "type": "output", "text": "분석 결과:..." }
{ "type": "approval_required", "id": "a_1", "prompt": "Edit src/app.tsx?" }
{ "type": "status", "status": "ready" }

Client → Server (승인 응답):
{ "type": "approve", "id": "a_1", "approved": true }
```

### 5.5 승인 처리 (Approval Handling)

CLI 도구가 파일 수정, 명령 실행 등에서 사용자 확인을 요구할 때:

#### 모드 1: 자동 승인
세션 생성 시 `"auto_approve": true`
- Claude Code: `--dangerously-skip-permissions` 플래그로 실행
- Codex: `--full-auto` 플래그
- Gemini: `-y` 플래그

#### 모드 2: API 폴링
```
GET /sessions/:id/pending

Response: 200
{
  "pending": {
    "id": "a_1",
    "type": "approval",
    "prompt": "Allow Edit to src/app.tsx?",
    "detected_at": "2026-03-14T10:05:30Z"
  }
}
```

```
POST /sessions/:id/approve/:approval_id

Request:
{ "approved": true }        // true = Y, false = N

Response: 200
{ "ok": true }
```

#### 모드 3: Webhook (계획)
세션 생성 시 `"approval_webhook": "https://..."` 지정
```
// Consolent → Webhook POST
{
  "session_id": "s_a1b2c3",
  "approval_id": "a_1",
  "prompt": "Allow Edit to src/app.tsx?"
}

// Webhook 응답
{ "approved": true }
```

### 5.6 Raw 입력 (Low-level)

특수 키 입력이나 직접 바이트 제어가 필요할 때:
```
POST /sessions/:id/input

Request:
{
  "text": "/help\n"                   // 문자열 입력
}
// 또는
{
  "keys": ["ctrl+c"]                  // 특수 키
}

지원 키: ctrl+c, ctrl+d, ctrl+z, ctrl+l, enter, tab, escape, up, down, left, right

Response: 200
{ "ok": true }
```

### 5.7 출력 버퍼 조회

세션의 전체 출력 히스토리를 조회:
```
GET /sessions/:id/output?since=<offset>&limit=<bytes>

Response: 200
{
  "text": "...",
  "raw": "...(ANSI 포함)...",
  "offset": 10240,
  "total_bytes": 52480
}
```

---

## 6. 터미널 UI

### 6.1 메인 윈도우

```
┌───────────────────────────────────────────────────────────┐
│ Consolent                                                  │
├────────────┬──────────────────────────────────────────────│
│ Sessions   │                                              │
│            │  $ claude                                    │
│ ┌────────┐ │  Welcome to Claude Code v1.x                 │
│ │ s_a1   │ │                                              │
│ │Claude ●│ │  > src/auth.ts 코드 리뷰해줘                  │
│ └────────┘ │                                              │
│ ┌────────┐ │  src/auth.ts를 분석해봤습니다.                  │
│ │ s_b2   │ │                                              │
│ │Codex  ○│ │  > _                                         │
│ └────────┘ │                                              │
│            │                                              │
│   [+] [⚙]  │                                              │
│            ├──────────────────────────────────────────────│
│ API:ON 9999│ Status: ready │ Msg: 12 │ Claude Code        │
└────────────┴──────────────────────────────────────────────┘
```

### 6.2 UI 기능

- **사이드바**: 세션 목록, CLI 타입별 뱃지 표시, 상태 인디케이터
- **터미널 영역**: SwiftTerm 기반, 키보드로 직접 타이핑하여 개입 가능
- **상태바**: 세션 상태, 메시지 수, CLI 타입, 승인 버튼
- **새 세션 시트**: CLI 타입 선택 (Claude Code / Codex / Gemini), 작업 디렉토리, 자동 승인
- **설정 윈도우**: API 서버, 세션, CLI, 터미널 설정
- **사용자 가이드**: 내장 도움말 + API 레퍼런스
- **키보드 단축키**: Cmd+T (새 세션), Cmd+W (세션 닫기), Cmd+Shift+[/] (세션 전환)

### 6.3 새 세션 다이얼로그

```
┌─ New Session ──────────────────────┐
│ CLI Type     [Claude Code ▼]       │
│              Claude Code           │
│              Codex CLI             │
│              Gemini CLI            │
│                                    │
│ Working Dir  [~/myproject    ] [📁] │
│ Auto Approve [ ]                   │
│                                    │
│         [Cancel]  [Create]         │
└────────────────────────────────────┘
```

---

## 7. 핵심 기술 과제

### 7.1 응답 완료 감지 (Critical — 해결됨)

**구현된 2단계 전략:**

| 단계 | 트리거 | 체크 내용 | 신뢰도 |
|------|--------|----------|--------|
| Fast Path | 매 PTY 출력 시 | `screenBuffer.contains(adapter.readySignal)` | 높음 |
| Safe Path | idle 1~10초 후 | `adapter.isResponseComplete(screenBuffer)` | 높음 |
| Safety Net | 600초 후 | 강제 완료 | 안전망 |

**CLI별 신호:**

| CLI | readySignal | processingSignal |
|-----|------------|-----------------|
| Claude Code | `"? for shortcuts"` | `"esc to interrupt"` (regex) |
| Codex CLI | `"% left"` | `"esc\\s+to\\s+interrupt"` (regex) |
| Gemini CLI | `"Type your message"` | `"esc\\s+to\\s+cancel"` (regex) |

**구현 핵심:**
- PTY 출력 → SwiftTerm 헤드리스 터미널 → 스크린 버퍼 (500행 × 120열, scrollback 10000행)
- 스크린 버퍼에서 신호 탐색 (raw bytes가 아닌 ANSI 해석 후 텍스트)
- Fast path는 `readySignal`만 체크 (전환 구간 오탐 방지)
- Safe path는 `readySignal || !processingSignal` 전체 로직 사용

### 7.2 TUI 크롬 제거 (Adapter별 구현)

CLI TUI 출력에서 순수 응답 텍스트만 추출해야 한다.

**ClaudeCodeAdapter에서 제거하는 항목:**
- Box 문자: `│ ║ ╭ ╮ ╰ ╯`
- 구분선: `─ ━`
- 스피너: `✳ ◉ ● ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏`
- TUI 상태 텍스트: `"esc to interrupt"`, 토큰 카운트
- 도구 사용 마커: `"⏺ Read..."`, `"⏺ Wrote..."`, `"⏺ Ran..."`
- 빈 프롬프트: 단독 `›` / `>` / `❯` / `$`
- Null/backspace 문자

### 7.3 ANSI 출력 파싱 (4단계)

```
1. 수직 커서 이동 → 줄바꿈으로 변환
2. 수평 커서 이동 → 공백으로 변환
3. 나머지 ANSI escape code 제거
4. 연속 빈 줄 정리
```

### 7.4 승인 프롬프트 감지

```
감지 패턴:
- "(y/n)" / "(Y/n)" / "[y/N]" / "[Y/n]"
- "Do you want to proceed?"
- "Allow .+?"
- "Press Enter to continue"
```

정규식 기반 감지 → 세션 상태 `waiting_approval` 전환 → auto_approve이면 즉시 `y\n` 주입

### 7.5 동시 세션 리소스 관리

각 세션 = 1 PTY + 1 CLI 프로세스 + 1 헤드리스 터미널

| 리소스 | 제한 | 대응 |
|--------|------|------|
| PTY fd | macOS 기본 256개 | 세션 수 상한 설정 (기본 10) |
| 메모리 | CLI 프로세스당 ~200MB | 세션 수에 따른 메모리 모니터링 |
| 출력 버퍼 | 장시간 세션 시 수 GB 가능 | 스크롤백 버퍼 크기 제한 (기본 10MB/세션) |

---

## 8. 설정

### 앱 설정 UI

```
┌─ API Server ───────────────────────────────────┐
│ Enable API Server          [ON]                │
│ Port                       [9999]              │
│ Bind Address               [127.0.0.1 ▼]      │
│   ○ Localhost only (127.0.0.1)                 │
│   ○ LAN (0.0.0.0)                             │
│ API Key                    [cst_a1b2...] [재생성]│
│ Include Raw Output         [ ]                 │
├─ Sessions ─────────────────────────────────────┤
│ Max Concurrent Sessions    [10]                │
│ Idle Timeout (seconds)     [3600]              │
│ Output Buffer per Session  [10 MB]             │
├─ CLI Tool ─────────────────────────────────────┤
│ Default CLI Type           [Claude Code ▼]     │
│ Default Working Dir        [~]                 │
│ Default Shell              [/bin/zsh]          │
│ Prompt Detection Pattern   [> $]               │
├─ Terminal ─────────────────────────────────────┤
│ Font                       [SF Mono, 13pt]     │
│ Theme                      [Dark ▼]            │
│ Scrollback Lines           [10000]             │
└────────────────────────────────────────────────┘
```

### 설정 파일

`~/Library/Application Support/Consolent/config.json`
```json
{
  "apiEnabled": true,
  "apiPort": 9999,
  "apiBind": "127.0.0.1",
  "apiKey": "cst_a1b2c3d4e5f6...",
  "includeRawOutput": false,
  "maxConcurrentSessions": 10,
  "sessionIdleTimeout": 3600,
  "outputBufferMB": 10,
  "defaultCliType": "claude-code",
  "claudePath": "claude",
  "defaultCwd": "~",
  "defaultShell": "/bin/zsh",
  "promptPattern": "^> $",
  "fontFamily": "SF Mono",
  "fontSize": 13,
  "theme": "dark",
  "scrollbackLines": 10000,
  "sdkEnabled": false,
  "sdkPort": 8788,
  "sdkModel": "",
  "sdkPermissionMode": "acceptEdits",
  "sdkVenvPath": "sdk-venv",
  "bridgeLogLevel": "info"
}
```

**브릿지 관련 설정 설명:**

| 항목 | 기본값 | 설명 |
|------|--------|------|
| `sdkEnabled` | `false` | Agent 모드 활성화 여부 (Claude Code 전용) |
| `sdkPort` | `8788` | Agent API 서버 포트 (채널 모드의 8787과 구분) |
| `sdkModel` | `""` | Agent 모드에서 사용할 Claude 모델 ID |
| `sdkPermissionMode` | `acceptEdits` | Agent 모드 권한 모드 |
| `sdkVenvPath` | `sdk-venv` | Python 가상환경 경로 (세 브릿지 공유) |
| `bridgeLogLevel` | `info` | 브릿지 출력 레벨 (`error`/`info`/`debug`) |

---

## 9. 사용 시나리오

### 시나리오 1: OpenAI 호환 클라이언트에서 사용

```bash
# 기존 OpenAI 라이브러리로 즉시 사용 가능
curl http://localhost:9999/v1/chat/completions \
  -H "Authorization: Bearer cst_xxx" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-code",
    "messages": [{"role": "user", "content": "이 프로젝트의 구조 설명해줘"}]
  }' | jq .choices[0].message.content
```

```python
# Python OpenAI SDK로 사용
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:9999/v1",
    api_key="cst_xxx"
)

response = client.chat.completions.create(
    model="claude-code",
    messages=[{"role": "user", "content": "테스트 실패 원인 찾아줘"}]
)
print(response.choices[0].message.content)
```

### 시나리오 2: 멀티 CLI 동시 운영

```bash
# Claude Code 세션 생성
SESSION1=$(curl -s -X POST http://localhost:9999/sessions \
  -H "Authorization: Bearer cst_xxx" \
  -d '{"working_directory": "/repo", "cli_type": "claude-code"}' \
  | jq -r .session_id)

# Codex 세션 생성
SESSION2=$(curl -s -X POST http://localhost:9999/sessions \
  -H "Authorization: Bearer cst_xxx" \
  -d '{"working_directory": "/repo", "cli_type": "codex"}' \
  | jq -r .session_id)

# 같은 작업을 두 CLI에 동시 요청하여 비교
curl -s -X POST "http://localhost:9999/sessions/$SESSION1/message" \
  -H "Authorization: Bearer cst_xxx" \
  -d '{"text": "src/auth.ts 코드 리뷰해줘"}' &

curl -s -X POST "http://localhost:9999/sessions/$SESSION2/message" \
  -H "Authorization: Bearer cst_xxx" \
  -d '{"text": "src/auth.ts 코드 리뷰해줘"}' &

wait
```

### 시나리오 3: WebSocket 실시간 모니터링

```javascript
const ws = new WebSocket(
  "ws://localhost:9999/sessions/s_abc/stream?token=cst_xxx"
);

ws.onmessage = (e) => {
  const data = JSON.parse(e.data);

  switch (data.type) {
    case "output":
      terminal.write(data.text);
      break;
    case "approval_required":
      if (confirm(data.prompt)) {
        ws.send(JSON.stringify({ type: "approve", id: data.id, approved: true }));
      }
      break;
    case "status":
      updateStatusBadge(data.status);
      break;
  }
};

function sendMessage(text) {
  ws.send(JSON.stringify({ type: "input", text }));
}
```

### 시나리오 4: 수동 개입 하이브리드

1. API로 세션 생성 및 작업 지시
2. Consolent UI에서 진행 상황 모니터링
3. CLI가 잘못된 방향으로 가면 UI에서 직접 키보드로 개입
4. 수정 후 다시 API로 후속 작업 지시

---

## 10. 기술 스택

| 컴포넌트 | 기술 | 선정 이유 |
|---------|------|----------|
| App Framework | SwiftUI + AppKit | macOS 네이티브, 시스템 통합 |
| 터미널 렌더링 | SwiftTerm | 순수 Swift, PTY 통합 용이, ANSI 해석 |
| 헤드리스 터미널 | SwiftTerm Terminal | 렌더링 없이 ANSI 해석 + 스크린 버퍼 |
| PTY 관리 | `forkpty()` (POSIX) | 표준 유닉스 가상 터미널 |
| HTTP Server | Vapor (embedded) | Swift 네이티브, WebSocket 내장 |
| WebSocket | Vapor WebSocket | HTTP 서버와 통합 |
| 출력 파싱 | 자체 구현 (Swift) | 4단계 ANSI strip + 정규식 + Adapter별 크롬 제거 |
| 설정 저장 | JSON file | 간단하고 사람이 편집 가능 |

---

## 11. 프로젝트 구조

```
Consolent/
├── App/
│   └── ConsolentApp.swift          # SwiftUI 진입점, 메뉴 커맨드
├── Core/
│   ├── CLIAdapter.swift            # CLIAdapter 프로토콜 + CLIType 열거형
│   ├── Session.swift               # 세션 (PTY + 터미널 + 파서 + Agent/Bridge 모드)
│   ├── SessionManager.swift        # 전역 세션 매니저 (싱글톤)
│   ├── OutputParser.swift          # ANSI 파싱, 완료 감지, 승인 감지
│   ├── PTYProcess.swift            # forkpty() 래퍼
│   └── Adapters/
│       ├── ClaudeCodeAdapter.swift # Claude Code TUI 전용 구현
│       ├── CodexAdapter.swift      # Codex CLI TUI 구현
│       └── GeminiAdapter.swift     # Gemini CLI TUI 구현
├── API/
│   ├── APIServer.swift             # Vapor HTTP/WS 서버
│   └── APIAuthMiddleware.swift     # Bearer token 인증
├── Views/
│   ├── ContentView.swift           # 메인 윈도우 (사이드바 + 터미널 + 상태바)
│   ├── TerminalView.swift          # SwiftTerm NSViewRepresentable 래퍼 (PTY 세션)
│   ├── SDKTerminalView.swift       # 채팅 버블 UI (Agent/Bridge 세션)
│   ├── SettingsView.swift          # 설정 UI (일반/API/터미널/브릿지 탭)
│   └── HelpView.swift             # 사용자 가이드 + API 레퍼런스
└── Config/
    └── AppConfig.swift             # 설정 관리 (JSON 영속화)

tools/
├── sdk-bridge/
│   ├── sdk_bridge.py              # Claude Agent SDK OpenAI 호환 서버
│   └── requirements.txt           # claude-agent-sdk, aiohttp
├── gemini-bridge/
│   ├── gemini_bridge.py           # Gemini CLI 브릿지 (`gemini -p` 모드)
│   └── requirements.txt           # aiohttp
└── codex-bridge/
    ├── codex_bridge.py            # Codex CLI 브릿지 (JSON-RPC `app-server`)
    └── requirements.txt           # aiohttp

ConsolentTests/
├── ClaudeCodeAdapterTests.swift
├── GeminiAdapterTests.swift
├── CodexAdapterTests.swift
├── SessionNameTests.swift
├── StreamingTests.swift
├── CloudflareManagerTests.swift
└── SDKSessionTests.swift          # Agent 모드 단위 테스트
```

---

## 12. 구현 현황

### v0.1 — MVP

- [x] PTY 관리자: `forkpty()`로 CLI 프로세스 생성/관리
- [x] 기본 터미널 UI: SwiftTerm 기반, 멀티 세션
- [x] 헤드리스 터미널: SwiftTerm Terminal로 ANSI 해석 (렌더링 없이)
- [x] HTTP API: 세션 CRUD (`POST/GET/DELETE /sessions`)
- [x] 동기 메시지: `POST /sessions/:id/message`
- [x] 응답 완료 감지: 2단계 (readySignal fast path + idle safe path)
- [x] ANSI 출력 파싱: 4단계 strip + 정규식
- [x] Bearer token 인증
- [x] localhost 바인딩

### v0.2 — 스트리밍 & 승인 & OpenAI 호환

- [x] WebSocket 스트리밍: `/sessions/:id/stream`
- [x] 승인 프롬프트 감지 및 핸들링 (auto/polling)
- [x] 멀티 세션 (사이드바 UI + 세션별 전환)
- [x] OpenAI-호환 API: `GET /v1/models`, `POST /v1/chat/completions`
- [x] Raw 입력 API: 텍스트 + 특수 키 (ctrl+c, 방향키 등)
- [x] 출력 버퍼 조회 API
- [x] 사용자 가이드 + API 레퍼런스 (내장 HelpView)
- [ ] 비동기 메시지 모드 (`?async=true`)
- [ ] Webhook 승인

### v0.3 — 멀티 CLI 지원 (CLIAdapter)

- [x] CLIAdapter 프로토콜 정의
- [x] CLIType 열거형 (claude-code, codex, gemini)
- [x] ClaudeCodeAdapter: 완전 구현 (바이너리 탐색, 명령 구성, 완료 감지, TUI 크롬 제거)
- [x] CodexAdapter: 완전 구현 (nvm/fnm 경로 탐색, Ratatui TUI 파싱, 플레이스홀더 처리)
- [x] GeminiAdapter: 완전 구현 (다중 ✦ 섹션 누적, tool use 응답 처리)
- [x] Session/OutputParser에 Adapter 통합
- [x] API에 CLI 타입 파라미터 추가 (하위 호환 유지)
- [x] UI에 CLI 타입 선택 추가 (세션 생성, 설정)
- [x] `/v1/models`에 모든 Adapter 노출

### v0.4 — 안정화 & 설정

- [x] 설정 UI (포트, key, 세션 제한, CLI 타입 등)
- [x] 출력 파싱 고도화 (files_changed, TUI 크롬 제거)
- [x] 출력 버퍼 관리 (메모리 제한)
- [ ] idle 세션 자동 정리
- [ ] 비동기 메시지 모드

### v0.5 — SSE 스트리밍 + 안정화

- [x] SSE 스트리밍: `POST /v1/chat/completions` (`stream: true`)
- [x] 200ms 폴링 기반 실시간 delta 전송
- [x] 스트리밍 baseline 체크 (이전 턴 응답 재전송 방지)
- [x] 스트리밍 노이즈 필터 (TUI thinking/spinner 제거)
- [x] Headless terminal scrollback 10000행 (긴 응답 잘림 해결)
- [x] CJK 띄어쓰기 보정 (전 어댑터 `\0` → 공백 변환)
- [x] CodexAdapter 연속 요청 시 이전 응답 재전송 방지 (backupProcessingDetected)
- [x] GeminiAdapter 다중 ✦ 섹션 누적 (tool use 후 응답 누락 해결)
- [x] completeStreamingResponse() delta 일관성 수정
- [ ] idle 세션 자동 정리
- [ ] 비동기 메시지 모드

### v0.1.6~v0.1.7 — 모델 기반 라우팅 + 채널 서버 모드

- [x] 모델 기반 세션 라우팅 (OpenAI `model` 필드 → 세션 이름 매칭)
- [x] 채널 서버 모드 (Claude Code 내 MCP 서버 `@miloveme/claude-code-api`)
- [x] 채널 세션 410 Gone 응답 + 채널 URL 안내
- [x] 세션 이름 관리 (자동 번호 부여, 중복 방지)
- [x] CLI별 작업 디렉토리 설정 (`cwdPerCliType`)
- [x] 터미널 렌더링 안정화 (세션 전환 시 빈 화면 방지)

### v0.1.8 — TUI 노이즈 필터링 강화

- [x] TUI 노이즈 필터링 강화 (thinking indicator, transient text 등)
- [x] 로그 기반 회귀 테스트 인프라 + fixture 라이프사이클 관리
- [x] `isThinkingIndicator()`, `matchesTUIChrome()` 확장

### v0.1.9 — Agent 모드 + 브릿지 모드 (진행 중)

- [x] Agent 모드: Python SDK 브릿지 서버 (`tools/sdk-bridge/sdk_bridge.py`)
  - Claude Agent SDK + aiohttp 기반 OpenAI 호환 API 서버
  - HTTP-first 구조 (connection refused 없음)
  - `@@CONSOLENT@@{JSON}` 프로토콜로 채팅 버블 표시
- [x] Gemini 브릿지 모드 (`tools/gemini-bridge/gemini_bridge.py`)
  - `gemini -p` 파이프 모드, `communicate()` 방식으로 전체 응답 수집
  - keytar/keychain initialization 노이즈 필터링
- [x] Codex 브릿지 모드 (`tools/codex-bridge/codex_bridge.py`)
  - `codex app-server --listen stdio://` JSON-RPC 통신
  - `thread/start` → `turn/start` → `delta` 이벤트 스트리밍
  - Race condition 수정 (pending future 전송 전 등록)
- [x] `SDKTerminalView.swift` — 채팅 버블 UI (user/assistant/system/tool_use)
- [x] 설정 → 브릿지 탭: 공용 Python venv + 브릿지 출력 레벨 설정
- [x] 브릿지 출력 레벨 3단계 (`error`/`info`/`debug`)
  - 대화 타입(user/assistant/tool_use 등)은 레벨 무관 항상 표시
  - Python logger 레벨도 동기화 (stderr 노이즈 방지)
- [x] 응답 완료 후 입력창 포커스 자동 복원 (`@FocusState`)
- [x] "SDK Mode" → "Agent Mode" 용어 통일
- [ ] idle 세션 자동 정리
- [ ] 비동기 메시지 모드

### v1.0 — 배포

- [ ] macOS notarization (App Store 외 직접 배포)
- [ ] 자동 업데이트 (Sparkle)
- [ ] 에러 핸들링 전반 검토

---

## 13. 제약 및 한계

| 항목 | 설명 |
|------|------|
| macOS 전용 | PTY + 네이티브 앱이므로 macOS에서만 동작 |
| 로컬 전용 | CLI 도구가 로컬에 설치되어 있어야 함 |
| 싱글 유저 | 하나의 macOS 사용자 계정 기준 |
| CLI 의존 | CLI의 TUI 형식이 바뀌면 Adapter 업데이트 필요 |
| App Store 불가 | 샌드박스 제약으로 PTY/embedded 서버 사용 불가 → 직접 배포 |
| 스트리밍 방식 | SSE 스트리밍은 200ms 폴링 기반 (실시간 토큰 단위 아님) |
| 토큰 카운트 | OpenAI 호환 응답의 usage 필드는 항상 0 (CLI 출력에서 추출 불가) |

---

## 14. Open Questions

1. ~~**Codex/Gemini TUI 패턴**~~ — ✅ 해결됨. 세 CLI 모두 완전 구현.
2. ~~**스트리밍 응답**~~ — ✅ 해결됨. SSE 스트리밍 구현 (200ms 폴링 기반).
3. ~~**브릿지 모드 안정성**~~ — ✅ 해결됨. 세 CLI 브릿지 모드 모두 구현. HTTP-first 구조로 connection refused 없음. JSON-RPC thread_id/delta 파싱 수정.
4. **세션 복구** — 앱이 크래시되면 실행 중이던 CLI 프로세스는 어떻게 되는가? 프로세스 자체는 살아있을 수 있으니 재연결(reattach) 가능성 검토 필요.
5. **동시 세션 vs 구독 제한** — Claude Code 구독에 동시 사용 제한이 있는 경우, 멀티 세션 사용 시 rate limit에 걸릴 수 있다.
6. **새 CLI Adapter 기여** — 커뮤니티가 새 CLI Adapter를 추가할 수 있는 구조인지, 플러그인 형태가 필요한지 검토.
7. **브릿지 의존성 자동 설치** — 현재 수동 pip install 필요. Settings → 브릿지 탭에서 자동 설치 버튼 구현 검토.
8. **긴 응답 스트리밍 조기 종료** — PTY 모드에서 매우 긴 응답 시 스트리밍이 완료 전에 끊기는 현상 잔존. 추가 조사 필요.
