#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


from importlib.machinery import SourceFileLoader

PLUGIN = Path(__file__).resolve().parents[1]
RESUME = PLUGIN / "bin" / "resume"
R = SourceFileLoader("omarchy_resume", str(RESUME)).load_module()


class ProjectResolveTest(unittest.TestCase):
    def test_plain_path_uses_folder(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "scratch"
            path.mkdir()
            key, label = R.resolve_project(str(path))
            self.assertEqual(key, str(path.resolve()))
            self.assertEqual(label, str(path))

    def test_git_worktree_collapses_to_main_repo(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            main = Path(raw) / "berserk"
            work = Path(raw) / "worktrees" / "feat-x"
            main.mkdir()
            work.mkdir(parents=True)
            subprocess.run(["git", "init"], cwd=main, check=True, capture_output=True)
            (main / "README").write_text("x\n", encoding="utf-8")
            subprocess.run(["git", "add", "README"], cwd=main, check=True, capture_output=True)
            subprocess.run(
                ["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "init"],
                cwd=main,
                check=True,
                capture_output=True,
            )
            subprocess.run(["git", "worktree", "add", "--detach", str(work)], cwd=main, check=True, capture_output=True)
            R._project_cache.clear()
            main_key, main_label = R.resolve_project(str(main))
            work_key, work_label = R.resolve_project(str(work))
            self.assertEqual(main_key, work_key)
            self.assertEqual(main_label, "berserk")
            self.assertEqual(work_label, "berserk")

    def test_vanished_herdr_worktree_uses_sibling(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            main = Path(raw) / "code" / "berserk"
            alive = Path(raw) / "worktrees" / "berserk" / "alive"
            gone = Path(raw) / "worktrees" / "berserk" / "gone"
            main.mkdir(parents=True)
            (main / ".git").mkdir()
            alive.mkdir(parents=True)
            (alive / ".git").write_text(f"gitdir: {main / '.git' / 'worktrees' / 'alive'}\n", encoding="utf-8")
            (main / ".git" / "worktrees" / "alive").mkdir(parents=True)
            R._project_cache.clear()
            gone_key, gone_label = R.resolve_project(str(gone))
            self.assertEqual(gone_key, str(main.resolve()))
            self.assertEqual(gone_label, "berserk")

    def test_jj_workspace_collapses_to_default(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            main = Path(raw) / "ivory-tower"
            extra = Path(raw) / "ivory-tower-map"
            main_jj = main / ".jj"
            extra_jj = extra / ".jj"
            (main_jj / "repo").mkdir(parents=True)
            extra_jj.mkdir(parents=True)
            (extra_jj / "repo").write_text("../../ivory-tower/.jj/repo\n", encoding="utf-8")
            R._project_cache.clear()
            main_key, main_label = R.resolve_project(str(main))
            extra_key, extra_label = R.resolve_project(str(extra))
            self.assertEqual(main_key, extra_key)
            self.assertEqual(main_label, "ivory-tower")
            self.assertEqual(extra_label, "ivory-tower")


class PrivateFileTest(unittest.TestCase):
    def test_write_private_text_is_owner_only(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "secret.md"
            old = os.umask(0o022)
            try:
                R.write_private_text(path, "private transcript")
            finally:
                os.umask(old)
            mode = path.stat().st_mode
            self.assertEqual(stat.S_IMODE(mode), 0o600)
            self.assertEqual(path.read_text(encoding="utf-8"), "private transcript\n")

    def test_prune_handoffs_removes_stale_files(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            fresh = directory / "fresh.md"
            stale = directory / "stale.md"
            fresh.write_text("new\n", encoding="utf-8")
            stale.write_text("old\n", encoding="utf-8")
            old = time.time() - R.HANDOFF_TTL_SECONDS - 10
            os.utime(stale, (old, old))
            R.prune_handoffs(directory)
            self.assertTrue(fresh.is_file())
            self.assertFalse(stale.exists())


class SessionIndexTest(unittest.TestCase):
    def tearDown(self) -> None:
        os.environ.pop("OMARCHY_RESUME_INDEX", None)
        os.environ.pop("CLAUDE_CONFIG_DIR", None)
        os.environ.pop("GROK_HOME", None)
        R.reset_index()

    def test_unchanged_file_is_not_reread(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            os.environ["OMARCHY_RESUME_INDEX"] = str(root / "index.json")
            os.environ["CLAUDE_CONFIG_DIR"] = str(root / "claude")
            R.reset_index()
            project = root / "claude" / "projects" / "-tmp-demo"
            project.mkdir(parents=True)
            path = project / "cached.jsonl"
            original = json.dumps({"type": "user", "sessionId": "cached", "cwd": "/tmp/demo", "message": {"role": "user", "content": "first title"}}) + "\n"
            path.write_text(original, encoding="utf-8")
            adapter = R.ClaudeAdapter()
            first = adapter.list_sessions(10)
            self.assertEqual(first[0]["title"], "first title")
            R.session_index().save()
            st = path.stat()
            path.write_bytes(b"x" * len(original.encode()))
            os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns))
            R.reset_index()
            second = R.ClaudeAdapter().list_sessions(10)
            self.assertEqual(second[0]["title"], "first title")

    def test_legacy_entry_without_sig_is_a_miss(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "session.jsonl"
            path.write_text("x\n", encoding="utf-8")
            index = R.SessionIndex(Path(raw) / "index.json")
            index.entries[str(path)] = {
                "mtimeNs": path.stat().st_mtime_ns,
                "size": path.stat().st_size,
                "source": "claude",
                "sessions": [{"id": "stale"}],
            }
            sig = R.cache_signature([path])
            self.assertIsNone(index.get(path, sig))

    def test_grok_sidecar_change_invalidates_and_updates_timestamp(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            os.environ["OMARCHY_RESUME_INDEX"] = str(root / "index.json")
            os.environ["GROK_HOME"] = str(root)
            R.reset_index()
            session = root / "sessions" / "%2Ftmp" / "abc-123"
            session.mkdir(parents=True)
            summary = session / "summary.json"
            summary.write_text(
                json.dumps(
                    {
                        "info": {"id": "abc-123", "cwd": "/tmp"},
                        "generated_title": "Old title",
                        "updated_at": "2026-08-01T00:00:00Z",
                        "last_active_at": "2026-08-01T00:00:00Z",
                    }
                ),
                encoding="utf-8",
            )
            first = R.GrokAdapter().list_sessions(10)
            self.assertEqual(first[0]["title"], "Old title")
            first_ms = first[0]["updatedAtMs"]
            R.session_index().save()
            time.sleep(0.02)
            (session / "chat_history.jsonl").write_text('{"type":"user","content":"later"}\n', encoding="utf-8")
            R.reset_index()
            second = R.GrokAdapter().list_sessions(10)
            self.assertGreater(second[0]["updatedAtMs"], first_ms)

    def test_refresh_rereads_same_mtime(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            os.environ["OMARCHY_RESUME_INDEX"] = str(root / "index.json")
            os.environ["CLAUDE_CONFIG_DIR"] = str(root / "claude")
            R.reset_index()
            project = root / "claude" / "projects" / "-tmp-demo"
            project.mkdir(parents=True)
            path = project / "cached.jsonl"
            original = json.dumps({"type": "user", "sessionId": "cached", "cwd": "/tmp/demo", "message": {"role": "user", "content": "first title"}}) + "\n"
            path.write_text(original, encoding="utf-8")
            adapter = R.ClaudeAdapter()
            adapter.list_sessions(10)
            R.session_index().save()
            st = path.stat()
            path.write_text(
                json.dumps({"type": "user", "sessionId": "cached", "cwd": "/tmp/demo", "message": {"role": "user", "content": "other title"}}) + "\n",
                encoding="utf-8",
            )
            os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns))
            R.reset_index()
            cached = R.ClaudeAdapter().list_sessions(10)
            self.assertEqual(cached[0]["title"], "first title")
            refreshed = R.ClaudeAdapter().list_sessions(10, force=True)
            self.assertEqual(refreshed[0]["title"], "other title")


class HelpersTest(unittest.TestCase):
    def test_extract_text_from_blocks(self) -> None:
        text = R.extract_text([{"type": "input_text", "text": "hello"}, {"type": "text", "text": "world"}])
        self.assertIn("hello", text)
        self.assertIn("world", text)

    def test_filter_requires_every_needle(self) -> None:
        sessions = [
            {"title": "Fix lock screen", "snippet": "", "project": "omarchy", "cwd": "/x", "source": "grok", "model": "", "id": "1", "updatedAtMs": 2},
            {"title": "Rewrite the bar", "snippet": "", "project": "omarchy", "cwd": "/x", "source": "claude", "model": "", "id": "2", "updatedAtMs": 1},
        ]
        found = R.filter_sessions(sessions, "lock grok", "")
        self.assertEqual([item["id"] for item in found], ["1"])


class ClaudeAdapterTest(unittest.TestCase):
    def test_lists_first_user_prompt(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            project = root / "projects" / "-home-thomas-code-demo"
            project.mkdir(parents=True)
            path = project / "sess-1.jsonl"
            path.write_text(
                json.dumps({"type": "user", "sessionId": "sess-1", "cwd": "/home/thomas/code/demo", "message": {"role": "user", "content": "fix the idle flicker"}})
                + "\n"
                + json.dumps({"type": "assistant", "message": {"role": "assistant", "content": "Looking.", "model": "claude-opus"}})
                + "\n",
                encoding="utf-8",
            )
            adapter = R.ClaudeAdapter()
            adapter.root = lambda: root  # type: ignore[method-assign]
            sessions = adapter.list_sessions(10)
            self.assertEqual(len(sessions), 1)
            self.assertEqual(sessions[0]["id"], "sess-1")
            self.assertEqual(sessions[0]["title"], "fix the idle flicker")
            self.assertEqual(sessions[0]["cwd"], "/home/thomas/code/demo")
            preview = adapter.preview("sess-1")
            self.assertIn("You", preview)
            self.assertIn("fix the idle flicker", preview)


class GrokAdapterTest(unittest.TestCase):
    def test_reads_summary_json(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            session = root / "sessions" / "%2Fhome%2Fthomas" / "abc-123"
            session.mkdir(parents=True)
            (session / "summary.json").write_text(
                json.dumps(
                    {
                        "info": {"id": "abc-123", "cwd": "/home/thomas"},
                        "generated_title": "Theme the bar",
                        "last_turn_summary": "Use Color.menu tokens",
                        "updated_at": "2026-08-15T12:00:00Z",
                        "num_chat_messages": 4,
                        "current_model_id": "grok-4.6",
                    }
                ),
                encoding="utf-8",
            )
            adapter = R.GrokAdapter()
            adapter.root = lambda: root  # type: ignore[method-assign]
            sessions = adapter.list_sessions(10)
            self.assertEqual(sessions[0]["title"], "Theme the bar")
            self.assertEqual(sessions[0]["model"], "grok-4.6")

    def test_cache_files_include_transcript_sidecars(self) -> None:
        adapter = R.GrokAdapter()
        summary = Path("/tmp/sessions/proj/abc/summary.json")
        files = adapter.cache_files(summary)
        self.assertEqual(
            files,
            [summary, summary.parent / "chat_history.jsonl", summary.parent / "updates.jsonl"],
        )


class OpenCodeAdapterTest(unittest.TestCase):
    def test_cache_files_include_wal(self) -> None:
        adapter = R.OpenCodeAdapter()
        db = Path("/tmp/opencode.db")
        self.assertEqual(adapter.cache_files(db), [db, Path("/tmp/opencode.db-wal")])


class ExternalAdapterTest(unittest.TestCase):
    def test_json_array_list(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            script = Path(raw) / "omarchy-agent-sessions-demo"
            script.write_text(
                "#!/usr/bin/env python3\n"
                "import json,sys\n"
                "if sys.argv[1]=='list':\n"
                "    json.dump([{'id':'x','title':'from adapter','cwd':'/tmp','updatedAt':'2026-08-15T00:00:00Z'}], sys.stdout)\n"
                "elif sys.argv[1]=='preview':\n"
                "    print('hello')\n"
                "elif sys.argv[1]=='resume':\n"
                "    json.dump({'command':['true'],'cwd':'/tmp'}, sys.stdout)\n",
                encoding="utf-8",
            )
            script.chmod(script.stat().st_mode | stat.S_IEXEC)
            adapter = R.ExternalAdapter("demo", script, name="Demo")
            sessions = adapter.list_sessions(10)
            self.assertEqual(sessions[0]["id"], "x")
            self.assertEqual(adapter.preview("x").strip(), "hello")
            plan = adapter.resume_plan("x")
            self.assertEqual(plan["command"], ["true"])


class HandoffTest(unittest.TestCase):
    def test_start_command_matches_omarchy_agent(self) -> None:
        claude = R.start_command("claude", "hello")
        self.assertEqual(claude[:3], ["claude", "--permission-mode", "bypassPermissions"])
        self.assertEqual(claude[-1], "hello")
        self.assertIsNone(R.start_command("unknown", "hello"))

    def test_handoff_includes_title_and_transcript(self) -> None:
        text = R.compose_handoff(
            {"source": "grok", "title": "Fix the bar", "cwd": "/tmp/proj"},
            "You\nhello\n\nAgent\nworld",
        )
        self.assertIn("Original agent: grok", text)
        self.assertIn("Fix the bar", text)
        self.assertIn("/tmp/proj", text)
        self.assertIn("hello", text)


class HerdrHelpersTest(unittest.TestCase):
    def test_process_ppid_reads_status(self) -> None:
        self.assertEqual(R.process_ppid(os.getpid()), os.getppid())

    def test_sanitize_and_unique_names(self) -> None:
        self.assertEqual(R.sanitize_herdr_name("Grok", "Ivory Tower"), "grok-ivory-tower")
        self.assertEqual(R.sanitize_herdr_name("123"), "r123")
        self.assertEqual(R.unique_herdr_name("grok", {"grok", "grok-2"}), "grok-3")

    def test_pick_workspace_prefers_checkout_and_skips_home(self) -> None:
        workspaces = [
            {"workspace_id": "wR", "label": "~"},
            {
                "workspace_id": "w2",
                "label": "berserk",
                "worktree": {
                    "checkout_path": "/home/thomas/code/berserk",
                    "repo_root": "/home/thomas/code/berserk",
                },
            },
        ]
        match = R.pick_herdr_workspace(workspaces, "/home/thomas/code/berserk/apps/docs")
        self.assertEqual(match["workspace_id"], "w2")
        self.assertIsNone(R.pick_herdr_workspace(workspaces, "/home/thomas/code/other"))
        home = R.pick_herdr_workspace(workspaces, str(Path.home()))
        self.assertEqual(home["workspace_id"], "wR")

    def test_resolve_launch_target(self) -> None:
        self.assertEqual(R.resolve_launch_target(herdr=False, terminal=True), "terminal")
        self.assertEqual(R.resolve_launch_target(herdr=True, terminal=False), "herdr")

    def test_herdr_status_when_missing(self) -> None:
        original = R.which
        R.which = lambda name: None  # type: ignore[method-assign]
        try:
            payload = R.herdr_status_payload()
        finally:
            R.which = original  # type: ignore[method-assign]
        self.assertFalse(payload["available"])
        self.assertFalse(payload["running"])

    def test_herdr_running_session_prefers_default(self) -> None:
        original_sessions = R.herdr_sessions
        R.herdr_sessions = lambda: [  # type: ignore[method-assign]
            {"name": "scratch", "running": True},
            {"name": "default", "running": True, "default": True, "socket_path": "/tmp/herdr.sock"},
            {"name": "dead", "running": False},
        ]
        try:
            session = R.herdr_running_session()
            self.assertEqual(session["name"], "default")
            self.assertEqual(R.resolve_launch_target(), "herdr")
        finally:
            R.herdr_sessions = original_sessions  # type: ignore[method-assign]


class LaunchDirTest(unittest.TestCase):
    def test_resume_plan_keeps_session_cwd(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            project = root / "projects" / "-home-thomas-code-demo"
            project.mkdir(parents=True)
            (project / "sess-dir.jsonl").write_text(
                json.dumps({"type": "user", "sessionId": "sess-dir", "cwd": "/home/thomas/code/demo", "message": {"role": "user", "content": "work here"}}) + "\n",
                encoding="utf-8",
            )
            adapter = R.ClaudeAdapter()
            adapter.root = lambda: root  # type: ignore[method-assign]
            plan = adapter.resume_plan("sess-dir")
            self.assertEqual(plan["cwd"], "/home/thomas/code/demo")

    def test_missing_cwd_falls_back_home(self) -> None:
        self.assertEqual(R.resolved_workdir("/definitely-not-a-dir"), str(Path.home()))


class OpenCodeResumeTest(unittest.TestCase):
    def test_resume_plan_uses_session_option(self) -> None:
        adapter = R.OpenCodeAdapter()
        adapter.list_sessions = lambda _limit: [{"id": "session-1", "cwd": "/tmp"}]  # type: ignore[method-assign]
        self.assertEqual(
            adapter.resume_plan("session-1")["command"],
            ["opencode", "--auto", "--session", "session-1"],
        )


class HerdrSessionFocusTest(unittest.TestCase):
    def test_focuses_pane_with_matching_native_session(self) -> None:
        calls: list[list[str]] = []
        original = R.herdr_json

        def fake_herdr_json(args, _session, timeout=20):
            calls.append(args)
            if args == ["agent", "list"]:
                return {"result": {"agents": [{"pane_id": "w1:p2", "agent_session": {"value": "session-1"}}]}}
            return {}

        R.herdr_json = fake_herdr_json
        try:
            self.assertTrue(R.focus_herdr_session({"name": "default"}, "session-1"))
        finally:
            R.herdr_json = original

        self.assertEqual(calls, [["agent", "list"], ["agent", "focus", "w1:p2"]])

    def test_focuses_pane_with_matching_opencode_arguments(self) -> None:
        calls: list[list[str]] = []
        original = R.herdr_json

        def fake_herdr_json(args, _session, timeout=20):
            calls.append(args)
            if args == ["agent", "list"]:
                return {"result": {"agents": [{"pane_id": "w1:p2"}]}}
            if args == ["pane", "process-info", "--pane", "w1:p2"]:
                return {"result": {"process_info": {"foreground_processes": [{"argv": ["opencode", "--auto", "--session", "session-1"]}]}}}
            return {}

        R.herdr_json = fake_herdr_json
        try:
            self.assertTrue(R.focus_herdr_session({"name": "default"}, "session-1"))
        finally:
            R.herdr_json = original

        self.assertEqual(calls, [["agent", "list"], ["pane", "process-info", "--pane", "w1:p2"], ["agent", "focus", "w1:p2"]])


class CliSmokeTest(unittest.TestCase):
    def test_herdr_status_command(self) -> None:
        proc = subprocess.run([str(RESUME), "herdr-status"], check=False, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertIn("available", data)
        self.assertIn("running", data)

    def test_sources_command(self) -> None:
        env = os.environ.copy()
        env["CLAUDE_CONFIG_DIR"] = "/tmp/resume-missing-claude"
        env["CODEX_HOME"] = "/tmp/resume-missing-codex"
        env["GROK_HOME"] = "/tmp/resume-missing-grok"
        proc = subprocess.run([str(RESUME), "sources"], check=False, capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertEqual(data["schemaVersion"], 1)
        self.assertIn("sources", data)


if __name__ == "__main__":
    unittest.main()
