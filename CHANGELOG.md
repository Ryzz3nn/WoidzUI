# Changelog

## 0.6.0

- Minimap: a zoom setting, and an option to keep it there. Zero is as far out as
  the client will go, but the game re-zooms on the way indoors and back out, so a
  map left fully out did not stay that way. The wheel still overrides it.
- Professions: shift click a row in the levelling guide to link the item. With
  the auction house open that fills the search box, with chat open it inserts the
  link, the same as shift clicking a reagent anywhere else.
- Professions: the same click now works in the Craft window that enchanting uses.
  Its reagent buttons carried no click handler at all, which is why the click
  worked in blacksmithing and did nothing under enchanting.
- XP bar: fixed an error every time the bar drew a watched reputation. The
  Anniversary client has no GetWatchedFactionInfo; reputation moved to
  C_Reputation.GetWatchedFactionData, and both are now read.

## 0.5.0

First public release.

- Square minimap with library icons re-placed along the flat edge.
- Button tray that collects stray addon buttons out of the minimap ring.
- Free floating XP bar with session rate, kills, and time to level.
- Party quest line tracking. Says who is ahead in a line and which quest each of
  you is on, using Questie for the group's active quests and a direct exchange
  between two WoidzUI clients for the lines finished before the group formed.
- Profession levelling guides with live auction house costs from TSM or
  Auctionator.
- Shared settings window and `/wui` commands for every module.
