#!/usr/bin/env python3
"""Register (or remove) the agent-status hook in Claude Code's and Codex's
hook config. Idempotent: our entries are stripped and re-added, everything
else in the files is preserved. A one-time backup (<file>.bak) is kept.

usage: register.py install|remove /path/to/agent-status
"""
import json
import os
import sys

CONFIGS = {
    "claude": (os.path.expanduser("~/.claude/settings.json"), [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PreCompact", "PermissionRequest", "Notification", "Stop",
        "StopFailure", "SessionEnd",
    ]),
    "codex": (os.path.expanduser("~/.codex/hooks.json"), [
        "SessionStart", "UserPromptSubmit", "PostToolUse", "PermissionRequest",
        "Stop", "Interrupt", "SessionEnd",
    ]),
}
OURS = ("agent-monitor/agent-status", "/.codex/hooks/codex-status")


def is_ours(entry):
    cmd = entry.get("command", "") if isinstance(entry, dict) else ""
    return any(marker in cmd for marker in OURS)


def strip(hooks):
    for event in list(hooks):
        groups = []
        for group in hooks[event]:
            if not isinstance(group, dict):
                groups.append(group)
                continue
            group["hooks"] = [h for h in group.get("hooks", []) if not is_ours(h)]
            if group["hooks"]:
                groups.append(group)
        if groups:
            hooks[event] = groups
        else:
            del hooks[event]


def main():
    action, hook = sys.argv[1], sys.argv[2]
    for agent, (path, events) in CONFIGS.items():
        data = {}
        if os.path.exists(path):
            with open(path) as f:
                data = json.load(f)
            if not os.path.exists(path + ".bak"):
                with open(path + ".bak", "w") as f:
                    json.dump(data, f, indent=2)
        hooks = data.setdefault("hooks", {})
        strip(hooks)
        if action == "install":
            entry = {"type": "command", "command": "%s %s" % (hook, agent), "timeout": 10}
            for event in events:
                hooks.setdefault(event, []).append({"hooks": [entry]})
        if not hooks:
            del data["hooks"]
        if action == "remove" and not data:
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        print("    %s: %s" % ("registered in" if action == "install" else "removed from", path))


if __name__ == "__main__":
    main()
