"""Run: python3 test_hook.py"""
import json, os, subprocess, sys, tempfile

d = tempfile.mkdtemp()
env = dict(os.environ, ATTENTION_ISLAND_DIR=d)


def fire(**event):
    event.setdefault("session_id", "s1")
    subprocess.run([sys.executable, "-S", "hook.py"], input=json.dumps(event), text=True, env=env, check=True)


def entry(session="s1"):
    p = os.path.join(d, f"{session}.json")
    return json.load(open(p)) if os.path.exists(p) else None


fire(hook_event_name="SessionStart"); assert entry() is None
fire(hook_event_name="UserPromptSubmit", prompt="fix the  login\nbug", cwd="/x/app")
e = entry(); assert (e["state"], e["prompt"], e["cwd"]) == ("running", "fix the login bug", "/x/app")
fire(hook_event_name="PreToolUse", tool_name="Bash"); assert entry()["since"] == e["since"] and entry()["seen"] >= e["seen"]
fire(hook_event_name="PermissionRequest", tool_name="Bash", tool_input={"command": "rm -rf build"})
assert entry()["state"] == "input" and entry()["detail"] == "Needs approval · Bash: rm -rf build"
fire(hook_event_name="PostToolUse", tool_name="Bash"); assert (entry()["state"], entry()["detail"]) == ("running", "")
fire(hook_event_name="PreToolUse", tool_name="AskUserQuestion", tool_input={"questions": [{"question": "Which DB?"}]})
assert entry()["detail"] == "Asking · Which DB?"
fire(hook_event_name="Notification", notification_type="idle_prompt"); assert entry()["state"] == "input"
fire(hook_event_name="Stop", last_assistant_message="All done."); e = entry()
assert (e["state"], e["detail"], e["failed"], e["prompt"]) == ("done", "All done.", False, "fix the login bug")

transcript = os.path.join(d, "t.jsonl")
with open(transcript, "w") as f:
    f.write(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "From transcript"}]}}) + "\n")
    f.write(json.dumps({"type": "user", "message": {"content": "hi"}}) + "\n")
fire(hook_event_name="Stop", transcript_path=transcript); assert entry()["detail"] == "From transcript"
assert entry()["title"] is None
with open(transcript, "a") as f:
    f.write(json.dumps({"type": "custom-title", "customTitle": "Old name", "sessionId": "s1"}) + "\n")
    f.write("{broken\n")
    f.write(json.dumps({"type": "custom-title", "customTitle": "Fix login bug", "sessionId": "s1"}) + "\n")
fire(hook_event_name="PreToolUse", tool_name="Bash", transcript_path=transcript); assert entry()["title"] == "Fix login bug"
fire(hook_event_name="PreToolUse", tool_name="Bash"); assert entry()["title"] == "Fix login bug"
fire(hook_event_name="StopFailure", last_assistant_message="API error"); assert entry()["failed"] is True
fire(hook_event_name="SessionEnd"); assert entry() is None

fire(hook_event_name="UserPromptSubmit", session_id="../evil"); assert os.listdir(d) == ["t.jsonl"]
subprocess.run([sys.executable, "-S", "hook.py"], input="not json", text=True, env=env, check=True)
print("hook ok")
