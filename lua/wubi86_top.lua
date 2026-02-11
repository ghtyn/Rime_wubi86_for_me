
local schema_caches = {}
local state = { pending_text = "", needs_fix = false }

local YIJIAN = {
    g="一", f="地", d="在", s="要", a="工", 
    h="上", j="是", k="中", l="国", m="同", 
    n="民", b="了", v="发", c="以", x="经", 
    t="和", r="的", e="有", w="人", q="我", 
    y="主", u="产", i="不", o="为", p="这"
}

local function is_yijian_word(code, text)
    return #code == 1 and YIJIAN[code] == text
end

local function get_cache(env)
    local sid = env.engine.schema.schema_id
    if not schema_caches[sid] then
        local config = env.engine.schema.config
        local u_dir  = rime_api.get_user_data_dir()
        schema_caches[sid] = { 
            p_list = {}, p_set = {}, d_set = {}, p_index = {}, loaded = false,
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
    local f = io.open(cache.pin_file, "w")
    if not f then return end
    local seen = {}
    for i = 1, #cache.p_list do
        local code = cache.p_list[i].code
        if not seen[code] then
            local row = { code }
            local texts = cache.p_index[code]
            for j = 1, #texts do table.insert(row, texts[j]) end
            f:write(table.concat(row, "\t") .. "\n")
            seen[code] = true
        end
    end
    f:close()
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
                    if is_pin then
                        table.insert(cache.p_list, {text = text, code = code})
                        if not cache.p_index[code] then cache.p_index[code] = {} end
                        table.insert(cache.p_index[code], text)
                        cache.p_set[text .. code] = true
                    else cache.d_set[text .. code] = true end
                end
            end
        end
        f:close()
    end
    parse(cache.pin_file, true); parse(cache.del_file, false)
    cache.loaded = true
end

-- 【新增部分】翻译器逻辑：将置顶文件里的词直接注入候选流
function translator(input, seg, env)
    local cache = get_cache(env)
    if not cache.loaded then load_all(env) end
    
    local p_texts = cache.p_index[input]
    if p_texts then
        for i = 1, #p_texts do
            -- 构造虚拟候选词，标记为 "pinned" 类型供 filter 识别
            local cand = Candidate("pinned", seg.start, seg._end, p_texts[i], "")
            yield(cand)
        end
    end
end

function processor(key, env)
    local context, cache = env.engine.context, get_cache(env)
    if not cache.loaded then load_all(env) end
    if not context:is_composing() then return 2 end
    
    local cand = context:get_selected_candidate()
    if not cand then return 2 end
    local key_repr = key:repr()
    local code = context.input

    if key_repr == cache.pin_key then
        if is_yijian_word(code, cand.text) then return 1 end
        local uk = cand.text .. code
        state.pending_text, state.needs_fix = cand.text, true 
        if cache.p_set[uk] then
            cache.p_set[uk] = nil
            for i = #cache.p_list, 1, -1 do
                if cache.p_list[i].text == cand.text and cache.p_list[i].code == code then table.remove(cache.p_list, i); break end 
            end
            local ilist = cache.p_index[code]
            for i = #ilist, 1, -1 do if ilist[i] == cand.text then table.remove(ilist, i); break end end
        else
            table.insert(cache.p_list, {text = cand.text, code = code})
            if not cache.p_index[code] then cache.p_index[code] = {} end
            table.insert(cache.p_index[code], cand.text); cache.p_set[uk] = true
        end
        save_pinned(cache); context:refresh_non_confirmed_composition(); return 1
    elseif key_repr == cache.del_key then
        local uk = cand.text .. code
        if is_yijian_word(code, cand.text) or cache.p_set[uk] then return 1 end
        cache.d_set[uk] = true
        local f = io.open(cache.del_file, "a")
        if f then f:write(code .. "\t" .. cand.text .. "\n"); f:close() end
        context:refresh_non_confirmed_composition(); return 1
    end
    return 2
end

function filter(input, env)
    local cache, context = get_cache(env), env.engine.context
    local code = context.input
    local pinned_map, others, yijian_cand, count = {}, {}, nil, 0
    local is_yijian = (#code == 1 and YIJIAN[code])
    
    -- 核心：排重。因为 translator 已经注入了置顶词，原码表可能也会出同一个词。
    local yielded_pinned = {}

    for cand in input:iter() do
        local t, pk = cand.text, cand.text .. code
        if not cache.d_set[pk] then
            if is_yijian and t == YIJIAN[code] then 
                yijian_cand = cand
            elseif cache.p_set[pk] then 
                if not yielded_pinned[pk] then
                    pinned_map[pk] = cand
                    yielded_pinned[pk] = true
                end
            else
                others[#others + 1] = cand
                if #others >= cache.max_scan then break end
            end
        end
    end

    if yijian_cand then yield(yijian_cand); count = count + 1 end 
    
    if cache.p_index[code] then
        for i = 1, #cache.p_index[code] do
            local t = cache.p_index[code][i]
            local pk = t .. code
            local co = pinned_map[pk]
            -- 如果 co 存在说明是码表里有的，直接净化标记输出
            -- 如果 co 不存在说明码表里没这个词，我们手动创建一个 Candidate 输出
            if co then
                yield(Candidate(co.type, co.start, co._end, t, cache.mark))
            else
                yield(Candidate("pinned", 0, #code, t, cache.mark))
            end
            count = count + 1
        end
    end
    
    for i = 1, #others do yield(others[i]); count = count + 1 end 
    for cand in input:iter() do yield(cand) end

    if state.needs_fix then
        local menu = context.menu
        for i = 0, count do
            local c = menu:get_candidate_at(i)
            if c and c.text == state.pending_text then context.selected_index = i; break end
        end
        state.needs_fix = false
    end
end

return { processor = processor, filter = filter, translator = translator }