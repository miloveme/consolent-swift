#!/usr/bin/env python3
"""
Consolent Codex Bridge Server
================================
Codex CLI의 app-server 모드를 OpenAI / Anthropic 호환 API로 노출하는 브릿지 서버.

Codex JSON-RPC 프로토콜 (codex app-server --listen stdio://):
- "jsonrpc" 필드 없음 (Codex 고유 프로토콜)
- 핸드셰이크: initialize 요청 → initialized 알림 → thread/start 요청 (→ thread_id 획득)
- 메시지 처리: turn/start 요청 → item/agentMessage/delta 알림 스트림 → turn/completed
- 자동 승인: item/commandExecution/requestApproval → 즉시 "approved" 응답

Usage:
    python3 codex_bridge.py --port 8790 --cwd /path/to/project
"""

import argparse
import asyncio
import json
import logging
import os
import time
import uuid
from typing import Optional

from aiohttp import web

logging.basicConfig(
    level=logging.WARNING,
    format="[%(asctime)s] %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("codex-bridge")
logging.getLogger("aiohttp.access").setLevel(logging.WARNING)

CONSOLENT_PREFIX = "@@CONSOLENT@@"

_LOG_LEVEL = "info"
_LOG_ORDER = {"error": 0, "info": 1, "debug": 2}


def _set_log_level(level: str) -> None:
    global _LOG_LEVEL
    _LOG_LEVEL = level if level in _LOG_ORDER else "info"
    # Python logging 레벨도 동기화:
    # error → ERROR (오류만), info → WARNING (INFO 숨김), debug → DEBUG (전부)
    py_level = {"error": logging.ERROR, "info": logging.WARNING, "debug": logging.DEBUG}
    logger.setLevel(py_level.get(_LOG_LEVEL, logging.WARNING))


# 로그 레벨과 무관하게 항상 표시해야 하는 대화 타입
_CONVERSATION_TYPES = {"user", "assistant", "assistant_done", "tool_use", "tool_result", "thinking"}


def _emit(type_: str, content: str, level: str = "info") -> None:
    """@@CONSOLENT@@ 프로토콜로 stdout에 로그 출력.
    level: "error" (항상 표시) | "info" (기본) | "debug" (상세 진단)
    대화 타입(user/assistant 등)은 로그 레벨과 무관하게 항상 표시.
    """
    if type_ not in _CONVERSATION_TYPES and _LOG_ORDER.get(level, 1) > _LOG_ORDER.get(_LOG_LEVEL, 1):
        return
    payload = json.dumps({"type": type_, "content": content}, ensure_ascii=False)
    print(f"{CONSOLENT_PREFIX}{payload}", flush=True)


async def _get_login_shell_env() -> dict:
    """login shell의 PATH를 포함한 환경 변수를 반환한다.
    macOS .app은 최소 PATH만 갖고 있어 node/npm 등이 없으므로 login shell PATH를 사용."""
    shell = os.environ.get("SHELL", "/bin/zsh")
    try:
        proc = await asyncio.create_subprocess_exec(
            shell, "-li", "-c", "printenv PATH",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=10)
        login_path = out.decode().strip()
        env = os.environ.copy()
        if login_path:
            env["PATH"] = login_path
            logger.info(f"login shell PATH 적용: {login_path[:120]}...")
        return env
    except Exception as e:
        logger.warning(f"login shell PATH 조회 실패: {e}")
        return os.environ.copy()


class CodexBridge:
    """Codex app-server를 OpenAI / Anthropic 호환 API로 노출하는 브릿지."""

    def __init__(
        self,
        port: int,
        cwd: str,
        codex_path: str = "codex",
        api_key: Optional[str] = None,
    ):
        self.port = port
        self.cwd = cwd
        self.codex_path = codex_path
        self.api_key = api_key
        self.ready = False
        self.init_error: Optional[str] = None
        self.busy = False
        self._process: Optional[asyncio.subprocess.Process] = None
        self._thread_id: Optional[str] = None
        self._rpc_id = 0
        # 대기 중인 RPC 요청: id → Future
        self._pending: dict[int, asyncio.Future] = {}
        # 알림 큐 (turn 처리 중에 사용)
        self._notifications: asyncio.Queue = asyncio.Queue()
        self._reader_task: Optional[asyncio.Task] = None
        self._lock = asyncio.Lock()

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    async def start(self) -> None:
        """Codex 프로세스를 시작하고 핸드셰이크를 완료한다."""
        codex_cmd = await self._find_codex()
        cmd = [codex_cmd, "app-server", "--listen", "stdio://"]
        # login shell PATH 사용 (node 등 포함)
        env = await _get_login_shell_env()

        logger.info(f"Codex 시작 명령: {' '.join(cmd)}")
        _emit("system", f"Codex 프로세스 시작 중... (cmd={' '.join(cmd)})")

        try:
            self._process = await asyncio.create_subprocess_exec(
                *cmd,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=self.cwd,
                env=env,
            )
        except FileNotFoundError:
            msg = f"codex 바이너리를 찾을 수 없습니다: {codex_cmd}"
            _emit("system", f"❌ {msg}")
            raise RuntimeError(msg)

        logger.info(f"Codex 프로세스 시작 (PID {self._process.pid})")
        _emit("system", f"Codex 프로세스 시작 (PID {self._process.pid})")

        # 백그라운드 리더 + stderr 수집 시작
        self._reader_task = asyncio.create_task(self._reader_loop())
        asyncio.create_task(self._stderr_logger())

        # 핸드셰이크
        try:
            await asyncio.wait_for(self._handshake(), timeout=30)
        except asyncio.TimeoutError:
            msg = "Codex 핸드셰이크 타임아웃 (30초). 'codex app-server' 명령을 지원하는지 확인하세요."
            _emit("system", f"❌ {msg}")
            raise RuntimeError(msg)
        except Exception as e:
            msg = f"Codex 핸드셰이크 실패: {e}"
            _emit("system", f"❌ {msg}")
            raise RuntimeError(msg)

        self.ready = True
        _emit("system", f"Codex 브릿지 서버 시작 (cwd={self.cwd}, thread={self._thread_id})")

    async def stop(self) -> None:
        if self._reader_task:
            self._reader_task.cancel()
            try:
                await self._reader_task
            except asyncio.CancelledError:
                pass
        if self._process:
            try:
                self._process.terminate()
                await asyncio.wait_for(self._process.wait(), timeout=3)
            except Exception:
                try:
                    self._process.kill()
                except Exception:
                    pass
        self.ready = False
        _emit("system", "Codex 브릿지 서버 종료")

    async def _stderr_logger(self) -> None:
        """stderr를 읽어 @@CONSOLENT@@ system 메시지로 출력한다."""
        if not self._process or not self._process.stderr:
            return
        try:
            while True:
                line_bytes = await self._process.stderr.readline()
                if not line_bytes:
                    break
                line = line_bytes.decode("utf-8", errors="replace").strip()
                if line:
                    logger.warning(f"[codex stderr] {line}")
                    lvl = "error" if any(k in line.lower() for k in ("error", "no such", "not found", "fatal", "exception")) else "debug"
                    _emit("system", f"⚠️ {line}", level=lvl)
        except Exception:
            pass

    # ------------------------------------------------------------------
    # JSON-RPC helpers
    # ------------------------------------------------------------------

    def _next_id(self) -> int:
        self._rpc_id += 1
        return self._rpc_id

    async def _send_rpc(
        self, method: str, params: dict, has_response: bool = True
    ) -> Optional[dict]:
        """JSON-RPC 메시지 전송. has_response=False면 알림(notification)."""
        if has_response:
            rpc_id = self._next_id()
            msg = {"id": rpc_id, "method": method, "params": params}
            # race condition 방지: pending future를 전송 전에 등록
            future: asyncio.Future = asyncio.get_event_loop().create_future()
            self._pending[rpc_id] = future
        else:
            rpc_id = None
            msg = {"method": method, "params": params}

        line = json.dumps(msg, ensure_ascii=False) + "\n"
        self._process.stdin.write(line.encode("utf-8"))
        await self._process.stdin.drain()

        if not has_response:
            return None

        try:
            return await asyncio.wait_for(future, timeout=60)
        finally:
            self._pending.pop(rpc_id, None)

    async def _reader_loop(self) -> None:
        """프로세스 stdout을 읽어 RPC 응답과 알림을 라우팅한다."""
        while self._process and self._process.returncode is None:
            try:
                line_bytes = await asyncio.wait_for(
                    self._process.stdout.readline(), timeout=1
                )
            except asyncio.TimeoutError:
                continue
            except Exception as e:
                logger.error(f"reader_loop 오류: {e}")
                break
            if not line_bytes:
                break

            line = line_bytes.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                logger.debug(f"JSON 파싱 실패: {line[:200]}")
                continue

            logger.debug(f"[codex RPC] {line[:300]}")
            _emit("system", f"[Codex RPC] {line[:300]}", level="debug")

            msg_id = msg.get("id")
            if msg_id is not None and msg_id in self._pending:
                # RPC 응답
                fut = self._pending.get(msg_id)
                if fut and not fut.done():
                    if "error" in msg:
                        fut.set_exception(RuntimeError(str(msg["error"])))
                    else:
                        fut.set_result(msg.get("result", {}))
            else:
                # 알림 (method가 있는 메시지)
                if "method" in msg:
                    await self._notifications.put(msg)

    async def _handshake(self) -> None:
        """JSON-RPC 핸드셰이크: initialize → initialized → thread/start"""
        logger.info("Codex 핸드셰이크 시작")
        _emit("system", "Codex 핸드셰이크 중...")

        # initialize 요청
        await self._send_rpc("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "consolent", "version": "1.0"},
        })

        # initialized 알림 (응답 없음)
        await self._send_rpc("initialized", {}, has_response=False)

        # thread/start 요청 — thread_id 획득
        # 실제 응답 구조: {"thread": {"id": "...", ...}, "model": ..., ...}
        result = await self._send_rpc("thread/start", {"workingDirectory": self.cwd})
        thread_data = result.get("thread") or {}
        self._thread_id = (
            thread_data.get("id")           # 실제 키: result.thread.id
            or result.get("threadId")       # 폴백
            or result.get("thread_id")      # 폴백
        )
        if not self._thread_id:
            raise RuntimeError(f"thread_id를 가져올 수 없습니다. 응답: {str(result)[:200]}")
        logger.info(f"Codex thread_id: {self._thread_id}")
        _emit("system", f"Codex 핸드셰이크 완료 (thread={self._thread_id})")

    # ------------------------------------------------------------------
    # Auth / Ready helpers
    # ------------------------------------------------------------------

    def _check_auth(self, request: web.Request) -> Optional[web.Response]:
        if not self.api_key:
            return None
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or auth[7:] != self.api_key:
            return web.json_response(
                {"error": {"message": "Invalid API key", "type": "auth_error"}}, status=401
            )
        return None

    def _check_ready(self) -> Optional[web.Response]:
        if self.init_error:
            return web.json_response(
                {"error": {"message": f"초기화 실패: {self.init_error}", "type": "server_error"}}, status=503
            )
        if not self.ready:
            return web.json_response(
                {"error": {"message": "Server initializing", "type": "server_error"}}, status=503
            )
        if self.busy:
            return web.json_response(
                {"error": {"message": "Session is busy", "type": "conflict"}}, status=409
            )
        return None

    # ------------------------------------------------------------------
    # HTTP Handlers
    # ------------------------------------------------------------------

    async def handle_health(self, _request: web.Request) -> web.Response:
        if self.init_error:
            return web.json_response({
                "status": "error",
                "error": self.init_error,
                "cwd": self.cwd,
            }, status=503)
        return web.json_response({
            "status": "ready" if self.ready and not self.busy else ("busy" if self.busy else "initializing"),
            "thread_id": self._thread_id,
            "cwd": self.cwd,
        })

    async def handle_models(self, _request: web.Request) -> web.Response:
        return web.json_response({
            "object": "list",
            "data": [{
                "id": "codex-bridge",
                "object": "model",
                "created": int(time.time()),
                "owned_by": "codex",
            }],
        })

    async def handle_chat_completions(self, request: web.Request) -> web.Response:
        """POST /v1/chat/completions — OpenAI 호환"""
        if err := self._check_auth(request):
            return err
        if err := self._check_ready():
            return err
        try:
            body = await request.json()
        except Exception:
            return web.json_response({"error": {"message": "Invalid JSON"}}, status=400)

        messages = body.get("messages", [])
        stream = body.get("stream", False)
        system_prompt, user_prompt = self._extract_openai_messages(messages)

        if not user_prompt:
            return web.json_response({"error": {"message": "No user message"}}, status=400)

        self.busy = True
        request_id = f"chatcmpl-{uuid.uuid4().hex[:12]}"
        _emit("user", user_prompt)

        try:
            if stream:
                return await self._openai_stream(request, system_prompt, user_prompt, request_id)
            else:
                return await self._openai_sync(system_prompt, user_prompt, request_id)
        except asyncio.TimeoutError:
            msg = "Codex 응답 타임아웃 — 프로세스가 응답하지 않습니다"
            _emit("system", f"❌ {msg}", level="error")
            return web.json_response({"error": {"message": msg, "type": "timeout"}}, status=504)
        except Exception as e:
            msg = f"Codex 요청 처리 오류: {e}"
            _emit("system", f"❌ {msg}", level="error")
            return web.json_response({"error": {"message": msg, "type": "server_error"}}, status=500)
        finally:
            self.busy = False

    async def handle_messages(self, request: web.Request) -> web.Response:
        """POST /v1/messages — Anthropic Messages API 호환"""
        if err := self._check_auth(request):
            return err
        if err := self._check_ready():
            return err
        try:
            body = await request.json()
        except Exception:
            return web.json_response(
                {"type": "error", "error": {"type": "invalid_request_error", "message": "Invalid JSON"}},
                status=400,
            )

        system_raw = body.get("system", None)
        system_prompt: Optional[str] = None
        if isinstance(system_raw, str):
            system_prompt = system_raw
        elif isinstance(system_raw, list):
            system_prompt = " ".join(
                b.get("text", "") for b in system_raw if b.get("type") == "text"
            )

        messages = body.get("messages", [])
        stream = body.get("stream", False)
        request_model = body.get("model", "codex-bridge")

        user_prompt = self._extract_anthropic_user(messages)
        if not user_prompt:
            return web.json_response(
                {"type": "error", "error": {"type": "invalid_request_error", "message": "No user message"}},
                status=400,
            )

        self.busy = True
        msg_id = f"msg_{uuid.uuid4().hex[:24]}"
        _emit("user", user_prompt)

        try:
            if stream:
                return await self._anthropic_stream(request, system_prompt, user_prompt, msg_id, request_model)
            else:
                return await self._anthropic_sync(system_prompt, user_prompt, msg_id, request_model)
        except asyncio.TimeoutError:
            msg = "Codex 응답 타임아웃 — 프로세스가 응답하지 않습니다"
            _emit("system", f"❌ {msg}", level="error")
            return web.json_response(
                {"type": "error", "error": {"type": "server_error", "message": msg}}, status=504
            )
        except Exception as e:
            msg = f"Codex 요청 처리 오류: {e}"
            _emit("system", f"❌ {msg}", level="error")
            return web.json_response(
                {"type": "error", "error": {"type": "server_error", "message": msg}}, status=500
            )
        finally:
            self.busy = False

    # ------------------------------------------------------------------
    # Core query logic
    # ------------------------------------------------------------------

    async def _query_codex_stream(self, system_prompt: Optional[str], user_prompt: str):
        """Codex에 turn/start를 보내고 델타 청크를 비동기 생성한다."""
        async with self._lock:
            input_text = user_prompt
            if system_prompt:
                input_text = f"[System: {system_prompt}]\n\n{user_prompt}"

            # turn/start 요청
            # Codex 프로토콜: turn/start → 동기 RPC 응답(id 매칭) + turn/started notification
            # race condition 방지: pending future를 전송 전에 등록
            rpc_id = self._next_id()
            future: asyncio.Future = asyncio.get_event_loop().create_future()
            self._pending[rpc_id] = future

            msg = {
                "id": rpc_id,
                "method": "turn/start",
                "params": {
                    "threadId": self._thread_id,
                    "input": [{"type": "text", "text": input_text}],
                },
            }
            self._process.stdin.write((json.dumps(msg, ensure_ascii=False) + "\n").encode("utf-8"))
            await self._process.stdin.drain()

            # turn/start RPC 응답 대기 (즉시 반환됨)
            try:
                await asyncio.wait_for(future, timeout=30)
            except asyncio.TimeoutError:
                raise asyncio.TimeoutError("turn/start 응답 타임아웃 (30초)")
            finally:
                self._pending.pop(rpc_id, None)

            # 알림 처리 — turn/completed 까지
            deadline = time.time() + 300
            while time.time() < deadline:
                try:
                    notif = await asyncio.wait_for(
                        self._notifications.get(), timeout=120
                    )
                except asyncio.TimeoutError:
                    break

                method = notif.get("method", "")
                params = notif.get("params", {})

                if method == "turn/started":
                    pass  # 처리 시작 확인용

                elif method == "item/agentMessage/delta":
                    # Codex 실제 프로토콜: params["delta"]가 string 직접
                    # e.g. {"delta": "Hi"} — dict가 아님
                    delta = params.get("delta", "")
                    if isinstance(delta, str):
                        text = delta
                    elif isinstance(delta, dict):
                        text = delta.get("text", "") or delta.get("content", "")
                    else:
                        text = ""
                    if text:
                        yield text

                elif method == "item/completed":
                    pass  # 아이템 완료

                elif method == "item/commandExecution/requestApproval":
                    # 자동 승인
                    notif_id = notif.get("id")
                    cmd_info = params.get("command", params.get("tool", "unknown"))
                    _emit("tool_use", f"승인: {cmd_info}")
                    if notif_id is not None:
                        approval = {"id": notif_id, "result": {"decision": "approved"}}
                        self._process.stdin.write(
                            (json.dumps(approval) + "\n").encode("utf-8")
                        )
                        await self._process.stdin.drain()

                elif method == "turn/completed":
                    break

                else:
                    logger.debug(f"알 수 없는 알림: {method} params={str(params)[:200]}")
                    _emit("system", f"[codex 알림] {method}", level="debug")

    async def _query_codex(self, system_prompt: Optional[str], user_prompt: str) -> str:
        full_text = ""
        async for chunk in self._query_codex_stream(system_prompt, user_prompt):
            full_text += chunk
        return full_text

    # ------------------------------------------------------------------
    # OpenAI 응답 생성
    # ------------------------------------------------------------------

    async def _openai_stream(
        self, request: web.Request, system_prompt, user_prompt, request_id
    ) -> web.StreamResponse:
        response = web.StreamResponse(status=200, headers={
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        })
        await response.prepare(request)

        full_text = ""
        try:
            async for chunk in self._query_codex_stream(system_prompt, user_prompt):
                full_text += chunk
                data = {
                    "id": request_id,
                    "object": "chat.completion.chunk",
                    "choices": [{"delta": {"content": chunk, "role": "assistant"}, "index": 0, "finish_reason": None}],
                }
                await response.write(f"data: {json.dumps(data, ensure_ascii=False)}\n\n".encode())
        except Exception as e:
            logger.error(f"스트리밍 오류: {e}")

        # 마지막 청크: finish_reason=stop (OpenAI SSE 표준)
        finish_data = {
            "id": request_id,
            "object": "chat.completion.chunk",
            "choices": [{"delta": {}, "index": 0, "finish_reason": "stop"}],
        }
        await response.write(f"data: {json.dumps(finish_data, ensure_ascii=False, separators=(',', ':'))}\n\n".encode())
        await response.write(b"data: [DONE]\n\n")
        _emit("assistant", full_text)
        _emit("assistant_done", "")
        return response

    async def _openai_sync(self, system_prompt, user_prompt, request_id) -> web.Response:
        full_text = await self._query_codex(system_prompt, user_prompt)
        _emit("assistant", full_text)
        return web.json_response({
            "id": request_id,
            "object": "chat.completion",
            "created": int(time.time()),
            "model": "codex-bridge",
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": full_text},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        })

    # ------------------------------------------------------------------
    # Anthropic 응답 생성
    # ------------------------------------------------------------------

    async def _anthropic_stream(
        self, request: web.Request, system_prompt, user_prompt, msg_id, model
    ) -> web.StreamResponse:
        response = web.StreamResponse(status=200, headers={
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        })
        await response.prepare(request)

        async def send_event(event_type: str, data: dict) -> None:
            line = f"event: {event_type}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"
            await response.write(line.encode())

        await send_event("message_start", {
            "type": "message_start",
            "message": {
                "id": msg_id, "type": "message", "role": "assistant",
                "content": [], "model": model, "stop_reason": None,
                "usage": {"input_tokens": 0, "output_tokens": 0},
            },
        })
        await send_event("content_block_start", {
            "type": "content_block_start", "index": 0,
            "content_block": {"type": "text", "text": ""},
        })

        full_text = ""
        try:
            async for chunk in self._query_codex_stream(system_prompt, user_prompt):
                full_text += chunk
                await send_event("content_block_delta", {
                    "type": "content_block_delta", "index": 0,
                    "delta": {"type": "text_delta", "text": chunk},
                })
        except Exception as e:
            logger.error(f"Anthropic 스트리밍 오류: {e}")

        await send_event("content_block_stop", {"type": "content_block_stop", "index": 0})
        await send_event("message_delta", {
            "type": "message_delta",
            "delta": {"stop_reason": "end_turn"},
            "usage": {"output_tokens": 0},
        })
        await send_event("message_stop", {"type": "message_stop"})

        _emit("assistant", full_text)
        _emit("assistant_done", "")
        return response

    async def _anthropic_sync(self, system_prompt, user_prompt, msg_id, model) -> web.Response:
        full_text = await self._query_codex(system_prompt, user_prompt)
        _emit("assistant", full_text)
        return web.json_response({
            "id": msg_id, "type": "message", "role": "assistant",
            "content": [{"type": "text", "text": full_text}],
            "model": model, "stop_reason": "end_turn",
            "usage": {"input_tokens": 0, "output_tokens": len(full_text)},
        })

    # ------------------------------------------------------------------
    # Message extraction helpers
    # ------------------------------------------------------------------

    def _extract_openai_messages(self, messages: list) -> tuple[Optional[str], str]:
        system_prompt = None
        user_parts = []
        for msg in messages:
            role = msg.get("role", "")
            content = msg.get("content", "")
            if role == "system":
                system_prompt = content if isinstance(content, str) else \
                    " ".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
            elif role == "user":
                if isinstance(content, str):
                    user_parts.append(content)
                elif isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "text":
                            user_parts.append(block.get("text", ""))
        return system_prompt, "\n".join(user_parts)

    def _extract_anthropic_user(self, messages: list) -> str:
        parts = []
        for msg in messages:
            if msg.get("role") != "user":
                continue
            content = msg.get("content", "")
            if isinstance(content, str):
                parts.append(content)
            elif isinstance(content, list):
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "text":
                        parts.append(b.get("text", ""))
        return "\n".join(parts)

    # ------------------------------------------------------------------
    # codex binary finder
    # ------------------------------------------------------------------

    async def _find_codex(self) -> str:
        """codex 바이너리 경로를 찾는다."""
        candidates = [
            self.codex_path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            os.path.expanduser("~/.local/bin/codex"),
            os.path.expanduser("~/.npm-global/bin/codex"),
        ]
        for path in candidates:
            if os.path.isfile(path) and os.access(path, os.X_OK):
                return path
        try:
            shell = os.environ.get("SHELL", "/bin/zsh")
            proc = await asyncio.create_subprocess_exec(
                shell, "-li", "-c", "which codex",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
            out, _ = await asyncio.wait_for(proc.communicate(), timeout=10)
            path = out.decode().strip()
            if path:
                return path
        except Exception:
            pass
        return "codex"


def create_app(bridge: CodexBridge) -> web.Application:
    app = web.Application()
    app.router.add_get("/health", bridge.handle_health)
    app.router.add_get("/v1/models", bridge.handle_models)
    app.router.add_post("/v1/chat/completions", bridge.handle_chat_completions)
    app.router.add_post("/v1/messages", bridge.handle_messages)
    return app


async def main() -> None:
    parser = argparse.ArgumentParser(description="Consolent Codex Bridge Server")
    parser.add_argument("--port", type=int, default=8790)
    parser.add_argument("--cwd", default=".")
    parser.add_argument("--codex-path", default="codex")
    parser.add_argument("--api-key", default=None)
    parser.add_argument("--log-level", default="info",
                        choices=["error", "info", "debug"],
                        help="출력 레벨: error(오류만) | info(상태메시지) | debug(원시출력 포함)")
    args = parser.parse_args()
    _set_log_level(args.log_level)

    bridge = CodexBridge(
        port=args.port,
        cwd=os.path.abspath(args.cwd),
        codex_path=args.codex_path,
        api_key=args.api_key,
    )

    # HTTP 서버를 먼저 시작한다 — /health가 "initializing"을 반환하므로
    # Consolent Swift 측에서 폴링하는 동안 connection refused가 발생하지 않는다.
    app = create_app(bridge)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", args.port)
    await site.start()
    logger.info(f"Codex 브릿지 HTTP 서버 바인딩: http://127.0.0.1:{args.port}")
    _emit("system", f"Codex 브릿지 서버 시작: http://127.0.0.1:{args.port}")

    # 백그라운드에서 Codex 프로세스 시작 + 핸드셰이크
    try:
        await bridge.start()
    except Exception as e:
        bridge.init_error = str(e)
        logger.error(f"Codex 초기화 실패: {e}")
        # 서버는 유지하되 /health에서 error 상태를 반환
        # Consolent Swift의 health 폴링이 오류를 감지할 수 있도록

    try:
        await asyncio.Event().wait()
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    finally:
        await bridge.stop()
        await runner.cleanup()


if __name__ == "__main__":
    asyncio.run(main())
