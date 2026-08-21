# Pim

Pim is a native macOS session multiplexer for [Pi](https://github.com/earendil-works/pi).

It gives Pi a calm, macOS-native home: a resizable sidebar for navigating chats and an embedded Ghostty terminal for the selected session.

> Pim is experimental and currently intended as a local development build.

## What Pim does

- Reads Pi's JSONL sessions directly; Pi remains the source of truth.
- Embeds Pi inside a pinned Ghostty/libghostty macOS build.
- Keeps visited sessions warm while allowing cold sessions to load on demand.
- Shows warm, working, cold, and unread state in the sidebar.
- Organizes sessions into **Pinned** and **Recents**.
- Supports local custom chat names and pinning without modifying Pi session files.
- Provides native chat search, including asynchronous transcript search.
- Uses native macOS split views, titlebar controls, menus, materials, and keyboard behavior.

Pim does not maintain a separate conversation database. Local presentation state—pins, names, and read markers—is stored in macOS `UserDefaults`.

## Requirements

- macOS
- Xcode and the macOS SDK
- Zig
- [Pi](https://github.com/earendil-works/pi) available on `PATH`, or configured with `PIM_PI_PATH`

## Build and run the native app

```sh
cd ~/pim
./macos/build-pim.sh
./macos/run-pim.sh
```

The first build compiles the pinned Ghostty checkout and may take a while. The result is an unsigned local app at:

```text
build/Pim.app
```

For a clean local screenshot environment without using your normal Pi sessions:

```sh
./macos/run-pim-clean.sh
```

This points both Pim and Pi at a temporary empty agent directory and removes it
when the app exits. It does not require a second macOS user or a virtual machine.
Pim also accepts `PIM_AGENT_DIR` or Pi's `PI_CODING_AGENT_DIR` when you want to
choose a persistent alternate agent directory yourself.

Pim currently starts without sandboxing because it needs to read Pi's local session directory and launch Pi processes.

## The original tmux prototype

The tmux prototype remains available and is useful for testing the basic session model without building the native app:

```sh
ln -sf "$HOME/pim/pim.py" "$HOME/.local/bin/pim"
pim
```

Run its self-test with:

```sh
python3 ~/pim/pim.py --self-test
```

The prototype requires `tmux` and Pi on `PATH`.

## Data and privacy

Pim reads sessions from Pi's local agent directory and does not upload conversation data. Be careful when sharing screenshots: terminal contents and session titles may contain private information.

For a clean demo environment, a separate macOS user account is preferable to a virtual machine. It provides a real native macOS window without exposing your personal `~/.pi` data. A future demo fixture mode can populate that account with synthetic Pi session JSONL files and a stub Pi executable.
