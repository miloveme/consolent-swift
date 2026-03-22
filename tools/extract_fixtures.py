#!/usr/bin/env python3
"""
로그 파일에서 회귀 테스트용 fixture를 자동 추출한다.

사용법:
    python3 tools/extract_fixtures.py <log.jsonl> [--output-dir ConsolentTests/Fixtures]
    python3 tools/extract_fixtures.py <log.jsonl> --message-id msg_xxx   # 특정 메시지만
    python3 tools/extract_fixtures.py <log.jsonl> --errors-only           # 에러 케이스만
    python3 tools/extract_fixtures.py <log.jsonl> --empty-only            # 빈 응답만

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
import argparse
from collections import defaultdict
from datetime import datetime


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


def print_summary(events, groups):
    """로그 요약 출력."""
    meta = extract_session_metadata(events)
    print(f"\n{'='*60}")
    print(f"  로그 분석 요약")
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


def main():
    parser = argparse.ArgumentParser(
        description="로그 파일에서 회귀 테스트용 fixture 추출",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
예시:
  # 로그 분석만 (fixture 생성 없이 요약 출력)
  python3 tools/extract_fixtures.py logs/session.jsonl --summary

  # 전체 fixture 추출
  python3 tools/extract_fixtures.py logs/session.jsonl

  # 특정 메시지만 추출
  python3 tools/extract_fixtures.py logs/session.jsonl --message-id msg_abc123

  # 빈 응답 / 에러 케이스만
  python3 tools/extract_fixtures.py logs/session.jsonl --empty-only
  python3 tools/extract_fixtures.py logs/session.jsonl --errors-only
        """,
    )
    parser.add_argument("logfile", help="JSONL 로그 파일 경로")
    parser.add_argument("--output-dir", "-o", default="ConsolentTests/Fixtures",
                        help="fixture 출력 디렉토리 (기본: ConsolentTests/Fixtures)")
    parser.add_argument("--message-id", "-m", help="특정 messageId만 추출")
    parser.add_argument("--errors-only", "-e", action="store_true", help="에러 케이스만")
    parser.add_argument("--empty-only", action="store_true", help="빈 응답만")
    parser.add_argument("--summary", "-s", action="store_true", help="요약만 출력 (fixture 미생성)")
    parser.add_argument("--pretty", action="store_true", default=True, help="JSON 정렬 출력 (기본)")
    parser.add_argument("--compact", action="store_true", help="JSON 압축 출력")

    args = parser.parse_args()

    if not os.path.isfile(args.logfile):
        print(f"오류: 파일을 찾을 수 없습니다: {args.logfile}", file=sys.stderr)
        sys.exit(1)

    print(f"로그 로딩: {args.logfile}")
    events = load_log(args.logfile)

    if not events:
        print("이벤트가 없습니다.", file=sys.stderr)
        sys.exit(1)

    groups = group_by_message(events)
    print_summary(events, groups)

    if args.summary:
        return

    # Fixture 생성
    filters = {
        "message_id": args.message_id,
        "errors_only": args.errors_only,
        "empty_only": args.empty_only,
    }

    fixture = generate_fixture(args.logfile, events, groups, filters)

    if not fixture:
        print("필터 조건에 맞는 케이스가 없습니다.")
        sys.exit(0)

    # 출력 파일명 생성
    meta = fixture["metadata"]
    session_id = meta["sessionId"][:8] if meta["sessionId"] else "unknown"
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")

    suffix = ""
    if args.errors_only:
        suffix = "_errors"
    elif args.empty_only:
        suffix = "_empty"
    elif args.message_id:
        suffix = f"_{args.message_id[:12]}"

    filename = f"fixture_{session_id}{suffix}_{timestamp}.json"

    os.makedirs(args.output_dir, exist_ok=True)
    output_path = os.path.join(args.output_dir, filename)

    indent = None if args.compact else 2
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(fixture, f, ensure_ascii=False, indent=indent)

    print(f"Fixture 생성 완료: {output_path}")
    print(f"  케이스 수: {len(fixture['cases'])}")
    print(f"  빈 응답:   {sum(1 for c in fixture['cases'] if c['wasEmpty'])}개")
    print(f"  에러:      {sum(1 for c in fixture['cases'] if c['hasError'])}개")
    print()
    print("💡 description 필드를 수동으로 채우면 테스트 실패 시 원인 파악이 쉬워집니다.")


if __name__ == "__main__":
    main()
