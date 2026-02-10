-- rime.lua
-- 1. 加载五笔增强工具箱 (wubi86_top.lua)
local wubi86_top = require("wubi86_top")

-- 2. 映射组件名称（需与 patch 中的名称一致）
pin_word_processor = wubi86_top.processor
pin_word_filter = wubi86_top.filter

-- 3. 加载日期翻译器
date_translator = require("date")