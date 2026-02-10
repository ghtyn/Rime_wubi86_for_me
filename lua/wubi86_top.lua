local schema_caches = {}
local state = { pending_text = "", needs_fix = false }

-- 1. 配置区：一简映射（保持不变）
local YIJIAN = {
    g="一", f="地", d="在", s="要", a="工", h="上", j="是", k="中", l="国", m="同", 
    n="民", b="了", v="发", c="以", x="经", t="和", r="的", e="有", w="人", q="我", 
    y="主", u="产", i="不", o="为", p="这"
}

local function get_cache(env)
    local sid = env.engine.schema.schema_id
    if not schema_caches[sid] then
        local config = env.engine.schema.config
        local u_dir  = rime_api.get_user_data_dir()
        schema_caches[sid] = { 
            p_list = {}, p_set = {}, d_set = {}, p_index = {}, loaded = false, dirty = false,
            mark     = config:get_string("wubi86_top/mark") or " ᵀᴼᴾ",
            max_scan = config:get_int("wubi86_top/max_scan") or 30,
            pin_key  = config:get_string("wubi86_top/pin_key") or "Control+t",
            del_key  = config:get_string("wubi86_top/del_key") or "Control+d",
            pin_file = u_dir .. "/pinned_"  .. sid .. ".txt",
            del_file = u_dir .. "/deleted_" .. sid .. ".txt"
        }
    end
    return schema_caches[sid]
end

local function save_pinned(cache)
    if not cache.dirty then return end
    local f = io.open(cache.pin_file, "w")
    if not f then return end
    local seen_code = {}
    for i = 1, #cache.p_list do
        local code = cache.p_list[i].code
        if not seen_code[code] then
            local texts = cache.p_index[code]
            if texts and #texts > 0 then
                f:write(code .. "\t" .. table.concat(texts, "\t") .. "\n")
            end
            seen_code[code] = true
        end
    end
    f:close()
    cache.dirty = false
end

local function load_all(env)
    local cache = get_cache(env)
    local function parse(path, is_pin)
        local f = io.open(path, "r")
        if not f then return end
        for line in f:lines() do
            local parts = {}
            for part in line:gmatch("[^\t\r\n]+") do table.insert(parts, part) end
            if #parts >= 2 then
                local code = parts[1]
                for i = 2, #parts do
                    local text = parts[i]
                    local uk = text .. code
                    if is_pin then
                        if not cache.p_set[uk] then
                            table.insert(cache.p_list, {text = text, code = code})
                            if not cache.p_index[code] then cache.p_index[code] = {} end
                            table.insert(cache.p_index[code], text)
                            cache.p_set[uk] = true
                        end
                    else cache.d_set[uk] = true end
                end
            end
        end
        f:close()
    end
    parse(cache.pin_file, true); parse(cache.del_file, false)
    cache.loaded = true
end

-- 处理器逻辑
local function processor(key, env)
    local context, cache = env.engine.context, get_cache(env)
    if not cache.loaded then load_all(env) end
    if not context:is_composing() then return 2 end
    
    local cand = context:get_selected_candidate()
    if not cand then return 2 end
    local key_repr = key:repr()

    if key_repr == cache.pin_key then
        if #context.input == 1 and YIJIAN[context.input] == cand.text then return 1 end
        local code, uk = context.input, cand.text .. context.input
        state.pending_text, state.needs_fix = cand.text, true 
        cache.dirty = true
        
        if cache.p_set[uk] then
            cache.p_set[uk] = nil
            for i = #cache.p_list, 1, -1 do
                if cache.p_list[i].text == cand.text and cache.p_list[i].code == code then 
                    table.remove(cache.p_list, i) 
                    break 
                end 
            end
            local ilist = cache.p_index[code]
            if ilist then
                for i = #ilist, 1, -1 do 
                    if ilist[i] == cand.text then table.remove(ilist, i); break end 
                end
            end
        else
            table.insert(cache.p_list, {text = cand.text, code = code})
            if not cache.p_index[code] then cache.p_index[code] = {} end
            table.insert(cache.p_index[code], cand.text)
            cache.p_set[uk] = true
        end
        save_pinned(cache)
        context:refresh_non_confirmed_composition()
        return 1
    elseif key_repr == cache.del_key then
        if #context.input == 1 and YIJIAN[context.input] == cand.text then return 1 end
        local uk = cand.text .. context.input
        if cache.p_set[uk] then return 1 end 
        cache.d_set[uk] = true
        local f = io.open(cache.del_file, "a")
        if f then f:write(context.input .. "\t" .. cand.text .. "\n"); f:close() end
        context:refresh_non_confirmed_composition()
        return 1
    end
    return 2
end

-- 过滤器逻辑
local function filter(input, env)
    local cache, context = get_cache(env), env.engine.context
    local code = context.input
    local is_yijian = (#code == 1 and YIJIAN[code])
    local p_texts = cache.p_index[code]
    
    local pinned_cands = {}
    local others = {}
    local yijian_cand = nil
    local yielded_set = {}
    local count = 0

    -- 1. 预扫描及分类
    for cand in input:iter() do
        local t = cand.text
        local pk = t .. code
        if not cache.d_set[pk] then
            if is_yijian and t == is_yijian then
                yijian_cand = cand
            elseif cache.p_set[pk] then
                if not pinned_cands[t] then pinned_cands[t] = cand end
            else
                table.insert(others, cand)
            end
        end
        if #others >= cache.max_scan then break end
    end

    -- 2. 顺序输出
    -- 第一：一简
    if yijian_cand then 
        yield(yijian_cand)
        yielded_set[yijian_cand.text] = true
        count = count + 1 
    end 
    
    -- 第二：置顶词
    if p_texts then
        for i = 1, #p_texts do
            local t = p_texts[i]
            if not yielded_set[t] then
                local co = pinned_cands[t]
                if co then
                    yield(Candidate(co.type, co.start, co._end, t, cache.mark))
                    yielded_set[t] = true
                    count = count + 1
                end
            end
        end
    end
    
    -- 第三：普通候选
    for i = 1, #others do
        local cand = others[i]
        if not yielded_set[cand.text] then
            yield(cand)
            yielded_set[cand.text] = true
            count = count + 1
        end
    end

    -- 3. 补齐剩余（流式输出，确保不丢词）
    for cand in input:iter() do
        if not yielded_set[cand.text] and not cache.d_set[cand.text .. code] then
            yield(cand)
        end
    end

    -- 4. 视觉焦点修正
    if state.needs_fix then
        local menu = context.menu
        for i = 0, count + 5 do 
            local c = menu:get_candidate_at(i)
            if c and c.text == state.pending_text then 
                context.selected_index = i
                break 
            end
        end
        state.needs_fix = false
    end
end

-- 重要：显式导出补丁中使用的函数名
return { 
    processor = processor, 
    filter = filter 
}