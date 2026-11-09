#!/usr/bin/env python3 -S
"""Claude Code hook: record whether a session is running or waiting on me.

Hook JSON on stdin. Writes ~/.attention-island/sessions/<session>.json, deletes it when the turn ends.
"""
import json, os, sys, time

ROOT = os.environ.get("ATTENTION_ISLAND_DIR") or os.path.expanduser("~/.attention-island/sessions")
INPUT_NOTIFICATIONS = {"permission_prompt", "elicitation_dialog"}
DONE = {"Stop", "StopFailure", "SessionEnd"}


def state_for(event):
    name = event.get("hook_event_name")
    if name in DONE:
        return None
    if name in ("PermissionRequest", "Elicitation"):
        return "input"
    if name == "PreToolUse" and event.get("tool_name") == "AskUserQuestion":
        return "input"
    if name == "Notification":
        return "input" if event.get("notification_type") in INPUT_NOTIFICATIONS else "skip"
    if name in ("UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                "PermissionDenied", "ElicitationResult"):
        return "running"
    return "skip"  # SessionStart, Subagent*, compaction: no change


def main():
    event = json.load(sys.stdin)
    session = str(event.get("session_id") or "")
    if not session or "/" in session:
        return
    state = state_for(event)
    if state == "skip":
        return
    path = os.path.join(ROOT, f"{session}.json")
    if state is None:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
        return
    os.makedirs(ROOT, exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        json.dump({"state": state, "cwd": event.get("cwd"), "at": time.time()}, f)
    os.replace(tmp, path)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # never block the agent
