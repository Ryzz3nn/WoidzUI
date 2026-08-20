// Loads WoidzUI into a Lua VM against a mock of the WoW client, fires the two
// bootstrap events, builds the settings window and every page, and drives the
// widgets. Catches what a /reload would, without a /reload.
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { LuaFactory } from 'wasmoon';

const HARNESS = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HARNESS, '..', '..');
const read = (p) => readFileSync(p, 'utf8');

const toc = read(join(ROOT, 'WoidzUI.toc'))
  .split(/\r?\n/)
  .filter((l) => l.trim().toLowerCase().endsWith('.lua'))
  .map((l) => l.trim().replace(/\\/g, '/'));

const lua = await new LuaFactory().createEngine({ openStandardLibs: true });
await lua.doString(read(join(HARNESS, 'wowmock.lua')));

for (const f of toc) {
  lua.global.set('__src', read(join(ROOT, f)));
  lua.global.set('__name', f);
  await lua.doString(`
    local chunk, err = loadstring(__src, "@" .. __name)
    if not chunk then error("load " .. __name .. ": " .. tostring(err)) end
    _G.__NS = _G.__NS or {}
    local ok, e = pcall(chunk, "WoidzUI", _G.__NS)
    if not ok then error(__name .. ": " .. tostring(e)) end
  `);
}

await lua.doString(read(join(HARNESS, 'exercise.lua')));
console.log(lua.global.get('__RESULT'));
lua.global.close();
