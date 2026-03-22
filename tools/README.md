# tools/

Consolent 개발·운영 도구 모음.

---

## extract_fixtures.py

디버그 로그(JSONL)에서 **회귀 테스트용 fixture를 자동 추출**하고, fixture 라이프사이클을 관리하는 스크립트.

### 왜 필요한가

Consolent은 CLI 도구(Claude Code, Gemini CLI, Codex)의 터미널 출력을 파싱하여 응답을 추출한다.
각 CLI의 TUI(Terminal User Interface)가 다르므로, 어댑터(`CLIAdapter`)가 화면 텍스트에서 응답 본문만 정확히 추출해야 한다.

문제는 **파싱이 깨지는 경우를 사전에 알기 어렵다**는 것이다:
- TUI chrome(`? for shortcuts`, `esc to interrupt` 등)이 응답에 섞임
- 동일 문장이 중복 출력됨
- 코드 펜스(```)가 닫히지 않는 잘린 응답
- 스트리밍 델타와 최종 응답 간 불일치

이 스크립트는 **실제 사용 중 기록된 디버그 로그**에서 이런 문제를 자동 감지하고, 테스트 가능한 fixture 파일로 변환한다.

### 전제 조건

앱 설정에서 **로그 레벨을 INFO 이상**으로 설정해야 한다.
(설정 → 디버그 → 로그 레벨)

로그 파일 위치: `~/Library/Logs/Consolent/debug/{날짜}/{세션}.jsonl`

### 기본 사용법

```bash
# 프로젝트 루트에서 실행
cd /path/to/Consolent

# 로그 디렉토리 전체 스캔 — 문제가 있는 케이스만 fixture로 추출
python3 tools/extract_fixtures.py

# 오늘 로그만 스캔
python3 tools/extract_fixtures.py --today

# 최근 3일 로그만 스캔
python3 tools/extract_fixtures.py --days 3

# 특정 로그 파일 지정
python3 tools/extract_fixtures.py ~/Library/Logs/Consolent/debug/2026-03-22/session.jsonl

# 모든 케이스 추출 (문제 없는 것 포함)
python3 tools/extract_fixtures.py --all
```

출력: `ConsolentTests/Fixtures/fixture_{sessionId}_{timestamp}.json`

### 필터 옵션

```bash
# 에러가 발생한 케이스만
python3 tools/extract_fixtures.py --errors-only

# 빈 응답(cleanText가 비어있는) 케이스만
python3 tools/extract_fixtures.py --empty-only

# 품질 의심 케이스만 (아래 '품질 감지' 참조)
python3 tools/extract_fixtures.py --suspicious-only

# 특정 메시지만
python3 tools/extract_fixtures.py --message-id msg_abc123

# 요약만 출력 (fixture 파일 생성하지 않음)
python3 tools/extract_fixtures.py --summary

# JSON 압축 출력
python3 tools/extract_fixtures.py --compact
```

### 품질 감지 (Suspicious Detection)

스크립트는 8가지 휴리스틱으로 응답 품질 문제를 자동 감지한다:

| 유형 | 조건 | 의미 |
|------|------|------|
| `timeout` | 완료 신호가 타임아웃 | 응답이 끝나지 않고 타임아웃으로 강제 종료됨 |
| `streaming_gap` | 스트리밍 누적량 ≠ 최종 응답 (>20% 차이) | 스트리밍 도중 데이터 누락 또는 중복 |
| `tui_noise` | 응답에 TUI chrome 패턴 잔존 | 어댑터가 TUI 요소를 제거하지 못함 |
| `duplication` | 동일 문장이 2회 이상 반복 | 화면 버퍼 중복 읽기 또는 파싱 오류 |
| `truncation` | 코드 펜스 미닫힘 (홀수 개) | 응답이 잘린 상태로 수집됨 |
| `truncation` | 마지막 줄이 문장부호 없이 끝남 | 텍스트가 중간에서 끊김 |
| `high_reduction` | 화면 대비 파싱 결과 <5% | 어댑터가 응답 대부분을 잘못 제거함 |
| `streaming_noise` | 스트리밍 델타에 TUI 노이즈 포함 | 스트리밍 필터링 부족 |

감지에 사용하는 TUI 노이즈 패턴:

```
❯                         # 프롬프트
⎿                         # 도구 출력 접두사
esc to interrupt/cancel   # 처리 중 표시
? for shortcuts           # 준비 상태 표시
shift+tab to cycle        # UI 힌트
ctrl+X to ...             # UI 힌트
Reading N file            # 파일 읽기 상태
claude --resume           # TUI 안내
N tokens                  # 토큰 카운트
Tip: Use /                # Claude 팁
```

---

## Fixture 라이프사이클

fixture는 4단계 라이프사이클을 거친다:

```
[추출]  →  [교정]  →  [해결]  →  [정리]
 open       open       resolved    삭제
            corrected
```

### 1단계: 추출 (open)

```bash
python3 tools/extract_fixtures.py --today
```

- 스크립트가 로그에서 fixture를 생성하면 `status: "open"`으로 저장
- `expectedCleanText`는 어댑터의 **현재** 출력 (버그가 있으면 버그 포함)
- `RegressionTests`의 **품질 테스트**가 자동으로 문제를 감지:
  - `testNoTUINoiseInCleanResponse` — TUI 노이즈 잔존 검사
  - `testNoDuplicatedContent` — 동일 문장 반복 검사
  - `testCodeFencesBalanced` — 코드 펜스 미닫힘 검사
  - `testStreamingDeltas_consistency` — 스트리밍 델타 일관성 검사
  - `testCompletionDetection_consistency` — 완료 감지 일관성 검사

### 2단계: 교정 (open + corrected)

문제가 감지된 fixture의 `expectedCleanText`를 **올바른 기대값으로 수동 수정**:

```json
{
  "id": "msg_001",
  "screenText": "\n\n\n⏺ Hello!\n\n  ? for shortcuts  ❯ ",
  "expectedCleanText": "Hello!",
  "corrected": true
}
```

- `corrected: true`를 추가하면 `testCorrectedFixtures`가 어댑터 출력과 비교
- 어댑터가 잘못된 결과를 내는 동안 **테스트가 실패**
- 이 실패가 어댑터를 수정하도록 유도

### 3단계: 해결 (resolved)

어댑터 수정 후 모든 테스트가 통과하면:

```bash
# 테스트 통과 확인
xcodebuild test -project Consolent.xcodeproj -scheme Consolent \
  -destination 'platform=macOS,arch=arm64'

# resolve 가능 여부 확인
python3 tools/extract_fixtures.py --resolve

# 실제 전환
python3 tools/extract_fixtures.py --resolve --confirm
```

- `status`가 `"resolved"`로 변경
- 회귀 방지를 위해 **영구 보관**
- 이후 어댑터가 다시 깨지면 테스트가 실패

### 4단계: 정리 (cleanup)

같은 어댑터에 resolved fixture가 3개 이상 쌓이면:

```bash
# 정리 대상 확인
python3 tools/extract_fixtures.py --cleanup

# 실제 삭제
python3 tools/extract_fixtures.py --cleanup --confirm
```

어댑터당 대표 fixture 2개만 남기고 나머지 삭제.

---

## Fixture 관리 명령

### --status

fixture 현황과 로그 처리 상태를 한눈에 확인:

```bash
python3 tools/extract_fixtures.py --status
```

출력 예시:

```
======================================================================
  Fixture 현황: ConsolentTests/Fixtures
======================================================================

  🔴 fixture_s_abc123_20260322_120000_1234.json
     [claude-code] open | 5건, 교정 2, 의심 1 — TUI 노이즈 잔존
  🟢 fixture_s_def456_20260320_100000_5678.json
     [gemini] resolved | 3건

  ──────────────────────────────────────────────────
  총 2개 파일, 8건 케이스 (교정 2건)
  🔴 open: 1  🟢 resolved: 1

  ──────────────────────────────────────────────────
  📂 로그 현황: ~/Library/Logs/Consolent/debug
     전체: 10개 | 처리됨: 2개 | 미처리: 8개

  ⚠️  문제 있는 미처리 로그 (3개):
     [2026-03-22] session_abc.jsonl (1.2MB)
     [2026-03-21] session_def.jsonl (800KB)

  🕐 만료 임박 (1개, 보관 7일):
     [2026-03-16] session_old.jsonl — 1일 남음 (⚠️ 미처리)
======================================================================
```

- **Fixture 현황**: 각 fixture의 상태(open/resolved), 케이스 수, 교정·의심 건수
- **로그 현황**: fixture의 `metadata.source`와 로그 디렉토리를 비교하여 미처리 로그 자동 식별
- **만료 임박**: 보관 기간(기본 7일) 이내에 삭제될 로그 경고. 미처리 상태면 별도 표시

```bash
# 보관 기간을 14일로 변경하여 확인
python3 tools/extract_fixtures.py --status --retention-days 14
```

### --resolve

open fixture 중 품질 문제가 없는 것을 resolved로 전환:

```bash
# 확인만 (dry-run)
python3 tools/extract_fixtures.py --resolve

# 실제 전환
python3 tools/extract_fixtures.py --resolve --confirm
```

판단 기준:
- TUI 노이즈, 중복, 코드 펜스 미닫힘 등 품질 검사를 Python 측에서 수행
- 품질 문제가 있으면 건너뜀
- `corrected: true` 케이스가 있으면 `xcodebuild test` 통과를 전제로 전환
  (Swift 테스트에서도 통과 시 resolve 안내 메시지 출력)

### --cleanup

resolved 중복 fixture 정리:

```bash
# 정리 대상 확인 (dry-run)
python3 tools/extract_fixtures.py --cleanup

# 실제 삭제
python3 tools/extract_fixtures.py --cleanup --confirm
```

### 조합 사용

```bash
# 현황 + resolve 가능 여부 + 정리 대상을 한번에 확인
python3 tools/extract_fixtures.py --status --resolve --cleanup
```

---

## 로그 이벤트 매핑

디버그 로그(JSONL)의 각 이벤트가 fixture의 어느 필드로 매핑되는지:

| 로그 이벤트 | 로그 시점 | fixture 매핑 |
|-------------|-----------|--------------|
| `session_start` | 세션 생성 | `metadata.sessionId`, `metadata.cliType` |
| `message_sent` | 메시지 전송 | `case.id`, `case.message`, `case.type` (sync/streaming) |
| `screen_buffer` | 화면 스냅샷 | (내부 참조용) |
| `parsing_result` | `cleanResponse()` 실행 | `case.screenText`, `case.expectedCleanText`, `case.adapterType` |
| `streaming_poll` | 스트리밍 델타 발생 | `case.streamingDeltas`, `case.pollCount`, `case.totalDeltaLength` |
| `streaming_baseline` | 스트리밍 시작 시 기준점 | `case.baseline` |
| `completion_detected` | 응답 완료 감지 | `case.completionSignal` |
| `error` | 에러 발생 | `case.hasError`, `case.errors` |
| `pty_output` | PTY 원본 출력 (DEBUG 레벨) | (fixture에 미포함) |
| `api_request` | API 요청 수신 | (fixture에 미포함) |
| `api_response` | API 응답 발송 | (fixture에 미포함) |
| `session_end` | 세션 종료 | (메시지 그룹핑 종료 신호) |

### 메시지 그룹핑

스크립트는 `message_sent` 이벤트를 기준으로 후속 이벤트를 그룹핑한다:

```
message_sent (msg_001)     ← 그룹 시작
  ├─ screen_buffer
  ├─ streaming_baseline
  ├─ streaming_poll ×N
  ├─ parsing_result        ← fixture의 핵심 데이터
  ├─ completion_detected
  └─ error (있으면)
message_sent (msg_002)     ← 다음 그룹 시작
  └─ ...
```

`parsing_result` 중 context에 `"complete"`가 포함된 것이 최종 결과이며, 이것이 fixture의 `screenText`/`expectedCleanText`가 된다.

---

## Fixture 파일 형식

### 전체 구조

```json
{
  "metadata": {
    "source": "s_abc123_claude-code_19-55-42.jsonl",
    "extractedAt": "2026-03-22T20:30:00",
    "sessionId": "abc12345",
    "cliType": "claude-code",
    "sessionName": "claude-code",
    "totalMessages": 10,
    "extractedCases": 3,
    "status": "open",
    "description": ""
  },
  "cases": [...]
}
```

| 메타데이터 필드 | 설명 |
|-----------------|------|
| `source` | 원본 로그 파일명 (로그 처리 추적에 사용) |
| `extractedAt` | 추출 시각 (ISO 8601) |
| `sessionId` | 세션 ID |
| `cliType` | CLI 종류: `claude-code`, `gemini`, `codex` |
| `status` | `"open"` 또는 `"resolved"` |
| `description` | 수동 기입하는 설명 (테스트 실패 시 원인 파악용) |

### 동기(sync) 케이스

```json
{
  "id": "msg_001",
  "type": "sync",
  "message": "hello",
  "adapterType": "ClaudeCodeAdapter",
  "screenText": "\n\n\n⏺ Hello!\n\n  ? for shortcuts  ❯ ",
  "expectedCleanText": "Hello!",
  "completionSignal": "ready_signal",
  "wasEmpty": false,
  "hasError": false,
  "suspicious": false,
  "suspiciousReasons": [],
  "corrected": true
}
```

### 스트리밍(streaming) 케이스

```json
{
  "id": "msg_002",
  "type": "streaming",
  "message": "explain swift",
  "adapterType": "ClaudeCodeAdapter",
  "screenText": "...",
  "expectedCleanText": "Swift is a modern programming language...",
  "completionSignal": "ready_signal",
  "wasEmpty": false,
  "hasError": false,
  "suspicious": true,
  "suspiciousReasons": ["streaming_gap"],
  "suspiciousDetails": [
    {"type": "streaming_gap", "detail": "스트리밍 누적 120자 vs 최종 180자 (차이 60자, 33%)"}
  ],
  "baseline": "",
  "pollCount": 15,
  "totalDeltaLength": 120,
  "streamingDeltas": [
    "Swift",
    " is a modern",
    " programming",
    "... (5 polls omitted) ...",
    " language",
    " developed by Apple."
  ]
}
```

| 케이스 필드 | 설명 |
|-------------|------|
| `id` | 메시지 ID (로그의 `messageId`) |
| `type` | `"sync"` 또는 `"streaming"` |
| `message` | 사용자가 보낸 메시지 텍스트 |
| `adapterType` | 어댑터 클래스명: `ClaudeCodeAdapter`, `GeminiAdapter`, `CodexAdapter` |
| `screenText` | 헤드리스 터미널의 화면 텍스트 (TUI chrome 포함) |
| `expectedCleanText` | `cleanResponse()` 기대 결과 (추출 시 현재 출력, 교정 시 올바른 값) |
| `completionSignal` | 완료 감지 신호: `ready_signal`, `timeout` 등 |
| `wasEmpty` | cleanText가 빈 문자열이었는지 |
| `hasError` | 에러 발생 여부 |
| `suspicious` | 품질 의심 여부 |
| `suspiciousReasons` | 의심 유형 배열: `["tui_noise", "duplication"]` |
| `corrected` | `true`면 사람이 `expectedCleanText`를 교정함 (정확한 기대값) |
| `baseline` | (스트리밍) 이전 턴 응답 — 새 응답과 구분하는 기준점 |
| `pollCount` | (스트리밍) 폴링 횟수 |
| `totalDeltaLength` | (스트리밍) 전체 델타 누적 길이 |
| `streamingDeltas` | (스트리밍) 델타 배열 (10개 초과 시 중간 생략) |

---

## 회귀 테스트 (RegressionTests.swift)

`ConsolentTests/RegressionTests.swift`는 fixture를 로드하여 6가지 테스트를 수행한다:

| 테스트 | 검증 대상 | 실패 조건 |
|--------|-----------|-----------|
| `testCorrectedFixtures` | 교정된 fixture의 정확성 | `cleanResponse(screenText) ≠ expectedCleanText` |
| `testNoTUINoiseInCleanResponse` | TUI chrome 제거 | 응답에 `esc to interrupt`, `? for shortcuts` 등 잔존 |
| `testNoDuplicatedContent` | 내용 중복 | 20자 이상의 동일 줄이 2회 이상 반복 |
| `testCodeFencesBalanced` | 코드 펜스 완결성 | ` ``` ` 개수가 홀수 (미닫힘) |
| `testStreamingDeltas_consistency` | 스트리밍 일관성 | 델타 누적과 최종 응답 유사도 < 50% |
| `testCompletionDetection_consistency` | 완료 감지 | `ready_signal`인데 `isResponseComplete()` false |

### Fixture 로드 경로

1. 테스트 번들 리소스 (`ConsolentTests/Fixtures/`) — Xcode 빌드 시 복사됨
2. `SRCROOT` 환경 변수 기반 경로 — `xcodebuild` 실행 시
3. `#file` 기반 소스 디렉토리 — 폴백

---

## 전체 옵션 레퍼런스

```
python3 tools/extract_fixtures.py [옵션] [로그파일]
```

### 추출 옵션

| 옵션 | 단축 | 설명 |
|------|------|------|
| `logfile` | | JSONL 로그 파일 경로 (미지정 시 디렉토리 스캔) |
| `--log-dir DIR` | | 로그 디렉토리 (기본: `~/Library/Logs/Consolent/debug`) |
| `--output-dir DIR` | `-o` | fixture 출력 디렉토리 (기본: `ConsolentTests/Fixtures`) |
| `--today` | `-t` | 오늘 로그만 스캔 |
| `--days N` | `-d` | 최근 N일 로그만 스캔 |
| `--all` | `-a` | 모든 케이스 추출 (기본: 문제 있는 것만) |
| `--summary` | `-s` | 요약만 출력, fixture 생성하지 않음 |
| `--compact` | | JSON 압축 출력 (기본: 2칸 들여쓰기) |

### 필터 옵션

| 옵션 | 단축 | 설명 |
|------|------|------|
| `--errors-only` | `-e` | 에러가 발생한 케이스만 |
| `--empty-only` | | 빈 응답 케이스만 |
| `--suspicious-only` | | 품질 의심 케이스만 |
| `--message-id ID` | `-m` | 특정 메시지 ID만 추출 |

### 관리 옵션

| 옵션 | 설명 |
|------|------|
| `--status` | fixture 현황 + 로그 처리 상태 대시보드 |
| `--resolve` | open → resolved 전환 가능 여부 확인 (dry-run) |
| `--cleanup` | resolved 중복 fixture 정리 대상 확인 (dry-run) |
| `--confirm` | `--resolve`/`--cleanup`과 함께 — 실제 실행 |
| `--retention-days N` | 로그 보관 기간 (기본: 7일, `--status`에서 만료 경고에 사용) |

---

## 빌드 & 테스트

### 기본 명령

```bash
# 프로젝트 루트에서 실행 (Consolent/)

# 빌드
xcodebuild build -project Consolent.xcodeproj -scheme Consolent \
  -destination 'platform=macOS,arch=arm64'

# 전체 테스트 (회귀 테스트 포함)
xcodebuild test -project Consolent.xcodeproj -scheme Consolent \
  -destination 'platform=macOS,arch=arm64'

# 회귀 테스트만 실행
xcodebuild test -project Consolent.xcodeproj -scheme Consolent \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ConsolentTests/RegressionTests
```

> **주의**: `xcodebuild test`는 반드시 `-scheme Consolent`을 지정해야 한다.
> 생략하면 `The test action requires that the name of a scheme...` 에러가 발생한다.

### alias 설정 (선택)

매번 긴 명령을 치기 번거로우면 shell에 alias를 추가:

```bash
# ~/.zshrc 또는 ~/.bashrc에 추가
alias cb='xcodebuild build -project Consolent.xcodeproj -scheme Consolent -destination "platform=macOS,arch=arm64"'
alias ct='xcodebuild test -project Consolent.xcodeproj -scheme Consolent -destination "platform=macOS,arch=arm64"'
```

이후 `cb`(빌드), `ct`(테스트)로 간단히 실행.

---

## 일상 워크플로우

### 1. 현황 확인

```bash
python3 tools/extract_fixtures.py --status
```

미처리 로그, 만료 임박 경고, fixture 상태를 한눈에 확인.

### 2. Fixture 추출

```bash
# 오늘 로그에서 문제 있는 케이스만 추출
python3 tools/extract_fixtures.py --today
```

### 3. 테스트 실행

```bash
xcodebuild test -project Consolent.xcodeproj -scheme Consolent \
  -destination 'platform=macOS,arch=arm64'
```

추출된 fixture에 품질 문제가 있으면 **자동으로 테스트가 실패**한다.
(TUI 노이즈 잔존, 내용 중복, 코드 펜스 미닫힘, 스트리밍 불일치 등)

### 4. 어댑터 수정

테스트 실패 메시지를 보고 어댑터(`Consolent/Core/Adapters/`)를 수정.

필요하면 fixture의 `expectedCleanText`를 올바른 기대값으로 교정하고 `"corrected": true`를 추가.
→ `testCorrectedFixtures`가 정확한 값과 비교하여 실패/통과를 판단.

### 5. Resolve 전환

모든 테스트 통과 후:

```bash
python3 tools/extract_fixtures.py --resolve --confirm
```

### 6. 정기 정리

resolved fixture가 쌓이면:

```bash
python3 tools/extract_fixtures.py --cleanup --confirm
```

---

## 디렉토리 구조

```
tools/
├── README.md                 ← 이 문서
├── extract_fixtures.py       ← fixture 추출 + 관리 스크립트
└── ConsolentTests/           ← (스크립트 실행 시 생성될 수 있는 임시 디렉토리)

ConsolentTests/
├── Fixtures/                 ← fixture 파일 저장 위치
│   ├── fixture_sample.json   ← 샘플 fixture (테스트 검증용)
│   └── fixture_*.json        ← 추출된 fixture들
└── RegressionTests.swift     ← fixture 기반 회귀 테스트

~/Library/Logs/Consolent/debug/
├── 2026-03-22/               ← 날짜별 디렉토리
│   ├── s_abc123_claude-code_19-55-42.jsonl
│   └── api_2026-03-22.jsonl  ← 세션에 속하지 않는 API 로그
└── 2026-03-21/
    └── ...
```
