"""Adds the island hook to ~/.claude/settings.json. Safe to rerun; leaves other hooks alone."""
import json, os, shutil

COMMAND = "python3 -S ~/.attention-island/hook.py"
EVENTS = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
          "PermissionDenied", "Notification", "Elicitation", "ElicitationResult", "Stop", "StopFailure", "SessionEnd"]

path = os.path.expanduser("~/.claude/settings.json")
settings = json.load(open(path))
hooks = settings.setdefault("hooks", {})
added = [e for e in EVENTS
         if not any(h.get("command") == COMMAND for g in hooks.get(e, []) for h in g.get("hooks", []))]
if added:
    shutil.copy(path, path + ".bak-attention-island")
    for e in added:
        hooks.setdefault(e, []).append({"hooks": [{"type": "command", "command": COMMAND, "timeout": 5}]})
    with open(path, "w") as f:
        f.write(json.dumps(settings, indent=2, ensure_ascii=False) + "\n")
print(f"claude hooks: added {len(added)}, already present {len(EVENTS) - len(added)}")
