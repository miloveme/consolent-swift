#!/usr/bin/env python3
"""
로그 파일에서 회귀 테스트용 fixture를 자동 추출한다.

사용법:
    # 인자 없이 — 로그 디렉토리 전체 스캔
    python3 tools/extract_fixtures.py

    # 특정 파일만
    python3 tools/extract_fixtures.py path/to/log.jsonl

    # 오늘 로그만 스캔
    python3 tools/extract_fixtures.py --today

    # 최근 N일 로그 스캔
    python3 tools/extract_fixtures.py --days 3

    # 필터
    python3 tools/extract_fixtures.py --errors-only
    python3 tools/extract_fixtures.py --empty-only
    python3 tools/extract_fixtures.py --suspicious-only
    python3 tools/extract_fixtures.py --message-id msg_xxx

출력:
    fixture_{sessionId}_{timestamp}.json — RegressionTests.swift에서 로드하는 형식

로그 이벤트 매핑:
    message_sent      → 요청 정보
    parsing_result    → screenText → cleanText 매핑 (핵심)
    streaming_poll    → 스트리밍 델타 시퀀스
    streaming_baseline→ 스트리밍 baseline
    completion_detected→ 완료 신호
    error             → 에러 기록

품질 감지:
    ⚠ 의심 케이스 (suspicious) — 에러는 아니지만 응답 품질에 문제가 있을 수 있음:
    - timeout: 완료 신호가 타임아웃
    - streaming_gap: 스트리밍 누적량 ≠ 최종 응답 길이 (>20% 차이)
    - tui_noise: 응답에 TUI chrome 잔존 (❯, ⎿, esc to, ? for shortcuts 등)
    - duplication: 동일 문장이 2회 이상 반복
    - truncation: 코드 펜스 미닫힘, 문장 중간 끊김
    - high_reduction: 화면 대비 파싱 결과가 비정상적으로 작음 (<5%)
"""

import json
import re
import sys
import os
from collections import defaultdict, Counter
from datetime import datetime, timedelta
from pathlib import Path


# 기본 로그 디렉토리
DEFAULT_LOG_DIR = os.path.expanduser("~/Library/Logs/Consolent/debug")

# TUI 노이즈 패턴 (응답에 남아있으면 안 되는 것들)
TUI_NOISE_PATTERNS = [
    re.compile(r'^\s*❯\s*', re.MULTILINE),           # 프롬프트
    re.compile(r'⎿\s', re.MULTILINE),                 # 도구 출력 접두사
    re.compile(r'esc to (interrupt|cancel)', re.I),    # 처리 중 표시
    re.compile(r'\? for shortcuts'),                   # 준비 상태 표시
    re.compile(r'shift\+tab to cycle', re.I),          # UI 힌트
    re.compile(r'ctrl\+[a-z] to', re.I),               # UI 힌트
    re.compile(r'^\s*Reading \d+ file', re.MULTILINE), # 파일 읽기 상태
    re.compile(r'claude --resume'),                    # TUI 안내
    re.compile(r'^\s*\d+k? tokens?\s*$', re.MULTILINE),  # 토큰 카운트
    re.compile(r'Tip: Use /'),                         # Claude 팁
]

# 중복 감지용 최소 문장 길이
MIN_SENTENCE_LEN = 20


def find_log_files(log_dir, days=None, today=False):
    """로그 디렉토리에서 .jsonl 파일 목록을 반환."""
    if not os.path.isdir(log_dir):
        return []

    date_dirs = sorted(Path(log_dir).iterdir(), reverse=True)

    if today:
        cutoff = datetime.now().strftime("%Y-%m-%d")
        date_dirs = [d for d in date_dirs if d.name == cutoff]
    elif days is not None:
        cutoff = (datetime.now() - timedelta(days=days - 1)).strftime("%Y-%m-%d")
        date_dirs = [d for d in date_dirs if d.is_dir() and d.name >= cutoff]

    files = []
    for d in date_dirs:
        if not d.is_dir():
            continue
        for f in sorted(d.glob("*.jsonl")):
            files.append(str(f))

    return files


def load_log(path):
    """JSONL 파일을 읽어 이벤트 리스트로 반환."""
    events = []
    with open(path, "r", encoding="utf-8") as f:
        for i, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                print(f"  [경고] {i}행 JSON 파싱 실패, 건너뜀", file=sys.stderr)
    return events


def group_by_message(events):
    """이벤트를 messageId 기준으로 그룹핑."""
    groups = defaultdict(lambda: {
        "message_sent": None,
        "parsing_results": [],
        "streaming_polls": [],
        "streaming_baseline": None,
        "completion": None,
        "errors": [],
        "screen_buffers": [],
    })

    current_msg_id = None

    for ev in events:
        event_type = ev.get("event", "")
        data = ev.get("data", {})
        timestamp = ev.get("timestamp", "")

        if event_type == "message_sent":
            msg_id = data.get("messageId", "")
            current_msg_id = msg_id
            groups[msg_id]["message_sent"] = {
                "timestamp": timestamp,
                "text": data.get("text", ""),
                "streaming": data.get("streaming", False),
                "messageId": msg_id,
            }
        elif event_type == "parsing_result" and current_msg_id:
            groups[current_msg_id]["parsing_results"].append({
                "timestamp": timestamp,
                "screenText": data.get("screenText", ""),
                "cleanText": data.get("cleanText", ""),
                "adapterType": data.get("adapterType", ""),
                "context": data.get("context", ""),
                "screenLength": data.get("screenLength", 0),
                "cleanLength": data.get("cleanLength", 0),
            })
        elif event_type == "streaming_poll" and current_msg_id:
            groups[current_msg_id]["streaming_polls"].append({
                "timestamp": timestamp,
                "delta": data.get("delta", ""),
                "deltaLength": data.get("deltaLength", 0),
                "sentLength": data.get("sentLength", 0),
                "totalLength": data.get("totalLength", 0),
                "elapsed": data.get("elapsed", "0"),
            })
        elif event_type == "streaming_baseline" and current_msg_id:
            groups[current_msg_id]["streaming_baseline"] = {
                "timestamp": timestamp,
                "baseline": data.get("baseline", ""),
                "length": data.get("length", 0),
            }
        elif event_type == "completion_detected" and current_msg_id:
            groups[current_msg_id]["completion"] = {
                "timestamp": timestamp,
                "signal": data.get("signal", ""),
                "screenText": data.get("screenText", ""),
                "cleanText": data.get("cleanText", ""),
                "context": data.get("context", ""),
            }
        elif event_type == "error" and current_msg_id:
            groups[current_msg_id]["errors"].append({
                "timestamp": timestamp,
                "message": data.get("message", ""),
                "context": data.get("context", ""),
            })
        elif event_type == "screen_buffer" and current_msg_id:
            groups[current_msg_id]["screen_buffers"].append({
                "timestamp": timestamp,
                "screenText": data.get("screenText", ""),
                "context": data.get("context", ""),
                "lineCount": data.get("lineCount", 0),
            })
        elif event_type == "session_end":
            current_msg_id = None

    return groups


# ──────────────────────────────────────────────────────────────
# 품질 감지 (suspicious detection)
# ──────────────────────────────────────────────────────────────

def detect_suspicious(group):
    """응답 품질 문제를 감지하여 의심 사유 리스트를 반환.

    Returns:
        list of dict: [{"type": "tui_noise", "detail": "..."}, ...]
    """
    issues = []
    sent = group["message_sent"]
    if not sent:
        return issues

    is_streaming = sent.get("streaming", False)

    # 최종 parsing_result 찾기
    final_pr = None
    for pr in group["parsing_results"]:
        if "complete" in pr.get("context", "").lower():
            final_pr = pr
    if not final_pr and group["parsing_results"]:
        final_pr = group["parsing_results"][-1]

    if not final_pr:
        return issues

    clean_text = final_pr.get("cleanText", "")
    screen_text = final_pr.get("screenText", "")
    screen_len = final_pr.get("screenLength", 0)
    clean_len = final_pr.get("cleanLength", 0)

    # 1) 타임아웃 완료
    completion = group["completion"]
    if completion:
        sig = completion.get("signal", "").lower()
        if "timeout" in sig:
            issues.append({
                "type": "timeout",
                "detail": f"완료 신호가 타임아웃: {completion['signal']}",
            })

    # 2) 스트리밍 누적량 vs 최종 응답 불일치
    if is_streaming and group["streaming_polls"]:
        total_streamed = sum(p.get("deltaLength", 0) for p in group["streaming_polls"])
        if clean_len > 0 and total_streamed > 0:
            gap = abs(clean_len - total_streamed)
            ratio = gap / max(clean_len, total_streamed)
            if ratio > 0.2:  # 20% 이상 차이
                issues.append({
                    "type": "streaming_gap",
                    "detail": f"스트리밍 누적 {total_streamed}자 vs 최종 {clean_len}자 (차이 {gap}자, {ratio:.0%})",
                })

    # 3) TUI 노이즈 잔존
    noise_found = []
    for pattern in TUI_NOISE_PATTERNS:
        matches = pattern.findall(clean_text)
        if matches:
            sample = matches[0].strip()[:40]
            noise_found.append(sample)
    if noise_found:
        issues.append({
            "type": "tui_noise",
            "detail": f"TUI 노이즈 {len(noise_found)}건: {', '.join(repr(n) for n in noise_found[:3])}",
        })

    # 4) 내용 중복 (동일 문장 2회 이상)
    if clean_len > MIN_SENTENCE_LEN * 2:
        duplicates = detect_duplicated_sentences(clean_text)
        if duplicates:
            issues.append({
                "type": "duplication",
                "detail": f"중복 문장 {len(duplicates)}건: {repr(duplicates[0][:50])}...",
            })

    # 5) 코드 펜스 미닫힘
    fence_count = clean_text.count("```")
    if fence_count % 2 != 0:
        issues.append({
            "type": "truncation",
            "detail": f"코드 펜스 {fence_count}개 (홀수 — 미닫힘)",
        })

    # 6) 문장 중간 끊김 (마지막 줄이 문장부호 없이 끝남)
    if clean_len > 50:
        last_line = clean_text.rstrip().split("\n")[-1].strip()
        if last_line and len(last_line) > 10:
            # 코드가 아닌 텍스트 줄이 문장부호 없이 끝남
            if not re.search(r'[.!?。！？:;)\]}>`"\'\-–—]$', last_line):
                if not re.match(r'^[\s`#\-*|]', last_line):  # 코드/마크다운 아님
                    issues.append({
                        "type": "truncation",
                        "detail": f"마지막 줄이 문장 중간에서 끊김: \"{last_line[-40:]}\"",
                    })

    # 7) 화면 대비 파싱 비율이 비정상적으로 낮음
    if screen_len > 200 and clean_len > 0:
        reduction = clean_len / screen_len
        if reduction < 0.05:  # 5% 미만
            issues.append({
                "type": "high_reduction",
                "detail": f"화면 {screen_len}자 → 파싱 {clean_len}자 ({reduction:.1%})",
            })

    # 8) 스트리밍 델타에 노이즈 포함
    if is_streaming and group["streaming_polls"]:
        noisy_deltas = 0
        for poll in group["streaming_polls"]:
            delta = poll.get("delta", "")
            for pattern in TUI_NOISE_PATTERNS:
                if pattern.search(delta):
                    noisy_deltas += 1
                    break
        if noisy_deltas > 0:
            total_polls = len(group["streaming_polls"])
            issues.append({
                "type": "streaming_noise",
                "detail": f"스트리밍 델타 {noisy_deltas}/{total_polls}개에 TUI 노이즈 포함",
            })

    return issues


def detect_duplicated_sentences(text):
    """텍스트에서 중복된 문장을 찾는다."""
    # 줄 단위로 분리 후 의미 있는 줄만
    lines = [l.strip() for l in text.split("\n") if len(l.strip()) >= MIN_SENTENCE_LEN]

    # 정규화: 공백 통일
    normalized = [re.sub(r'\s+', ' ', l) for l in lines]

    seen = Counter(normalized)
    duplicates = [line for line, count in seen.items() if count >= 2]
    return duplicates


# ──────────────────────────────────────────────────────────────
# Fixture 생성
# ──────────────────────────────────────────────────────────────

def build_fixture_case(msg_id, group):
    """하나의 메시지 그룹에서 fixture case를 생성."""
    sent = group["message_sent"]
    if not sent:
        return None

    is_streaming = sent.get("streaming", False)

    final_parsing = None
    for pr in group["parsing_results"]:
        if "complete" in pr.get("context", "").lower():
            final_parsing = pr
    if not final_parsing and group["parsing_results"]:
        final_parsing = group["parsing_results"][-1]

    # 품질 감지
    suspicious = detect_suspicious(group)

    case = {
        "id": msg_id,
        "type": "streaming" if is_streaming else "sync",
        "message": sent.get("text", ""),
        "adapterType": final_parsing.get("adapterType", "") if final_parsing else "",
        "screenText": final_parsing.get("screenText", "") if final_parsing else "",
        "expectedCleanText": final_parsing.get("cleanText", "") if final_parsing else "",
        "completionSignal": group["completion"]["signal"] if group["completion"] else "",
        "wasEmpty": (final_parsing.get("cleanLength", 0) == 0) if final_parsing else True,
        "hasError": len(group["errors"]) > 0,
        "suspicious": len(suspicious) > 0,
        "suspiciousReasons": [s["type"] for s in suspicious] if suspicious else [],
    }

    # 스트리밍 추가 데이터
    if is_streaming and group["streaming_polls"]:
        case["baseline"] = group["streaming_baseline"]["baseline"] if group["streaming_baseline"] else ""
        case["pollCount"] = len(group["streaming_polls"])
        case["totalDeltaLength"] = sum(p.get("deltaLength", 0) for p in group["streaming_polls"])
        polls = group["streaming_polls"]
        if len(polls) > 10:
            case["streamingDeltas"] = (
                [p["delta"] for p in polls[:5]] +
                ["... ({} polls omitted) ...".format(len(polls) - 10)] +
                [p["delta"] for p in polls[-5:]]
            )
        else:
            case["streamingDeltas"] = [p["delta"] for p in polls]

    # 에러/의심 상세
    if group["errors"]:
        case["errors"] = group["errors"]
    if suspicious:
        case["suspiciousDetails"] = suspicious

    return case


def extract_session_metadata(events):
    """로그에서 세션 메타데이터 추출."""
    for ev in events:
        if ev.get("event") == "session_start":
            data = ev.get("data", {})
            return {
                "sessionId": ev.get("sessionId", ""),
                "cliType": data.get("cliType", ""),
                "sessionName": data.get("name", ""),
                "startTime": ev.get("timestamp", ""),
            }
    if events:
        return {
            "sessionId": events[0].get("sessionId", "unknown"),
            "cliType": "",
            "sessionName": "",
            "startTime": events[0].get("timestamp", ""),
        }
    return {"sessionId": "unknown", "cliType": "", "sessionName": "", "startTime": ""}


def generate_fixture(log_path, events, groups, filters):
    """fixture JSON 생성."""
    meta = extract_session_metadata(events)

    cases = []
    for msg_id, group in groups.items():
        case = build_fixture_case(msg_id, group)
        if not case:
            continue

        # 필터 적용
        if filters.get("message_id") and case["id"] != filters["message_id"]:
            continue
        if filters.get("errors_only") and not case["hasError"]:
            continue
        if filters.get("empty_only") and not case["wasEmpty"]:
            continue
        if filters.get("suspicious_only") and not case["suspicious"]:
            continue

        cases.append(case)

    if not cases:
        return None

    fixture = {
        "metadata": {
            "source": os.path.basename(log_path),
            "extractedAt": datetime.now().isoformat(),
            "sessionId": meta["sessionId"],
            "cliType": meta["cliType"],
            "sessionName": meta["sessionName"],
            "totalMessages": len(groups),
            "extractedCases": len(cases),
            "description": "",
        },
        "cases": cases,
    }

    return fixture


# ──────────────────────────────────────────────────────────────
# 출력
# ──────────────────────────────────────────────────────────────

def print_file_summary(log_path, events, groups):
    """단일 파일의 요약 한 줄 출력."""
    meta = extract_session_metadata(events)
    file_size = os.path.getsize(log_path)
    size_str = format_size(file_size)

    total_msgs = len(groups)
    error_count = sum(1 for g in groups.values() if g["errors"])
    empty_count = sum(
        1 for g in groups.values()
        if g["parsing_results"] and g["parsing_results"][-1].get("cleanLength", 0) == 0
    )
    suspicious_count = sum(1 for g in groups.values() if detect_suspicious(g))

    status_parts = []
    if error_count:
        status_parts.append(f"❌ 에러 {error_count}")
    if empty_count:
        status_parts.append(f"⚠️ 빈응답 {empty_count}")
    if suspicious_count:
        status_parts.append(f"🔍 의심 {suspicious_count}")
    status = " | ".join(status_parts) if status_parts else "✅"

    cli = meta["cliType"] or "?"
    print(f"  [{cli}] {os.path.basename(log_path)} ({size_str}) — {total_msgs}건 {status}")


def print_detail_summary(log_path, events, groups):
    """상세 요약 출력."""
    meta = extract_session_metadata(events)
    print(f"\n{'='*60}")
    print(f"  로그 분석: {os.path.basename(log_path)}")
    print(f"{'='*60}")
    print(f"  세션 ID:    {meta['sessionId']}")
    print(f"  CLI 타입:   {meta['cliType']}")
    print(f"  세션 이름:  {meta['sessionName']}")
    print(f"  총 이벤트:  {len(events)}")
    print(f"  메시지 수:  {len(groups)}")
    print()

    for msg_id, group in groups.items():
        sent = group["message_sent"]
        if not sent:
            continue

        msg_preview = sent["text"][:50] + ("..." if len(sent["text"]) > 50 else "")
        mode = "스트리밍" if sent["streaming"] else "동기"

        final_pr = None
        for pr in group["parsing_results"]:
            if "complete" in pr.get("context", "").lower():
                final_pr = pr
        if not final_pr and group["parsing_results"]:
            final_pr = group["parsing_results"][-1]

        clean_len = final_pr["cleanLength"] if final_pr else 0
        screen_len = final_pr["screenLength"] if final_pr else 0
        adapter = final_pr["adapterType"] if final_pr else "?"
        signal = group["completion"]["signal"] if group["completion"] else "?"

        # 품질 감지
        suspicious = detect_suspicious(group)
        has_error = group["errors"]
        is_empty = clean_len == 0

        if has_error:
            icon = "❌"
        elif is_empty:
            icon = "⚠️"
        elif suspicious:
            icon = "🔍"
        else:
            icon = "✅"

        empty_flag = " ⚠️빈응답" if is_empty else ""

        print(f"  {icon} [{mode}] {msg_id}")
        print(f"     메시지: \"{msg_preview}\"")
        print(f"     어댑터: {adapter} | 완료: {signal}")
        print(f"     화면: {screen_len}자 → 파싱: {clean_len}자{empty_flag}")
        if group["streaming_polls"]:
            total_streamed = sum(p.get("deltaLength", 0) for p in group["streaming_polls"])
            print(f"     폴링: {len(group['streaming_polls'])}회, 누적 {total_streamed}자")
        if has_error:
            for err in group["errors"]:
                print(f"     ❌ 에러: {err['message']} ({err['context']})")
        if suspicious:
            for s in suspicious:
                print(f"     🔍 {s['type']}: {s['detail']}")
        print()

    print(f"{'='*60}\n")


def format_size(size_bytes):
    """바이트를 사람이 읽기 좋은 형식으로 변환."""
    if size_bytes < 1024:
        return f"{size_bytes}B"
    elif size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.1f}KB"
    else:
        return f"{size_bytes / (1024 * 1024):.1f}MB"


def has_interesting_cases(groups, filters):
    """필터 조건에 맞는 주목할 만한 케이스가 있는지 확인."""
    for msg_id, group in groups.items():
        case = build_fixture_case(msg_id, group)
        if not case:
            continue
        if filters.get("message_id") and case["id"] != filters["message_id"]:
            continue
        if filters.get("errors_only") and not case["hasError"]:
            continue
        if filters.get("empty_only") and not case["wasEmpty"]:
            continue
        if filters.get("suspicious_only") and not case["suspicious"]:
            continue
        return True
    return False


def process_single_file(log_path, args, filters):
    """단일 로그 파일 처리."""
    events = load_log(log_path)
    if not events:
        return None

    groups = group_by_message(events)
    if not groups:
        return None

    if args.summary:
        print_detail_summary(log_path, events, groups)
        return None

    if not has_interesting_cases(groups, filters):
        return None

    fixture = generate_fixture(log_path, events, groups, filters)
    if not fixture:
        return None

    # 출력 파일명
    meta = fixture["metadata"]
    session_id = meta["sessionId"][:8] if meta["sessionId"] else "unknown"
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    source_hash = abs(hash(os.path.basename(log_path))) % 10000

    suffix = ""
    if args.errors_only:
        suffix = "_errors"
    elif args.empty_only:
        suffix = "_empty"
    elif args.suspicious_only:
        suffix = "_suspicious"
    elif getattr(args, 'message_id', None):
        suffix = f"_{args.message_id[:12]}"

    filename = f"fixture_{session_id}{suffix}_{timestamp}_{source_hash:04d}.json"

    os.makedirs(args.output_dir, exist_ok=True)
    output_path = os.path.join(args.output_dir, filename)

    indent = None if args.compact else 2
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(fixture, f, ensure_ascii=False, indent=indent)

    return output_path, fixture


def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="로그 파일에서 회귀 테스트용 fixture 추출",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
예시:
  # 로그 디렉토리 전체 스캔 (문제 있는 케이스만 추출)
  python3 tools/extract_fixtures.py

  # 오늘 로그만 스캔
  python3 tools/extract_fixtures.py --today

  # 최근 3일 로그 스캔
  python3 tools/extract_fixtures.py --days 3

  # 특정 파일 지정
  python3 tools/extract_fixtures.py path/to/log.jsonl

  # 전체 요약만 출력
  python3 tools/extract_fixtures.py --summary

  # 필터 옵션
  python3 tools/extract_fixtures.py --empty-only        # 빈 응답만
  python3 tools/extract_fixtures.py --errors-only       # 에러만
  python3 tools/extract_fixtures.py --suspicious-only   # 의심 케이스만

품질 감지 (🔍 의심 케이스):
  timeout          — 타임아웃으로 완료
  streaming_gap    — 스트리밍 누적 ≠ 최종 응답 (>20% 차이)
  tui_noise        — 응답에 TUI chrome 잔존
  duplication      — 동일 문장 반복
  truncation       — 코드 펜스 미닫힘, 문장 중간 끊김
  high_reduction   — 화면 대비 파싱 결과 <5%
  streaming_noise  — 스트리밍 델타에 TUI 노이즈
        """,
    )
    parser.add_argument("logfile", nargs="?", default=None,
                        help="JSONL 로그 파일 경로 (미지정 시 로그 디렉토리 전체 스캔)")
    parser.add_argument("--log-dir", default=DEFAULT_LOG_DIR,
                        help=f"로그 디렉토리 (기본: {DEFAULT_LOG_DIR})")
    parser.add_argument("--output-dir", "-o", default="ConsolentTests/Fixtures",
                        help="fixture 출력 디렉토리 (기본: ConsolentTests/Fixtures)")
    parser.add_argument("--today", "-t", action="store_true", help="오늘 로그만 스캔")
    parser.add_argument("--days", "-d", type=int, default=None, help="최근 N일 로그만 스캔")
    parser.add_argument("--message-id", "-m", help="특정 messageId만 추출")
    parser.add_argument("--errors-only", "-e", action="store_true", help="에러 케이스만")
    parser.add_argument("--empty-only", action="store_true", help="빈 응답만")
    parser.add_argument("--suspicious-only", action="store_true", help="의심 케이스만")
    parser.add_argument("--all", "-a", action="store_true",
                        help="모든 케이스 추출 (기본: 문제 있는 것만)")
    parser.add_argument("--summary", "-s", action="store_true", help="요약만 출력 (fixture 미생성)")
    parser.add_argument("--pretty", action="store_true", default=True, help="JSON 정렬 출력 (기본)")
    parser.add_argument("--compact", action="store_true", help="JSON 압축 출력")

    args = parser.parse_args()

    filters = {
        "message_id": args.message_id,
        "errors_only": args.errors_only,
        "empty_only": args.empty_only,
        "suspicious_only": args.suspicious_only,
    }

    # 파일 목록 결정
    if args.logfile:
        if not os.path.isfile(args.logfile):
            print(f"오류: 파일을 찾을 수 없습니다: {args.logfile}", file=sys.stderr)
            sys.exit(1)
        log_files = [args.logfile]
    else:
        log_files = find_log_files(args.log_dir, days=args.days, today=args.today)
        if not log_files:
            print(f"로그 파일이 없습니다: {args.log_dir}")
            if not os.path.isdir(args.log_dir):
                print("  (로그 디렉토리가 존재하지 않습니다. 설정에서 로그 레벨을 INFO 이상으로 설정하세요.)")
            sys.exit(0)

        if not args.all and not any([args.errors_only, args.empty_only, args.suspicious_only,
                                      args.message_id, args.summary]):
            print("💡 기본: 에러/빈응답/의심 케이스만 추출합니다. 전체 추출은 --all 옵션.\n")

    # 전체 스캔 헤더
    if not args.logfile:
        scope = "오늘" if args.today else f"최근 {args.days}일" if args.days else "전체"
        print(f"📂 로그 디렉토리: {args.log_dir}")
        print(f"📋 스캔 범위: {scope} ({len(log_files)}개 파일)\n")

    # 파일별 처리
    total_files = 0
    total_errors = 0
    total_empty = 0
    total_suspicious = 0
    total_cases = 0
    generated_fixtures = []

    for log_path in log_files:
        events = load_log(log_path)
        if not events:
            continue

        groups = group_by_message(events)
        if not groups:
            continue

        total_files += 1

        # 파일별 요약
        if not args.logfile:
            print_file_summary(log_path, events, groups)

        # 통계
        for g in groups.values():
            if g["errors"]:
                total_errors += 1
            prs = g["parsing_results"]
            if prs and prs[-1].get("cleanLength", 0) == 0:
                total_empty += 1
            if detect_suspicious(g):
                total_suspicious += 1

        # 상세 요약
        if args.summary:
            if args.logfile:
                print_detail_summary(log_path, events, groups)
            continue

        # 디렉토리 스캔 시 기본은 문제 케이스만
        effective_filters = dict(filters)
        if not args.logfile and not args.all and not any([args.errors_only, args.empty_only,
                                                          args.suspicious_only, args.message_id]):
            has_problems = any(
                g["errors"]
                or (g["parsing_results"] and g["parsing_results"][-1].get("cleanLength", 0) == 0)
                or detect_suspicious(g)
                for g in groups.values()
            )
            if not has_problems:
                continue

        result = process_single_file(log_path, args, effective_filters)
        if result:
            output_path, fixture = result
            case_count = len(fixture["cases"])
            total_cases += case_count
            generated_fixtures.append((output_path, case_count))

    # 최종 리포트
    print(f"\n{'='*60}")
    print(f"  스캔 결과")
    print(f"{'='*60}")
    print(f"  파일:   {total_files}개 스캔")
    print(f"  에러:   {total_errors}건")
    print(f"  빈응답: {total_empty}건")
    print(f"  의심:   {total_suspicious}건")

    if not args.summary:
        if generated_fixtures:
            print(f"\n  생성된 fixture:")
            for path, count in generated_fixtures:
                print(f"    → {path} ({count}건)")
            print(f"\n  총 {total_cases}개 케이스 추출")
            print(f"\n💡 description 필드를 수동으로 채우면 테스트 실패 시 원인 파악이 쉬워집니다.")
        else:
            if total_files > 0:
                print(f"\n  추출할 케이스가 없습니다.")
            else:
                print(f"\n  처리할 로그 파일이 없습니다.")

    print(f"{'='*60}\n")


if __name__ == "__main__":
    main()
