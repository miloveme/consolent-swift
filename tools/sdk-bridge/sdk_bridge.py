#!/usr/bin/env python3
"""
Consolent SDK Bridge Server
============================
Claude Agent SDK의 ClaudeSDKClient를 감싸는 OpenAI / Anthropic 호환 HTTP API 서버.
Consolent 앱에서 서브프로세스로 실행되며, 유저 앱(Cursor, Claude Desktop 등)이 직접 호출할 수 있다.

사용법:
    python3 sdk_bridge.py --port 8788 --cwd /path/to/project
    python3 sdk_bridge.py --port 8788 --cwd . --model claude-sonnet-4-20250514

지원 API:
    OpenAI 호환:    POST /v1/chat/completions  (stream 지원)
    Anthropic 호환: POST /v1/messages          (stream 지원)
    공통:           GET  /v1/models, GET /health
"""

import argparse
import asyncio
import json
import logging
import sys
import time
import uuid
import base64
import tempfile
import os
from typing import Optional

from aiohttp import web

from claude_agent_sdk import (
    ClaudeSDKClient,
    ClaudeAgentOptions,
    AssistantMessage,
    UserMessage,
    ResultMessage,
    SystemMessage,
    TextBlock,
    ThinkingBlock,
    ToolUseBlock,
    ToolResultBlock,
)

logging.basicConfig(
    level=logging.WARNING,
    format="[%(asctime)s] %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("sdk-bridge")
logging.getLogger("aiohttp.access").setLevel(logging.WARNING)

CONSOLENT_PREFIX = "@@CONSOLENT@@"
_LOG_LEVEL = "info"
_LOG_ORDER = {"error": 0, "info": 1, "debug": 2}


def _set_log_level(level: str) -> None:
    global _LOG_LEVEL
    _LOG_LEVEL = level if level in _LOG_ORDER else "info"
    py_level = {"error": logging.ERROR, "info": logging.WARNING, "debug": logging.DEBUG}
    logger.setLevel(py_level.get(_LOG_LEVEL, logging.WARNING))


def _emit_level(type_: str, content: str, level: str = "info") -> None:
    """레벨 필터링이 있는 emit. debug 전용 메시지에 사용."""
    if _LOG_ORDER.get(level, 1) > _LOG_ORDER.get(_LOG_LEVEL, 1):
        return
    payload = json.dumps({"type": type_, "content": content}, ensure_ascii=False)
    sys.stdout.write(f"{CONSOLENT_PREFIX}{payload}\n")
    sys.stdout.flush()


class SDKBridge:
    """Claude Agent SDK를 OpenAI / Anthropic 호환 API로 노출하는 브릿지 서버."""

    def __init__(
        self,
        port: int,
        cwd: str,
        model: Optional[str] = None,
        permission_mode: str = "acceptEdits",
        allowed_tools: Optional[list[str]] = None,
        api_key: Optional[str] = None,
    ):
        self.port = port
        self.cwd = cwd
        self.model = model
        self.permission_mode = permission_mode
        self.allowed_tools = allowed_tools or []
        self.api_key = api_key
        self.client: Optional[ClaudeSDKClient] = None
        self.session_id: Optional[str] = None
        self.ready = False
        self.busy = False
        self.init_error: Optional[str] = None
        self._app: Optional[web.Application] = None

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    async def start(self) -> None:
        options = ClaudeAgentOptions(
            cwd=self.cwd,
            permission_mode=self.permission_mode,
        )
        if self.model:
            options.model = self.model
        if self.allowed_tools:
            options.allowed_tools = self.allowed_tools

        self.client = ClaudeSDKClient(options=options)
        await self.client.connect()
        self.ready = True
        self._emit("system", f"SDK 클라이언트 연결 완료 (cwd={self.cwd})")

    async def stop(self) -> None:
        if self.client:
            await self.client.disconnect()
            self.client = None
        self.ready = False
        self._emit("system", "SDK 클라이언트 종료")

    # ------------------------------------------------------------------
    # Auth Helper
    # ------------------------------------------------------------------

    def _check_auth(self, request: web.Request) -> Optional[web.Response]:
        """인증 실패 시 에러 응답 반환. 성공 시 None."""
        if not self.api_key:
            return None
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or auth[7:] != self.api_key:
            return web.json_response(
                {"error": {"message": "Invalid API key", "type": "auth_error"}},
                status=401,
            )
        return None

    def _check_ready(self) -> Optional[web.Response]:
        """서버 준비 상태 확인. 문제 있으면 에러 응답 반환."""
        if not self.ready:
            return web.json_response(
                {"error": {"message": "SDK client not ready", "type": "server_error"}},
                status=503,
            )
        if self.busy:
            return web.json_response(
                {"error": {"message": "Session is busy", "type": "conflict"}},
                status=409,
            )
        return None

    # ------------------------------------------------------------------
    # HTTP Handlers — 공통
    # ------------------------------------------------------------------

    async def handle_health(self, _request: web.Request) -> web.Response:
        """GET /health"""
        if self.init_error:
            return web.json_response({
                "status": "error",
                "error": self.init_error,
                "cwd": self.cwd,
            }, status=503)
        if not self.ready:
            return web.json_response({
                "status": "initializing",
                "cwd": self.cwd,
            })
        return web.json_response({
            "status": "ready" if not self.busy else "busy",
            "session_id": self.session_id,
            "model": self.model,
            "cwd": self.cwd,
        })

    async def handle_models(self, request: web.Request) -> web.Response:
        """GET /v1/models — OpenAI + Anthropic 공통"""
        if err := self._check_auth(request): return err
        model_id = self.model or "claude-agent-sdk"
        return web.json_response({
            "object": "list",
            "data": [{
                "id": model_id,
                "object": "model",
                "created": int(time.time()),
                "owned_by": "sdk",
            }],
        })

    async def handle_interrupt(self, request: web.Request) -> web.Response:
        """POST /interrupt"""
        if err := self._check_auth(request): return err
        if self.client and self.busy:
            await self.client.interrupt()
            return web.json_response({"status": "interrupted"})
        return web.json_response({"status": "not_busy"})

    async def handle_disconnect(self, request: web.Request) -> web.Response:
        """POST /disconnect"""
        if err := self._check_auth(request): return err
        await self.stop()
        return web.json_response({"status": "disconnected"})

    # ------------------------------------------------------------------
    # HTTP Handlers — OpenAI 호환
    # ------------------------------------------------------------------

    async def handle_chat_completions(self, request: web.Request) -> web.Response:
        """POST /v1/chat/completions — OpenAI 호환"""
        if err := self._check_auth(request): return err
        if err := self._check_ready(): return err

        try:
            body = await request.json()
        except json.JSONDecodeError:
            return web.json_response(
                {"error": {"message": "Invalid JSON", "type": "invalid_request"}},
                status=400,
            )

        messages = body.get("messages", [])
        stream = body.get("stream", False)
        request_model = body.get("model", self.model or "claude-agent-sdk")

        system_prompt, user_prompt, image_paths = self._extract_openai_messages(messages)
        if not user_prompt:
            return web.json_response(
                {"error": {"message": "No user message found", "type": "invalid_request"}},
                status=400,
            )

        original_user_text = user_prompt
        prompt = self._build_prompt(user_prompt, system_prompt, image_paths)

        self.busy = True
        request_id = f"chatcmpl-{uuid.uuid4().hex[:12]}"
        self._emit("user", original_user_text)

        try:
            if stream:
                return await self._openai_stream(request, prompt, request_id, request_model)
            else:
                return await self._openai_sync(prompt, request_id, request_model)
        finally:
            self.busy = False

    # ------------------------------------------------------------------
    # HTTP Handlers — Anthropic 호환
    # ------------------------------------------------------------------

    async def handle_messages(self, request: web.Request) -> web.Response:
        """POST /v1/messages — Anthropic Messages API 호환"""
        if err := self._check_auth(request): return err
        if err := self._check_ready(): return err

        try:
            body = await request.json()
        except json.JSONDecodeError:
            return web.json_response(
                {"type": "error", "error": {"type": "invalid_request_error", "message": "Invalid JSON"}},
                status=400,
            )

        # Anthropic 형식: system은 top-level 문자열 또는 content 블록 배열
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
        request_model = body.get("model", self.model or "claude-agent-sdk")
        max_tokens = body.get("max_tokens", 8096)

        user_prompt, image_paths = self._extract_anthropic_user(messages)
        if not user_prompt:
            return web.json_response(
                {"type": "error", "error": {"type": "invalid_request_error", "message": "No user message found"}},
                status=400,
            )

        original_user_text = user_prompt
        prompt = self._build_prompt(user_prompt, system_prompt, image_paths)

        self.busy = True
        msg_id = f"msg_{uuid.uuid4().hex[:24]}"
        self._emit("user", original_user_text)

        try:
            if stream:
                return await self._anthropic_stream(request, prompt, msg_id, request_model)
            else:
                return await self._anthropic_sync(prompt, msg_id, request_model, max_tokens)
        finally:
            self.busy = False

    # ------------------------------------------------------------------
    # OpenAI 응답 생성
    # ------------------------------------------------------------------

    async def _openai_stream(self, request: web.Request, prompt: str, request_id: str, model: str) -> web.StreamResponse:
        response = web.StreamResponse(status=200, headers={
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        })
        await response.prepare(request)

        full_text = ""
        await self.client.query(prompt)
        async for message in self.client.receive_response():
            _emit_level("system", f"[SDK] {type(message).__name__}: {repr(message)[:300]}", level="debug")
            if isinstance(message, AssistantMessage):
                for block in message.content:
                    if isinstance(block, TextBlock):
                        full_text += block.text
                        chunk = self._openai_chunk(request_id, model, content=block.text)
                        await response.write(f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n".encode())
                    elif isinstance(block, ToolUseBlock):
                        self._emit("tool_use", f"{block.name}({json.dumps(block.input, ensure_ascii=False)})")
                        chunk = self._openai_chunk(request_id, model, tool_call={
                            "id": block.id, "type": "function",
                            "function": {"name": block.name, "arguments": json.dumps(block.input, ensure_ascii=False)},
                        })
                        await response.write(f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n".encode())
                    elif isinstance(block, ToolResultBlock):
                        self._emit_tool_result(block)
                    elif isinstance(block, ThinkingBlock):
                        self._emit("thinking", block.thinking[:100])
            elif isinstance(message, ResultMessage):
                self.session_id = message.session_id

        # 마지막 청크: finish_reason=stop (OpenAI SSE 표준)
        finish_chunk = self._openai_chunk(request_id, model, finish_reason="stop")
        await response.write(f"data: {json.dumps(finish_chunk, ensure_ascii=False, separators=(',', ':'))}\n\n".encode())
        await response.write(b"data: [DONE]\n\n")
        self._emit("assistant", full_text)
        self._emit("assistant_done", "")
        return response

    async def _openai_sync(self, prompt: str, request_id: str, model: str) -> web.Response:
        full_text = ""
        tool_calls = []

        await self.client.query(prompt)
        async for message in self.client.receive_response():
            _emit_level("system", f"[SDK] {type(message).__name__}: {repr(message)[:300]}", level="debug")
            if isinstance(message, AssistantMessage):
                for block in message.content:
                    if isinstance(block, TextBlock):
                        full_text += block.text
                    elif isinstance(block, ToolUseBlock):
                        self._emit("tool_use", f"{block.name}({json.dumps(block.input, ensure_ascii=False)})")
                        tool_calls.append({
                            "id": block.id, "type": "function",
                            "function": {"name": block.name, "arguments": json.dumps(block.input, ensure_ascii=False)},
                        })
                    elif isinstance(block, ToolResultBlock):
                        self._emit_tool_result(block)
                    elif isinstance(block, ThinkingBlock):
                        self._emit("thinking", block.thinking[:100])
            elif isinstance(message, ResultMessage):
                self.session_id = message.session_id

        self._emit("assistant", full_text)
        assistant_message: dict = {"role": "assistant", "content": full_text}
        if tool_calls:
            assistant_message["tool_calls"] = tool_calls

        return web.json_response({
            "id": request_id,
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model,
            "choices": [{"index": 0, "message": assistant_message,
                         "finish_reason": "tool_calls" if tool_calls else "stop"}],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        })

    # ------------------------------------------------------------------
    # Anthropic 응답 생성
    # ------------------------------------------------------------------

    async def _anthropic_stream(self, request: web.Request, prompt: str, msg_id: str, model: str) -> web.StreamResponse:
        """Anthropic SSE 스트리밍: message_start → content_block_* → message_stop"""
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

        block_index = 0
        full_text = ""

        await self.client.query(prompt)
        async for message in self.client.receive_response():
            _emit_level("system", f"[SDK] {type(message).__name__}: {repr(message)[:300]}", level="debug")
            if isinstance(message, AssistantMessage):
                for block in message.content:
                    if isinstance(block, TextBlock):
                        await send_event("content_block_start", {
                            "type": "content_block_start", "index": block_index,
                            "content_block": {"type": "text", "text": ""},
                        })
                        await send_event("content_block_delta", {
                            "type": "content_block_delta", "index": block_index,
                            "delta": {"type": "text_delta", "text": block.text},
                        })
                        await send_event("content_block_stop", {
                            "type": "content_block_stop", "index": block_index,
                        })
                        full_text += block.text
                        block_index += 1

                    elif isinstance(block, ToolUseBlock):
                        self._emit("tool_use", f"{block.name}({json.dumps(block.input, ensure_ascii=False)})")
                        await send_event("content_block_start", {
                            "type": "content_block_start", "index": block_index,
                            "content_block": {"type": "tool_use", "id": block.id,
                                              "name": block.name, "input": {}},
                        })
                        await send_event("content_block_delta", {
                            "type": "content_block_delta", "index": block_index,
                            "delta": {"type": "input_json_delta",
                                      "partial_json": json.dumps(block.input, ensure_ascii=False)},
                        })
                        await send_event("content_block_stop", {
                            "type": "content_block_stop", "index": block_index,
                        })
                        block_index += 1

                    elif isinstance(block, ToolResultBlock):
                        self._emit_tool_result(block)

                    elif isinstance(block, ThinkingBlock):
                        self._emit("thinking", block.thinking[:100])

            elif isinstance(message, ResultMessage):
                self.session_id = message.session_id

        output_tokens = len(full_text.split())
        await send_event("message_delta", {
            "type": "message_delta",
            "delta": {"stop_reason": "end_turn", "stop_sequence": None},
            "usage": {"output_tokens": output_tokens},
        })
        await send_event("message_stop", {"type": "message_stop"})
        self._emit("assistant", full_text)
        self._emit("assistant_done", "")
        return response

    async def _anthropic_sync(self, prompt: str, msg_id: str, model: str, max_tokens: int) -> web.Response:
        """Anthropic JSON 응답."""
        full_text = ""
        content_blocks: list[dict] = []

        await self.client.query(prompt)
        async for message in self.client.receive_response():
            _emit_level("system", f"[SDK] {type(message).__name__}: {repr(message)[:300]}", level="debug")
            if isinstance(message, AssistantMessage):
                for block in message.content:
                    if isinstance(block, TextBlock):
                        full_text += block.text
                        content_blocks.append({"type": "text", "text": block.text})
                    elif isinstance(block, ToolUseBlock):
                        self._emit("tool_use", f"{block.name}({json.dumps(block.input, ensure_ascii=False)})")
                        content_blocks.append({
                            "type": "tool_use", "id": block.id,
                            "name": block.name, "input": block.input,
                        })
                    elif isinstance(block, ToolResultBlock):
                        self._emit_tool_result(block)
                    elif isinstance(block, ThinkingBlock):
                        self._emit("thinking", block.thinking[:100])
            elif isinstance(message, ResultMessage):
                self.session_id = message.session_id

        self._emit("assistant", full_text)
        stop_reason = "tool_use" if any(b["type"] == "tool_use" for b in content_blocks) else "end_turn"

        return web.json_response({
            "id": msg_id,
            "type": "message",
            "role": "assistant",
            "content": content_blocks,
            "model": model,
            "stop_reason": stop_reason,
            "stop_sequence": None,
            "usage": {
                "input_tokens": 0,
                "output_tokens": len(full_text.split()),
            },
        })

    # ------------------------------------------------------------------
    # Message Parsing
    # ------------------------------------------------------------------

    def _build_prompt(self, user_prompt: str, system_prompt: Optional[str], image_paths: list[str]) -> str:
        """SDK로 전송할 최종 프롬프트를 조합한다."""
        prompt = user_prompt
        if system_prompt:
            prompt = f"[System: {system_prompt}]\n\n{prompt}"
        if image_paths:
            img_note = "\n".join(f"[Image: {p}]" for p in image_paths)
            prompt = f"{img_note}\n\n{prompt}"
        return prompt

    def _extract_openai_messages(self, messages: list[dict]) -> tuple[Optional[str], Optional[str], list[str]]:
        """OpenAI 메시지 배열 → (system_prompt, user_prompt, image_paths)"""
        system_prompt = None
        user_prompt = None
        image_paths: list[str] = []

        for msg in messages:
            role = msg.get("role", "")
            content = msg.get("content", "")

            if role == "system":
                system_prompt = content if isinstance(content, str) else \
                    " ".join(c.get("text", "") for c in content if c.get("type") == "text")

            elif role == "user":
                if isinstance(content, str):
                    user_prompt = content
                elif isinstance(content, list):
                    text_parts = []
                    for block in content:
                        if block.get("type") == "text":
                            text_parts.append(block.get("text", ""))
                        elif block.get("type") == "image_url":
                            image_url = block.get("image_url", {}).get("url", "")
                            if image_url.startswith("data:"):
                                path = self._save_base64_image(image_url)
                                if path:
                                    image_paths.append(path)
                            elif image_url:
                                image_paths.append(image_url)
                    user_prompt = " ".join(text_parts)

        return system_prompt, user_prompt, image_paths

    def _extract_anthropic_user(self, messages: list[dict]) -> tuple[Optional[str], list[str]]:
        """Anthropic 메시지 배열 → (user_prompt, image_paths)
        마지막 user 메시지를 프롬프트로 사용한다."""
        user_prompt = None
        image_paths: list[str] = []

        for msg in reversed(messages):
            if msg.get("role") != "user":
                continue
            content = msg.get("content", "")
            if isinstance(content, str):
                user_prompt = content
            elif isinstance(content, list):
                text_parts = []
                for block in content:
                    btype = block.get("type", "")
                    if btype == "text":
                        text_parts.append(block.get("text", ""))
                    elif btype == "image":
                        source = block.get("source", {})
                        stype = source.get("type", "")
                        if stype == "base64":
                            media = source.get("media_type", "image/png")
                            data_b64 = source.get("data", "")
                            data_uri = f"data:{media};base64,{data_b64}"
                            path = self._save_base64_image(data_uri)
                            if path:
                                image_paths.append(path)
                        elif stype == "url":
                            image_paths.append(source.get("url", ""))
                user_prompt = " ".join(text_parts)
            break  # 마지막 user 메시지만 사용

        return user_prompt, image_paths

    def _save_base64_image(self, data_uri: str) -> Optional[str]:
        try:
            header, encoded = data_uri.split(",", 1)
            mime = header.split(":")[1].split(";")[0]
            ext = mime.split("/")[1] if "/" in mime else "png"
            data = base64.b64decode(encoded)
            fd, path = tempfile.mkstemp(suffix=f".{ext}", prefix="consolent_img_")
            os.write(fd, data)
            os.close(fd)
            return path
        except Exception as e:
            logger.error("이미지 저장 실패: %s", e)
            return None

    # ------------------------------------------------------------------
    # Emit / Chunk Helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _emit(event_type: str, content: str) -> None:
        payload = json.dumps({"type": event_type, "content": content}, ensure_ascii=False)
        sys.stdout.write(f"@@CONSOLENT@@{payload}\n")
        sys.stdout.flush()

    def _emit_tool_result(self, block: ToolResultBlock) -> None:
        result_text = ""
        if isinstance(block.content, str):
            result_text = block.content
        elif isinstance(block.content, list):
            result_text = " ".join(
                c.get("text", "") for c in block.content if isinstance(c, dict)
            )
        if result_text:
            self._emit("tool_result", f"[{block.tool_use_id}] {result_text[:200]}")

    @staticmethod
    def _openai_chunk(request_id: str, model: str, content: str | None = None,
                      tool_call: dict | None = None, finish_reason: str | None = None) -> dict:
        delta: dict = {}
        if content is not None:
            delta["content"] = content
        if tool_call is not None:
            delta["tool_calls"] = [tool_call]
        return {
            "id": request_id, "object": "chat.completion.chunk",
            "created": int(time.time()), "model": model,
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish_reason}],
        }

    # ------------------------------------------------------------------
    # Server Setup
    # ------------------------------------------------------------------

    def create_app(self) -> web.Application:
        app = web.Application()
        # 공통
        app.router.add_get("/health", self.handle_health)
        app.router.add_get("/v1/models", self.handle_models)
        app.router.add_post("/interrupt", self.handle_interrupt)
        app.router.add_post("/disconnect", self.handle_disconnect)
        # OpenAI 호환
        app.router.add_post("/v1/chat/completions", self.handle_chat_completions)
        # Anthropic 호환
        app.router.add_post("/v1/messages", self.handle_messages)
        self._app = app
        return app

    async def run(self) -> None:
        # HTTP 서버를 먼저 바인딩 — /health가 "initializing"을 반환하므로
        # Swift 폴링에서 connection refused(-1004) 없이 대기 가능
        app = self.create_app()
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, "127.0.0.1", self.port)
        await site.start()
        _emit_level("system", f"SDK Bridge HTTP 서버 바인딩: http://127.0.0.1:{self.port}")

        # SDK 클라이언트 초기화 (시간이 걸릴 수 있음)
        try:
            await self.start()
        except Exception as e:
            self.init_error = str(e)
            _emit_level("system", f"❌ SDK 초기화 실패: {e}", level="error")

        try:
            while True:
                await asyncio.sleep(3600)
        except (KeyboardInterrupt, asyncio.CancelledError):
            pass
        finally:
            await self.stop()
            await runner.cleanup()


def main():
    parser = argparse.ArgumentParser(description="Consolent SDK Bridge Server")
    parser.add_argument("--port", type=int, default=8788)
    parser.add_argument("--cwd", type=str, default=".")
    parser.add_argument("--model", type=str, default=None)
    parser.add_argument("--permission-mode", type=str, default="acceptEdits",
                        choices=["default", "acceptEdits", "plan", "bypassPermissions"])
    parser.add_argument("--allowed-tools", type=str, default=None)
    parser.add_argument("--api-key", type=str, default=None)
    parser.add_argument("--log-level", type=str, default="info",
                        choices=["error", "info", "debug"],
                        help="출력 레벨: error(오류만) | info(상태메시지) | debug(상세)")

    args = parser.parse_args()
    _set_log_level(args.log_level)
    allowed_tools = [t.strip() for t in args.allowed_tools.split(",")] if args.allowed_tools else None

    bridge = SDKBridge(
        port=args.port,
        cwd=os.path.abspath(args.cwd),
        model=args.model,
        permission_mode=args.permission_mode,
        allowed_tools=allowed_tools,
        api_key=args.api_key,
    )
    asyncio.run(bridge.run())


if __name__ == "__main__":
    main()
