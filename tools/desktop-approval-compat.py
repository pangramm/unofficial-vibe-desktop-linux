"""Serve Desktop 1.3.0's approval RPCs with mistral-vibe 3.1.3's agent profiles."""

from dataclasses import replace
import sys

from pydantic import RootModel

from vibe.app_server import server, stdio
from vibe.app_server._dispatch import RequestFailure
from vibe.app_server.protocol import AgentsListResponse, ProtocolErrorCode, RuntimeSnapshot


SESSION_OPEN = {"session/start", "session/resume", "session/continue", "session/fork"}
POLICY_FIELDS = {"name", "displayName", "description", "safety"}


def policy_summary(agent):
    return {key: value for key, value in agent.items() if key in POLICY_FIELDS}


def project_policies(catalogue, active_key):
    catalogue["activeApprovalPolicy"] = policy_summary(catalogue[active_key])
    catalogue["approvalPolicies"] = [policy_summary(agent) for agent in catalogue["agents"]]


def session_params(params):
    config = params.get("agentConfig")
    if not isinstance(config, dict) or "approvalPolicy" not in config:
        return params
    config = config.copy()
    policy = config.pop("approvalPolicy")
    if not isinstance(policy, str) or not policy:
        raise RequestFailure(ProtocolErrorCode.INVALID_PARAMS, "approvalPolicy must be a nonempty string")
    if config.get("agent") not in (None, policy):
        raise RequestFailure(
            ProtocolErrorCode.INVALID_PARAMS,
            "This backend cannot select a separate agent and approval policy",
        )
    return {**params, "agentConfig": {**config, "agent": policy}}


class DesktopAppServer(server.AppServer):
    async def _dispatch_request(self, method, raw_params):
        if method in SESSION_OPEN:
            raw_params = session_params(raw_params)
        if method == "session/approvalPolicy/update":
            if "approvalPolicy" not in raw_params or "agentName" in raw_params:
                raise RequestFailure(ProtocolErrorCode.INVALID_PARAMS, "Expected approvalPolicy")
            raw_params = raw_params.copy()
            raw_params["agentName"] = raw_params.pop("approvalPolicy")
            result = await super()._dispatch_request("session/agent/update", raw_params)
        else:
            result = await super()._dispatch_request(method, raw_params)

        if method not in SESSION_OPEN | {
            "agents/list", "runtime/read", "session/approvalPolicy/update", "session/read",
        }:
            return result
        response = result.response.model_dump(mode="json", by_alias=True)
        if method == "agents/list":
            project_policies(response, "active")
        elif method in {"runtime/read", "session/approvalPolicy/update"}:
            project_policies(response["runtime"], "activeAgent")
        else:
            session = response["state"]["session"]
            if session.get("agent") is not None:
                session["approvalPolicy"] = policy_summary(session["agent"])
        return replace(result, response=RootModel(response))


def main():
    # A wheel built from the Desktop source may already implement the contract.
    if all(
        "active_approval_policy" not in model.model_fields
        and "approval_policies" not in model.model_fields
        for model in (AgentsListResponse, RuntimeSnapshot)
    ):
        server.AppServer = DesktopAppServer
    sys.argv[0] = "vibe-app-server"
    return stdio.main()


if __name__ == "__main__":
    sys.exit(main())
