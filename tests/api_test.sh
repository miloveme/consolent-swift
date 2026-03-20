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

set -euo pipefail

# ── Configuration ──
BASE_URL="${BASE_URL:-http://127.0.0.1:9999}"
API_KEY="${API_KEY:?'API_KEY is required. Usage: API_KEY=\"cst_xxx\" ./tests/api_test.sh'}"

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Counters ──
PASS=0
FAIL=0
SKIP=0

# ── Session data (parallel arrays — bash 3.x 호환) ──
# 인덱스로 매칭: STYPES[i], SIDS[i], SNAMES[i]
STYPES=()   # cli_type
SIDS=()     # session_id
SNAMES=()   # session_name

# ── Helpers ──
pass() {
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC} $1"
}

fail() {
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC} $1"
    [ -n "${2:-}" ] && echo -e "       ${RED}$2${NC}"
}

skip() {
    SKIP=$((SKIP + 1))
    echo -e "  ${YELLOW}SKIP${NC} $1"
}

section() {
    echo -e "\n${CYAN}── $1 ──${NC}"
}

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

api_get_noauth() {
    curl -s -w "\n%{http_code}" "$BASE_URL$1" \
        -H "Content-Type: application/json"
}

api_get_badauth() {
    curl -s -w "\n%{http_code}" "$BASE_URL$1" \
        -H "Authorization: Bearer invalid_key_12345" \
        -H "Content-Type: application/json"
}

parse_response() {
    local response="$1"
    HTTP_CODE=$(echo "$response" | tail -n1)
    HTTP_BODY=$(echo "$response" | sed '$d')
}

# 세션이 ready 될 때까지 대기 (최대 60초)
wait_for_ready() {
    local sid="$1"
    local max_wait="${2:-60}"
    local elapsed=0
    while [ "$elapsed" -lt "$max_wait" ]; do
        response=$(api_get "/sessions/$sid")
        parse_response "$response"
        local status=$(echo "$HTTP_BODY" | jq -r '.status // empty')
        if [ "$status" = "ready" ]; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

# 타입이 이미 등록됐는지 확인
type_already_added() {
    local check_type="$1"
    for t in "${STYPES[@]+"${STYPES[@]}"}"; do
        if [ "$t" = "$check_type" ]; then
            return 0
        fi
    done
    return 1
}

# ══════════════════════════════════════════════
# Tests
# ══════════════════════════════════════════════

echo -e "${CYAN}Consolent API Integration Tests${NC}"
echo "Base URL: $BASE_URL"
echo ""

# ── 1. Health Check ──
section "Health Check"

response=$(api_get "/")
parse_response "$response"

if [ "$HTTP_CODE" = "200" ]; then
    app=$(echo "$HTTP_BODY" | jq -r '.app // empty')
    status=$(echo "$HTTP_BODY" | jq -r '.status // empty')
    if [ "$app" = "Consolent" ] && [ "$status" = "ok" ]; then
        pass "GET / returns status ok"
    else
        fail "GET / unexpected body" "$HTTP_BODY"
    fi
else
    fail "GET / expected 200, got $HTTP_CODE"
fi

# ── 2. Authentication ──
section "Authentication"

response=$(api_get_noauth "/")
parse_response "$response"
if [ "$HTTP_CODE" = "401" ]; then
    pass "No auth header → 401"
else
    fail "No auth header expected 401, got $HTTP_CODE"
fi

response=$(api_get_badauth "/")
parse_response "$response"
if [ "$HTTP_CODE" = "401" ]; then
    pass "Invalid API key → 401"
else
    fail "Invalid API key expected 401, got $HTTP_CODE"
fi

# ── 3. Session Discovery ──
section "Session Discovery"

response=$(api_get "/sessions")
parse_response "$response"

if [ "$HTTP_CODE" = "200" ]; then
    session_count=$(echo "$HTTP_BODY" | jq '.sessions | length')
    pass "GET /sessions returns $session_count session(s)"

    if [ "$session_count" -gt 0 ]; then
        # 세션 정보를 임시 파일로 추출 (bash 3.x 서브셸 변수 문제 회피)
        SESS_TMP=$(mktemp)
        echo "$HTTP_BODY" | jq -r '.sessions[] | "\(.cli_type)\t\(.id)\t\(.name // "")\t\(.status)"' > "$SESS_TMP"

        while IFS=$'\t' read -r stype sid sname sstatus; do
            echo "       Found: $sname ($stype) — $sid [status: $sstatus]"
            # 타입별 첫 번째 세션만 저장
            if ! type_already_added "$stype"; then
                STYPES+=("$stype")
                SIDS+=("$sid")
                SNAMES+=("$sname")
            fi
        done < "$SESS_TMP"
        rm -f "$SESS_TMP"

        # ready 상태 대기 — ready가 아닌 세션은 제거
        READY_STYPES=()
        READY_SIDS=()
        READY_SNAMES=()
        for i in $(seq 0 $((${#STYPES[@]} - 1))); do
            sid="${SIDS[$i]}"
            stype="${STYPES[$i]}"
            sname="${SNAMES[$i]}"
            if wait_for_ready "$sid" 60; then
                READY_STYPES+=("$stype")
                READY_SIDS+=("$sid")
                READY_SNAMES+=("$sname")
                echo -e "       ${GREEN}$stype ($sname) ready${NC}"
            else
                echo -e "       ${YELLOW}$stype ($sname) not ready, skipping${NC}"
            fi
        done

        # 이후 테스트는 READY_ 배열 사용
        STYPES=("${READY_STYPES[@]+"${READY_STYPES[@]}"}")
        SIDS=("${READY_SIDS[@]+"${READY_SIDS[@]}"}")
        SNAMES=("${READY_SNAMES[@]+"${READY_SNAMES[@]}"}")

        if [ ${#STYPES[@]} -eq 0 ]; then
            fail "No ready sessions found"
        else
            pass "Ready sessions: ${STYPES[*]}"
        fi
    fi
else
    fail "GET /sessions expected 200, got $HTTP_CODE"
fi

# ── 4. Session Status (타입별) ──
section "Session Status"

for i in $(seq 0 $((${#STYPES[@]} - 1))); do
    stype="${STYPES[$i]}"
    sid="${SIDS[$i]}"

    response=$(api_get "/sessions/$sid")
    parse_response "$response"

    if [ "$HTTP_CODE" = "200" ]; then
        got_id=$(echo "$HTTP_BODY" | jq -r '.id')
        got_name=$(echo "$HTTP_BODY" | jq -r '.name // empty')
        got_status=$(echo "$HTTP_BODY" | jq -r '.status')
        if [ "$got_id" = "$sid" ]; then
            pass "[$stype] name=$got_name, status=$got_status"
        else
            fail "[$stype] returned wrong id"
        fi
    else
        fail "[$stype] expected 200, got $HTTP_CODE"
    fi
done

response=$(api_get "/sessions/s_nonexistent")
parse_response "$response"
if [ "$HTTP_CODE" = "404" ]; then
    pass "Non-existent session → 404"
else
    fail "Non-existent expected 404, got $HTTP_CODE"
fi

# ── 5. OpenAI Compatible: Models ──
section "OpenAI Compatible — Models"

response=$(api_get "/v1/models")
parse_response "$response"

if [ "$HTTP_CODE" = "200" ]; then
    object=$(echo "$HTTP_BODY" | jq -r '.object // empty')
    model_count=$(echo "$HTTP_BODY" | jq '.data | length')

    if [ "$object" = "list" ]; then
        pass "GET /v1/models returns object=list ($model_count model(s))"
    else
        fail "GET /v1/models unexpected object" "$object"
    fi

    for i in $(seq 0 $((${#STYPES[@]} - 1))); do
        sname="${SNAMES[$i]}"
        if echo "$HTTP_BODY" | jq -r '.data[].id' | grep -qi "^${sname}$"; then
            pass "Model list includes '$sname'"
        else
            fail "Model list missing '$sname'"
        fi
    done
else
    fail "GET /v1/models expected 200, got $HTTP_CODE"
fi

# ── 6. Send Message — 타입별 ──
for i in $(seq 0 $((${#STYPES[@]} - 1))); do
    stype="${STYPES[$i]}"
    sid="${SIDS[$i]}"

    section "Send Message [$stype]"

    response=$(api_post "/sessions/$sid/message" '{"text":"Say just the word OK and nothing else.","timeout":60}')
    parse_response "$response"

    if [ "$HTTP_CODE" = "200" ]; then
        msg_id=$(echo "$HTTP_BODY" | jq -r '.message_id // empty')
        result=$(echo "$HTTP_BODY" | jq -r '.response.result // empty')
        duration=$(echo "$HTTP_BODY" | jq -r '.response.duration_ms // empty')

        [ -n "$msg_id" ] && pass "[$stype] message_id: $msg_id" || fail "[$stype] missing message_id"
        [ -n "$result" ] && pass "[$stype] result (${#result} chars): $(echo "$result" | head -c 80)" || fail "[$stype] result empty"
        [ -n "$duration" ] && pass "[$stype] duration: ${duration}ms" || fail "[$stype] missing duration"
    else
        fail "[$stype] expected 200, got $HTTP_CODE" "$HTTP_BODY"
    fi
done

# ── 7. Model-Based Routing — 타입별 ──
for i in $(seq 0 $((${#STYPES[@]} - 1))); do
    stype="${STYPES[$i]}"
    sname="${SNAMES[$i]}"

    section "Model Routing [$stype] — model=$sname"

    response=$(api_post "/v1/chat/completions" "{
        \"model\": \"$sname\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Reply with just the word PONG\"}],
        \"timeout\": 60
    }")
    parse_response "$response"

    if [ "$HTTP_CODE" = "200" ]; then
        obj=$(echo "$HTTP_BODY" | jq -r '.object // empty')
        resp_model=$(echo "$HTTP_BODY" | jq -r '.model // empty')
        content=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.content // empty')
        role=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.role // empty')
        finish=$(echo "$HTTP_BODY" | jq -r '.choices[0].finish_reason // empty')

        [ "$obj" = "chat.completion" ] && pass "[$stype] object=chat.completion" || fail "[$stype] object=$obj"
        [ "$resp_model" = "$sname" ] && pass "[$stype] model='$resp_model' matches" || fail "[$stype] model='$resp_model' != '$sname'"
        [ "$role" = "assistant" ] && pass "[$stype] role=assistant" || fail "[$stype] role=$role"
        [ "$finish" = "stop" ] && pass "[$stype] finish_reason=stop" || fail "[$stype] finish=$finish"
        [ -n "$content" ] && pass "[$stype] content: $(echo "$content" | head -c 80)" || fail "[$stype] content empty"
    else
        fail "[$stype] expected 200, got $HTTP_CODE" "$HTTP_BODY"
    fi
done

# ── 8. Response Accumulation — 타입별 ──
for i in $(seq 0 $((${#STYPES[@]} - 1))); do
    stype="${STYPES[$i]}"
    sname="${SNAMES[$i]}"

    section "Response Accumulation [$stype]"

    response1=$(api_post "/v1/chat/completions" "{
        \"model\": \"$sname\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Reply with just: ALPHA123\"}],
        \"timeout\": 60
    }")
    parse_response "$response1"
    content1=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.content // empty')

    if [ "$HTTP_CODE" = "200" ] && [ -n "$content1" ]; then
        pass "[$stype] 1st: $(echo "$content1" | head -c 50)"

        response2=$(api_post "/v1/chat/completions" "{
            \"model\": \"$sname\",
            \"messages\": [{\"role\": \"user\", \"content\": \"Reply with just: BETA456\"}],
            \"timeout\": 60
        }")
        parse_response "$response2"
        content2=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.content // empty')

        if [ "$HTTP_CODE" = "200" ] && [ -n "$content2" ]; then
            if echo "$content2" | grep -q "ALPHA123"; then
                fail "[$stype] accumulation bug — 2nd contains 1st"
            else
                pass "[$stype] no accumulation — 2nd: $(echo "$content2" | head -c 50)"
            fi
        else
            fail "[$stype] 2nd failed (HTTP $HTTP_CODE)"
        fi
    else
        fail "[$stype] 1st failed (HTTP $HTTP_CODE)"
    fi
done

# ── 9. Multi-turn Context — 타입별 ──
for i in $(seq 0 $((${#STYPES[@]} - 1))); do
    stype="${STYPES[$i]}"
    sname="${SNAMES[$i]}"

    section "Multi-turn Context [$stype]"

    response=$(api_post "/v1/chat/completions" "{
        \"model\": \"$sname\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Remember this number: 7742. Reply with just OK.\"}],
        \"timeout\": 60
    }")
    parse_response "$response"

    if [ "$HTTP_CODE" = "200" ]; then
        pass "[$stype] context setup sent"

        response=$(api_post "/v1/chat/completions" "{
            \"model\": \"$sname\",
            \"messages\": [{\"role\": \"user\", \"content\": \"What was the number I asked you to remember? Reply with just the number.\"}],
            \"timeout\": 60
        }")
        parse_response "$response"
        content=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.content // empty')

        if [ "$HTTP_CODE" = "200" ] && [ -n "$content" ]; then
            if echo "$content" | grep -q "7742"; then
                pass "[$stype] context retained: recalled 7742"
            else
                fail "[$stype] context lost: expected 7742, got: $content"
            fi
        else
            fail "[$stype] context recall failed (HTTP $HTTP_CODE)"
        fi
    else
        fail "[$stype] context setup failed (HTTP $HTTP_CODE)"
    fi
done

# ── 10. SSE Streaming — 타입별 ──
for i in $(seq 0 $((${#STYPES[@]} - 1))); do
    stype="${STYPES[$i]}"
    sname="${SNAMES[$i]}"

    section "SSE Streaming [$stype]"

    STREAM_TMP=$(mktemp)
    curl -sN --max-time 120 "$BASE_URL/v1/chat/completions" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"$sname\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with just: STREAM_OK\"}],\"stream\":true,\"timeout\":60}" \
        > "$STREAM_TMP" 2>/dev/null &
    CURL_PID=$!

    for w in $(seq 1 60); do
        sleep 2
        if grep -q "\[DONE\]" "$STREAM_TMP" 2>/dev/null; then
            break
        fi
    done
    kill $CURL_PID 2>/dev/null || true
    wait $CURL_PID 2>/dev/null || true

    if [ -s "$STREAM_TMP" ]; then
        non_empty=$(grep -v '^$' "$STREAM_TMP" | wc -l | tr -d ' ')
        data_lines=$(grep -c '^data: ' "$STREAM_TMP" || true)

        [ "$non_empty" = "$data_lines" ] && [ "$non_empty" -gt 0 ] \
            && pass "[$stype] SSE format OK" || fail "[$stype] SSE format mismatch"

        head -1 "$STREAM_TMP" | grep -q '"role"' \
            && pass "[$stype] role chunk" || fail "[$stype] missing role chunk"

        content_chunks=$(grep '"content"' "$STREAM_TMP" | grep -v '"content":null' | wc -l | tr -d ' ')
        [ "$content_chunks" -gt 0 ] \
            && pass "[$stype] $content_chunks content chunks" || fail "[$stype] no content chunks"

        grep -q 'data: \[DONE\]' "$STREAM_TMP" \
            && pass "[$stype] [DONE]" || fail "[$stype] missing [DONE]"

        grep -q '"finish_reason":"stop"' "$STREAM_TMP" \
            && pass "[$stype] finish_reason=stop" || fail "[$stype] missing finish_reason"

        total=$(grep -c '^data: {' "$STREAM_TMP" || true)
        [ "$total" -ge 3 ] \
            && pass "[$stype] $total chunks" || fail "[$stype] expected ≥3, got $total"

        # model 필드 확인
        stream_model=$(grep '"model"' "$STREAM_TMP" | head -1 | sed 's/.*"model":"\([^"]*\)".*/\1/')
        [ "$stream_model" = "$sname" ] \
            && pass "[$stype] stream model='$stream_model'" || fail "[$stype] stream model='$stream_model' != '$sname'"
    else
        fail "[$stype] no streaming response"
    fi
    rm -f "$STREAM_TMP"
done

# ── 11. Input Validation ──
section "Input Validation"

response=$(api_post "/v1/chat/completions" '{"messages":[]}')
parse_response "$response"
[ "$HTTP_CODE" = "400" ] \
    && pass "Empty messages → 400" || fail "Empty messages expected 400, got $HTTP_CODE"

# ── 12. Cloudflare Quick Tunnel ──
section "Cloudflare Quick Tunnel"

if [ ${#SIDS[@]} -gt 0 ]; then
    response=$(api_get "/sessions/${SIDS[0]}")
    parse_response "$response"

    if [ "$HTTP_CODE" = "200" ]; then
        local_url=$(echo "$HTTP_BODY" | jq -r '.local_url // empty')
        tunnel_url=$(echo "$HTTP_BODY" | jq -r '.tunnel_url // empty')

        [ -n "$local_url" ] && pass "local_url: $local_url" || fail "missing local_url"
        [ -z "$tunnel_url" ] && pass "No tunnel by default" || pass "tunnel_url: $tunnel_url"
    else
        fail "expected 200, got $HTTP_CODE"
    fi
else
    skip "Cloudflare tunnel (no session)"
fi

# ══════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════

echo ""
echo -e "${CYAN}══════════════════════════════════${NC}"
echo -e "  ${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}  ${YELLOW}SKIP: $SKIP${NC}"
TOTAL=$((PASS + FAIL))
echo -e "  Tested: ${STYPES[*]:-none}"
echo -e "  Total: $TOTAL tests"
echo -e "${CYAN}══════════════════════════════════${NC}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
