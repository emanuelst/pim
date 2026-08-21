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


def confirm(stdscr: curses.window, prompt: str) -> bool:
    curses.echo()
    try:
        stdscr.addstr(0, 0, prompt + " [y/N] ")
        stdscr.refresh()
        answer = stdscr.getstr().decode(errors="replace").strip().lower()
        return answer in {"y", "yes"}
    finally:
        curses.noecho()


def ask(stdscr: curses.window, prompt: str) -> str:
    curses.echo()
    try:
        stdscr.addstr(0, 0, prompt + " ")
        stdscr.refresh()
        return stdscr.getstr().decode(errors="replace").strip()
    finally:
        curses.noecho()


def flatten(items: list[Session]) -> tuple[list[tuple[str, str | Session]], list[int]]:
    groups: dict[str, list[Session]] = {}
    for item in items:
        groups.setdefault(item.cwd, []).append(item)

    rows: list[tuple[str, str | Session]] = []
    session_rows: list[int] = []
    for cwd, group in sorted(groups.items(), key=lambda pair: max(s.updated for s in pair[1]), reverse=True):
        rows.append(("heading", cwd))
        for item in group:
            session_rows.append(len(rows))
            rows.append(("session", item))
    return rows, session_rows


def draw(
    stdscr: curses.window,
    items: list[Session],
    selected: int,
    active: Path | None,
    status: str,
) -> dict[int, int]:
    stdscr.erase()
    height, width = stdscr.getmaxyx()
    row_map: dict[int, int] = {}
    rows, session_rows = flatten(items)
    selected = max(0, min(selected, max(0, len(items) - 1)))

    try:
        stdscr.addnstr(0, 0, " PIM  sessions", width - 1, curses.A_BOLD)
        stdscr.addnstr(1, 0, " n new   Enter switch   F6 focus   q quit", width - 1, curses.A_DIM)
    except curses.error:
        return row_map

    selected_path = items[selected].file if items else None
    visible = max(1, height - 4)
    first = 0
    if selected_path:
        selected_row = next((i for i, (_, value) in enumerate(rows) if value == items[selected]), 0)
        first = max(0, min(selected_row - visible // 2, max(0, len(rows) - visible)))

    session_index = 0
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
        row_map[screen_row] = session_index
        marker = ">" if item.file == selected_path else " "
        active_marker = " *" if active and item.file == active else "  "
        text = f"{marker}{active_marker} {item.label}"
        if item.title and not item.name:
            text = f"{marker}{active_marker} {item.title}"
        attr = curses.A_REVERSE if item.file == selected_path else curses.A_NORMAL
        try:
            stdscr.addnstr(screen_row, 0, text, width - 1, attr)
        except curses.error:
            pass
        session_index += 1

    try:
        stdscr.addnstr(height - 1, 0, " " + status, width - 1, curses.A_DIM)
    except curses.error:
        pass
    stdscr.refresh()
    return row_map


def manager_loop(socket: str, session_name: str, right_pane: str, start_cwd: str) -> None:
    active_item = next((item for item in sessions() if item.cwd == start_cwd), None)
    active: Path | None = active_item.file if active_item else None
    selected = 0
    status = "Click a session or use ↑↓, then Enter."

    def load() -> list[Session]:
        return sessions()

    def switch(stdscr: curses.window, item: Session) -> tuple[Path | None, str]:
        nonlocal active
        cwd = item.cwd if os.path.isdir(item.cwd) else start_cwd
        if not os.path.isdir(item.cwd):
            return active, f"Missing folder: {item.cwd}"
        if active != item.file and not confirm(stdscr, "Stop current Pi and switch? "):
            return active, "Switch cancelled"
        respawn_pi(socket, right_pane, cwd, item.file)
        return item.file, f"Switched to {item.label}"

    def new_session(stdscr: curses.window) -> tuple[Path | None, str]:
        name = ask(stdscr, "New session name (optional):")
        if active and not confirm(stdscr, "Stop current Pi and start new session? "):
            return active, "New session cancelled"
        respawn_pi(socket, right_pane, start_cwd, name=name or None)
        return None, "Started new session"

    def loop(stdscr: curses.window) -> None:
        nonlocal active, selected, status
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        stdscr.keypad(True)
        stdscr.timeout(1000)
        curses.mousemask(curses.ALL_MOUSE_EVENTS)

        while True:
            items = load()
            if items:
                selected = min(selected, len(items) - 1)
            else:
                selected = 0
            row_map = draw(stdscr, items, selected, active, status)
            key = stdscr.getch()

            if key == -1:
                continue
            if key in (ord("q"), 3):
                tmux(socket, "kill-session", "-t", session_name, check=False)
                return
            if key in (curses.KEY_UP, ord("k")) and items:
                selected = (selected - 1) % len(items)
            elif key in (curses.KEY_DOWN, ord("j")) and items:
                selected = (selected + 1) % len(items)
            elif key in (10, 13, curses.KEY_ENTER) and items:
                active, status = switch(stdscr, items[selected])
            elif key == ord("n"):
                active, status = new_session(stdscr)
            elif key in (ord("r"), curses.KEY_F5):
                status = "Session list refreshed"
            elif key == curses.KEY_MOUSE:
                try:
                    _, _, y, _, buttons = curses.getmouse()
                    if buttons & (curses.BUTTON1_CLICKED | curses.BUTTON1_PRESSED):
                        index = row_map.get(y)
                        if index is not None:
                            selected = index
                            active, status = switch(stdscr, items[selected])
                except curses.error:
                    pass

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
