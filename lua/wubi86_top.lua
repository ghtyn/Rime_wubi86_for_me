-- ============================================================================
-- 功能：一级简码固词 / 词条置顶 (Ctrl+t) / 词条屏蔽 (Ctrl+d)
-- 特性：单码单行存储、JIT 性能优化、异常容错处理
-- ============================================================================

local schema_caches = {} 
local state = { needs_fix = false, pending_text = "" }

-- ----------------------------------------------------------------------------
-- 1. 一级简码配置 (5个一组，最后一行已更正为：主产不为这)
-- ----------------------------------------------------------------------------
local YIJIAN = {
    g="一", f="地", d="在", s="要", a="工", 
    h="上", j="是", k="中", l="国", m="同", 
    n="民", b="了", v="发", c="以", x="经", 
    t="和", r="的", e="有", w="人", q="我", 
    y="主", u="产", i="不", o="为", p="这"
}

-- ----------------------------------------------------------------------------
-- 2. 环境初始化 (读取 YAML 配置与建立路径缓存)
-- ----------------------------------------------------------------------------
local function get_cache(env)
    local sid = env.engine.schema.schema_id
    if not schema_caches[sid] then
        local config = env.engine.schema.config
        local u_dir  = rime_api.get_user_data_dir()
        schema_caches[sid] = { 
            p_list   = {}, -- 置顶有序列表
            p_set    = {}, -- 置顶查重集合
            d_set    = {}, -- 屏蔽查重集合
            p_index  = {}, -- 编码->词条二级索引
            loaded   = false,
            mark     = config:get_string("wubi_top/mark") or " ᵀᴼᴾ",
            max_scan = config:get_int("wubi_top/max_scan") or 30,
            pin_file = u_dir .. "/pinned_"  .. sid .. ".txt",
            del_file = u_dir .. "/deleted_" .. sid .. ".txt",
            pin_key  = config:get_string("key_binder/pin_cand") or "Control+t",
            del_key  = config:get_string("key_binder/del_cand") or "Control+d"
        }
    end
    return schema_caches[sid]
end

-- ----------------------------------------------------------------------------
-- 3. 持久化层 (文件读取与写入，支持单码多词格式)
-- ----------------------------------------------------------------------------
local function load_all(env)
    local cache = get_cache(env)
    local function parse(path, is_pin)
        local f = io.open(path, "r")
        if not f then return end
        for line in f:lines() do
            local parts = {}
            for part in line:gmatch("[^\t\r\n]+") do parts[#parts + 1] = part end
            if #parts >= 2 then
                local code = parts[1]
                for i = 2, #parts do
                    local text = parts[i]
                    local uk = text .. code
                    if is_pin then
                        cache.p_list[#cache.p_list + 1] = {text = text, code = code}
                        if not cache.p_index[code] then cache.p_index[code] = {} end
                        local idx = cache.p_index[code]
                        idx[#idx + 1] = text
                        cache.p_set[uk] = true
                    else
                        cache.d_set[uk] = true
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

-- 高效保存函数 (采用 table.concat 减少内存碎片)
local function save_pinned(cache)
    local f = io.open(cache.pin_file, "w")
    if not f then return end
    local seen = {}
    for i = 1, #cache.p_list do
        local code = cache.p_list[i].code
        if not seen[code] then
            local row = { code }
            local texts = cache.p_index[code]
            for j = 1, #texts do row[#row + 1] = texts[j] end
            f:write(table.concat(row, "\t") .. "\n")
            seen[code] = true
        end
    end
    f:close()
end

-- ----------------------------------------------------------------------------
-- 4. 处理器 (Processor): 负责拦截按键，执行置顶/屏蔽动作
-- ----------------------------------------------------------------------------
function processor(key, env)
    local context = env.engine.context
    if not context:is_composing() then return 2 end
    local cache = get_cache(env)
    if not cache.loaded then load_all(env) end
    local cand = context:get_selected_candidate()
    if not cand then return 2 end
    
    local key_repr, code = key:repr(), context.input
    
    -- [屏蔽逻辑]
    if key_repr == cache.del_key then
        local pk = cand.text .. code
        if not cache.d_set[pk] then
            cache.d_set[pk] = true
            local f = io.open(cache.del_file, "a")
            if f then f:write(code .. "\t" .. cand.text .. "\n"); f:close() end
        end
        context:refresh_non_confirmed_composition()
        return 1
    
    -- [置顶逻辑]
    elseif key_repr == cache.pin_key then
        local uk = cand.text .. code
        state.pending_text, state.needs_fix = cand.text, true 
        if cache.p_set[uk] then
            cache.p_set[uk] = nil
            for i = #cache.p_list, 1, -1 do
                if cache.p_list[i].text == cand.text and cache.p_list[i].code == code then 
                    table.remove(cache.p_list, i) break 
                end 
            end
            local ilist = cache.p_index[code]
            for i = #ilist, 1, -1 do
                if ilist[i] == cand.text then table.remove(ilist, i) break end
            end
        else
            cache.p_list[#cache.p_list + 1] = {text = cand.text, code = code}
            if not cache.p_index[code] then cache.p_index[code] = {} end
            local idx = cache.p_index[code]
            idx[#idx + 1] = cand.text
            cache.p_set[uk] = true
        end
        save_pinned(cache)
        context:refresh_non_confirmed_composition()
        return 1
    end
    return 2
end

-- ----------------------------------------------------------------------------
-- 5. 过滤器 (Filter): 负责候选词重新排队与上色
-- ----------------------------------------------------------------------------
function filter(input, env)
    local cache = get_cache(env)
    local context = env.engine.context
    local code = context.input
    if not cache.loaded then load_all(env) end

    local pinned_map, others = {}, {}
    local yijian_cand, count = nil, 0
    local is_yijian = (#code == 1 and YIJIAN[code])
    local p_texts = cache.p_index[code]
    local has_pinned = (p_texts ~= nil)

    -- 缓存局部变量加速 JIT 访问
    local d_set, p_set, max_s = cache.d_set, cache.p_set, cache.max_scan

    -- [核心筛选循环]
    for cand in input:iter() do
        local t = cand.text
        local pk = t .. code
        
        if not d_set[pk] then
            if is_yijian and t == YIJIAN[code] then
                yijian_cand = cand
            elseif has_pinned and p_set[pk] then
                pinned_map[pk] = cand
            else
                others[#others + 1] = cand
                if #others >= max_s then break end
            end
        elseif is_yijian and t == YIJIAN[code] then -- 豁免逻辑
            yijian_cand = cand
        elseif has_pinned and p_set[pk] then        -- 豁免逻辑
            pinned_map[pk] = cand
        end
    end

    -- [第一优先级] 输出一级简码
    if yijian_cand then yield(yijian_cand); count = count + 1 end 
    
    -- [第二优先级] 输出置顶词条
    if has_pinned then
        for i = 1, #p_texts do
            local t = p_texts[i]
            local co = pinned_map[t .. code]
            if co and not (is_yijian and t == YIJIAN[code]) then
                yield(Candidate(co.type, co.start, co._end, t, co.comment .. cache.mark))
                count = count + 1
            end
        end
    end

    -- [第三优先级] 输出普通词库候选项
    for i = 1, #others do yield(others[i]); count = count + 1 end 
    
    -- [兜底逻辑] 吐出剩余流
    for cand in input:iter() do yield(cand) end

    -- [焦点同步] 防止置顶后选中框乱跳
    if state.needs_fix then
        local menu = context.menu
        for i = 0, count do
            local c = menu:get_candidate_at(i)
            if c and c.text == state.pending_text then 
                context.selected_index = i 
                break 
            end
        end
        state.needs_fix = false
    end
end

return { processor = processor, filter = filter }