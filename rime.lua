-- rime.lua
-- 映射五笔全能组件，require的名字对应 lua 文件夹下的文件名
local wubi_top = require("wubi86_top")
wubi86_top_processor = wubi_top.processor
wubi86_top_filter = wubi_top.filter

-- 日期翻译器 (确保你已经有 date.lua)
date_translator = require("date")