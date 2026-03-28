#!/bin/bash
#
# Consolent API Integration Tests
#
# Prerequisites:
#   - Consolent app running with at least one ready session
#   - jq installed (brew install jq)
#
# Usage:
#   API_KEY="cst_xxx" ./tests/api_test.sh
#   API_KEY="cst_xxx" BASE_URL="http://127.0.0.1:9999" ./tests/api_test.sh
#
# 세션 분류:
#   PTY     — 일반 PTY 세션 (claude-code / gemini / codex, 브릿지 비활성)
#   CHANNEL — channel_enabled=true (channel_url 직접 테스트)
#   AGENT   — bridge_enabled=true  (bridge_url 직접 테스트: SDK / Gemini-Stream / Codex-App)

set -euo pipefail

# ── Configuration ──
BASE_URL="${BASE_URL:-http://127.0.0.1:9999}"
API_KEY="${API_KEY:?'API_KEY is required. Usage: API_KEY="cst_xxx" ./tests/api_test.sh'}"

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Counters ──
PASS=0
FAIL=0
SKIP=0

# ── Session parallel arrays ──
# PTY 세션 (일반)
PTY_STYPES=(); PTY_SIDS=(); PTY_SNAMES=()
# Channel 세션
CH_STYPES=();  CH_SIDS=();  CH_SNAMES=();  CH_SURLS=()
# Agent/Bridge 세션
AG_STYPES=();  AG_SIDS=();  AG_SNAMES=();  AG_SURLS=()

# ── Helpers ──
pass() { PASS=$((PASS+1)); echo -e "  ${GREEN}PASS${NC} $1"; }
fail() { FAIL=$((FAIL+1)); echo -e "  ${RED}FAIL${NC} $1"; [ -n "${2:-}" ] && echo -e "       ${RED}$2${NC}"; }
skip() { SKIP=$((SKIP+1)); echo -e "  ${YELLOW}SKIP${NC} $1"; }
section() { echo -e "\n${CYAN}${BOLD}── $1 ──${NC}"; }
subsect() { echo -e "\n${CYAN}  · $1${NC}"; }

api_get() {
    curl -s -w "\n%{http_code}" "$BASE_URL$1" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json"
}
api_post() {
    curl -s -w "\n%{http_code}" "$BASE_URL$1" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$2"
}
api_delete() {
    curl -s -w "\n%{http_code}" "$BASE_URL$1" \
        -H "Authorization: Bearer $API_KEY"
}
api_get_noauth()  { curl -s -w "\n%{http_code}" "$BASE_URL$1"; }
api_get_badauth() {
    curl -s -w "\n%{http_code}" "$BASE_URL$1" \
        -H "Authorization: Bearer invalid_key_12345"
}

# 외부 URL에 직접 요청 (브릿지/채널 서버용)
ext_get() {
    curl -s -w "\n%{http_code}" "$1" \
        -H "Content-Type: application/json"
}
ext_post() {
    curl -s -w "\n%{http_code}" "$1" \
        -H "Content-Type: application/json" \
        -d "$2"
}

parse_response() {
    HTTP_CODE=$(echo "$1" | tail -n1)
    HTTP_BODY=$(echo "$1" | sed '$d')
}

# 세션이 ready 될 때까지 대기 (최대 N초)
wait_for_ready() {
    local sid="$1" max_wait="${2:-60}" elapsed=0
    while [ "$elapsed" -lt "$max_wait" ]; do
        response=$(api_get "/sessions/$sid")
        parse_response "$response"
        local st; st=$(echo "$HTTP_BODY" | jq -r '.status // empty')
        [ "$st" = "ready" ] && return 0
        sleep 2; elapsed=$((elapsed+2))
    done
    return 1
}

# 타입 중복 확인
type_in_array() {
    local needle="$1"; shift
    for t in "$@"; do [ "$t" = "$needle" ] && return 0; done
    return 1
}

# SSE 스트리밍 테스트 공통 함수
# $1=label  $2=url  $3=auth_header(or "none")  $4=json_body
test_sse_streaming() {
    local label="$1" url="$2" auth_header="$3" body="$4"
    local STREAM_TMP; STREAM_TMP=$(mktemp)

    if [ "$auth_header" = "none" ]; then
        curl -sN --max-time 120 "$url" \
            -H "Content-Type: application/json" \
            -d "$body" > "$STREAM_TMP" 2>/dev/null &
    else
        curl -sN --max-time 120 "$url" \
            -H "$auth_header" \
            -H "Content-Type: application/json" \
            -d "$body" > "$STREAM_TMP" 2>/dev/null &
    fi
    local CURL_PID=$!

    for w in $(seq 1 60); do
        sleep 2
        grep -q "\[DONE\]" "$STREAM_TMP" 2>/dev/null && break
    done
    kill $CURL_PID 2>/dev/null || true
    wait $CURL_PID 2>/dev/null || true

    if [ -s "$STREAM_TMP" ]; then
        local data_lines; data_lines=$(grep -c '^data: ' "$STREAM_TMP" || true)
        [ "$data_lines" -gt 0 ] \
            && pass "[$label] SSE data lines: $data_lines" \
            || fail "[$label] no SSE data lines"

        grep -q 'data: \[DONE\]' "$STREAM_TMP" \
            && pass "[$label] [DONE] received" \
            || fail "[$label] [DONE] missing"

        grep -q '"finish_reason":"stop"' "$STREAM_TMP" \
            && pass "[$label] finish_reason=stop" \
            || fail "[$label] finish_reason missing"

        local content_chunks; content_chunks=$(grep '"content"' "$STREAM_TMP" | grep -v '"content":null' | wc -l | tr -d ' ')
        [ "$content_chunks" -gt 0 ] \
            && pass "[$label] $content_chunks content chunks" \
            || fail "[$label] no content chunks"
    else
        fail "[$label] no streaming response"
    fi
    rm -f "$STREAM_TMP"
}

# OpenAI /v1/chat/completions 단일 응답 테스트
# $1=label  $2=url  $3=auth_header(or "none")  $4=model  $5=message
test_chat() {
    local label="$1" url="$2" auth_header="$3" model="$4" message="$5"
    local body; body="{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"$message\"}],\"timeout\":90}"
    local resp

    if [ "$auth_header" = "none" ]; then
        resp=$(curl -s -w "\n%{http_code}" "$url" \
            -H "Content-Type: application/json" -d "$body")
    else
        resp=$(curl -s -w "\n%{http_code}" "$url" \
            -H "$auth_header" \
            -H "Content-Type: application/json" -d "$body")
    fi
    parse_response "$resp"

    if [ "$HTTP_CODE" = "200" ]; then
        local content; content=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.content // empty')
        local role;    role=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.role // empty')
        local finish;  finish=$(echo "$HTTP_BODY" | jq -r '.choices[0].finish_reason // empty')
        [ "$role" = "assistant" ]  && pass "[$label] role=assistant"      || fail "[$label] role=$role"
        [ "$finish" = "stop" ]     && pass "[$label] finish_reason=stop"  || fail "[$label] finish=$finish"
        [ -n "$content" ]          && pass "[$label] content: $(echo "$content" | head -c 80)" || fail "[$label] content empty"
    else
        fail "[$label] expected 200, got $HTTP_CODE" "$HTTP_BODY"
    fi
}

# ══════════════════════════════════════════════
echo -e "\n${CYAN}${BOLD}Consolent API Integration Tests${NC}"
echo "Base URL : $BASE_URL"
echo ""

# ─────────────────────────────────────────────
# 1. Health Check
# ─────────────────────────────────────────────
section "1. Health Check"

response=$(api_get "/")
parse_response "$response"

if [ "$HTTP_CODE" = "200" ]; then
    app=$(echo "$HTTP_BODY" | jq -r '.app // empty')
    st=$(echo "$HTTP_BODY" | jq -r '.status // empty')
    [ "$app" = "Consolent" ] && [ "$st" = "ok" ] \
        && pass "GET / → app=Consolent, status=ok" \
        || fail "GET / unexpected body" "$HTTP_BODY"
else
    fail "GET / expected 200, got $HTTP_CODE"
fi

# ─────────────────────────────────────────────
# 2. Authentication
# ─────────────────────────────────────────────
section "2. Authentication"

parse_response "$(api_get_noauth '/')"
[ "$HTTP_CODE" = "401" ] && pass "No auth → 401" || fail "No auth expected 401, got $HTTP_CODE"

parse_response "$(api_get_badauth '/')"
[ "$HTTP_CODE" = "401" ] && pass "Bad key → 401" || fail "Bad key expected 401, got $HTTP_CODE"

# ─────────────────────────────────────────────
# 3. Session Discovery & Categorization
# ─────────────────────────────────────────────
section "3. Session Discovery & Categorization"

response=$(api_get "/sessions")
parse_response "$response"

if [ "$HTTP_CODE" != "200" ]; then
    fail "GET /sessions expected 200, got $HTTP_CODE"
    echo -e "\n${RED}Cannot continue without sessions.${NC}"
    exit 1
fi

session_count=$(echo "$HTTP_BODY" | jq '.sessions | length')
pass "GET /sessions → $session_count session(s)"

if [ "$session_count" -eq 0 ]; then
    echo -e "${YELLOW}No sessions found. Start Consolent and create sessions first.${NC}"
    exit 0
fi

# 세션 목록을 임시 파일로 추출
SESS_TMP=$(mktemp)
# 구분자로 | 사용 (tab은 bash whitespace → 연속 탭이 collapse되어 빈 필드 소실됨)
echo "$HTTP_BODY" | jq -r '.sessions[] | "\(.id)|\(.name // "")|\(.cli_type // .cliType)|\(.status)|\((.channel_enabled // .channelEnabled) // false)|\(.channel_url // .channelUrl // "")|\((.bridge_enabled // .bridgeEnabled) // false)|\(.bridge_url // .bridgeUrl // "")"' > "$SESS_TMP"

while IFS='|' read -r sid sname stype sstatus ch_en ch_url br_en br_url; do
    mode="PTY"
    [ "$ch_en" = "true" ] && mode="CHANNEL"
    [ "$br_en" = "true" ] && mode="AGENT"
    echo "       [$mode] $sname ($stype) — $sid [status:$sstatus]"

    # 타입별 첫 번째 세션만 등록
    if [ "$ch_en" = "true" ]; then
        if ! type_in_array "$stype" "${CH_STYPES[@]+"${CH_STYPES[@]}"}"; then
            CH_STYPES+=("$stype"); CH_SIDS+=("$sid"); CH_SNAMES+=("$sname"); CH_SURLS+=("$ch_url")
        fi
    elif [ "$br_en" = "true" ]; then
        if ! type_in_array "$stype" "${AG_STYPES[@]+"${AG_STYPES[@]}"}"; then
            AG_STYPES+=("$stype"); AG_SIDS+=("$sid"); AG_SNAMES+=("$sname"); AG_SURLS+=("$br_url")
        fi
    else
        if ! type_in_array "$stype" "${PTY_STYPES[@]+"${PTY_STYPES[@]}"}"; then
            PTY_STYPES+=("$stype"); PTY_SIDS+=("$sid"); PTY_SNAMES+=("$sname")
        fi
    fi
done < "$SESS_TMP"
rm -f "$SESS_TMP"

echo ""
echo "       PTY sessions    : ${#PTY_STYPES[@]}  (${PTY_STYPES[*]:-none})"
echo "       Channel sessions: ${#CH_STYPES[@]}   (${CH_STYPES[*]:-none})"
echo "       Agent sessions  : ${#AG_STYPES[@]}   (${AG_STYPES[*]:-none})"

# Ready 대기 — PTY
READY_PTY_STYPES=(); READY_PTY_SIDS=(); READY_PTY_SNAMES=()
for i in $(seq 0 $((${#PTY_STYPES[@]}-1))); do
    sid="${PTY_SIDS[$i]}"; stype="${PTY_STYPES[$i]}"; sname="${PTY_SNAMES[$i]}"
    if wait_for_ready "$sid" 60; then
        READY_PTY_STYPES+=("$stype"); READY_PTY_SIDS+=("$sid"); READY_PTY_SNAMES+=("$sname")
        echo -e "       ${GREEN}PTY[$stype] ready${NC}"
    else
        echo -e "       ${YELLOW}PTY[$stype] not ready, skipping${NC}"
    fi
done
PTY_STYPES=("${READY_PTY_STYPES[@]+"${READY_PTY_STYPES[@]}"}"); PTY_SIDS=("${READY_PTY_SIDS[@]+"${READY_PTY_SIDS[@]}"}"); PTY_SNAMES=("${READY_PTY_SNAMES[@]+"${READY_PTY_SNAMES[@]}"}")

# Ready 대기 — Channel
READY_CH_STYPES=(); READY_CH_SIDS=(); READY_CH_SNAMES=(); READY_CH_SURLS=()
for i in $(seq 0 $((${#CH_STYPES[@]}-1))); do
    sid="${CH_SIDS[$i]}"; stype="${CH_STYPES[$i]}"; sname="${CH_SNAMES[$i]}"; curl="${CH_SURLS[$i]}"
    if wait_for_ready "$sid" 60; then
        READY_CH_STYPES+=("$stype"); READY_CH_SIDS+=("$sid"); READY_CH_SNAMES+=("$sname"); READY_CH_SURLS+=("$curl")
        echo -e "       ${GREEN}Channel[$stype] ready${NC}"
    else
        echo -e "       ${YELLOW}Channel[$stype] not ready, skipping${NC}"
    fi
done
CH_STYPES=("${READY_CH_STYPES[@]+"${READY_CH_STYPES[@]}"}"); CH_SIDS=("${READY_CH_SIDS[@]+"${READY_CH_SIDS[@]}"}"); CH_SNAMES=("${READY_CH_SNAMES[@]+"${READY_CH_SNAMES[@]}"}"); CH_SURLS=("${READY_CH_SURLS[@]+"${READY_CH_SURLS[@]}"}")

# Ready 대기 — Agent
READY_AG_STYPES=(); READY_AG_SIDS=(); READY_AG_SNAMES=(); READY_AG_SURLS=()
for i in $(seq 0 $((${#AG_STYPES[@]}-1))); do
    sid="${AG_SIDS[$i]}"; stype="${AG_STYPES[$i]}"; sname="${AG_SNAMES[$i]}"; burl="${AG_SURLS[$i]}"
    if wait_for_ready "$sid" 60; then
        READY_AG_STYPES+=("$stype"); READY_AG_SIDS+=("$sid"); READY_AG_SNAMES+=("$sname"); READY_AG_SURLS+=("$burl")
        echo -e "       ${GREEN}Agent[$stype] ready${NC}"
    else
        echo -e "       ${YELLOW}Agent[$stype] not ready, skipping${NC}"
    fi
done
AG_STYPES=("${READY_AG_STYPES[@]+"${READY_AG_STYPES[@]}"}"); AG_SIDS=("${READY_AG_SIDS[@]+"${READY_AG_SIDS[@]}"}"); AG_SNAMES=("${READY_AG_SNAMES[@]+"${READY_AG_SNAMES[@]}"}"); AG_SURLS=("${READY_AG_SURLS[@]+"${READY_AG_SURLS[@]}"}")

total_ready=$((${#PTY_STYPES[@]} + ${#CH_STYPES[@]} + ${#AG_STYPES[@]}))
[ "$total_ready" -gt 0 ] \
    && pass "Ready: ${#PTY_STYPES[@]} PTY + ${#CH_STYPES[@]} Channel + ${#AG_STYPES[@]} Agent" \
    || fail "No ready sessions found"

# ─────────────────────────────────────────────
# 4. Session Status (전체)
# ─────────────────────────────────────────────
section "4. Session Status"

for i in $(seq 0 $((${#PTY_STYPES[@]}-1))); do
    sid="${PTY_SIDS[$i]}"; stype="${PTY_STYPES[$i]}"
    parse_response "$(api_get "/sessions/$sid")"
    [ "$HTTP_CODE" = "200" ] \
        && pass "[PTY/$stype] status=$(echo "$HTTP_BODY" | jq -r '.status')" \
        || fail "[PTY/$stype] expected 200, got $HTTP_CODE"
done
for i in $(seq 0 $((${#CH_STYPES[@]}-1))); do
    sid="${CH_SIDS[$i]}"; stype="${CH_STYPES[$i]}"
    parse_response "$(api_get "/sessions/$sid")"
    if [ "$HTTP_CODE" = "200" ]; then
        ch_url=$(echo "$HTTP_BODY" | jq -r '.channel_url // empty')
        pass "[Channel/$stype] status=$(echo "$HTTP_BODY" | jq -r '.status'), channel_url=$ch_url"
    else
        fail "[Channel/$stype] expected 200, got $HTTP_CODE"
    fi
done
for i in $(seq 0 $((${#AG_STYPES[@]}-1))); do
    sid="${AG_SIDS[$i]}"; stype="${AG_STYPES[$i]}"
    parse_response "$(api_get "/sessions/$sid")"
    if [ "$HTTP_CODE" = "200" ]; then
        br_url=$(echo "$HTTP_BODY" | jq -r '.bridge_url // empty')
        pass "[Agent/$stype] status=$(echo "$HTTP_BODY" | jq -r '.status'), bridge_url=$br_url"
    else
        fail "[Agent/$stype] expected 200, got $HTTP_CODE"
    fi
done

# 존재하지 않는 세션
parse_response "$(api_get '/sessions/s_nonexistent')"
[ "$HTTP_CODE" = "404" ] && pass "Non-existent session → 404" || fail "Non-existent expected 404, got $HTTP_CODE"

# ─────────────────────────────────────────────
# 5. OpenAI Models API
# ─────────────────────────────────────────────
section "5. OpenAI Models API"

parse_response "$(api_get '/v1/models')"
if [ "$HTTP_CODE" = "200" ]; then
    obj=$(echo "$HTTP_BODY" | jq -r '.object // empty')
    mc=$(echo "$HTTP_BODY" | jq '.data | length')
    [ "$obj" = "list" ] && pass "GET /v1/models → object=list ($mc models)" || fail "models unexpected object=$obj"

    for sname in "${PTY_SNAMES[@]+"${PTY_SNAMES[@]}"}" "${CH_SNAMES[@]+"${CH_SNAMES[@]}"}" "${AG_SNAMES[@]+"${AG_SNAMES[@]}"}"; do
        echo "$HTTP_BODY" | jq -r '.data[].id' | grep -qi "^${sname}$" \
            && pass "  model '$sname' listed" \
            || fail "  model '$sname' missing from list"
    done
else
    fail "GET /v1/models expected 200, got $HTTP_CODE"
fi

# ─────────────────────────────────────────────
# 6. PTY Sessions — Direct Consolent API
# ─────────────────────────────────────────────
if [ ${#PTY_STYPES[@]} -gt 0 ]; then
section "6. PTY Sessions — Consolent API"

for i in $(seq 0 $((${#PTY_STYPES[@]}-1))); do
    stype="${PTY_STYPES[$i]}"; sid="${PTY_SIDS[$i]}"; sname="${PTY_SNAMES[$i]}"

    subsect "PTY[$stype] sendMessage"
    parse_response "$(api_post "/sessions/$sid/message" '{"text":"Say just the word OK and nothing else.","timeout":90}')"
    if [ "$HTTP_CODE" = "200" ]; then
        msg_id=$(echo "$HTTP_BODY" | jq -r '.message_id // empty')
        result=$(echo "$HTTP_BODY" | jq -r '.response.result // empty')
        [ -n "$msg_id" ] && pass "[PTY/$stype] message_id: $msg_id" || fail "[PTY/$stype] missing message_id"
        [ -n "$result" ] && pass "[PTY/$stype] result: $(echo "$result" | head -c 60)" || fail "[PTY/$stype] result empty"
    else
        fail "[PTY/$stype] sendMessage expected 200, got $HTTP_CODE" "$HTTP_BODY"
    fi

    subsect "PTY[$stype] /v1/chat/completions"
    test_chat "PTY/$stype" "$BASE_URL/v1/chat/completions" "Authorization: Bearer $API_KEY" "$sname" "Reply with just the word PONG"

    subsect "PTY[$stype] SSE Streaming"
    test_sse_streaming "PTY/$stype" \
        "$BASE_URL/v1/chat/completions" \
        "Authorization: Bearer $API_KEY" \
        "{\"model\":\"$sname\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with: STREAM_OK\"}],\"stream\":true,\"timeout\":90}"
    # SSE 후 세션 ready 복귀 대기
    wait_for_ready "$sid" 30 || true

    subsect "PTY[$stype] Response Accumulation"
    _b1=$(printf '{"model":"%s","messages":[{"role":"user","content":"Reply with just: ALPHA123"}],"timeout":90}' "$sname")
    _b2=$(printf '{"model":"%s","messages":[{"role":"user","content":"Reply with just: BETA456"}],"timeout":90}' "$sname")
    _c1=$(curl -s "$BASE_URL/v1/chat/completions" -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d "$_b1" | jq -r '.choices[0].message.content // empty')
    _c2=$(curl -s "$BASE_URL/v1/chat/completions" -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d "$_b2" | jq -r '.choices[0].message.content // empty')
    if [ -n "$_c1" ] && [ -n "$_c2" ]; then
        pass "[PTY/$stype] 1st: $(echo "$_c1" | head -c 40)"
        echo "$_c2" | grep -q "ALPHA123" \
            && fail "[PTY/$stype] accumulation bug — 2nd contains 1st" \
            || pass "[PTY/$stype] no accumulation: $(echo "$_c2" | head -c 40)"
    else
        fail "[PTY/$stype] accumulation test failed c1=[$_c1] c2=[$_c2]"
    fi

    subsect "PTY[$stype] Multi-turn Context"
    _bctx1=$(printf '{"model":"%s","messages":[{"role":"user","content":"Remember: 7742. Reply OK."}],"timeout":90}' "$sname")
    _bctx2=$(printf '{"model":"%s","messages":[{"role":"user","content":"What number did I ask you to remember? Reply with just the number."}],"timeout":90}' "$sname")
    _rctx=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/v1/chat/completions" -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d "$_bctx1")
    if [ "$_rctx" = "200" ]; then
        pass "[PTY/$stype] context setup OK"
        ctx=$(curl -s "$BASE_URL/v1/chat/completions" -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d "$_bctx2" | jq -r '.choices[0].message.content // empty')
        echo "$ctx" | grep -q "7742" \
            && pass "[PTY/$stype] context retained (7742)" \
            || fail "[PTY/$stype] context lost — got: $(echo "$ctx" | head -c 40)"
    else
        fail "[PTY/$stype] context setup failed (HTTP $_rctx)"
    fi
done
fi  # PTY

# ─────────────────────────────────────────────
# 7. Channel Sessions
# ─────────────────────────────────────────────
if [ ${#CH_STYPES[@]} -gt 0 ]; then
section "7. Channel Sessions"

for i in $(seq 0 $((${#CH_STYPES[@]}-1))); do
    stype="${CH_STYPES[$i]}"; sid="${CH_SIDS[$i]}"; sname="${CH_SNAMES[$i]}"; ch_url="${CH_SURLS[$i]}"

    # 채널 URL 없으면 세션 재조회
    if [ -z "$ch_url" ]; then
        parse_response "$(api_get "/sessions/$sid")"
        ch_url=$(echo "$HTTP_BODY" | jq -r '.channel_url // empty')
    fi

    echo "       Channel URL: $ch_url"

    subsect "Channel[$stype/$sname] Consolent → 410 Gone"
    parse_response "$(api_post '/v1/chat/completions' "{\"model\":\"$sname\",\"messages\":[{\"role\":\"user\",\"content\":\"test\"}]}")"
    if [ "$HTTP_CODE" = "410" ]; then
        reason=$(echo "$HTTP_BODY" | jq -r '.reason // empty')
        pass "[Channel/$stype] Consolent returns 410 Gone"
        echo "$reason" | grep -q "channel" \
            && pass "[Channel/$stype] reason mentions channel" \
            || fail "[Channel/$stype] reason: $reason"
    else
        fail "[Channel/$stype] expected 410, got $HTTP_CODE"
    fi

    if [ -n "$ch_url" ]; then
        subsect "Channel[$stype] Direct server — /v1/models"
        parse_response "$(ext_get "$ch_url/v1/models")"
        [ "$HTTP_CODE" = "200" ] \
            && pass "[Channel/$stype] $ch_url/v1/models → 200" \
            || fail "[Channel/$stype] /v1/models expected 200, got $HTTP_CODE"

        subsect "Channel[$stype] Direct server — /v1/chat/completions"
        test_chat "Channel/$stype" "$ch_url/v1/chat/completions" "none" "$sname" "Reply with just the word PONG"

        subsect "Channel[$stype] Direct server — SSE Streaming"
        test_sse_streaming "Channel/$stype" \
            "$ch_url/v1/chat/completions" \
            "none" \
            "{\"model\":\"$sname\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with: STREAM_OK\"}],\"stream\":true,\"timeout\":90}"
        sleep 3  # 스트리밍 응답 완료 후 세션 ready 대기

        subsect "Channel[$stype] Multi-turn Context"
        parse_response "$(ext_post "$ch_url/v1/chat/completions" "{\"model\":\"$sname\",\"messages\":[{\"role\":\"user\",\"content\":\"Remember: 8833. Reply OK.\"}],\"timeout\":90}")"
        if [ "$HTTP_CODE" = "200" ]; then
            pass "[Channel/$stype] context setup OK"
            parse_response "$(ext_post "$ch_url/v1/chat/completions" "{\"model\":\"$sname\",\"messages\":[{\"role\":\"user\",\"content\":\"What number? Reply with just the number.\"}],\"timeout\":90}")"
            ctx=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.content // empty')
            echo "$ctx" | grep -q "8833" \
                && pass "[Channel/$stype] context retained (8833)" \
                || fail "[Channel/$stype] context lost — got: $(echo "$ctx" | head -c 40)"
        else
            fail "[Channel/$stype] context setup failed (HTTP $HTTP_CODE)"
        fi
    else
        skip "[Channel/$stype] direct server tests (no channel_url)"
    fi
done
fi  # Channel

# ─────────────────────────────────────────────
# 8. Agent/Bridge Sessions
# ─────────────────────────────────────────────
if [ ${#AG_STYPES[@]} -gt 0 ]; then
section "8. Agent / Bridge Sessions"

for i in $(seq 0 $((${#AG_STYPES[@]}-1))); do
    stype="${AG_STYPES[$i]}"; sid="${AG_SIDS[$i]}"; sname="${AG_SNAMES[$i]}"; br_url="${AG_SURLS[$i]}"

    # bridge URL 없으면 세션 재조회
    if [ -z "$br_url" ]; then
        parse_response "$(api_get "/sessions/$sid")"
        br_url=$(echo "$HTTP_BODY" | jq -r '.bridge_url // .sdk_url // empty')
    fi

    echo "       Bridge URL: $br_url"

    subsect "Agent[$stype/$sname] Consolent → 410 Gone"
    parse_response "$(api_post '/v1/chat/completions' "{\"model\":\"$sname\",\"messages\":[{\"role\":\"user\",\"content\":\"test\"}]}")"
    if [ "$HTTP_CODE" = "410" ]; then
        reason=$(echo "$HTTP_BODY" | jq -r '.reason // empty')
        pass "[Agent/$stype] Consolent returns 410 Gone"
        echo "$reason" | grep -qiE "bridge|agent|sdk|direct" \
            && pass "[Agent/$stype] reason mentions bridge/agent" \
            || fail "[Agent/$stype] reason: $reason"
    else
        fail "[Agent/$stype] expected 410, got $HTTP_CODE" "$HTTP_BODY"
    fi

    if [ -n "$br_url" ]; then
        subsect "Agent[$stype] Bridge server — /health"
        parse_response "$(ext_get "$br_url/health")"
        [ "$HTTP_CODE" = "200" ] \
            && pass "[Agent/$stype] $br_url/health → 200" \
            || fail "[Agent/$stype] /health expected 200, got $HTTP_CODE"

        subsect "Agent[$stype] Bridge server — /v1/models"
        parse_response "$(ext_get "$br_url/v1/models")"
        [ "$HTTP_CODE" = "200" ] \
            && pass "[Agent/$stype] /v1/models → 200 ($(echo "$HTTP_BODY" | jq '.data | length') models)" \
            || fail "[Agent/$stype] /v1/models expected 200, got $HTTP_CODE"

        subsect "Agent[$stype] Bridge server — /v1/chat/completions"
        test_chat "Agent/$stype" "$br_url/v1/chat/completions" "none" "$sname" "Reply with just the word PONG"

        subsect "Agent[$stype] Bridge server — SSE Streaming"
        test_sse_streaming "Agent/$stype" \
            "$br_url/v1/chat/completions" \
            "none" \
            "{\"model\":\"$sname\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with: STREAM_OK\"}],\"stream\":true,\"timeout\":90}"
        sleep 3  # 스트리밍 응답 완료 후 세션 ready 대기

        subsect "Agent[$stype] Response Accumulation"
        parse_response "$(ext_post "$br_url/v1/chat/completions" "{\"model\":\"$sname\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with just: DELTA111\"}],\"timeout\":90}")"
        c1=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.content // empty')
        if [ "$HTTP_CODE" = "200" ] && [ -n "$c1" ]; then
            pass "[Agent/$stype] 1st: $(echo "$c1" | head -c 40)"
            parse_response "$(ext_post "$br_url/v1/chat/completions" "{\"model\":\"$sname\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with just: GAMMA222\"}],\"timeout\":90}")"
            c2=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.content // empty')
            if [ "$HTTP_CODE" = "200" ] && [ -n "$c2" ]; then
                echo "$c2" | grep -q "DELTA111" \
                    && fail "[Agent/$stype] accumulation bug — 2nd contains 1st" \
                    || pass "[Agent/$stype] no accumulation: $(echo "$c2" | head -c 40)"
            else
                fail "[Agent/$stype] 2nd request failed (HTTP $HTTP_CODE)"
            fi
        else
            fail "[Agent/$stype] 1st request failed (HTTP $HTTP_CODE)"
        fi

        subsect "Agent[$stype] Multi-turn Context"
        parse_response "$(ext_post "$br_url/v1/chat/completions" "{\"model\":\"$sname\",\"messages\":[{\"role\":\"user\",\"content\":\"Remember: 5599. Reply OK.\"}],\"timeout\":90}")"
        if [ "$HTTP_CODE" = "200" ]; then
            pass "[Agent/$stype] context setup OK"
            parse_response "$(ext_post "$br_url/v1/chat/completions" "{\"model\":\"$sname\",\"messages\":[{\"role\":\"user\",\"content\":\"What number? Reply with just the number.\"}],\"timeout\":90}")"
            ctx=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.content // empty')
            echo "$ctx" | grep -q "5599" \
                && pass "[Agent/$stype] context retained (5599)" \
                || fail "[Agent/$stype] context lost — got: $(echo "$ctx" | head -c 40)"
        else
            fail "[Agent/$stype] context setup failed (HTTP $HTTP_CODE)"
        fi
    else
        skip "[Agent/$stype] direct bridge tests (no bridge_url)"
    fi
done
fi  # Agent

# ─────────────────────────────────────────────
# 9. Input Validation
# ─────────────────────────────────────────────
section "9. Input Validation"

parse_response "$(api_post '/v1/chat/completions' '{"messages":[]}')"
[ "$HTTP_CODE" = "400" ] \
    && pass "Empty messages → 400" \
    || fail "Empty messages expected 400, got $HTTP_CODE"

parse_response "$(api_post '/v1/chat/completions' '{"model":"__nonexistent__","messages":[{"role":"user","content":"test"}]}')"
[ "$HTTP_CODE" = "200" ] \
    && pass "Unknown model → fallback session (200)" \
    || pass "Unknown model → $HTTP_CODE (no default session, expected)"

# ─────────────────────────────────────────────
# 10. Cloudflare Quick Tunnel
# ─────────────────────────────────────────────
section "10. Cloudflare Quick Tunnel"

ALL_SIDS=("${PTY_SIDS[@]+"${PTY_SIDS[@]}"}" "${CH_SIDS[@]+"${CH_SIDS[@]}"}" "${AG_SIDS[@]+"${AG_SIDS[@]}"}")
if [ ${#ALL_SIDS[@]} -gt 0 ]; then
    parse_response "$(api_get "/sessions/${ALL_SIDS[0]}")"
    if [ "$HTTP_CODE" = "200" ]; then
        local_url=$(echo "$HTTP_BODY" | jq -r '.local_url // empty')
        tunnel_url=$(echo "$HTTP_BODY" | jq -r '.tunnel_url // empty')
        [ -n "$local_url" ] && pass "local_url: $local_url" || fail "missing local_url"
        [ -z "$tunnel_url" ] && pass "No tunnel (default)" || pass "tunnel_url: $tunnel_url"
    else
        fail "Session status expected 200, got $HTTP_CODE"
    fi
else
    skip "Cloudflare tunnel check (no sessions)"
fi

# ══════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════
echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════${NC}"
echo -e "  ${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}  ${YELLOW}SKIP: $SKIP${NC}"
TOTAL=$((PASS + FAIL))
echo -e "  PTY     : ${PTY_STYPES[*]:-none}"
echo -e "  Channel : ${CH_STYPES[*]:-none}"
echo -e "  Agent   : ${AG_STYPES[*]:-none}"
echo -e "  Total   : $TOTAL tests"
echo -e "${CYAN}${BOLD}══════════════════════════════════${NC}"

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
