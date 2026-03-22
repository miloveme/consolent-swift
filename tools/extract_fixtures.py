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
"""

import json
import sys
import os
import glob
import argparse
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path


# 기본 로그 디렉토리
DEFAULT_LOG_DIR = os.path.expanduser("~/Library/Logs/Consolent/debug")


def find_log_files(log_dir, days=None, today=False):
    """로그 디렉토리에서 .jsonl 파일 목록을 반환.

    Args:
        log_dir: 로그 루트 디렉토리
        days: 최근 N일만 (None이면 전체)
        today: 오늘만
    """
    if not os.path.isdir(log_dir):
        return []

    # 날짜 디렉토리 목록 (yyyy-MM-dd 형식)
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
    """이벤트를 messageId 기준으로 그룹핑.

    message_sent 이벤트의 messageId를 키로 사용하고,
    그 이후의 이벤트를 같은 그룹에 추가한다.
    """
    groups = defaultdict(lambda: {
        "message_sent": None,
        "parsing_results": [],
        "streaming_polls": [],
        "streaming_baseline": None,
        "completion": None,
        "errors": [],
        "screen_buffers": [],
    })

    # 현재 활성 messageId 추적
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


def build_fixture_case(msg_id, group):
    """하나의 메시지 그룹에서 fixture case를 생성."""
    sent = group["message_sent"]
    if not sent:
        return None

    is_streaming = sent.get("streaming", False)

    # 최종 parsing_result 사용 (completeResponse/completeStreamingResponse에서 기록)
    final_parsing = None
    for pr in group["parsing_results"]:
        ctx = pr.get("context", "")
        if "complete" in ctx.lower():
            final_parsing = pr

    # complete 컨텍스트가 없으면 마지막 parsing_result 사용
    if not final_parsing and group["parsing_results"]:
        final_parsing = group["parsing_results"][-1]

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
    }

    # 스트리밍인 경우 추가 데이터
    if is_streaming and group["streaming_polls"]:
        case["baseline"] = group["streaming_baseline"]["baseline"] if group["streaming_baseline"] else ""
        case["pollCount"] = len(group["streaming_polls"])
        case["totalDeltaLength"] = sum(p.get("deltaLength", 0) for p in group["streaming_polls"])
        # 스트리밍 델타 시퀀스 (디버깅용, 너무 크면 처음/마지막 5개만)
        polls = group["streaming_polls"]
        if len(polls) > 10:
            case["streamingDeltas"] = (
                [p["delta"] for p in polls[:5]] +
                ["... ({} polls omitted) ...".format(len(polls) - 10)] +
                [p["delta"] for p in polls[-5:]]
            )
        else:
            case["streamingDeltas"] = [p["delta"] for p in polls]

    # 에러 정보
    if group["errors"]:
        case["errors"] = group["errors"]

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
    # session_start가 없으면 (분할된 로그 등) 첫 이벤트에서 추출
    if events:
        return {
            "sessionId": events[0].get("sessionId", "unknown"),
            "cliType": "",
            "sessionName": "",
            "startTime": events[0].get("timestamp", ""),
        }
    return {"sessionId": "unknown", "cliType": "", "sessionName": "", "startTime": ""}


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
        return True
    return False


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
            "description": "",  # 사용자가 수동으로 채움
        },
        "cases": cases,
    }

    return fixture


def print_file_summary(log_path, events, groups):
    """단일 파일의 요약 출력."""
    meta = extract_session_metadata(events)
    file_size = os.path.getsize(log_path)
    size_str = format_size(file_size)

    total_msgs = len(groups)
    error_count = sum(1 for g in groups.values() if g["errors"])
    empty_count = sum(
        1 for g in groups.values()
        if g["parsing_results"] and g["parsing_results"][-1].get("cleanLength", 0) == 0
    )

    status_parts = []
    if error_count:
        status_parts.append(f"❌ 에러 {error_count}")
    if empty_count:
        status_parts.append(f"⚠️ 빈응답 {empty_count}")
    status = " | ".join(status_parts) if status_parts else "✅"

    cli = meta["cliType"] or "?"
    print(f"  [{cli}] {os.path.basename(log_path)} ({size_str}) — {total_msgs}건 {status}")


def print_detail_summary(log_path, events, groups):
    """상세 요약 출력."""
    meta = extract_session_metadata(events)
    print(f"\n{'='*60}")
    print(f"  로그 분석 요약: {os.path.basename(log_path)}")
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
        has_error = "❌" if group["errors"] else "✅"
        empty_flag = " ⚠️빈응답" if clean_len == 0 else ""

        print(f"  {has_error} [{mode}] {msg_id}")
        print(f"     메시지: \"{msg_preview}\"")
        print(f"     어댑터: {adapter} | 완료: {signal}")
        print(f"     화면: {screen_len}자 → 파싱: {clean_len}자{empty_flag}")
        if group["streaming_polls"]:
            print(f"     폴링: {len(group['streaming_polls'])}회")
        if group["errors"]:
            for err in group["errors"]:
                print(f"     에러: {err['message']} ({err['context']})")
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


def process_single_file(log_path, args, filters):
    """단일 로그 파일 처리. fixture를 생성하면 경로 반환, 아니면 None."""
    events = load_log(log_path)
    if not events:
        return None

    groups = group_by_message(events)
    if not groups:
        return None

    # 상세 요약 모드
    if args.summary:
        print_detail_summary(log_path, events, groups)
        return None

    # 필터 조건에 맞는 케이스가 없으면 건너뜀
    if not has_interesting_cases(groups, filters):
        return None

    fixture = generate_fixture(log_path, events, groups, filters)
    if not fixture:
        return None

    # 출력 파일명 생성
    meta = fixture["metadata"]
    session_id = meta["sessionId"][:8] if meta["sessionId"] else "unknown"
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    # 파일 단위 고유성을 위해 원본 파일명 해시 추가
    source_hash = abs(hash(os.path.basename(log_path))) % 10000

    suffix = ""
    if args.errors_only:
        suffix = "_errors"
    elif args.empty_only:
        suffix = "_empty"
    elif args.message_id:
        suffix = f"_{args.message_id[:12]}"

    filename = f"fixture_{session_id}{suffix}_{timestamp}_{source_hash:04d}.json"

    os.makedirs(args.output_dir, exist_ok=True)
    output_path = os.path.join(args.output_dir, filename)

    indent = None if args.compact else 2
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(fixture, f, ensure_ascii=False, indent=indent)

    return output_path, fixture


def main():
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

  # 빈 응답 / 에러 케이스만
  python3 tools/extract_fixtures.py --empty-only
  python3 tools/extract_fixtures.py --errors-only
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
    parser.add_argument("--all", "-a", action="store_true",
                        help="모든 케이스 추출 (기본: 에러/빈응답만)")
    parser.add_argument("--summary", "-s", action="store_true", help="요약만 출력 (fixture 미생성)")
    parser.add_argument("--pretty", action="store_true", default=True, help="JSON 정렬 출력 (기본)")
    parser.add_argument("--compact", action="store_true", help="JSON 압축 출력")

    args = parser.parse_args()

    # 필터 결정: 기본은 에러+빈응답만. --all이면 전체.
    filters = {
        "message_id": args.message_id,
        "errors_only": args.errors_only,
        "empty_only": args.empty_only,
    }

    # 특정 파일 지정
    if args.logfile:
        if not os.path.isfile(args.logfile):
            print(f"오류: 파일을 찾을 수 없습니다: {args.logfile}", file=sys.stderr)
            sys.exit(1)
        log_files = [args.logfile]
    else:
        # 디렉토리 전체 스캔
        log_files = find_log_files(args.log_dir, days=args.days, today=args.today)
        if not log_files:
            print(f"로그 파일이 없습니다: {args.log_dir}")
            if not os.path.isdir(args.log_dir):
                print("  (로그 디렉토리가 존재하지 않습니다. 설정에서 로그 레벨을 INFO 이상으로 설정하세요.)")
            sys.exit(0)

        # --all이 아니고 필터도 없으면 기본적으로 문제 있는 케이스만 추출
        if not args.all and not args.errors_only and not args.empty_only and not args.message_id and not args.summary:
            print("💡 기본: 에러/빈응답 케이스만 추출합니다. 전체 추출은 --all 옵션 사용.\n")

    # 전체 스캔 헤더
    if not args.logfile:
        scope = "오늘" if args.today else f"최근 {args.days}일" if args.days else "전체"
        print(f"📂 로그 디렉토리: {args.log_dir}")
        print(f"📋 스캔 범위: {scope} ({len(log_files)}개 파일)\n")

    # 파일별 처리
    total_files = 0
    total_cases = 0
    total_errors = 0
    total_empty = 0
    generated_fixtures = []

    for log_path in log_files:
        events = load_log(log_path)
        if not events:
            continue

        groups = group_by_message(events)
        if not groups:
            continue

        total_files += 1

        # 파일별 요약 한 줄 출력
        if not args.logfile:
            print_file_summary(log_path, events, groups)

        # 통계
        for g in groups.values():
            if g["errors"]:
                total_errors += 1
            prs = g["parsing_results"]
            if prs and prs[-1].get("cleanLength", 0) == 0:
                total_empty += 1

        # 상세 요약 모드
        if args.summary:
            if args.logfile:
                print_detail_summary(log_path, events, groups)
            continue

        # 디렉토리 스캔 시 --all이 아니면 문제 케이스만 추출
        effective_filters = dict(filters)
        if not args.logfile and not args.all and not args.errors_only and not args.empty_only and not args.message_id:
            # 에러 또는 빈 응답이 있는 케이스만
            has_problems = any(
                g["errors"] or (g["parsing_results"] and g["parsing_results"][-1].get("cleanLength", 0) == 0)
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
    print(f"  파일: {total_files}개 스캔")
    print(f"  에러: {total_errors}건")
    print(f"  빈응답: {total_empty}건")

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
