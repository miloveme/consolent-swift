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
SESSION_ID=""
GEMINI_SESSION_ID=""

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

# Authenticated GET request
api_get() {
    curl -s -w "\n%{http_code}" "$BASE_URL$1" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json"
}

# Authenticated POST request
api_post() {
    curl -s -w "\n%{http_code}" "$BASE_URL$1" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$2"
}

# Authenticated DELETE request
api_delete() {
    curl -s -w "\n%{http_code}" "$BASE_URL$1" \
        -H "Authorization: Bearer $API_KEY"
}

# Unauthenticated GET request
api_get_noauth() {
    curl -s -w "\n%{http_code}" "$BASE_URL$1" \
        -H "Content-Type: application/json"
}

# GET with wrong key
api_get_badauth() {
    curl -s -w "\n%{http_code}" "$BASE_URL$1" \
        -H "Authorization: Bearer invalid_key_12345" \
        -H "Content-Type: application/json"
}

# Extract HTTP status code (last line) and body (everything else)
parse_response() {
    local response="$1"
    HTTP_CODE=$(echo "$response" | tail -n1)
    HTTP_BODY=$(echo "$response" | sed '$d')
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

# ── 3. Session List ──
section "Session Management"

response=$(api_get "/sessions")
parse_response "$response"

if [ "$HTTP_CODE" = "200" ]; then
    session_count=$(echo "$HTTP_BODY" | jq '.sessions | length')
    pass "GET /sessions returns $session_count session(s)"

    if [ "$session_count" -gt 0 ]; then
        # Prefer claude-code session if available
        SESSION_ID=$(echo "$HTTP_BODY" | jq -r '[.sessions[] | select(.cli_type == "claude-code" or .cli_type == null)] | .[0].id // empty')
        session_status=$(echo "$HTTP_BODY" | jq -r '[.sessions[] | select(.cli_type == "claude-code" or .cli_type == null)] | .[0].status // empty')
        CLI_TYPE="claude-code"

        # Fallback to first session if no claude-code session found
        if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; then
            SESSION_ID=$(echo "$HTTP_BODY" | jq -r '.sessions[0].id')
            session_status=$(echo "$HTTP_BODY" | jq -r '.sessions[0].status')
            CLI_TYPE=$(echo "$HTTP_BODY" | jq -r '.sessions[0].cli_type // "unknown"')
        fi
        echo "       First session: $SESSION_ID (status: $session_status, cli: $CLI_TYPE)"

        # Gemini 세션 찾기 (마크다운 불릿 테스트용)
        GEMINI_SESSION_ID=$(echo "$HTTP_BODY" | jq -r '[.sessions[] | select(.cli_type == "gemini")] | .[0].id // empty')
        if [ -n "$GEMINI_SESSION_ID" ] && [ "$GEMINI_SESSION_ID" != "null" ]; then
            gemini_status=$(echo "$HTTP_BODY" | jq -r "[.sessions[] | select(.id == \"$GEMINI_SESSION_ID\")] | .[0].status // empty")
            echo "       Gemini session: $GEMINI_SESSION_ID (status: $gemini_status)"
        else
            GEMINI_SESSION_ID=""
        fi

        # Wait for session to become ready (max 60 seconds)
        if [ "$session_status" != "ready" ]; then
            echo -e "       ${YELLOW}Waiting for session to become ready...${NC}"
            for i in $(seq 1 30); do
                sleep 2
                response=$(api_get "/sessions/$SESSION_ID")
                parse_response "$response"
                session_status=$(echo "$HTTP_BODY" | jq -r '.status // empty')
                if [ "$session_status" = "ready" ]; then
                    echo -e "       ${GREEN}Session ready after $((i * 2))s${NC}"
                    break
                fi
                printf "       Waiting... (%ds, status: %s)\n" "$((i * 2))" "$session_status"
            done
            if [ "$session_status" != "ready" ]; then
                fail "Session did not become ready within 60s (status: $session_status)"
            fi
        fi
    fi
else
    fail "GET /sessions expected 200, got $HTTP_CODE"
fi

# ── 4. Session Status ──
section "Session Status"

if [ -n "$SESSION_ID" ]; then
    response=$(api_get "/sessions/$SESSION_ID")
    parse_response "$response"

    if [ "$HTTP_CODE" = "200" ]; then
        sid=$(echo "$HTTP_BODY" | jq -r '.id')
        sstatus=$(echo "$HTTP_BODY" | jq -r '.status')
        if [ "$sid" = "$SESSION_ID" ]; then
            pass "GET /sessions/:id returns correct session (status: $sstatus)"
        else
            fail "GET /sessions/:id returned wrong id" "expected $SESSION_ID, got $sid"
        fi
    else
        fail "GET /sessions/:id expected 200, got $HTTP_CODE"
    fi

    # Non-existent session
    response=$(api_get "/sessions/s_nonexistent")
    parse_response "$response"
    if [ "$HTTP_CODE" = "404" ]; then
        pass "GET /sessions/non-existent → 404"
    else
        fail "GET /sessions/non-existent expected 404, got $HTTP_CODE"
    fi
else
    skip "Session status (no session available)"
fi

# ── 5. Send Message ──
section "Send Message"

if [ -n "$SESSION_ID" ]; then
    response=$(api_post "/sessions/$SESSION_ID/message" '{"text":"Say just the word OK and nothing else.","timeout":30}')
    parse_response "$response"

    if [ "$HTTP_CODE" = "200" ]; then
        msg_id=$(echo "$HTTP_BODY" | jq -r '.message_id // empty')
        result=$(echo "$HTTP_BODY" | jq -r '.response.result // empty')
        duration=$(echo "$HTTP_BODY" | jq -r '.response.duration_ms // empty')

        if [ -n "$msg_id" ]; then
            pass "POST /sessions/:id/message returns message_id: $msg_id"
        else
            fail "POST /sessions/:id/message missing message_id"
        fi

        if [ -n "$result" ]; then
            pass "Response result is not empty (${#result} chars)"
            echo "       Result: $(echo "$result" | head -c 100)..."
        else
            fail "Response result is empty"
            echo "       Full response: $HTTP_BODY" | head -c 500
        fi

        if [ -n "$duration" ]; then
            pass "Response duration_ms: ${duration}ms"
        else
            fail "Response missing duration_ms"
        fi

        # Check raw field is null when includeRawOutput is off
        raw=$(echo "$HTTP_BODY" | jq -r '.response.raw // "null"')
        if [ "$raw" = "null" ]; then
            pass "Response raw is null (includeRawOutput=false)"
        else
            echo "       (raw field is present — includeRawOutput may be enabled)"
        fi
    else
        fail "POST /sessions/:id/message expected 200, got $HTTP_CODE" "$HTTP_BODY"
    fi
else
    skip "Send message (no session available)"
fi

# ── 6. Terminal Output ──
section "Terminal Output"

if [ -n "$SESSION_ID" ]; then
    response=$(api_get "/sessions/$SESSION_ID/output")
    parse_response "$response"

    if [ "$HTTP_CODE" = "200" ]; then
        total=$(echo "$HTTP_BODY" | jq -r '.total_bytes // 0')
        pass "GET /sessions/:id/output (total_bytes: $total)"
    else
        fail "GET /sessions/:id/output expected 200, got $HTTP_CODE"
    fi
else
    skip "Terminal output (no session available)"
fi

# ── 7. Pending Approvals ──
section "Pending Approvals"

if [ -n "$SESSION_ID" ]; then
    response=$(api_get "/sessions/$SESSION_ID/pending")
    parse_response "$response"

    if [ "$HTTP_CODE" = "200" ]; then
        pass "GET /sessions/:id/pending returns 200"
    else
        fail "GET /sessions/:id/pending expected 200, got $HTTP_CODE"
    fi
else
    skip "Pending approvals (no session available)"
fi

# ── 8. OpenAI Compatible: Models ──
section "OpenAI Compatible — Models"

response=$(api_get "/v1/models")
parse_response "$response"

if [ "$HTTP_CODE" = "200" ]; then
    object=$(echo "$HTTP_BODY" | jq -r '.object // empty')
    model_id=$(echo "$HTTP_BODY" | jq -r '.data[0].id // empty')

    if [ "$object" = "list" ]; then
        pass "GET /v1/models returns object=list"
    else
        fail "GET /v1/models unexpected object" "$object"
    fi

    if [ "$model_id" = "claude-code" ]; then
        pass "GET /v1/models includes claude-code model"
    else
        fail "GET /v1/models expected claude-code model" "$model_id"
    fi
else
    fail "GET /v1/models expected 200, got $HTTP_CODE"
fi

# ── 9. OpenAI Compatible: Chat Completions ──
section "OpenAI Compatible — Chat Completions"

response=$(api_post "/v1/chat/completions" '{
    "model": "claude-code",
    "messages": [{"role": "user", "content": "Reply with just the word PONG"}],
    "timeout": 30
}')
parse_response "$response"

if [ "$HTTP_CODE" = "200" ]; then
    obj=$(echo "$HTTP_BODY" | jq -r '.object // empty')
    content=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.content // empty')
    role=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.role // empty')
    finish=$(echo "$HTTP_BODY" | jq -r '.choices[0].finish_reason // empty')

    if [ "$obj" = "chat.completion" ]; then
        pass "object=chat.completion"
    else
        fail "Expected object=chat.completion" "$obj"
    fi

    if [ "$role" = "assistant" ]; then
        pass "role=assistant"
    else
        fail "Expected role=assistant" "$role"
    fi

    if [ "$finish" = "stop" ]; then
        pass "finish_reason=stop"
    else
        fail "Expected finish_reason=stop" "$finish"
    fi

    if [ -n "$content" ]; then
        pass "Content is not empty: $(echo "$content" | head -c 80)"
    else
        fail "Content is empty"
    fi
else
    fail "POST /v1/chat/completions expected 200, got $HTTP_CODE" "$HTTP_BODY"
fi

# ── 10. Response Accumulation Check ──
section "Response Accumulation Check"

# Send two consecutive messages and verify second doesn't include first
response1=$(api_post "/v1/chat/completions" '{
    "model": "claude-code",
    "messages": [{"role": "user", "content": "Reply with just: ALPHA123"}],
    "timeout": 30
}')
parse_response "$response1"
content1=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.content // empty')

if [ "$HTTP_CODE" = "200" ] && [ -n "$content1" ]; then
    pass "First message returned: $(echo "$content1" | head -c 50)"

    response2=$(api_post "/v1/chat/completions" '{
        "model": "claude-code",
        "messages": [{"role": "user", "content": "Reply with just: BETA456"}],
        "timeout": 30
    }')
    parse_response "$response2"
    content2=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.content // empty')

    if [ "$HTTP_CODE" = "200" ] && [ -n "$content2" ]; then
        # Check that ALPHA123 is NOT in second response
        if echo "$content2" | grep -q "ALPHA123"; then
            fail "Second response contains first response (accumulation bug)"
            echo "       Content2: $content2"
        else
            pass "Second response does NOT contain first response content"
            echo "       Content2: $(echo "$content2" | head -c 50)"
        fi
    else
        fail "Second message failed (HTTP $HTTP_CODE)"
    fi
else
    fail "First message failed (HTTP $HTTP_CODE)"
fi

# ── 11. Complex Task: Generate HTML ──
section "Complex Task — HTML Generation"

# Gemini CLI는 보안 정책상 허용된 디렉토리에만 파일 생성 가능
if [ "${CLI_TYPE:-}" = "gemini" ]; then
    TEMP_DIR="$HOME/.gemini/tmp/gemini"
    mkdir -p "$TEMP_DIR"
    CLEANUP_TEMP=false
else
    TEMP_DIR=$(mktemp -d)
    CLEANUP_TEMP=true
fi

response=$(api_post "/v1/chat/completions" "{
    \"model\": \"claude-code\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Create a simple self-introduction HTML file at ${TEMP_DIR}/intro.html. Include: name='Consolent Test', role='API Testing Bot', a short paragraph about testing APIs, and basic CSS styling with a centered card layout. Do not ask for confirmation, just create the file.\"}],
    \"timeout\": 120
}")
parse_response "$response"

if [ "$HTTP_CODE" = "200" ]; then
    content=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.content // empty')

    if [ -n "$content" ]; then
        pass "HTML generation response received (${#content} chars)"
        echo "       Result preview: $(echo "$content" | head -c 120)..."
    else
        fail "HTML generation returned empty content"
    fi

    # Verify the file was actually created
    if [ -f "${TEMP_DIR}/intro.html" ]; then
        file_size=$(wc -c < "${TEMP_DIR}/intro.html" | tr -d ' ')
        pass "intro.html created (${file_size} bytes)"

        # Check HTML structure
        if grep -q "<html" "${TEMP_DIR}/intro.html"; then
            pass "File contains <html> tag"
        else
            fail "File missing <html> tag"
        fi

        if grep -q "Consolent Test" "${TEMP_DIR}/intro.html"; then
            pass "File contains requested name"
        else
            fail "File missing requested name 'Consolent Test'"
        fi

        if grep -q "<style" "${TEMP_DIR}/intro.html" || grep -q "style=" "${TEMP_DIR}/intro.html"; then
            pass "File contains CSS styling"
        else
            fail "File missing CSS styling"
        fi
    else
        fail "intro.html was NOT created at ${TEMP_DIR}"
    fi

    # Cleanup
    if [ "$CLEANUP_TEMP" = true ]; then
        rm -rf "${TEMP_DIR}"
    else
        rm -f "${TEMP_DIR}/intro.html"
    fi
else
    fail "HTML generation request failed (HTTP $HTTP_CODE)" "$HTTP_BODY"
    if [ "$CLEANUP_TEMP" = true ]; then
        rm -rf "${TEMP_DIR}"
    fi
fi

# ── 12. Complex Task: Code Explanation ──
section "Complex Task — Code Explanation"

response=$(api_post "/v1/chat/completions" "{
    \"model\": \"claude-code\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Explain what this Swift code does in 2-3 sentences: func fibonacci(_ n: Int) -> [Int] { var seq = [0, 1]; for i in 2..<n { seq.append(seq[i-1] + seq[i-2]) }; return seq }\"}],
    \"timeout\": 60
}")
parse_response "$response"

if [ "$HTTP_CODE" = "200" ]; then
    content=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.content // empty')

    if [ -n "$content" ]; then
        char_count=${#content}
        pass "Code explanation received (${char_count} chars)"

        # Should mention fibonacci or sequence
        if echo "$content" | grep -qi "fibonacci\|sequence\|피보나치"; then
            pass "Response mentions fibonacci/sequence"
        else
            fail "Response doesn't seem related to fibonacci" "$(echo "$content" | head -c 100)"
        fi
    else
        fail "Code explanation returned empty content"
    fi
else
    fail "Code explanation request failed (HTTP $HTTP_CODE)" "$HTTP_BODY"
fi

# ── 13. Complex Task: Multi-turn Conversation ──
section "Complex Task — Multi-turn Context"

response=$(api_post "/v1/chat/completions" '{
    "model": "claude-code",
    "messages": [{"role": "user", "content": "Remember this number: 7742. Reply with just OK."}],
    "timeout": 30
}')
parse_response "$response"

if [ "$HTTP_CODE" = "200" ]; then
    pass "Context setup message sent"

    response=$(api_post "/v1/chat/completions" '{
        "model": "claude-code",
        "messages": [{"role": "user", "content": "What was the number I asked you to remember? Reply with just the number."}],
        "timeout": 30
    }')
    parse_response "$response"
    content=$(echo "$HTTP_BODY" | jq -r '.choices[0].message.content // empty')

    if [ "$HTTP_CODE" = "200" ] && [ -n "$content" ]; then
        if echo "$content" | grep -q "7742"; then
            pass "Context retained: correctly recalled 7742"
        else
            fail "Context lost: expected 7742" "Got: $content"
        fi
    else
        fail "Context recall failed (HTTP $HTTP_CODE)"
    fi
else
    fail "Context setup failed (HTTP $HTTP_CODE)"
fi

# ── 14. Cloudflare Quick Tunnel (세션별 제어) ──
section "Cloudflare Quick Tunnel"

if [ -n "$SESSION_ID" ]; then
    response=$(api_get "/sessions/$SESSION_ID")
    parse_response "$response"

    if [ "$HTTP_CODE" = "200" ]; then
        local_url=$(echo "$HTTP_BODY" | jq -r '.local_url // empty')
        tunnel_url=$(echo "$HTTP_BODY" | jq -r '.tunnel_url // empty')

        if [ -n "$local_url" ]; then
            pass "Session has local_url: $local_url"
        else
            fail "Session missing local_url" "expected http://..."
        fi

        # 세션별 터널: 기본 생성 시 터널은 시작되지 않음
        if [ -z "$tunnel_url" ]; then
            pass "No tunnel by default (per-session control)"
        else
            # 터널이 켜져 있다면 형식과 접근 검증
            pass "Session has tunnel_url: $tunnel_url"

            if echo "$tunnel_url" | grep -qE '^https://[a-z0-9-]+\.trycloudflare\.com$'; then
                pass "tunnel_url matches trycloudflare.com pattern"
            else
                fail "tunnel_url unexpected format" "$tunnel_url"
            fi

            tunnel_response=$(curl -s --max-time 10 "$tunnel_url/" \
                -H "Authorization: Bearer $API_KEY" 2>&1)
            if echo "$tunnel_response" | grep -q "Consolent"; then
                pass "Tunnel URL external access works"
            else
                fail "Tunnel URL external access failed" "$tunnel_response"
            fi
        fi
    else
        fail "GET /sessions/:id expected 200, got $HTTP_CODE" "$HTTP_BODY"
    fi

    # 새 세션 생성 시 local_url 포함, tunnel_url 없음 확인
    create_response=$(api_post "/sessions" "{\"working_directory\": \"$HOME\", \"cli_type\": \"claude-code\"}")
    parse_response "$create_response"
    if [ "$HTTP_CODE" = "201" ]; then
        new_sid=$(echo "$HTTP_BODY" | jq -r '.session_id // empty')
        new_local=$(echo "$HTTP_BODY" | jq -r '.local_url // empty')
        new_tunnel=$(echo "$HTTP_BODY" | jq -r '.tunnel_url // empty')

        if [ -n "$new_local" ]; then
            pass "Create response includes local_url"
        else
            fail "Create response missing local_url" ""
        fi

        if [ -z "$new_tunnel" ]; then
            pass "Create response: no tunnel (per-session activation required)"
        else
            pass "Create response has tunnel: $new_tunnel"
        fi

        if [ -n "$new_sid" ]; then
            api_delete "/sessions/$new_sid" > /dev/null 2>&1
        fi
    else
        fail "POST /sessions expected 201, got $HTTP_CODE" "$HTTP_BODY"
    fi
else
    skip "Cloudflare tunnel (no session available)"
fi

# ── 15. Gemini Markdown Bullet Response ──
section "Gemini — Markdown Bullet Response"

if [ -n "$GEMINI_SESSION_ID" ]; then
    # Gemini 세션이 ready 상태인지 확인
    response=$(api_get "/sessions/$GEMINI_SESSION_ID")
    parse_response "$response"
    gemini_ready=$(echo "$HTTP_BODY" | jq -r '.status // empty')

    if [ "$gemini_ready" != "ready" ]; then
        echo -e "       ${YELLOW}Waiting for Gemini session to become ready...${NC}"
        for i in $(seq 1 30); do
            sleep 2
            response=$(api_get "/sessions/$GEMINI_SESSION_ID")
            parse_response "$response"
            gemini_ready=$(echo "$HTTP_BODY" | jq -r '.status // empty')
            if [ "$gemini_ready" = "ready" ]; then
                echo -e "       ${GREEN}Gemini session ready after $((i * 2))s${NC}"
                break
            fi
            printf "       Waiting... (%ds, status: %s)\n" "$((i * 2))" "$gemini_ready"
        done
    fi

    if [ "$gemini_ready" = "ready" ]; then
        # 마크다운 불릿이 포함된 응답을 유도하는 프롬프트
        response=$(api_post "/sessions/$GEMINI_SESSION_ID/message" '{"text":"Python 웹 프레임워크 5개를 비교해줘. 각각 한 줄로 설명해줘.","timeout":120}')
        parse_response "$response"

        if [ "$HTTP_CODE" = "200" ]; then
            GEMINI_RESULT=$(echo "$HTTP_BODY" | jq -r '.response.result // empty')

            if [ -n "$GEMINI_RESULT" ]; then
                pass "Markdown bullet response is NOT empty (${#GEMINI_RESULT} chars)"
                echo "       Preview: $(echo "$GEMINI_RESULT" | head -c 120)..."

                # 프레임워크 관련 키워드 확인
                if echo "$GEMINI_RESULT" | grep -qi "django\|flask\|fastapi\|tornado\|bottle\|pyramid\|sanic\|starlette\|falcon\|framework\|프레임워크"; then
                    pass "Response contains framework-related keywords"
                else
                    fail "Response doesn't mention any Python framework" "$(echo "$GEMINI_RESULT" | head -c 200)"
                fi
            else
                fail "Markdown bullet response is EMPTY (bug reproduced!)"
                echo "       Full body: $(echo "$HTTP_BODY" | head -c 300)"
            fi
        else
            fail "Gemini message expected 200, got $HTTP_CODE" "$HTTP_BODY"
        fi
    else
        skip "Gemini session not ready (status: $gemini_ready)"
    fi
else
    skip "Gemini markdown bullet test (no Gemini session available)"
fi

# ── 16. Gemini Multi-turn Last Response Only ──
section "Gemini — Multi-turn Last Response Only"

if [ -n "$GEMINI_SESSION_ID" ] && [ -n "$GEMINI_RESULT" ]; then
    # 두 번째 메시지: 다른 주제로 전환
    response=$(api_post "/sessions/$GEMINI_SESSION_ID/message" '{"text":"위에서 언급한 프레임워크 중 가장 인기 있는 것 하나만 이름만 알려줘.","timeout":60}')
    parse_response "$response"

    if [ "$HTTP_CODE" = "200" ]; then
        gemini_result2=$(echo "$HTTP_BODY" | jq -r '.response.result // empty')

        if [ -n "$gemini_result2" ]; then
            pass "Multi-turn second response is NOT empty (${#gemini_result2} chars)"
            echo "       Result: $(echo "$gemini_result2" | head -c 120)"

            # 첫 번째 응답의 처음 80자가 두 번째에 포함되면 → 응답 누적 버그
            first_snippet=$(echo "$GEMINI_RESULT" | head -c 80)
            if echo "$gemini_result2" | grep -qF "$first_snippet"; then
                fail "Second response contains first response (accumulation bug)"
            else
                pass "Second response does NOT contain first response (multi-turn isolation OK)"
            fi
        else
            fail "Multi-turn second response is EMPTY"
        fi
    else
        fail "Gemini second message expected 200, got $HTTP_CODE" "$HTTP_BODY"
    fi
else
    if [ -z "$GEMINI_SESSION_ID" ]; then
        skip "Gemini multi-turn test (no Gemini session available)"
    else
        skip "Gemini multi-turn test (first message failed)"
    fi
fi

# ── 17. Empty Message Validation ──
section "Input Validation"

response=$(api_post "/v1/chat/completions" '{
    "model": "claude-code",
    "messages": []
}')
parse_response "$response"
if [ "$HTTP_CODE" = "400" ]; then
    pass "Empty messages array → 400"
else
    fail "Empty messages expected 400, got $HTTP_CODE"
fi

# ══════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════

echo ""
echo -e "${CYAN}══════════════════════════════════${NC}"
echo -e "  ${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}  ${YELLOW}SKIP: $SKIP${NC}"
TOTAL=$((PASS + FAIL))
echo -e "  Total: $TOTAL tests"
echo -e "${CYAN}══════════════════════════════════${NC}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
