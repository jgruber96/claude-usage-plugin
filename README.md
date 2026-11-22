# Claude usage plugin

See your Claude plan limits coming: the 5-hour session limit and the 7-day weekly limit, each with a pace figure that says whether you are using them faster or slower than time is passing.

Three pieces, which work on their own or together:

| Piece | Where it shows | Files |
| --- | --- | --- |
| Status line | Claude Code in a terminal | `statusline.ps1`, `statusline.sh` |
| `plan-usage` mod | Claude Code in the desktop app: a row above the prompt, a Usage panel and a widget | `plan-usage/` |
| Overlay card | A small window anchored to the Claude desktop window, across Chat and Code (Windows) | `overlay/` |

None of them makes a network request or touches your credentials. They only use the rate-limit figures Claude Code already hands to status lines and mods.

## How to read it

Each limit is a thick usage bar with a thin pace line above it. The line shows how much of the window has passed:

| The line | means |
| --- | --- |
| Grey | Usage and time agree. |
| Green | Time is ahead of your usage: room to spare. |
| Orange | Your usage is ahead of time: you're going too fast. |
| Red | Too fast, and the limit is close (80% used or more). |

"On pace" means within three points of the time that has passed. The usage bar turns from blue to yellow at 80% used.

## Status line (terminal)

Copy `statusline.ps1` (Windows) or `statusline.sh` (macOS, Linux) somewhere and point Claude Code at it in `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "powershell -NoProfile -File \"C:/path/to/statusline.ps1\""
}
```

On macOS or Linux the command is the path to `statusline.sh`, after `chmod +x`. It needs only `sh`, `date` and `awk`.

Output looks like:

```
Fable 5.2 · my-project │ session 24% ██░░░░░░ -31% · 2h 14m left │ week 62% █████░░░ +33% · 5d 0h left
```

The figures appear after the first response in a session, and only on plans that report usage limits.

## plan-usage mod (desktop app)

The desktop app does not run the status line script, so the mod draws the same figures there.

```
/plugin install plan-usage --marketplace jgruber96/claude-usage-plugin
```

In the desktop app, where `/plugin` does not run: click + next to the prompt box, then Plugins, Add marketplace with `jgruber96/claude-usage-plugin`, then Add plugin.

- **Row above the prompt:** session and weekly bars with reset times, the week's pace and the conversation's context.
- **Usage panel:** the row's Details button, or `/plan-usage`. Context and every limit, each with its bars, reset time and pace, and a warning when the current rate would reach the limit before reset.
- **Widget:** minimize the panel to get a small glance card.

In a terminal the mod draws no row, since the status line already shows the figures there.

The mod also writes the latest reading to `~/.claude/plan-usage.json` for the overlay.

To check a change: `claude plugin validate ./plan-usage` and `claude plugin test ./plan-usage`.

## Overlay card (Windows)

A separate always-on-top card that pins itself to the bottom-left of the Claude desktop window and follows it, so the usage sits over the sidebar in both Chat and Code. It needs the mod installed, which supplies its figures, and nothing else: it is a single Windows PowerShell script.

Start it by double-clicking `overlay/start-overlay.cmd`.

- Drag the card to set its place in the Claude window. The place is remembered.
- Right-click for **Anchor to the Claude window**, **Lock position** and **Close**.
- It shows only while a Claude window is in front.

Its percentages update when a Claude Code session reports new ones. Chat use counts toward the same limits, so it shows up the next time a Code session makes a request. Times left and pace keep moving in between, and the card notes when the reading is more than 15 minutes old. Context is the most recently active Code session's, named by its folder.

## Credit

The bar-and-pace-line look follows [UI+ for Claude](https://github.com/LukasvanUden/ui-plus-for-claude) by Lukas van Uden. This project shares no code with it and works differently: it does not inject anything into the Claude app.

## License

MIT. See [LICENSE](LICENSE).

Not affiliated with or endorsed by Anthropic. Claude is a trademark of Anthropic, PBC.
