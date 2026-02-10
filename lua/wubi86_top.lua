-- lua/wubi86_top.lua

local schema_caches = {} 
local state = { needs_fix = false, pending_text = "" }

-- 【一简映射：如果想改某个按键出的字，改后面的汉字即可】
local YIJIAN = {
    g="一", f="地", d="在", s="要", a="工", 
    h="上", j="是", k="中", l="国", m="同", 
    n="民", b="了", v="发", c="以", x="经", 
    t="和", r="的", e="有", w="人", q="我", 
    y="主", u="产", i="不", o="为", p="这"
}

-- 初始化与配置读取 (自动兼容 YAML 参数)
local function get_cache(env)
    local sid = env.engine.schema.schema_id
    if not schema_caches[sid] then
        local config = env.engine.schema.config
        local u_dir = rime_api.get_user_data_dir()
        
        schema_caches[sid] = { 
            p_list = {}, p_set = {}, d_set = {}, p_index = {},
            loaded = false,
            mark = config:get_string("wubi_top/mark") or " ᵀᴼᴾ", -- 默认置顶标记
            max_scan = config:get_int("wubi_top/max_scan") or 30, -- 默认扫描30个词
            pin_file = u_dir .. "/pinned_" .. sid .. ".txt",
            del_file = u_dir .. "/deleted_" .. sid .. ".txt",
            pin_key = config:get_string("key_binder/pin_cand") or "Control+t",
            del_key = config:get_string("key_binder/del_cand") or "Control+d"
        }
    end
    return schema_caches[sid]
end

-- [全自动抗造加载]：支持单行多词，且自动忽略格式错误的行
local function load_all(env)
    local cache = get_cache(env)
    local function parse_combined_file(path, is_pin)
        local f = io.open(path, "r")
        if not f then return end -- 文件不存在就直接跳过，不报任何错
        
        for line in f:lines() do
            local parts = {}
            -- 这里改用更强的匹配模式：自动跳过空格和奇怪的字符
            for part in line:gmatch("[^\t\r\n]+") do
                table.insert(parts, part)
            end
            
            -- 只有当这一行有“编码”和“词条”时才处理
            if #parts >= 2 then
                local code = parts[1]:gsub("%s+", "") -- 剔除编码里不小心打进去的空格
                for i = 2, #parts do
                    local text = parts[i]:gsub("%s+", "") -- 剔除词条里不小心打进去的空格
                    if text ~= "" then
                        local uk = text .. code
                        if is_pin then
                            table.insert(cache.p_list, {text = text, code = code})
                            if not cache.p_index[code] then cache.p_index[code] = {} end
                            table.insert(cache.p_index[code], text)
                            cache.p_set[uk] = true
                        else
                            cache.d_set[uk] = true
                        end
                    end
                end
            end
        end
        f:close()
    end
    
    parse_combined_file(cache.pin_file, true)
    parse_combined_file(cache.del_file, false)
    cache.loaded = true
end

-- 【按键处理器】：负责记录你的 Ctrl+t 或 Ctrl+d 操作
local function processor(key, env)
    local context = env.engine.context
    if not context:is_composing() then return 2 end
    local cache = get_cache(env)
    if not cache.loaded then load_all(env) end
    
    local cand = context:get_selected_candidate()
    if not cand then return 2 end
    
    local key_repr = key:repr()
    local code = context.input

    -- 屏蔽逻辑：Ctrl+d
    if key_repr == cache.del_key then
        local pk = cand.text .. code
        if not cache.d_set[pk] then
            cache.d_set[pk] = true
            local f = io.open(cache.del_file, "a")
            if f then f:write(code .. "\t" .. cand.text .. "\n"); f:close() end
        end
        context:refresh_non_confirmed_composition()
        return 1
    end

    -- 置顶逻辑：Ctrl+t (自动合并同编码的词条到一行)
    if key_repr == cache.pin_key then
        local uk = cand.text .. code
        state.pending_text, state.needs_fix = cand.text, true 
        
        if cache.p_set[uk] then
            -- 如果已经置顶，则移除
            cache.p_set[uk] = nil
            for i, v in ipairs(cache.p_list) do 
                if v.text == cand.text and v.code == code then table.remove(cache.p_list, i) break end 
            end
            if cache.p_index[code] then
                for i, t in ipairs(cache.p_index[code]) do
                    if t == cand.text then table.remove(cache.p_index[code], i) break end
                end
            end
        else
            -- 如果没置顶，则加入
            table.insert(cache.p_list, {text = cand.text, code = code})
            if not cache.p_index[code] then cache.p_index[code] = {} end
            table.insert(cache.p_index[code], cand.text)
            cache.p_set[uk] = true
        end
        
        -- 全量写回文件：保持“编码 <Tab> 词1 <Tab> 词2”格式
        local f = io.open(cache.pin_file, "w")
        if f then
            local seen_code = {}
            for _, v in ipairs(cache.p_list) do
                if not seen_code[v.code] then
                    local line = v.code
                    if cache.p_index[v.code] then
                        for _, t in ipairs(cache.p_index[v.code]) do
                            line = line .. "\t" .. t
                        end
                        f:write(line .. "\n")
                    end
                    seen_code[v.code] = true
                end
            end
            f:close()
        end
        context:refresh_non_confirmed_composition()
        return 1
    end
    return 2
end

-- 【词条过滤器】：负责重新排列展示给你的词
local function filter(input, env)
    local cache, context = get_cache(env), env.engine.context
    local code = context.input
    if not cache.loaded then load_all(env) end

    local pinned_map, others, yijian_cand, count = {}, {}, nil, 0
    local is_yijian = (#code == 1 and YIJIAN[code])
    local has_pinned = cache.p_index[code] ~= nil

    -- [核心扫描环]：分类所有符合条件的词条
    for cand in input:iter() do
        local pk = cand.text .. code
        local is_this_yijian = (is_yijian and cand.text == YIJIAN[code])
        local is_this_pinned = has_pinned and cache.p_set[pk]

        if not cache.d_set[pk] or is_this_yijian or is_this_pinned then
            if is_this_yijian then
                yijian_cand = cand
            elseif is_this_pinned then
                pinned_map[pk] = cand
            else
                table.insert(others, cand)
            end
        end
        if #others >= cache.max_scan then break end
    end

    -- 按优先级倒出：1.一简词 -> 2.置顶词 -> 3.普通词
    if yijian_cand then yield(yijian_cand); count = count + 1 end 
    
    if has_pinned then
        for _, t in ipairs(cache.p_index[code]) do
            local co = pinned_map[t .. code]
            if co and not (is_yijian and t == YIJIAN[code]) then
                yield(Candidate(co.type, co.start, co._end, t, co.comment .. cache.mark))
                count = count + 1
            end
        end
    end

    for i = 1, #others do yield(others[i]); count = count + 1 end 
    for cand in input:iter() do yield(cand) end

    -- 焦点同步：置顶后，选中框依然在原来的词上
    if state.needs_fix then
        local menu = context.menu
        for i = 0, count do
            local c = menu:get_candidate_at(i)
            if c and c.text == state.pending_text then context.selected_index = i break end
        end
        state.needs_fix = false
    end
end

return { processor = processor, filter = filter }