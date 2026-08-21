#!/usr/bin/env python3
"""A tiny tmux-backed session switcher for pi."""

from __future__ import annotations

import argparse
import curses
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

SESSION_ROOT = Path.home() / ".pi" / "agent" / "sessions"
TMUX = shutil.which("tmux") or "tmux"
PI = shutil.which("pi") or "pi"


@dataclass(frozen=True)
class Session:
    file: Path
    cwd: str
    name: str | None
    title: str | None
    updated: float

    @property
    def label(self) -> str:
        return self.name or self.title or "untitled session"


def age_label(timestamp: float) -> str:
    seconds = max(0, time.time() - timestamp)
    if seconds < 60:
        return "now"
    if seconds < 3600:
        return f"{int(seconds // 60)}m"
    if seconds < 86400:
        return f"{int(seconds // 3600)}h"
    if seconds < 604800:
        return f"{int(seconds // 86400)}d"
    return time.strftime("%b %d", time.localtime(timestamp))


def read_session(path: Path) -> Session | None:
    header = None
    name = None
    title = None
    updated = path.stat().st_mtime

    try:
        with path.open(encoding="utf-8") as stream:
            for line in stream:
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue

                if entry.get("type") == "session" and header is None:
                    header = entry
                    continue
                if entry.get("type") == "session_info":
                    name = entry.get("name") or None
                    continue
                if entry.get("type") == "message":
                    message = entry.get("message", {})
                    if message.get("role") == "user" and title is None:
                        content = message.get("content", "")
                        if isinstance(content, list):
                            content = " ".join(
                                block.get("text", "")
                                for block in content
                                if block.get("type") == "text"
                            )
                        title = " ".join(str(content).split())[:100] or None
                timestamp = entry.get("timestamp")
                if isinstance(timestamp, str):
                    try:
                        updated = max(updated, time.mktime(time.strptime(timestamp[:19], "%Y-%m-%dT%H:%M:%S")))
                    except ValueError:
                        pass
    except (OSError, UnicodeError):
        return None

    if not header or not header.get("cwd"):
        return None
    return Session(path, header["cwd"], name, title, updated)


def sessions() -> list[Session]:
    if not SESSION_ROOT.exists():
        return []
    result = []
    for path in SESSION_ROOT.rglob("*.jsonl"):
        session = read_session(path)
        if session:
            result.append(session)
    return sorted(result, key=lambda item: item.updated, reverse=True)


def tmux(socket: str, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [TMUX, "-L", socket, *args],
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def pi_command(cwd: str, session_file: Path | None = None, name: str | None = None) -> str:
    command = f"cd -- {shlex.quote(cwd)} && exec {shlex.quote(PI)}"
    if session_file:
        command += f" --session {shlex.quote(str(session_file))}"
    elif name:
        command += f" --name {shlex.quote(name)}"
    return command


def respawn_pi(socket: str, pane: str, cwd: str, session_file: Path | None = None, name: str | None = None) -> None:
    tmux(socket, "respawn-pane", "-k", "-t", pane, pi_command(cwd, session_file, name))
    tmux(socket, "select-pane", "-t", pane)


def ask(stdscr: curses.window, prompt: str) -> str:
    curses.echo()
    try:
        stdscr.addstr(0, 0, prompt + " ")
        stdscr.refresh()
        return stdscr.getstr().decode(errors="replace").strip()
    finally:
        curses.noecho()


def flatten(items: list[Session], current_cwd: str) -> tuple[list[tuple[str, str | Session]], list[int]]:
    groups: dict[str, list[Session]] = {}
    for item in items:
        groups.setdefault(item.cwd, []).append(item)

    rows: list[tuple[str, str | Session]] = []
    order: list[int] = []
    index_by_file = {item.file: index for index, item in enumerate(items)}
    groups = dict(sorted(
        groups.items(),
        key=lambda pair: (pair[0] != current_cwd, -max(s.updated for s in pair[1])),
    ))
    for cwd, group in groups.items():
        rows.append(("heading", cwd))
        for item in group:
            rows.append(("session", item))
            order.append(index_by_file[item.file])
    return rows, order


def draw(
    stdscr: curses.window,
    items: list[Session],
    selected: int,
    active: Path | None,
    status: str,
    current_cwd: str,
) -> None:
    stdscr.erase()
    stdscr.touchwin()
    height, width = stdscr.getmaxyx()
    rows, _ = flatten(items, current_cwd)
    selected = max(0, min(selected, max(0, len(items) - 1)))

    try:
        stdscr.addnstr(0, 0, " PIM  sessions", width - 1, curses.A_BOLD)
        stdscr.addnstr(1, 0, " n new   r rename   Enter switch   F6 focus   q quit", width - 1, curses.A_DIM)
    except curses.error:
        return

    selected_path = items[selected].file if items else None
    visible = max(1, height - 4)
    first = 0
    if selected_path:
        selected_row = next((i for i, (_, value) in enumerate(rows) if value == items[selected]), 0)
        first = max(0, min(selected_row - visible // 2, max(0, len(rows) - visible)))

    for screen_row, row_index in enumerate(range(first, min(len(rows), first + visible)), start=2):
        kind, value = rows[row_index]
        if kind == "heading":
            try:
                stdscr.addnstr(screen_row, 0, f" {value}", width - 1, curses.A_DIM)
            except curses.error:
                pass
            continue

        item = value
        assert isinstance(item, Session)
        marker = ">" if item.file == selected_path else " "
        active_marker = " *" if active and item.file == active else "  "
        suffix = f" {age_label(item.updated)}"
        available = max(1, width - 1)
        label = item.label
        if len(label) > 56:
            label = label[:53] + "..."
        label_width = max(1, available - len(suffix))
        text = (f"{marker}{active_marker} {label}"[:label_width].ljust(label_width) + suffix)
        attr = curses.A_REVERSE if item.file == selected_path else curses.A_NORMAL
        try:
            stdscr.addnstr(screen_row, 0, text, available, attr)
        except curses.error:
            pass
    try:
        stdscr.addnstr(height - 1, 0, " " + status, width - 1, curses.A_DIM)
    except curses.error:
        pass
    stdscr.refresh()


def append_session_name(path: Path, name: str) -> None:
    last_id = None
    with path.open(encoding="utf-8") as stream:
        for line in stream:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if entry.get("id"):
                last_id = entry["id"]
    entry = {
        "type": "session_info",
        "id": uuid.uuid4().hex[:8],
        "parentId": last_id,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
        "name": name,
    }
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(entry) + "\n")


def manager_loop(socket: str, session_name: str, right_pane: str, start_cwd: str) -> None:
    active_item = next((item for item in sessions() if item.cwd == start_cwd), None)
    active: Path | None = active_item.file if active_item else None
    selected = 0
    status = "Click a session or use ↑↓, then Enter."

    def load() -> list[Session]:
        return sessions()

    def switch(item: Session) -> tuple[Path | None, str]:
        cwd = item.cwd if os.path.isdir(item.cwd) else start_cwd
        if not os.path.isdir(item.cwd):
            return active, f"Missing folder: {item.cwd}"
        respawn_pi(socket, right_pane, cwd, item.file)
        return item.file, f"Switched to {item.label}"

    def new_session(stdscr: curses.window) -> tuple[Path | None, str]:
        name = ask(stdscr, "New session name (optional):")
        respawn_pi(socket, right_pane, start_cwd, name=name or None)
        return None, "Started new session"

    def rename_session(stdscr: curses.window, item: Session) -> str:
        name = ask(stdscr, f"Rename '{item.label}':")
        if not name:
            return "Rename cancelled"
        append_session_name(item.file, name)
        return f"Renamed to {name}"

    def loop(stdscr: curses.window) -> None:
        nonlocal active, selected, status
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        def move_selection(items: list[Session], selected: int, delta: int) -> int:
            _, order = flatten(items, start_cwd)
            if not order:
                return 0
            position = order.index(selected) if selected in order else 0
            return order[(position + delta) % len(order)]

        def refresh_items(items: list[Session], selected: int) -> tuple[list[Session], int]:
            selected_file = items[selected].file if items and selected < len(items) else None
            fresh = load()
            if not fresh:
                return fresh, 0
            if selected_file:
                selected = next((i for i, item in enumerate(fresh) if item.file == selected_file), min(selected, len(fresh) - 1))
            else:
                selected = min(selected, len(fresh) - 1)
            return fresh, selected

        stdscr.keypad(True)
        stdscr.timeout(250)
        items, selected = refresh_items([], selected)
        next_refresh = time.monotonic() + 2
        while True:
            if time.monotonic() >= next_refresh:
                items, selected = refresh_items(items, selected)
                next_refresh = time.monotonic() + 2
                draw(stdscr, items, selected, active, status, start_cwd)

            key = stdscr.getch()
            if key == -1:
                continue
            if key in (ord("q"), 3):
                tmux(socket, "kill-session", "-t", session_name, check=False)
                return
            if key in (curses.KEY_UP, ord("k")) and items:
                selected = move_selection(items, selected, -1)
            elif key in (curses.KEY_DOWN, ord("j")) and items:
                selected = move_selection(items, selected, 1)
            elif key in (10, 13, curses.KEY_ENTER) and items:
                active, status = switch(items[selected])
                items, selected = refresh_items(items, selected)
                next_refresh = time.monotonic() + 2
            elif key == ord("n"):
                active, status = new_session(stdscr)
                items, selected = refresh_items(items, selected)
                next_refresh = time.monotonic() + 2
            elif key == ord("r") and items:
                status = rename_session(stdscr, items[selected])
                items, selected = refresh_items(items, selected)
                next_refresh = time.monotonic() + 2
            elif key in (ord("R"), curses.KEY_F5):
                items, selected = refresh_items(items, selected)
                next_refresh = time.monotonic() + 2
                status = "Session list refreshed"
            draw(stdscr, items, selected, active, status, start_cwd)

    curses.wrapper(loop)


def start() -> None:
    if not shutil.which("tmux"):
        raise SystemExit("pim needs tmux (brew install tmux)")
    if not shutil.which("pi"):
        raise SystemExit("pim needs pi on PATH")

    cwd = os.getcwd()
    socket = f"pim-{os.getpid()}"
    session_name = "pim"
    current = next((item for item in sessions() if item.cwd == cwd), None)

    tmux(socket, "-f", "/dev/null", "new-session", "-d", "-s", session_name, "-c", cwd, "sh")
    try:
        tmux(socket, "set-option", "-g", "mouse", "on")
        tmux(socket, "set-option", "-g", "status", "off")
        tmux(socket, "set-option", "-g", "remain-on-exit", "on")
        tmux(socket, "bind-key", "-n", "F6", "select-pane", "-l")
        tmux(socket, "split-window", "-h", "-t", f"{session_name}:0.0", "-c", cwd, "sh")
        panes = tmux(socket, "list-panes", "-t", session_name, "-F", "#{pane_id}").stdout.splitlines()
        if len(panes) != 2:
            raise RuntimeError("could not create Pi pane")
        left_pane, right_pane = panes
        tmux(socket, "resize-pane", "-t", left_pane, "-x", "36")
        respawn_pi(socket, right_pane, current.cwd if current else cwd, current.file if current else None)
        manager = [
            sys.executable,
            str(Path(__file__).resolve()),
            "--manager",
            "--socket",
            socket,
            "--session-name",
            session_name,
            "--right-pane",
            right_pane,
            "--cwd",
            cwd,
        ]
        tmux(socket, "respawn-pane", "-k", "-t", left_pane, " ".join(shlex.quote(part) for part in manager))
        tmux(socket, "select-pane", "-t", right_pane)
        subprocess.run([TMUX, "-L", socket, "attach-session", "-t", session_name])
    finally:
        tmux(socket, "kill-session", "-t", session_name, check=False)


def self_test() -> None:
    import tempfile

    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "test.jsonl"
        path.write_text(
            '{"type":"session","cwd":"/tmp/project"}\n'
            '{"type":"message","message":{"role":"user","content":"Fix the widget"}}\n'
            '{"type":"session_info","name":"Widget fix"}\n',
            encoding="utf-8",
        )
        item = read_session(path)
        assert item is not None
        assert item.cwd == "/tmp/project"
        assert item.label == "Widget fix"
        assert item.title == "Fix the widget"
        rows, order = flatten([
            Session(Path("/tmp/other.jsonl"), "/tmp/other", None, "other", 2),
            Session(Path("/tmp/current.jsonl"), "/tmp/current", None, "current", 1),
        ], "/tmp/current")
        assert order == [1, 0] and rows[0][0] == "heading"
        append_session_name(path, "Renamed")
        assert read_session(path).name == "Renamed"
    assert "pi" in pi_command("/tmp/project", Path("/tmp/a b.jsonl"))
    print("pim self-test: ok")


def main() -> None:
    parser = argparse.ArgumentParser(prog="pim", description="A sidebar session switcher for pi")
    parser.add_argument("--manager", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--socket", help=argparse.SUPPRESS)
    parser.add_argument("--session-name", help=argparse.SUPPRESS)
    parser.add_argument("--right-pane", help=argparse.SUPPRESS)
    parser.add_argument("--cwd", help=argparse.SUPPRESS)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
    elif args.manager:
        manager_loop(args.socket, args.session_name, args.right_pane, args.cwd)
    else:
        start()


if __name__ == "__main__":
    main()
