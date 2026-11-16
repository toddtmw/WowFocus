# WoWFocus

A World of Warcraft retail addon that strips world-quest noise so you can follow the campaign and main questlines without distraction.

## What it does

| Feature | Default | Toggle |
|---------|---------|--------|
| Hide world-quest pins on the world map | on | `/focus map` |
| Remove world quests from the objective tracker | on | `/focus tracker` |
| Show "Next: \<quest\>" for your active campaign quest | on | `/focus next` |

The "Next" frame is draggable. Its position is not yet saved between sessions (coming in a future version).

## What it hides

- World quest `!` pins on the map
- Bonus objectives
- Daily and weekly quest pins
- World quests in the objective tracker

## What it does not touch

- Campaign quests, story quests, or main-line side quests
- The quest log itself (it only watches it, never modifies it)
- Any gameplay action — it only hides UI elements

## Installation

1. Download or clone this repository.
2. Copy the `WoWFocus/` folder (the one that contains `WoWFocus.toc`) into your addons directory:
   - **Windows:** `C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\`
   - **macOS:** `/Applications/World of Warcraft/_retail_/Interface/AddOns/`
3. Launch WoW (or `/reload` if already in game) and enable **WoWFocus** on the character-select addon list.

## Slash commands

Both `/wf` and `/wowfocus` work. (`/focus` is a built-in WoW command that sets your focus target.)

```
/wf           toggle addon on/off
/wf on|off    explicit on/off
/wf map       toggle world-map pin hiding
/wf tracker   toggle tracker world-quest removal
/wf next      toggle "Next campaign quest" frame
/wf status    show current settings
/wf reset     restore defaults
/wf help      show this list in chat
```

## Interface version

The `.toc` `## Interface:` number must match the current retail patch. After loading, run:

```
/dump (select(4, GetBuildInfo()))
```

and update the first line of `WoWFocus.toc` if it differs.

## Known limitations / roadmap

- [ ] Suppress quest-complete toast popups
- [ ] Save "Next" frame position between sessions
- [ ] Settings panel (GUI)
- [ ] Packaging via BigWigs Packager / CurseForge

## License

MIT — see [LICENSE](LICENSE).
