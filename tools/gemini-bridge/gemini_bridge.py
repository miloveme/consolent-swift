#!/usr/bin/env python3
"""
Consolent Gemini Bridge Server
================================
Gemini CLI를 OpenAI / Anthropic 호환 API로 노출하는 브릿지 서버.

1) stdin 파이프 모드 (1차 시도): gemini --output-format stream-json --yolo 를
   영속 프로세스로 실행하고 stdin으로 프롬프트를 전달.
2) -p + --resume 모드 (폴백): 프로세스가 응답 후 종료하면,
   gemini -p "prompt" --output-format stream-json --yolo [--resume session_id] 로
   요청마다 실행. session_id는 --resume으로 이전 세션 복원.

Usage:
    python3 gemini_bridge.py --port 8789 --cwd /path/to/project
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
logger = logging.getLogger("gemini-bridge")
logger.setLevel(logging.INFO)
logging.getLogger("aiohttp.access").setLevel(logging.WARNING)

CONSOLENT_PREFIX = "@@CONSOLENT@@"

# 출력 레벨: error < info < debug
# 런타임에 --log-level 인자로 설정됨
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
    level: "error" (항상 표시) | "info" (기본, 상태 메시지) | "debug" (상세 진단)
    대화 타입(user/assistant 등)은 로그 레벨과 무관하게 항상 표시.
    """
    if type_ not in _CONVERSATION_TYPES and _LOG_ORDER.get(level, 1) > _LOG_ORDER.get(_LOG_LEVEL, 1):
        return  # 대화 외 메시지만 레벨 필터 적용
    payload = json.dumps({"type": type_, "content": content}, ensure_ascii=False)
    print(f"{CONSOLENT_PREFIX}{payload}", flush=True)


def _extract_text_from_event(event: dict) -> str:
    """Gemini CLI의 다양한 이벤트 구조에서 텍스트를 추출한다.

    알려진 포맷 변형:
    - {"type": "message", "content": "..."}
    - {"type": "content", "content": "..."}
    - {"type": "chunk", "text": "..."}
    - {"type": "text", "text": "..."}
    - {"type": "data", "data": {"text": "..."}}
    - {"type": "result", "response": {"text": "..."}} (전체 응답)
    """
    etype = event.get("type", "")

    # content 필드 (message, content 타입)
    content = event.get("content", "")
    if content and isinstance(content, str):
        return content

    # text 필드 (chunk, text 타입)
    text = event.get("text", "")
    if text and isinstance(text, str):
        return text

    # 중첩 data/response 구조
    data = event.get("data", {})
    if isinstance(data, dict):
        t = data.get("text", "") or data.get("content", "")
        if t:
            return t

    response = event.get("response", {})
    if isinstance(response, dict):
        t = response.get("text", "") or response.get("content", "")
        if t:
            return t
        # candidates 구조 (Gemini API 형식)
        candidates = response.get("candidates", [])
        if candidates:
            parts = candidates[0].get("content", {}).get("parts", [])
            return "".join(p.get("text", "") for p in parts)

    # parts 배열 구조
    parts = event.get("parts", [])
    if parts and isinstance(parts, list):
        return "".join(p.get("text", "") for p in parts if isinstance(p, dict))

    return ""


def _is_done_event(event: dict) -> bool:
    """응답 완료 이벤트인지 확인한다."""
    etype = event.get("type", "")
    if etype in ("result", "done", "end", "complete", "finish", "final"):
        return True
    # done 필드
    if event.get("done") is True:
        return True
    return False


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


class GeminiBridge:
    """Gemini CLI를 OpenAI / Anthropic 호환 API로 노출하는 브릿지."""

    def __init__(
        self,
        port: int,
        cwd: str,
        gemini_path: str = "gemini",
        api_key: Optional[str] = None,
    ):
        self.port = port
        self.cwd = cwd
        self.gemini_path = gemini_path
        self.api_key = api_key
        self.session_id: Optional[str] = None
        self.ready = False
        self.busy = False
        # None = 아직 미검증, True = stdin 파이프, False = -p 모드
        self._use_pipe_mode: Optional[bool] = None
        self._pipe_process: Optional[asyncio.subprocess.Process] = None
        self._pipe_lock = asyncio.Lock()
        self._login_env: Optional[dict] = None  # login shell 환경 (캐시)

    async def start(self) -> None:
        # login shell PATH 캐시 (node, gemini 등이 포함된 PATH)
        self._login_env = await _get_login_shell_env()
        # Gemini CLI는 각 응답 후 종료하므로 pipe 모드를 건너뛰고 바로 -p 모드 사용
        self._use_pipe_mode = False
        self.ready = True
        _emit("system", f"Gemini 브릿지 서버 시작 (cwd={self.cwd}, 모드=per-request)")

    async def stop(self) -> None:
        await self._kill_pipe_process()
        self.ready = False
        _emit("system", "Gemini 브릿지 서버 종료")

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
        if not self.ready:
            return web.json_response(
                {"error": {"message": "Server not ready", "type": "server_error"}}, status=503
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
        mode = "pipe" if self._use_pipe_mode else ("per_request" if self._use_pipe_mode is False else "unknown")
        return web.json_response({
            "status": "ready" if self.ready and not self.busy else "busy",
            "session_id": self.session_id,
            "cwd": self.cwd,
            "mode": mode,
        })

    async def handle_models(self, _request: web.Request) -> web.Response:
        return web.json_response({
            "object": "list",
            "data": [{
                "id": "gemini-bridge",
                "object": "model",
                "created": int(time.time()),
                "owned_by": "gemini",
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
        request_model = body.get("model", "gemini-bridge")

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
        finally:
            self.busy = False

    # ------------------------------------------------------------------
    # Core query logic
    # ------------------------------------------------------------------

    async def _query_gemini(self, system_prompt: Optional[str], user_prompt: str) -> str:
        """Gemini CLI에 쿼리하고 전체 응답 텍스트를 반환한다."""
        full_prompt = self._build_prompt(system_prompt, user_prompt)

        if self._use_pipe_mode is not False:
            try:
                result = await self._query_pipe(full_prompt)
                if result is not None:
                    return result
            except Exception as e:
                logger.warning(f"파이프 모드 실패: {e}, -p 모드로 폴백")
                self._use_pipe_mode = False

        return await self._query_per_request(full_prompt)

    async def _query_gemini_stream(self, system_prompt: Optional[str], user_prompt: str):
        """스트리밍 쿼리. 텍스트 청크를 비동기 생성한다."""
        full_prompt = self._build_prompt(system_prompt, user_prompt)

        if self._use_pipe_mode is not False:
            try:
                yielded_any = False
                async for chunk in self._query_pipe_stream(full_prompt):
                    yielded_any = True
                    yield chunk
                if yielded_any:
                    return
            except Exception as e:
                logger.warning(f"파이프 스트림 모드 실패: {e}, -p 모드로 폴백")
                self._use_pipe_mode = False

        async for chunk in self._query_per_request_stream(full_prompt):
            yield chunk

    def _build_prompt(self, system_prompt: Optional[str], user_prompt: str) -> str:
        if system_prompt:
            return f"[System: {system_prompt}]\n\n{user_prompt}"
        return user_prompt

    # ------------------------------------------------------------------
    # Pipe mode (stdin 파이프 — 영속 프로세스)
    # ------------------------------------------------------------------

    async def _ensure_pipe_process(self) -> asyncio.subprocess.Process:
        """파이프 프로세스가 살아있으면 반환, 아니면 새로 시작."""
        if self._pipe_process and self._pipe_process.returncode is None:
            return self._pipe_process

        cmd = [await self._find_gemini(), "--output-format", "stream-json", "--yolo"]
        env = os.environ.copy()
        self._pipe_process = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=self.cwd,
            env=env,
        )
        logger.info(f"Gemini 파이프 프로세스 시작 (PID {self._pipe_process.pid})")
        _emit("system", f"Gemini 파이프 프로세스 시작 (PID {self._pipe_process.pid})")
        # stderr 비동기 로깅
        asyncio.create_task(self._log_stderr(self._pipe_process))
        return self._pipe_process

    async def _log_stderr(self, proc: asyncio.subprocess.Process) -> None:
        """서브프로세스 stderr를 읽어 system 메시지로 출력한다."""
        if not proc.stderr:
            return
        try:
            while True:
                line = await proc.stderr.readline()
                if not line:
                    break
                text = line.decode("utf-8", errors="replace").strip()
                if text:
                    logger.info(f"[gemini stderr] {text}")
                    # 알려진 무해한 경고(keytar 등)는 debug로 낮춤
                    _KNOWN_NOISE = ("keytar", "keychain initialization", "cannot find module")
                    if any(k in text.lower() for k in _KNOWN_NOISE):
                        lvl = "debug"
                    elif any(k in text.lower() for k in ("error", "no such", "not found", "fatal", "exception")):
                        lvl = "error"
                    else:
                        lvl = "debug"
                    _emit("system", f"⚠️ gemini: {text}", level=lvl)
        except Exception:
            pass

    async def _kill_pipe_process(self) -> None:
        if self._pipe_process:
            try:
                self._pipe_process.terminate()
                await asyncio.wait_for(self._pipe_process.wait(), timeout=3)
            except Exception:
                try:
                    self._pipe_process.kill()
                except Exception:
                    pass
            self._pipe_process = None

    async def _read_jsonl_response(
        self, proc: asyncio.subprocess.Process
    ) -> tuple[str, Optional[str]]:
        """stdout에서 JSONL 이벤트를 읽어 전체 응답 텍스트와 session_id를 반환."""
        full_text = ""
        session_id = None
        unknown_events = []
        raw_lines_received = []

        while True:
            try:
                line_bytes = await asyncio.wait_for(proc.stdout.readline(), timeout=120)
            except asyncio.TimeoutError:
                break
            if not line_bytes:
                break
            line = line_bytes.decode("utf-8", errors="replace").strip()
            if not line:
                continue

            raw_lines_received.append(line[:200])

            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                # JSON이 아닌 텍스트는 직접 응답으로 처리
                logger.debug(f"JSON 아님: {line[:100]}")
                full_text += line + "\n"
                continue

            etype = event.get("type", "")

            if etype == "init":
                session_id = event.get("session_id") or event.get("sessionId")
                if session_id:
                    logger.info(f"Gemini session_id: {session_id}")
            elif etype in ("message", "content", "chunk", "text", "delta"):
                text = _extract_text_from_event(event)
                if text:
                    full_text += text
            elif _is_done_event(event):
                # result/done 이벤트에 전체 텍스트가 포함된 경우도 처리
                text = _extract_text_from_event(event)
                if text and not full_text:
                    full_text = text
                break
            elif etype in ("tool_call", "tool_use"):
                tool_name = event.get("name", event.get("tool", "unknown"))
                tool_input = event.get("input", event.get("arguments", {}))
                _emit("tool_use", f"{tool_name}({json.dumps(tool_input, ensure_ascii=False)})")
            elif etype == "error":
                err_msg = event.get("message", event.get("error", str(event)))
                _emit("system", f"❌ Gemini 오류: {err_msg}")
                raise RuntimeError(err_msg)
            else:
                # 알 수 없는 타입 — 텍스트 추출 시도
                text = _extract_text_from_event(event)
                if text:
                    full_text += text
                elif etype:
                    unknown_events.append(f"{etype}(keys={list(event.keys())})")

        if unknown_events:
            _emit("system", f"⚠️ 알 수 없는 Gemini 이벤트: {', '.join(set(unknown_events))}", level="debug")

        # 응답이 비었으면 수신한 원시 데이터를 진단 출력 (debug 레벨)
        if not full_text:
            if raw_lines_received:
                for raw in raw_lines_received[:3]:
                    _emit("system", f"[Gemini 원시 출력] {raw}", level="debug")
            else:
                _emit("system", "⚠️ Gemini stdout에서 아무 데이터도 수신되지 않았습니다.", level="error")

        return full_text, session_id

    async def _read_jsonl_stream(self, proc: asyncio.subprocess.Process):
        """stdout에서 JSONL 이벤트를 읽어 텍스트 청크를 스트리밍."""
        raw_lines_received = []
        yielded_any = False

        while True:
            try:
                line_bytes = await asyncio.wait_for(proc.stdout.readline(), timeout=120)
            except asyncio.TimeoutError:
                break
            if not line_bytes:
                break
            line = line_bytes.decode("utf-8", errors="replace").strip()
            if not line:
                continue

            raw_lines_received.append(line[:200])

            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                if line:
                    yield line
                    yielded_any = True
                continue

            etype = event.get("type", "")

            if etype == "init":
                sid = event.get("session_id") or event.get("sessionId")
                if sid:
                    self.session_id = sid
            elif etype in ("message", "content", "chunk", "text", "delta"):
                text = _extract_text_from_event(event)
                if text:
                    yield text
                    yielded_any = True
            elif _is_done_event(event):
                text = _extract_text_from_event(event)
                if text:
                    yield text
                    yielded_any = True
                break
            elif etype in ("tool_call", "tool_use"):
                tool_name = event.get("name", event.get("tool", "unknown"))
                tool_input = event.get("input", event.get("arguments", {}))
                _emit("tool_use", f"{tool_name}({json.dumps(tool_input, ensure_ascii=False)})")
            elif etype == "error":
                err_msg = event.get("message", event.get("error", str(event)))
                _emit("system", f"❌ Gemini 오류: {err_msg}")
                raise RuntimeError(err_msg)
            else:
                # 알 수 없는 타입 — 텍스트 추출 시도
                text = _extract_text_from_event(event)
                if text:
                    yield text
                    yielded_any = True
                elif etype:
                    _emit("system", f"⚠️ 미지원 이벤트: type={etype} keys={list(event.keys())}", level="debug")

        # 아무것도 안 나왔으면 원시 출력을 진단용으로 표시 (debug 레벨)
        if not yielded_any:
            if raw_lines_received:
                for raw in raw_lines_received[:3]:
                    _emit("system", f"[Gemini 원시 출력] {raw}", level="debug")
            else:
                _emit("system", "⚠️ Gemini stdout에서 아무 데이터도 수신되지 않았습니다.", level="error")

    async def _query_pipe(self, prompt: str) -> Optional[str]:
        """stdin 파이프 모드로 쿼리. 실패 시 None 반환."""
        async with self._pipe_lock:
            proc = await self._ensure_pipe_process()
            proc.stdin.write((prompt + "\n").encode("utf-8"))
            await proc.stdin.drain()

            full_text, session_id = await self._read_jsonl_response(proc)
            if session_id:
                self.session_id = session_id

            # 프로세스가 종료됐으면 파이프 모드 불가
            await asyncio.sleep(0.1)
            if proc.returncode is not None:
                logger.info("Gemini 프로세스가 응답 후 종료 → -p 모드로 전환")
                _emit("system", "Gemini 프로세스가 응답 후 종료 → -p 모드로 전환")
                self._use_pipe_mode = False
                self._pipe_process = None
            else:
                self._use_pipe_mode = True

            return full_text

    async def _query_pipe_stream(self, prompt: str):
        async with self._pipe_lock:
            proc = await self._ensure_pipe_process()
            proc.stdin.write((prompt + "\n").encode("utf-8"))
            await proc.stdin.drain()

            async for chunk in self._read_jsonl_stream(proc):
                yield chunk

            await asyncio.sleep(0.1)
            if proc.returncode is not None:
                self._use_pipe_mode = False
                self._pipe_process = None
            else:
                self._use_pipe_mode = True

    # ------------------------------------------------------------------
    # Per-request mode (-p + --resume)
    # ------------------------------------------------------------------

    async def _find_gemini(self) -> str:
        """gemini 바이너리 경로를 찾는다."""
        candidates = [
            self.gemini_path,
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini",
            os.path.expanduser("~/.local/bin/gemini"),
            os.path.expanduser("~/.npm-global/bin/gemini"),
        ]
        for path in candidates:
            if os.path.isfile(path) and os.access(path, os.X_OK):
                return path
        try:
            shell = os.environ.get("SHELL", "/bin/zsh")
            proc = await asyncio.create_subprocess_exec(
                shell, "-li", "-c", "which gemini",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
            out, _ = await asyncio.wait_for(proc.communicate(), timeout=10)
            path = out.decode().strip()
            if path:
                return path
        except Exception:
            pass
        return "gemini"

    async def _run_gemini_p(self, prompt: str) -> tuple[str, str]:
        """gemini -p <prompt> 를 실행하고 (stdout, stderr) 를 반환한다.
        communicate()로 프로세스 종료 후 전체 출력을 읽는다."""
        gemini = await self._find_gemini()
        cmd = [gemini, "-p", prompt, "--output-format", "stream-json", "--yolo"]
        if self.session_id:
            cmd += ["--resume", self.session_id]

        logger.info(f"Gemini -p 모드 실행: {gemini} -p <prompt> --output-format stream-json --yolo"
                    + (f" --resume {self.session_id}" if self.session_id else ""))

        env = self._login_env or os.environ.copy()
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=self.cwd,
            env=env,
        )
        try:
            stdout_bytes, stderr_bytes = await asyncio.wait_for(
                proc.communicate(), timeout=120
            )
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            _emit("system", "❌ Gemini 응답 타임아웃 (120초)", level="error")
            return "", ""

        stderr_text = stderr_bytes.decode("utf-8", errors="replace") if stderr_bytes else ""
        stdout_text = stdout_bytes.decode("utf-8", errors="replace") if stdout_bytes else ""

        # stderr 라인별 로깅
        for line in stderr_text.splitlines():
            line = line.strip()
            if not line:
                continue
            logger.info(f"[gemini stderr] {line}")
            _KNOWN_NOISE = ("keytar", "keychain initialization", "cannot find module")
            if any(k in line.lower() for k in _KNOWN_NOISE):
                lvl = "debug"
            elif any(k in line.lower() for k in ("error", "no such", "not found", "fatal", "exception")):
                lvl = "error"
            else:
                lvl = "debug"
            _emit("system", f"⚠️ gemini: {line}", level=lvl)

        # stdout 원시 출력 (debug 레벨)
        for line in stdout_text.splitlines():
            line = line.strip()
            if line:
                _emit("system", f"[Gemini 원시] {line[:400]}", level="debug")

        return stdout_text, stderr_text

    async def _query_per_request(self, prompt: str) -> str:
        stdout_text, _ = await self._run_gemini_p(prompt)

        if not stdout_text.strip():
            _emit("system", "⚠️ Gemini stdout이 비어있습니다.", level="error")
            return ""

        full_text, session_id = self._parse_jsonl_text(stdout_text)
        if session_id:
            self.session_id = session_id
        return full_text

    async def _query_per_request_stream(self, prompt: str):
        stdout_text, _ = await self._run_gemini_p(prompt)

        if not stdout_text.strip():
            _emit("system", "⚠️ Gemini stdout이 비어있습니다.", level="error")
            return

        for chunk in self._parse_jsonl_text_stream(stdout_text):
            yield chunk

    def _parse_jsonl_text(self, stdout_text: str) -> tuple[str, Optional[str]]:
        """stdout 전체 텍스트를 파싱하여 (full_text, session_id)를 반환한다."""
        full_text = ""
        session_id = None
        lines = stdout_text.splitlines()
        unknown_events = []

        # 단일 JSON 객체 (JSONL이 아닌 경우)
        if stdout_text.strip().startswith("{") and "\n" not in stdout_text.strip():
            try:
                event = json.loads(stdout_text.strip())
                text = _extract_text_from_event(event)
                return text, event.get("session_id") or event.get("sessionId")
            except json.JSONDecodeError:
                pass

        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                full_text += line + "\n"
                continue

            etype = event.get("type", "")
            if etype == "init":
                session_id = event.get("session_id") or event.get("sessionId")
            elif etype in ("message", "content", "chunk", "text", "delta"):
                text = _extract_text_from_event(event)
                if text:
                    full_text += text
            elif _is_done_event(event):
                text = _extract_text_from_event(event)
                if text and not full_text:
                    full_text = text
                break
            elif etype in ("tool_call", "tool_use"):
                tool_name = event.get("name", event.get("tool", "unknown"))
                tool_input = event.get("input", event.get("arguments", {}))
                _emit("tool_use", f"{tool_name}({json.dumps(tool_input, ensure_ascii=False)})")
            elif etype == "error":
                err_msg = event.get("message", event.get("error", str(event)))
                _emit("system", f"❌ Gemini 오류: {err_msg}", level="error")
            else:
                text = _extract_text_from_event(event)
                if text:
                    full_text += text
                elif etype:
                    unknown_events.append(f"{etype}(keys={list(event.keys())})")

        if unknown_events:
            _emit("system", f"⚠️ 알 수 없는 이벤트: {', '.join(set(unknown_events))}", level="debug")

        if not full_text:
            # 파싱 실패 — 원시 출력 진단
            for raw in stdout_text.splitlines()[:3]:
                if raw.strip():
                    _emit("system", f"[Gemini 원시 출력] {raw.strip()[:300]}", level="debug")

        return full_text, session_id

    def _parse_jsonl_text_stream(self, stdout_text: str):
        """stdout 텍스트를 파싱하여 텍스트 청크를 생성한다."""
        full_text, session_id = self._parse_jsonl_text(stdout_text)
        if session_id:
            self.session_id = session_id
        if full_text:
            # 스트리밍 효과를 위해 청크 단위로 분할 (최대 100자)
            chunk_size = 100
            for i in range(0, len(full_text), chunk_size):
                yield full_text[i:i + chunk_size]

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
            async for chunk in self._query_gemini_stream(system_prompt, user_prompt):
                full_text += chunk
                data = {
                    "id": request_id,
                    "object": "chat.completion.chunk",
                    "choices": [{"delta": {"content": chunk, "role": "assistant"}, "index": 0}],
                }
                await response.write(f"data: {json.dumps(data, ensure_ascii=False)}\n\n".encode())
        except Exception as e:
            logger.error(f"스트리밍 오류: {e}")

        await response.write(b"data: [DONE]\n\n")
        _emit("assistant", full_text)
        _emit("assistant_done", "")
        return response

    async def _openai_sync(self, system_prompt, user_prompt, request_id) -> web.Response:
        full_text = await self._query_gemini(system_prompt, user_prompt)
        _emit("assistant", full_text)
        return web.json_response({
            "id": request_id,
            "object": "chat.completion",
            "created": int(time.time()),
            "model": "gemini-bridge",
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
            async for chunk in self._query_gemini_stream(system_prompt, user_prompt):
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
        full_text = await self._query_gemini(system_prompt, user_prompt)
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


def create_app(bridge: GeminiBridge) -> web.Application:
    app = web.Application()
    app.router.add_get("/health", bridge.handle_health)
    app.router.add_get("/v1/models", bridge.handle_models)
    app.router.add_post("/v1/chat/completions", bridge.handle_chat_completions)
    app.router.add_post("/v1/messages", bridge.handle_messages)
    return app


async def main() -> None:
    parser = argparse.ArgumentParser(description="Consolent Gemini Bridge Server")
    parser.add_argument("--port", type=int, default=8789)
    parser.add_argument("--cwd", default=".")
    parser.add_argument("--gemini-path", default="gemini")
    parser.add_argument("--api-key", default=None)
    parser.add_argument("--log-level", default="info",
                        choices=["error", "info", "debug"],
                        help="출력 레벨: error(오류만) | info(상태메시지) | debug(원시출력 포함)")
    args = parser.parse_args()
    _set_log_level(args.log_level)

    bridge = GeminiBridge(
        port=args.port,
        cwd=os.path.abspath(args.cwd),
        gemini_path=args.gemini_path,
        api_key=args.api_key,
    )
    await bridge.start()

    app = create_app(bridge)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", args.port)
    await site.start()

    logger.info(f"Gemini 브릿지 서버 시작: http://127.0.0.1:{args.port}")

    try:
        await asyncio.Event().wait()
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    finally:
        await bridge.stop()
        await runner.cleanup()


if __name__ == "__main__":
    asyncio.run(main())
