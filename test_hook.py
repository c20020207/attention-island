"""Run: python3 test_hook.py"""
import json, os, subprocess, sys, tempfile

d = tempfile.mkdtemp()
env = dict(os.environ, ATTENTION_ISLAND_DIR=d)


def fire(**event):
    event.setdefault("session_id", "s1")
    subprocess.run([sys.executable, "-S", "hook.py"], input=json.dumps(event), text=True, env=env, check=True)


def state(session="s1"):
    p = os.path.join(d, f"{session}.json")
    return json.load(open(p))["state"] if os.path.exists(p) else None


fire(hook_event_name="SessionStart"); assert state() is None
fire(hook_event_name="UserPromptSubmit"); assert state() == "running"
fire(hook_event_name="PermissionRequest", tool_name="Bash"); assert state() == "input"
fire(hook_event_name="PostToolUse", tool_name="Bash"); assert state() == "running"
fire(hook_event_name="PreToolUse", tool_name="AskUserQuestion"); assert state() == "input"
fire(hook_event_name="PostToolUse", tool_name="AskUserQuestion"); assert state() == "running"
fire(hook_event_name="Notification", notification_type="idle_prompt"); assert state() == "running"
fire(hook_event_name="Notification", notification_type="permission_prompt"); assert state() == "input"
fire(hook_event_name="Stop"); assert state() is None
fire(hook_event_name="UserPromptSubmit", session_id="../evil"); assert os.listdir(d) == []
subprocess.run([sys.executable, "-S", "hook.py"], input="not json", text=True, env=env, check=True)
print("hook ok")
