-- rime.lua
local wubi_top = require("wubi86_top")
-- 这里映射的名字必须和 custom.yaml 里的 lua_processor@xxxx 一致
wubi86_top_processor = wubi_top.processor
wubi86_top_filter = wubi_top.filter

date_translator = require("date")