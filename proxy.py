#!/usr/bin/env python3
"""Socket-activated API proxy with model-specific reasoning translation."""
import asyncio
import json
import os

from aiohttp import ClientSession, ClientTimeout, web

HOP_HEADERS = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailer", "transfer-encoding", "upgrade",
}


def headers_without_hop(headers):
    excluded = HOP_HEADERS | {
        token.strip().lower() for token in headers.get("Connection", "").split(",")
    }
    return [(k, v) for k, v in headers.items() if k.lower() not in excluded]


def translate(body):
    # With tool use disabled, omit definitions from the model prompt too.
    if body.get("tool_choice") == "none":
        body.pop("tools", None)
    if os.environ.get("MODEL_FAMILY", "kimi") == "glm":
        reasoning = body.get("reasoning")
        if isinstance(reasoning, dict):
            if reasoning.get("enabled") is False:
                raise ValueError("GLM-5.3 always uses reasoning. Use reasoning.effort=low, high, or max instead of reasoning.enabled=false.")
            effort = reasoning.get("effort")
            if effort is not None:
                if effort not in {"low", "high", "max"}:
                    raise ValueError("GLM-5.3 reasoning effort must be low, high, or max.")
                body["chat_template_kwargs"] = {
                    **(body.get("chat_template_kwargs") or {}), "reasoning_effort": effort,
                }
        return body
    # K3 may generate raw tool-channel output if tool definitions remain in
    # the prompt while vLLM's tool parser is disabled by tool_choice=none.
    if body.get("tool_choice") == "none":
        body.pop("tools", None)
    reasoning = body.get("reasoning")
    if isinstance(reasoning, dict) and reasoning.get("enabled") is False:
        kwargs = body.get("chat_template_kwargs")
        if kwargs is None:
            kwargs = {}
        if not isinstance(kwargs, dict):
            raise ValueError("chat_template_kwargs must be an object")
        body["chat_template_kwargs"] = {**kwargs, "thinking": False}
        # Keep both aliases consistent when a caller supplies enable_thinking.
        if "enable_thinking" in kwargs:
            body["chat_template_kwargs"]["enable_thinking"] = False
    return body


async def forward(request):
    data = await request.read()
    headers = headers_without_hop(request.headers)
    if request.method == "POST" and request.path == "/v1/chat/completions":
        try:
            body = json.loads(data)
            if isinstance(body, dict):
                data = json.dumps(translate(body), ensure_ascii=False).encode()
                headers = [(k, v) for k, v in headers if k.lower() != "content-length"]
        except (ValueError, UnicodeDecodeError) as error:
            return web.json_response({"error": {"message": str(error)}}, status=400)
    try:
        async with request.app["client"].request(
            request.method, request.app["upstream"] + request.raw_path,
            data=data, headers=headers, allow_redirects=False,
        ) as upstream:
            response = web.StreamResponse(
                status=upstream.status, reason=upstream.reason,
                headers=headers_without_hop(upstream.headers),
            )
            await response.prepare(request)
            async for chunk in upstream.content.iter_any():
                await response.write(chunk)
            await response.write_eof()
            return response
    except (ConnectionError, asyncio.CancelledError):
        raise
    except Exception:
        if "response" in locals() and response.prepared:
            raise
        return web.json_response({"error": {"message": "vLLM upstream unavailable"}}, status=502)


async def client_context(app):
    async with ClientSession(
        timeout=ClientTimeout(total=None, sock_connect=10), auto_decompress=False,
    ) as client:
        app["client"] = client
        yield


def main():
    app = web.Application(client_max_size=64 * 1024 * 1024)
    app["upstream"] = os.environ.get("UPSTREAM_URL", "http://vllm:8000").rstrip("/")
    app.cleanup_ctx.append(client_context)
    app.router.add_route("*", "/{path:.*}", forward)
    web.run_app(app, host="0.0.0.0", port=8000, access_log=None)


if __name__ == "__main__":
    main()
