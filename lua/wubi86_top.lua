local schema_caches = {}
local state = { pending_text = "", needs_fix = false }

-- 一简映射（保护用）
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
            p_list = {}, p_index = {}, p_set = {}, d_set = {}, 
            yijian_index = {}, loaded = false,
            mark     = config:get_string("wubi86_top/mark") or " ᵀᴼᴾ",
            max_scan = config:get_int("wubi86_top/max_scan") or 30,
            pin_key  = config:get_string("wubi86_top/pin_key") or "Control+t",
            del_key  = config:get_string("wubi86_top/del_key") or "Control+d",
            pin_file = u_dir .. "/pinned_"  .. sid .. ".txt",
            del_file = u_dir .. "/deleted_" .. sid .. ".txt",
            dirty    = false,
            deleted_dirty = false,
            deleted_buffer = {}
        }
        for code, text in pairs(YIJIAN) do
            schema_caches[sid].yijian_index[code] = text
        end
    end
    return schema_caches[sid]
end

-- 保存置顶词
local function save_pinned(cache)
    if not cache.dirty then return end
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
    cache.dirty = false
end

-- 延迟写屏蔽词
local function save_deleted(cache)
    if not cache.deleted_dirty then return end
    local f = io.open(cache.del_file, "a")
    if not f then return end
    for text,_ in pairs(cache.deleted_buffer) do
        f:write("\t" .. text .. "\n")
    end
    f:close()
    cache.deleted_buffer = {}
    cache.deleted_dirty = false
end

local function load_all(env)
    local cache = get_cache(env)
    if cache.loaded then return end
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
                        table.insert(cache.p_list, {text=text, code=code})
                        if not cache.p_index[code] then cache.p_index[code] = {} end
                        table.insert(cache.p_index[code], text)
                        cache.p_set[text..code] = true
                    else
                        cache.d_set[text] = true
                    end
                end
            end
        end
        f:close()
    end
    parse(cache.pin_file, true)
    parse(cache.del_file, false)
    cache.loaded = true
end

-- translator
function translator(input, seg, env)
    local cache = get_cache(env)
    if not cache.loaded then load_all(env) end
    local p_texts = cache.p_index[input]
    if p_texts then
        for i=1,#p_texts do
            local text = p_texts[i]
            if not cache.d_set[text] then
                yield(Candidate("pinned", seg.start, seg._end, text, cache.mark))
            end
        end
    end
end

-- processor
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
        local uk = cand.text..code
        state.pending_text, state.needs_fix = cand.text, true
        if cache.p_set[uk] then
            cache.p_set[uk] = nil
            for i=#cache.p_list,1,-1 do
                if cache.p_list[i].text==cand.text and cache.p_list[i].code==code then table.remove(cache.p_list,i); break end
            end
            local ilist = cache.p_index[code]
            for i=#ilist,1,-1 do if ilist[i]==cand.text then table.remove(ilist,i); break end end
        else
            table.insert(cache.p_list,{text=cand.text, code=code})
            if not cache.p_index[code] then cache.p_index[code]={} end
            table.insert(cache.p_index[code], cand.text)
            cache.p_set[uk]=true
        end
        cache.dirty = true
        save_pinned(cache)
        context:refresh_non_confirmed_composition()
        return 1
    elseif key_repr == cache.del_key then
        if is_yijian_word(code, cand.text) then return 1 end
        cache.d_set[cand.text] = true
        cache.deleted_buffer[cand.text]=true
        cache.deleted_dirty = true
        save_deleted(cache)
        context:refresh_non_confirmed_composition()
        return 1
    end
    return 2
end

-- filter
function filter(input, env)
    local cache, context = get_cache(env), env.engine.context
    if not cache.loaded then load_all(env) end
    local code = context.input
    local yielded_set = {}
    local count = 0

    -- 一简优先
    if #code==1 and YIJIAN[code] then
        local t = YIJIAN[code]
        if not cache.d_set[t] then
            yield(Candidate("yijian",0,#code,t,""))
            yielded_set[t]=true
            count=count+1
        end
    end

    -- yield 置顶
    local p_texts = cache.p_index[code] or {}
    for i=1,#p_texts do
        local t = p_texts[i]
        if not cache.d_set[t] and not yielded_set[t] then
            yield(Candidate("pinned",0,#code,t,cache.mark))
            yielded_set[t]=true
            count=count+1
        end
    end

    -- 收集 others
    local others = {}
    local scan_count=0
    for cand in input:iter() do
        local t = cand.text
        if not cache.d_set[t] and not yielded_set[t] then
            table.insert(others,cand)
            yielded_set[t]=true
            count=count+1
            scan_count=scan_count+1
            if scan_count>=cache.max_scan then break end
        end
    end

    for i=1,#others do yield(others[i]) end

    if state.needs_fix then
        local menu = context.menu
        for i=0,count do
            local c = menu:get_candidate_at(i)
            if c and c.text==state.pending_text then context.selected_index=i; break end
        end
        state.needs_fix=false
    end
end

return { processor=processor, filter=filter, translator=translator }