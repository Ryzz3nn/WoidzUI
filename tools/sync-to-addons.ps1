# Copies the working tree into the live AddOns folder, so a /reload picks up a
# change without cutting a release first.
#
# WowUp owns that folder now. This only overwrites the files a release ships,
# never the folder itself, so WowUp's record survives. Clicking update in WowUp
# puts the released files back over the top of whatever was synced here.

$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$dest = "D:\World of Warcraft\_anniversary_\Interface\AddOns\WoidzUI"

if (-not (Test-Path $dest)) {
    throw "WoidzUI is not installed at $dest. Install it from WowUp first, then run this again."
}

# Lua and the TOC are the whole addon. The repo only files (README, DESIGN,
# .github, tools) have no business in the game folder.
robocopy $repo $dest *.lua *.toc /S /XD .git .github tools .release /NFL /NDL /NJH /NJS /NP | Out-Null

# Robocopy uses exit codes below 8 for success, where 1 means files were copied
# and 0 means everything already matched.
if ($LASTEXITCODE -ge 8) {
    throw "robocopy failed with exit code $LASTEXITCODE"
}

"Synced to $dest. Run /reload in game."
