#!/usr/bin/env python3 -S
"""Claude Code hook: record what each session is doing and whether it is waiting on me.

Hook JSON on stdin. Writes ~/.attention-island/sessions/<session>.json; SessionEnd deletes it.
States: running, input (blocked on an approval or a question), done (turn ended, my move).
"""
import json, os, sys, time

ROOT = os.environ.get("ATTENTION_ISLAND_DIR") or os.path.expanduser("~/.attention-island/sessions")
INPUT_NOTIFICATIONS = {"permission_prompt", "elicitation_dialog"}
RUNNING = {"UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionDenied", "ElicitationResult"}


def clip(text, limit=300):
    text = " ".join(str(text or "").split())
    return text[:limit - 1] + "…" if len(text) > limit else text


def tool_summary(event):
    tool, args = event.get("tool_name") or "tool", event.get("tool_input") or {}
    target = next((args[k] for k in ("command", "file_path", "url", "pattern", "description") if args.get(k)), "")
    return clip(f"{tool}: {target}" if target else tool)


def transcript_tail(event):
    """Newest-first entries from the last 256 KB of the transcript."""
    path = event.get("transcript_path")
    try:
        with open(path, "rb") as f:
            f.seek(max(0, os.path.getsize(path) - 256 * 1024))
            lines = f.read().decode("utf-8", "ignore").splitlines()
    except (OSError, TypeError):
        return
    for line in reversed(lines):
        try:
            yield json.loads(line)
        except ValueError:
            pass


def title(event):
    """The conversation title Claude shows in its sidebar; re-logged every turn."""
    return next((clip(e["customTitle"], 120) for e in transcript_tail(event)
                 if e.get("type") == "custom-title" and e.get("customTitle")), None)


def last_reply(event):
    if event.get("last_assistant_message"):
        return clip(event["last_assistant_message"])
    for entry in transcript_tail(event):  # older payloads lack the field
        if entry.get("type") == "assistant":
            texts = [c.get("text") for c in entry.get("message", {}).get("content", []) if c.get("type") == "text"]
            if texts:
                return clip(texts[-1])
    return ""


def update(event, entry):
    """Returns the new entry, None to delete it, or the old one unchanged."""
    name = event.get("hook_event_name")
    if name == "SessionEnd":
        return None
    if name in ("Stop", "StopFailure"):
        return {**entry, "state": "done", "detail": last_reply(event), "failed": name == "StopFailure"}
    if name == "PermissionRequest":
        return {**entry, "state": "input", "detail": "Needs approval · " + tool_summary(event)}
    if name == "PreToolUse" and event.get("tool_name") == "AskUserQuestion":
        questions = (event.get("tool_input") or {}).get("questions") or [{}]
        return {**entry, "state": "input", "detail": "Asking · " + clip(questions[0].get("question"))}
    if name == "Elicitation":
        return {**entry, "state": "input", "detail": "Asking · " + clip(event.get("message"))}
    if name == "Notification" and event.get("notification_type") in INPUT_NOTIFICATIONS:
        return {**entry, "state": "input", "detail": clip(event.get("message"))}
    if name == "UserPromptSubmit":
        return {**entry, "state": "running", "prompt": clip(event.get("prompt"), 200), "detail": ""}
    if name in RUNNING and entry.get("state") != "running":
        return {**entry, "state": "running", "detail": ""}
    return entry


def main():
    event = json.load(sys.stdin)
    session = str(event.get("session_id") or "")
    if not session or "/" in session:
        return
    path = os.path.join(ROOT, f"{session}.json")
    try:
        with open(path) as f:
            old = json.load(f)
    except (OSError, ValueError):
        old = {}
    new = update(event, dict(old, cwd=event.get("cwd") or old.get("cwd")))
    if new and (not new.get("title") or event.get("hook_event_name") in ("UserPromptSubmit", "Stop")):
        new["title"] = title(event) or new.get("title")
    if new is None:
        if old:
            os.remove(path)
        return
    if new.get("state") is None:
        return  # SessionStart and friends before any prompt: nothing to show yet
    now = time.time()
    changed = (new.get("state"), new.get("detail")) != (old.get("state"), old.get("detail"))
    new["since"] = now if changed else old.get("since", now)  # when the current state began
    new["seen"] = now  # last sign of life, for ageing out dead sessions
    os.makedirs(ROOT, exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        json.dump(new, f)
    os.replace(tmp, path)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # never block the agent
