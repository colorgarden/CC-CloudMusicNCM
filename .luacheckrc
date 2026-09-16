-- .luacheckrc - configuration for CC-CloudMusicNCM.
-- Target runtime: CC:Tweaked (Cobalt / Lua 5.2) with the CC global APIs.
std = "lua52"

read_globals = {
  -- CC:Tweaked global APIs used by install.lua / startup.lua
  "fs", "http", "term", "peripheral", "shell", "textutils",
  "colors", "colours", "keys", "sleep", "write", "read", "printError",
  -- CC:Tweaked's Cobalt provides the utf8 library (utf8.len etc.).
  "utf8",
}

-- Writable globals (CC packs and test shims override some of these).
globals = { "_G", "bit32", "unpack", "print" }

-- 143/142: setting a read-only / undefined global; 122: setting a field on an
-- undefined global. CC:Tweaked extends standard globals, so ignore those.
ignore = { "143", "142", "122" }

unused_args = false
unused_secondaries = false
max_line_length = false
