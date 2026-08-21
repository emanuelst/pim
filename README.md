# pim

A tiny tmux-backed session switcher for [pi](https://pi.dev).

## Install

```sh
ln -sf "$HOME/pim/pim.py" "$HOME/.local/bin/pim"
```

Requires `pi` and `tmux` on `PATH`.

## Run

```sh
pim
```

The left pane lists Pi sessions; the right pane is an unchanged Pi TUI.

- `↑` / `↓` or `j` / `k`: select a session
- `Enter`: switch (stops and restarts the right pane)
- `n`: start a new session
- `r`: rename the selected session
- `R`: refresh
- `F6`: toggle focus between panes
- click either pane to focus it
- `q`: quit

Sessions are never deleted. Switching directly stops and restarts the right Pi pane, so switch when the active turn is idle.

Run the small check with:

```sh
python3 ~/pim/pim.py --self-test
```
