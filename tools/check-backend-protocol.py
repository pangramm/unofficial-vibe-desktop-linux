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


async def send(server, channel, **message):
    frame = {"channelId": channel, "message": {"jsonrpc": "2.0", **message}}
    server.stdin.write((json.dumps(frame) + "\n").encode())
    await server.stdin.drain()


async def request(server, channel, method, params=None, *, expected_error=None):
    try:
        async with asyncio.timeout(30):
            await send(server, channel, id=method, method=method, params=params or {})
            while line := await server.stdout.readline():
                frame = json.loads(line)
                if frame["channelId"] != channel:
                    continue
                response = frame["message"]
                if response is None:
                    raise RuntimeError(f"{method}: app server closed channel ({frame.get('error')})")
                if response.get("id") != method:
                    continue
                if error := response.get("error"):
                    if error.get("code") == expected_error:
                        return None
                    raise RuntimeError(f"{method} returned {error}")
                if expected_error is not None:
                    raise RuntimeError(f"{method} accepted an unavailable approval policy")
                return response["result"]
            raise RuntimeError(f"{method}: app server closed stdout")
    except TimeoutError as exc:
        raise RuntimeError(f"{method}: app server timed out") from exc


async def initialize(server, channel):
    await request(server, channel, "initialize", {
        "clientInfo": {
            "name": "desktop-build-check", "version": "1.0.0",
            "terminalEmulator": "unknown",
        },
    })
    await send(server, channel, method="initialized", params={})


def check_active_policy(runtime, policy, errors, method):
    errors.extend(validate(
        runtime, {"runtime": {"activeAgent": AGENT, **CATALOGUE}}, method
    ))
    if not errors and runtime["runtime"]["activeApprovalPolicy"]["name"] != policy:
        errors.append(f"{method}: expected the active approval policy to be {policy}")


async def check(command, directory, errors):
    # A loopback model lets session/start run without credentials or a model server.
    # The probe never starts a turn.
    vibe_home = Path(directory) / ".vibe"
    vibe_home.mkdir(mode=0o700)
    (vibe_home / "config.toml").write_text(
        """active_model = "contract-probe"
enable_auto_approve = false

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
        *command, "--multiplex", cwd=directory, env=env,
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        limit=4 * 1024 * 1024,
    )
    try:
        await initialize(server, "1")
        agents = await request(server, "1", "agents/list")
        errors.extend(validate(agents, {"active": AGENT, **CATALOGUE}, "agents/list"))
        agent_config = {"cwd": directory, "trustWorkspace": True}
        if not errors:
            active_policy = agents["activeApprovalPolicy"]["name"]
            policies = {policy["name"] for policy in agents["approvalPolicies"]}
            if "auto-approve" in policies:
                errors.append("agents/list advertised auto-approve despite the config disabling it")
            selected_policy = min(policies - {active_policy}, default=active_policy)
            agent_config["approvalPolicy"] = selected_policy

        await initialize(server, "2")
        session = await request(server, "2", "session/start", {
            "agentConfig": agent_config,
            "kind": "ephemeral",
        })
        session_id = session["state"]["session"]["id"]
        params = {"sessionId": session_id}
        runtime = await request(server, "2", "runtime/read", params)
        check_active_policy(runtime, agent_config.get("approvalPolicy"), errors, "runtime/read")
        if errors:
            return

        update = "session/approvalPolicy/update"
        runtime = await request(server, "2", update, {**params, "approvalPolicy": active_policy})
        check_active_policy(runtime, active_policy, errors, update)
        await request(server, "2", update, {**params, "approvalPolicy": "auto-approve"},
                      expected_error="invalid_params")
        runtime = await request(server, "2", "runtime/read", params)
        check_active_policy(runtime, active_policy, errors, "runtime/read after rejected update")
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
    print("Desktop app-server contract passed for policy listing, session start, runtime read and policy changes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
