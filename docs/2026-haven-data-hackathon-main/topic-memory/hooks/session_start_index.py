"""Claude Code SessionStart hook: load a topic-memory index into the session, like MEMORY.md.

    settings.json: {"hooks": {"SessionStart": [{"hooks": [{"type": "command", "timeout": 30,
        "command": "[SF_ROLE=<role>] <python> topic-memory/hooks/session_start_index.py <mcp_url> <index_tool> [agent_type] [server]"}]}]}}

Calls the topic's index tool over MCP (SSO token via invocation-poc/sf_mcp_auth.py) and prints it as
additionalContext. Any failure prints nothing and exits 0, so a Snowflake problem never blocks a session.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def main() -> None:
    url, tool = sys.argv[1], sys.argv[2]
    agent_type = sys.argv[3] if len(sys.argv) > 3 else "claude_code"
    ref = f"`mcp__{sys.argv[4]}__{tool}`" if len(sys.argv) > 4 else f"`{tool}`"
    try:
        from mcp_http import McpClient
        text, is_error, _ = McpClient(url, timeout=25).call(tool, {"agent_type": agent_type})
    except Exception:
        return
    if is_error or not text.strip():
        return
    note = (f"\n\n(Loaded at session start by the topic-memory hook from MCP tool {ref}. Use the same server's "
            "search / get / record tools during the session.)")
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": text + note}}))


if __name__ == "__main__":
    main()
