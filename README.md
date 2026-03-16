# Consolent

> **Playwright for Terminals** — AI 코딩 CLI 도구를 OpenAI-호환 API로 조작하는 macOS 네이티브 앱

Consolent은 Claude Code, Codex CLI, Gemini CLI 등 터미널 기반 AI 코딩 에이전트를 [PTY](#term-pty)(가상 터미널)에서 실행하고, HTTP/WebSocket API로 제어합니다. CLI 도구 입장에서는 100% 사람이 타이핑하는 것과 동일하게 동작합니다.

```
┌─ Your App ──┐     HTTP/WebSocket      ┌─ Consolent ─────────────────────┐
│             │ ──────────────────────▶ │  API Server (Vapor)             │
│  웹앱        │  /v1/chat/completions   │    ↓                            │
│  봇          │                         │  Session Manager                │
│  스크립트     │                         │    ↓                            │
│  OpenAI SDK │ ◀────────────────────── │  PTY → claude/codex/gemini CLI  │
└─────────────┘     JSON Response       └─────────────────────────────────┘
```

## 왜 Consolent인가

|          | PTY 방식 (Consolent)              | SDK 방식                |
|----------|-----------------------------------|-------------------------|
| CLI 관점  | 사람이 쓰는 것과 동일                | 프로그래밍 호출             |
| 과금      | 기존 구독 그대로                    | 별도 API 과금             |
| 기능 범위  | CLI 전체 기능                      | SDK가 노출하는 범위만       |
| 인증      | 이미 로그인된 상태 사용              | 별도 API key 필요         |
| 확장성    | [Adapter](#term-adapter) 1개 추가 = 새 CLI 지원 | SDK별 개별 통합            |

## 지원 CLI

| CLI 도구    | 상태     | 비고                                |
|-------------|----------|-------------------------------------|
| Claude Code | 완전 구현 | [TUI](#term-tui) 패턴 파싱, [크롬](#term-tui-chrome) 제거, 완료 감지    |
| Gemini CLI  | 완전 구현 | [TUI](#term-tui) 패턴 파싱, [크롬](#term-tui-chrome) 제거, 완료 감지    |
| Codex CLI   | 완전 구현 | Rust/Ratatui TUI 파싱, nvm 경로 탐색, 플레이스홀더 처리 |

---

## 빠른 시작

### 요구 사항

- macOS 14.0+
- Xcode 15.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (자동 설치)
- Claude Code (또는 Codex/Gemini CLI)가 로컬에 설치 및 로그인된 상태

### 설치

```bash
git clone https://github.com/your/consolent.git
cd consolent

# Xcode 프로젝트 생성 & 열기
./setup.sh
open Consolent.xcodeproj
```

Xcode에서 `Cmd+R`로 빌드 및 실행.

### 첫 사용

1. Consolent 실행 → `Cmd+T`로 새 세션 생성
2. CLI 타입 선택 (Claude Code / Codex / Gemini), 작업 디렉토리 설정
3. 설정(⚙)에서 API Key 확인 (`cst_` prefix)
4. API 요청 시작!

---

## API 사용법

### OpenAI 호환 API

기존 OpenAI SDK/라이브러리로 즉시 사용 가능합니다.

**curl:**

```bash
curl http://localhost:9999/v1/chat/completions \
  -H "Authorization: Bearer cst_YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-code",
    "messages": [{"role": "user", "content": "이 프로젝트의 구조를 설명해줘"}]
  }'
```

**Python (OpenAI SDK):**

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:9999/v1",
    api_key="cst_YOUR_API_KEY"
)

response = client.chat.completions.create(
    model="claude-code",
    messages=[{"role": "user", "content": "테스트 실패 원인 찾아서 수정해줘"}]
)
print(response.choices[0].message.content)
```

**JavaScript (OpenAI SDK):**

```javascript
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "http://localhost:9999/v1",
  apiKey: "cst_YOUR_API_KEY",
});

const response = await client.chat.completions.create({
  model: "claude-code",
  messages: [{ role: "user", content: "src/auth.ts 코드 리뷰해줘" }],
});
console.log(response.choices[0].message.content);
```

### 모델 목록

```bash
curl http://localhost:9999/v1/models \
  -H "Authorization: Bearer cst_YOUR_API_KEY"
```

```json
{
  "object": "list",
  "data": [
    {"id": "claude-code", "object": "model", "owned_by": "consolent"},
    {"id": "codex", "object": "model", "owned_by": "consolent"},
    {"id": "gemini", "object": "model", "owned_by": "consolent"}
  ]
}
```

---

## OpenAI 호환 API Reference

모든 요청에 `Authorization: Bearer cst_YOUR_API_KEY` 헤더가 필요합니다.

### POST /v1/chat/completions

**Request Body:**

| 파라미터             | 타입              | 필수 | 기본값   | 설명                                      |
|---------------------|-------------------|------|---------|-------------------------------------------|
| `messages`          | `array`           | O    |         | 메시지 배열 (마지막 `user` 메시지를 전송)     |
| `model`             | `string`          |      |         | 모델 ID (`claude-code`, `codex`, `gemini`) |
| `stream`            | `boolean`         |      | `false` | SSE 스트리밍 활성화                          |
| `timeout`           | `integer`         |      | `300`   | 응답 대기 타임아웃 (초)                       |
| `temperature`       | `number`          |      |         | 호환성 위해 수용 (무시됨)                     |
| `max_tokens`        | `integer`         |      |         | 호환성 위해 수용 (무시됨)                     |
| `top_p`             | `number`          |      |         | 호환성 위해 수용 (무시됨)                     |
| `n`                 | `integer`         |      |         | 호환성 위해 수용 (무시됨)                     |
| `stop`              | `string`/`array`  |      |         | 호환성 위해 수용 (무시됨)                     |
| `presence_penalty`  | `number`          |      |         | 호환성 위해 수용 (무시됨)                     |
| `frequency_penalty` | `number`          |      |         | 호환성 위해 수용 (무시됨)                     |
| `user`              | `string`          |      |         | 호환성 위해 수용 (무시됨)                     |

> CLI 도구가 직접 생성하므로 `temperature`, `max_tokens` 등 생성 파라미터는 Consolent이 제어하지 않습니다.

**`messages` 형식:**

```json
// 문자열
{"role": "user", "content": "안녕"}

// 배열 (OpenAI vision 호환)
{"role": "user", "content": [{"type": "text", "text": "안녕"}]}
```

**응답 (비스트리밍):**

```json
{
  "id": "chatcmpl-m_x1y2z3",
  "object": "chat.completion",
  "created": 1710460800,
  "model": "claude-code",
  "choices": [
    {
      "index": 0,
      "message": {"role": "assistant", "content": "응답 텍스트..."},
      "finish_reason": "stop"
    }
  ],
  "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
}
```

> `usage` 필드는 호환성 위해 포함되며 항상 `0`입니다. CLI 도구가 토큰 수를 노출하지 않기 때문입니다.

**응답 (스트리밍, `stream: true`):**

`Content-Type: text/event-stream` 으로 SSE 형식 반환:

```
data: {"id":"chatcmpl-m_x1y2z3","object":"chat.completion.chunk","created":1710460800,"model":"claude-code","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

data: {"id":"chatcmpl-m_x1y2z3","object":"chat.completion.chunk","created":1710460800,"model":"claude-code","choices":[{"index":0,"delta":{"content":"응답 텍스트..."},"finish_reason":null}]}

data: {"id":"chatcmpl-m_x1y2z3","object":"chat.completion.chunk","created":1710460800,"model":"claude-code","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: [DONE]
```

> 현재 응답 전체를 수신한 후 청크로 분할 전송합니다. 실시간 토큰 단위 스트리밍은 아닙니다.

**에러:**

| 상태 코드 | 원인                         |
|----------|------------------------------|
| `400`    | `messages`가 비어있거나 `user` 메시지 없음 |
| `401`    | API Key 누락 또는 불일치         |
| `503`    | 준비된 세션 없음 (앱에서 세션 먼저 생성 필요) |

### GET /v1/models

**응답:**

```json
{
  "object": "list",
  "data": [
    {"id": "claude-code", "object": "model", "created": 1710460800, "owned_by": "consolent"},
    {"id": "codex",       "object": "model", "created": 1710460800, "owned_by": "consolent"},
    {"id": "gemini",      "object": "model", "created": 1710460800, "owned_by": "consolent"}
  ]
}
```

사용 가능한 모델은 `CLIType`에 등록된 CLI 도구에 따라 동적으로 생성됩니다.

---

## 세션 관리 API

### 세션 생성

```bash
curl -X POST http://localhost:9999/sessions \
  -H "Authorization: Bearer cst_YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "working_directory": "/path/to/project",
    "cli_type": "claude-code",
    "auto_approve": false
  }'
```

```json
{
  "session_id": "s_a1b2c3",
  "status": "initializing",
  "created_at": "2026-03-14T10:00:00Z"
}
```

### 세션 목록

```bash
curl http://localhost:9999/sessions \
  -H "Authorization: Bearer cst_YOUR_API_KEY"
```

### 메시지 전송 (동기)

```bash
curl -X POST http://localhost:9999/sessions/s_a1b2c3/message \
  -H "Authorization: Bearer cst_YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"text": "코드 리뷰해줘", "timeout": 120}'
```

```json
{
  "message_id": "m_x1y2z3",
  "response": {
    "text": "코드를 분석해봤습니다...",
    "files_changed": ["src/auth.ts"],
    "duration_ms": 4500
  }
}
```

### 세션 종료

```bash
curl -X DELETE http://localhost:9999/sessions/s_a1b2c3 \
  -H "Authorization: Bearer cst_YOUR_API_KEY"
```

---

## WebSocket 스트리밍

```javascript
const ws = new WebSocket(
  "ws://localhost:9999/sessions/s_a1b2c3/stream?token=cst_YOUR_API_KEY"
);

ws.onmessage = (e) => {
  const data = JSON.parse(e.data);
  switch (data.type) {
    case "output":
      console.log(data.text); // 실시간 CLI 출력
      break;
    case "approval_required":
      console.log(`승인 필요: ${data.prompt}`);
      ws.send(JSON.stringify({ type: "approve", id: data.id, approved: true }));
      break;
    case "status":
      console.log(`상태: ${data.status}`);
      break;
  }
};

// 메시지 전송
ws.send(JSON.stringify({ type: "input", text: "파일 분석해줘" }));
```

---

## 추가 API

### Raw 입력

```bash
# 텍스트 입력
curl -X POST http://localhost:9999/sessions/s_a1b2c3/input \
  -H "Authorization: Bearer cst_YOUR_API_KEY" \
  -d '{"text": "/help\n"}'

# 특수 키
curl -X POST http://localhost:9999/sessions/s_a1b2c3/input \
  -H "Authorization: Bearer cst_YOUR_API_KEY" \
  -d '{"keys": ["ctrl+c"]}'
```

지원 키: `ctrl+c`, `ctrl+d`, `ctrl+z`, `ctrl+l`, `enter`, `tab`, `escape`, `up`, `down`, `left`, `right`

### 출력 버퍼

```bash
curl http://localhost:9999/sessions/s_a1b2c3/output \
  -H "Authorization: Bearer cst_YOUR_API_KEY"
```

### 승인 확인 & 응답

```bash
# 대기 중 승인 확인
curl http://localhost:9999/sessions/s_a1b2c3/pending \
  -H "Authorization: Bearer cst_YOUR_API_KEY"

# 승인 응답
curl -X POST http://localhost:9999/sessions/s_a1b2c3/approve/a_1 \
  -H "Authorization: Bearer cst_YOUR_API_KEY" \
  -d '{"approved": true}'
```

---

## 테스트

```bash
# API 통합 테스트 (Consolent 앱이 실행 중이어야 함)
API_KEY="cst_YOUR_API_KEY" ./tests/api_test.sh

# 또는 커스텀 URL
API_KEY="cst_xxx" BASE_URL="http://127.0.0.1:9999" ./tests/api_test.sh
```

테스트 항목: 인증, 세션 CRUD, 메시지 전송, 출력 버퍼, 승인, OpenAI 호환 API, 응답 누적 방지, HTML 생성, 코드 설명, 멀티턴 컨텍스트 유지

---

## 아키텍처

```
Consolent/
├── App/
│   └── ConsolentApp.swift          # SwiftUI 진입점
├── Core/
│   ├── CLIAdapter.swift            # CLIAdapter 프로토콜 + CLIType
│   ├── Session.swift               # [PTY](#term-pty) + [헤드리스 터미널](#term-headless-terminal) + 파서
│   ├── SessionManager.swift        # 전역 세션 매니저
│   ├── OutputParser.swift          # [ANSI](#term-ansi) 파싱, 완료 감지, 승인 감지
│   ├── PTYProcess.swift            # forkpty() 래퍼
│   └── Adapters/
│       ├── ClaudeCodeAdapter.swift
│       ├── CodexAdapter.swift
│       └── GeminiAdapter.swift
├── API/
│   ├── APIServer.swift             # Vapor HTTP/WS 서버
│   └── APIAuthMiddleware.swift     # Bearer token 인증
├── Views/
│   ├── ContentView.swift           # 메인 윈도우
│   ├── TerminalView.swift          # SwiftTerm 래퍼
│   ├── SettingsView.swift          # 설정 UI
│   └── HelpView.swift             # 사용자 가이드 + API 레퍼런스
└── Config/
    └── AppConfig.swift             # JSON 설정 영속화
```

### 핵심 기술

| 컴포넌트        | 기술                                       |
|----------------|---------------------------------------------|
| App Framework  | SwiftUI + AppKit                            |
| 터미널          | SwiftTerm (렌더링 + 헤드리스 ANSI 해석)        |
| PTY            | `forkpty()` (POSIX)                         |
| HTTP/WS Server | Vapor (embedded)                            |
| 출력 파싱        | 4단계 [ANSI](#term-ansi) strip + [Adapter](#term-adapter)별 [TUI 크롬](#term-tui-chrome) 제거 |

### CLIAdapter 패턴

새로운 CLI 도구를 지원하려면 `CLIAdapter` 프로토콜을 구현하면 됩니다:

```swift
protocol CLIAdapter {
    var name: String { get }                    // "My CLI Tool"
    var modelId: String { get }                 // API에 노출되는 모델 ID
    var defaultBinaryPaths: [String] { get }    // 바이너리 탐색 경로
    var exitCommand: String { get }             // "/exit", "exit" 등
    var readySignal: String { get }             // [응답 완료 신호](#term-ready-signal)
    var processingSignal: String? { get }       // [처리 중 신호](#term-processing-signal) (regex)

    func findBinaryPath() -> String             // nvm 등 특수 경로 탐색 가능
    func buildCommand(binaryPath: String, args: [String], autoApprove: Bool) -> String
    func isResponseComplete(screenBuffer: String) -> Bool  // [Screen Buffer](#term-screen-buffer) 기반
    func cleanResponse(_ screenText: String) -> String
}
```

### CLI별 비교

| 항목 | Claude Code | Gemini CLI | Codex CLI |
|------|------------|------------|-----------|
| 런타임 | Node.js/Ink | Node.js/Ink | Rust/Ratatui |
| 사용자 입력 마커 | `❯` | `>` / `!` / `*` | `›` |
| 응답 마커 | `⏺` | `✦` | `•` / `◦` |
| Ready 신호 | `? for shortcuts` | `Type your message` | `% left` |
| Processing 신호 | `esc to interrupt` | `esc to cancel` | `esc to interrupt` |
| 자동 승인 플래그 | `--dangerously-skip-permissions` | `-y` | `--full-auto` |
| 종료 명령 | `/exit` | `/quit` | `/exit` |
| 바이너리 경로 | 표준 PATH | 표준 PATH | nvm 직접 탐색 필요 |

### 응답 완료 감지

[Idle Timer](#term-idle-timer) + [Adapter](#term-adapter) delegate 방식으로 정확하게 감지:

| 단계        | 트리거          | 체크                     | 용도          |
|-------------|-----------------|--------------------------|---------------|
| Idle Check  | idle 2초 후      | `isResponseComplete()`   | 주요 감지      |
| Safety Net  | 600초           | 강제 완료                 | 행 방지        |

---

## 설정

앱 내 Settings(⚙) 또는 설정 파일에서 관리:

`~/Library/Application Support/Consolent/config.json`

| 항목                     | 기본값        | 설명                |
|--------------------------|---------------|---------------------|
| `apiPort`                | `9999`        | API 서버 포트        |
| `apiBind`                | `127.0.0.1`  | 바인드 주소           |
| `defaultCliType`         | `claude-code` | 기본 CLI 도구        |
| `maxConcurrentSessions`  | `10`          | 최대 동시 세션        |
| `sessionIdleTimeout`     | `3600`        | 유휴 타임아웃 (초)    |
| `includeRawOutput`       | `false`       | ANSI 원본 포함 여부   |

---

## 보안

- **로컬 전용**: 기본 `127.0.0.1` 바인딩. 외부 접근 차단
- **CLI 인증 불필요**: 이미 로그인된 로컬 CLI를 그대로 사용
- **API Key 로컬 생성**: `cst_` prefix Bearer token. 원격 서버 미경유
- **데이터 경로**: Client → Consolent → PTY → CLI → 원격 서버 (Consolent은 I/O 중계만)

---

## 빌드 & 배포

### 개발 빌드

```bash
# Xcode 프로젝트 생성 (최초 1회)
./setup.sh

# 빌드
xcodebuild build -project Consolent.xcodeproj -scheme Consolent \
  -destination 'platform=macOS,arch=arm64'

# 유닛 테스트
xcodebuild test -project Consolent.xcodeproj -scheme Consolent \
  -destination 'platform=macOS,arch=arm64'
```

### DMG 배포용 빌드

App Store 배포가 불가능하므로(샌드박스 제약) DMG로 직접 배포합니다.

```bash
./scripts/build-dmg.sh
```

이 스크립트는 다음 단계를 자동으로 수행합니다:

1. **XcodeGen** — `project.yml`에서 Xcode 프로젝트 재생성
2. **Release 빌드** — `xcodebuild -configuration Release` (ad-hoc 서명)
3. **DMG 생성** — `create-dmg`로 Applications 바로가기 포함 DMG 생성 (없으면 `hdiutil` 폴백)

결과물: `build/Consolent.dmg`

```bash
# 설치
open build/Consolent.dmg
# → Consolent.app을 Applications로 드래그
```

**선택 의존성:**

| 도구 | 필수 | 용도 | 설치 |
|------|------|------|------|
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | 권장 | 프로젝트 생성 | `brew install xcodegen` |
| [create-dmg](https://github.com/create-dmg/create-dmg) | 선택 | 예쁜 DMG (Applications 바로가기) | `brew install create-dmg` |

> `create-dmg` 없이도 `hdiutil`로 기본 DMG가 생성됩니다.

---

## 제약 사항

- macOS 전용 (PTY + 네이티브 앱)
- CLI 도구가 로컬에 설치/로그인 필요
- CLI [TUI](#term-tui) 변경 시 [Adapter](#term-adapter) 업데이트 필요
- App Store 불가 (샌드박스 제약) — DMG 직접 배포 (`scripts/build-dmg.sh`)
- OpenAI API `stream: true`는 SSE 형식으로 지원하나, 응답 수신 후 일괄 전송 (실시간 토큰 스트리밍 아님)

---

## 용어집

| 용어              | 설명                                                                                         |
|-------------------|----------------------------------------------------------------------------------------------|
| <a id="term-pty"></a>**PTY**                       | Pseudo Terminal. 가상 터미널 장치. CLI 프로세스가 실제 터미널에 연결된 것처럼 동작하게 한다      |
| <a id="term-tui"></a>**TUI**                       | Text User Interface. 터미널에서 커서 이동, 색상, 박스 등으로 구성하는 텍스트 기반 UI             |
| <a id="term-tui-chrome"></a>**TUI Chrome**          | TUI의 장식 요소 (상태바, 스피너, 구분선, 프롬프트 기호 등). 응답 본문이 아닌 모든 UI 요소        |
| <a id="term-ansi"></a>**ANSI Escape**              | 터미널 제어 코드. 커서 이동, 색상, 화면 지우기 등에 사용. `\x1B[...` 형식                       |
| <a id="term-screen-buffer"></a>**Screen Buffer**    | 헤드리스 터미널이 ANSI를 해석한 후의 화면 상태. 실제 터미널에 보이는 것과 동일한 텍스트           |
| <a id="term-ready-signal"></a>**Ready Signal**      | CLI가 입력 대기 상태임을 나타내는 문자열 (예: `? for shortcuts`, `Type your message`, `% left`)  |
| <a id="term-processing-signal"></a>**Processing Signal** | CLI가 처리 중임을 나타내는 문자열 (예: `esc to interrupt`, `esc to cancel`)                |
| <a id="term-adapter"></a>**Adapter**                | CLIAdapter 프로토콜 구현체. CLI별 TUI 패턴, 완료 감지, 응답 파싱 로직을 캡슐화                  |
| <a id="term-idle-timer"></a>**Idle Timer**          | PTY 출력이 멈춘 후 일정 시간(2초) 대기하여 응답 완료를 판단하는 타이머                          |
| <a id="term-headless-terminal"></a>**Headless Terminal** | 화면에 렌더링하지 않고 ANSI 해석만 수행하는 SwiftTerm 인스턴스                              |

---

## 라이선스

Apache License 2.0 — [LICENSE](LICENSE) 참조
