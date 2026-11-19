#!/usr/bin/env python3
"""Check the Code RPC responses required by the Desktop 1.3.0 frontend."""

import asyncio
import json
import os
from pathlib import Path
import sys
from tempfile import TemporaryDirectory


AGENT = {"name": str, "displayName": str, "description": str, "agentType": str}
APPROVAL_POLICY = {"name": str, "displayName": str, "description": str, "safety": str}
CATALOGUE = {
    "agents": [AGENT],
    "activeApprovalPolicy": APPROVAL_POLICY,
    "approvalPolicies": [APPROVAL_POLICY],
}


def validate(value, schema, path):
    if isinstance(schema, dict) and isinstance(value, dict):
        for key, field in schema.items():
            if key not in value:
                yield f"{path}.{key} is missing"
            else:
                yield from validate(value[key], field, f"{path}.{key}")
    elif isinstance(schema, list) and isinstance(value, list):
        for index, item in enumerate(value):
            yield from validate(item, schema[0], f"{path}[{index}]")
    elif isinstance(schema, (dict, list)) or not isinstance(value, schema):
        expected = type(schema) if isinstance(schema, (dict, list)) else schema
        yield f"{path} must be {expected.__name__}"


async def send(server, **message):
    server.stdin.write((json.dumps({"jsonrpc": "2.0", **message}) + "\n").encode())
    await server.stdin.drain()


async def request(server, method, params=None):
    # Each method is called once, so the method name is also a unique request ID.
    try:
        async with asyncio.timeout(30):
            await send(server, id=method, method=method, params=params or {})
            while line := await server.stdout.readline():
                response = json.loads(line)
                if response.get("id") != method:
                    continue
                if "error" in response:
                    raise RuntimeError(f"{method} returned {response['error']}")
                return response["result"]
            raise RuntimeError(f"{method}: app server closed stdout")
    except TimeoutError as exc:
        raise RuntimeError(f"{method}: app server timed out") from exc


async def check(command, directory, errors):
    # A loopback model lets session/start run without credentials or a model server.
    # The probe never starts a turn.
    vibe_home = Path(directory) / ".vibe"
    vibe_home.mkdir(mode=0o700)
    (vibe_home / "config.toml").write_text(
        """active_model = "contract-probe"

[[providers]]
name = "contract-probe"
api_base = "http://127.0.0.1:1/v1"

[[models]]
name = "contract-probe"
alias = "contract-probe"
provider = "contract-probe"
""",
        encoding="utf-8",
    )
    env = {"PATH": os.defpath, "HOME": directory, "VIBE_HOME": str(vibe_home)}
    server = await asyncio.create_subprocess_exec(
        *command, cwd=directory, env=env,
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        limit=4 * 1024 * 1024,
    )
    try:
        await request(server, "initialize", {
            "clientInfo": {
                "name": "desktop-build-check", "version": "1.0.0",
                "terminalEmulator": "unknown",
            },
        })
        await send(server, method="initialized", params={})
        agents = await request(server, "agents/list")
        errors.extend(validate(agents, {"active": AGENT, **CATALOGUE}, "agents/list"))

        session = await request(server, "session/start", {
            "agentConfig": {"cwd": directory, "trustWorkspace": True},
            "kind": "ephemeral",
        })
        session_id = session["state"]["session"]["id"]
        runtime = await request(server, "runtime/read", {"sessionId": session_id})
        errors.extend(validate(
            runtime, {"runtime": {"activeAgent": AGENT, **CATALOGUE}}, "runtime/read"
        ))
    finally:
        if server.returncode is None:
            try:
                server.kill()
            except ProcessLookupError:
                pass
        await server.communicate()


def main():
    errors = []
    try:
        with TemporaryDirectory(prefix="vibe-backend-check-") as directory:
            command = [str(Path(sys.argv[1]).resolve()), *sys.argv[2:]]
            asyncio.run(check(command, directory, errors))
    except (OSError, RuntimeError, ValueError, KeyError, TypeError) as exc:
        errors.append(str(exc))
    if errors:
        print("Desktop app-server contract check failed:", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        return 1
    print("Desktop app-server contract passed for agents/list and runtime/read.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
