# WoidzUI - Design

The look every WoidzUI frame follows, and where it comes from. `Style.lua` is
the whole implementation; this file is why it looks the way it does.

## Identity

Orange on charcoal, flat, dense. Two rules carry everything:

- **Orange is state, never surface.** It marks the live tab, a checked box, the
  filled part of a slider, the value being read, and the one primary action per
  window. It never fills a panel or a row. A screen that reads orange has used
  the accent as a surface.
- **A surface is raised or cut, never flat with only a border.** Depth is one
  1px lit edge along the top and one 1px shade along the bottom. No glow, no
  gradients on panels, no art.

Density comes from a damage meter: rows are short, text is small, and a value
worth comparing gets a bar behind it rather than a column of its own.

## Why nothing uses a Blizzard template

`UIPanelButtonTemplate`, `UICheckButtonTemplate` and `OptionsSliderTemplate`
carry the 2004 stone and rivets look in their **art**, not in their colours, so
recolouring them does nothing. Every widget in `Style.lua` is drawn from flat
textures and hairlines instead.

Two templates are still used, for behaviour rather than for looks:
`UIPanelScrollFrameTemplate` and `InputBoxTemplate`. Their scrolling and text
input are worth keeping and their art is not, so `S.ScrollBar` and `S.EditBox`
strip the textures and redraw them.

## Tokens

`ns.C` carries the hues, `ns.W` the white alpha ladder. The ladder is
deliberately not part of the palette: every quiet surface, hairline and muted
caption is white at a low alpha over the dark canvas whatever the accent is.

| Token | Value | Use |
| --- | --- | --- |
| `bg` | `#0e0f11` at 0.96 | window canvas |
| `panel` | `#121316` | panel surface |
| `raised` | `#1b1c20` | control surface |
| `accent` | `#ff8f2e` | every live and active mark |
| `accentDark` | `#b85c12` | the dark end of a fill gradient |
| `accentLight` | `#ffbe80` | text on an accent control, on hover |
| `good` | `#3ec46a` | enough of a material, a finished guide |
| `warn` | `#ffd93d` | fully yellow, so it never reads as the accent |
| `bad` | `#f87171` | shortfalls and destructive actions |
| `text` | warm white | titles and body |
| `dim` | `#969a9c` | secondary |

Muted text never drops below white 0.50 on this canvas; that is where the
4.5:1 contrast floor sits.

## Widgets

| Call | What it draws |
| --- | --- |
| `S.Panel` | raised or cut surface with a hairline |
| `S.Header` | tracked label, then a hairline fading to the edge |
| `S.Button` | ghost, primary or danger. Translucent fill, 1px border, never a solid slab |
| `S.Check` | 15px box, accent fill and mark when ticked |
| `S.TickBox` | the same box as a real CheckButton, for list rows |
| `S.Slider` | caption and live value over a 4px track with an accent fill |
| `S.Tab` | label with a 2px accent sill under the live one |
| `S.CloseButton` | plain X, red on hover |
| `S.RowMeter` | the bar behind a row, filling in proportion to its value |
| `S.Gradient` | works on both the old and the new gradient API |
| `S.Track` | fakes letterspacing with spaces, ASCII only |

Tracking is faked because font strings have no letter spacing. It works per
byte, so a caption with a non ASCII character is uppercased and left untracked
rather than cut through the middle of a multi byte character.

## Money

Prices carry the coin colours the game itself uses: gold `#ffd700`, silver
`#c7c7cf`, copper `#eda55f`. `ns.Prices.Format(copper)` returns the plain
string, `ns.Prices.FormatColored(copper)` the coloured one. The on screen guide
and the chat report use the coloured form; anything meant to be copied out uses
the plain one.

Each denomination opens and closes its own colour, so nothing downstream can
be left painted. That is also why the guide no longer wraps a total in an
accent colour: an outer colour code is ended by the first inner `|r`, and the
rest of the line loses it.

## Checking it without the game

`tools/uitest` loads the addon into a Lua VM against a mock of the WoW client,
fires ADDON_LOADED and PLAYER_LOGIN, builds the settings window and every page,
drives the widgets, and draws the profession guide against the shipped guide
data.

```powershell
npx --yes -p wasmoon node tools/uitest/run.mjs
```

It prints one PASS or FAIL line per check. Run it before a `/reload`, not
instead of one: it catches Lua errors and wiring mistakes, not how something
looks.
