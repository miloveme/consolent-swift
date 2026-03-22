#!/bin/bash
#
# 로그 기반 회귀 테스트 한방 스크립트
#
# 사용법:
#   ./tools/log_test.sh              # 추출 + 테스트 + 실패만 출력
#   ./tools/log_test.sh --skip-extract  # 추출 건너뛰고 테스트만
#   ./tools/log_test.sh --today      # 오늘 로그만 추출
#   ./tools/log_test.sh --days 3     # 최근 3일 로그만 추출
#   ./tools/log_test.sh --all        # 전체 케이스 추출
#

set -euo pipefail

cd "$(dirname "$0")/.."

EXTRACT_ARGS=()
SKIP_EXTRACT=false

for arg in "$@"; do
    case "$arg" in
        --skip-extract) SKIP_EXTRACT=true ;;
        *) EXTRACT_ARGS+=("$arg") ;;
    esac
done

# ── 1. Fixture 추출 ──

if [ "$SKIP_EXTRACT" = false ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  1/3  Fixture 추출"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    python3 tools/extract_fixtures.py ${EXTRACT_ARGS[@]+"${EXTRACT_ARGS[@]}"}
    echo ""
fi

# ── 2. 테스트 실행 ──

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  2/3  회귀 테스트 실행"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

TEST_OUTPUT=$(xcodebuild test \
    -project Consolent.xcodeproj \
    -scheme Consolent \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:ConsolentTests/RegressionTests \
    2>&1) || true

# ── 3. 결과 분석 ──

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  3/3  결과"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 통과/실패 요약
PASSED=$(echo "$TEST_OUTPUT" | grep -c "passed" || true)
FAILED_LINES=$(echo "$TEST_OUTPUT" | grep "error:.*failed" || true)
FAILED_COUNT=$(echo "$FAILED_LINES" | grep -c "error:" || true)

if [ -z "$FAILED_LINES" ]; then
    FAILED_COUNT=0
fi

echo "  ✅ 통과: ${PASSED}개"
echo "  ❌ 실패: ${FAILED_COUNT}개"
echo ""

if [ "$FAILED_COUNT" -gt 0 ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  실패 상세"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # 실패 메시지 + 상세 내용
    echo "$TEST_OUTPUT" | grep -A10 'error:.*failed' | while IFS= read -r line; do
        # error: 줄이면 구분선 추가
        if echo "$line" | grep -q 'error:.*failed'; then
            echo "  ──────────────────────────────────────────"
        fi
        echo "  $line"
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  💡 이 출력을 Claude에게 붙여넣으면 어댑터 수정을 도와줍니다."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
else
    echo "  🎉 모든 회귀 테스트 통과!"

    # resolve 안내
    RESOLVE_HINT=$(echo "$TEST_OUTPUT" | grep "resolve 가능" || true)
    if [ -n "$RESOLVE_HINT" ]; then
        echo ""
        echo "  $RESOLVE_HINT"
        echo "  → python3 tools/extract_fixtures.py --resolve --confirm"
    fi

    exit 0
fi
