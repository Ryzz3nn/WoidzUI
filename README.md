# WoidzUI

A modular UI suite for World of Warcraft Burning Crusade Classic, built for the Anniversary realms (interface 20506). Square minimap, a button tray, a free floating XP bar, party quest line tracking, and profession levelling with auction house costs. Every module can be switched off on its own, and all of them share one settings window.

## Install

### WowUp (recommended)

1. Open WowUp and go to Get Addons.
2. Choose Install from URL.
3. Paste `https://github.com/Ryzz3nn/WoidzUI` and confirm.

WowUp reads the latest tagged release, so updates arrive the same way every other addon's do.

### Manual

1. Download the zip from [Releases](https://github.com/Ryzz3nn/WoidzUI/releases/latest).
2. Extract it into `World of Warcraft\_anniversary_\Interface\AddOns`, so the folder lands as `Interface\AddOns\WoidzUI`.
3. Restart the client, or `/reload` if it was already running.

## Modules

| Module | What it does |
|---|---|
| Minimap | Square minimap with the clutter stripped off, library icons re-placed along the flat edge. |
| Buttons | Collects stray addon buttons into one tray instead of a ring around the minimap. |
| XP bar | Free floating experience bar with session rate, kills, and time to level. |
| Party quests | Says when someone in the group is ahead of you in a quest line, and which quest each of you is on. |
| Professions | Levelling guides with live auction house costs, read from TSM or Auctionator. |

## Commands

`/wui`, `/woidz` and `/woidzui` all do the same thing.

| Command | What it does |
|---|---|
| `/wui` | Opens the settings window. |
| `/wui unlock` | Unlocks every frame for dragging. `/wui lock` puts them back. |
| `/wui scan` | Picks up addon buttons that appeared after login. |
| `/wui square` | Re-places library icons against the square minimap edge. |
| `/wui quests` | Full party quest line report for the current group. |
| `/wui prof [name]` | Profession report, optionally for one profession. |
| `/wui guide [name]` | Toggles the levelling guide panel. |
| `/wui xp [n]` | Previews the XP bar at a given level. |

## Optional dependencies

None are required, but each one adds something:

- **Questie** feeds the party quest module. Without it there is no way to read another player's quest log at all. Two people both running WoidzUI also report their exact position to each other, which covers quest lines finished before the group formed.
- **TradeSkillMaster** or **Auctionator** supplies the prices behind the profession costs.

## Building a release

Tag a version and push the tag. `.github/workflows/release.yml` runs the BigWigs packager, which builds the zip, writes `release.json` with the bcc flavor so WowUp can match it to the client, and attaches both to the GitHub release.

```bash
git tag -a v0.5.0 -m "v0.5.0"
git push origin v0.5.0
```

## License

MIT. See [LICENSE](LICENSE).
