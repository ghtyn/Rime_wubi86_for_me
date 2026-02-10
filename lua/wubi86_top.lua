-- lua/wubi86_top.lua
-- ============================================================================
-- 86五笔集成工具箱：置顶 (Pin) / 屏蔽 (Delete) / 一简固词 (Fixed)
-- ============================================================================

-- [配置参数]
local CONFIG = {
    mark = " ᵀᴼᴾ",      -- 置顶词条后缀标记
    max_scan = 30,      -- 过滤器最大扫描候选项数量
}

-- [一级简码静态映射]
local YIJIAN = {
    g="一", f="地", d="在", s="要", a="工", 
    h="上", j="是", k="中", l="国", m="同", 
    n="民", b="了", v="发", c="以", x="经", 
    t="和", r="的", e="有", w="人", q="我", 
    u="产", i="不", o="为", p="这", y="主"
}

local schema_caches = {} 
local state = { needs_fix = false, pending_text = "" }

-- 获取方案配置缓存、路径及按键绑定
local function get_cache(env)
    local sid = env.engine.schema.schema_id
    if not schema_caches[sid] then
        local config = env.engine.schema.config
        local u_dir = rime_api.get_user_data_dir()
        schema_caches[sid] = { 
            p_list = {}, p_set = {}, d_set = {}, loaded = false,
            pin_file = u_dir .. "/pinned_" .. sid .. ".txt",
            del_file = u_dir .. "/deleted_" .. sid .. ".txt",
            -- 从 key_binder/pin_cand 获取自定义快捷键变量
            pin_key = config:get_string("key_binder/pin_cand") or "Control+t",
            del_key = config:get_string("key_binder/del_cand") or "Control+d"
        }
    end
    return schema_caches[sid]
end

-- 加载持久化数据（Tab分隔格式：词条 \t 编码）
local function load_all(env)
    local cache = get_cache(env)
    local function parse_file(path, target_set, target_list)
        local f = io.open(path, "r")
        if f then
            for line in f:lines() do
                local t, c = line:match("^(.-)%s+([%a%d]+)$")
                if t and c then
                    if target_list then table.insert(target_list, {text = t, code = c}) end
                    target_set[t .. c] = true
                end
            end
            f:close()
        end
    end
    parse_file(cache.pin_file, cache.p_set, cache.p_list)
    parse_file(cache.del_file, cache.d_set)
    cache.loaded = true
end

-- ============================================================================
-- 处理器 (Processor)：按键事件拦截与持久化操作
-- ============================================================================
local function processor(key, env)
    local context = env.engine.context
    if not context:is_composing() then return 2 end
    local cache = get_cache(env)
    if not cache.loaded then load_all(env) end
    
    local cand = context:get_selected_candidate()
    if not cand then return 2 end
    
    local key_repr = key:repr()
    local code = context.input

    -- 屏蔽逻辑：同步更新内存并追加写入磁盘
    if key_repr == cache.del_key then
        local pk = cand.text .. code
        cache.d_set[pk] = true
        local f = io.open(cache.del_file, "a")
        if f then f:write(cand.text .. "\t" .. code .. "\n"); f:close() end
        context:refresh_non_confirmed_composition()
        return 1
    end

    -- 置顶/取消置顶逻辑：同步内存并全量改写磁盘
    if key_repr == cache.pin_key then
        local uk = cand.text .. code
        -- 记录待操作词条用于后续焦点同步
        state.pending_text, state.needs_fix = cand.text, true 
        if cache.p_set[uk] then
            cache.p_set[uk] = nil
            for i, v in ipairs(cache.p_list) do 
                if v.text == cand.text and v.code == code then table.remove(cache.p_list, i) break end 
            end
        else
            table.insert(cache.p_list, {text = cand.text, code = code})
            cache.p_set[uk] = true
        end
        local f = io.open(cache.pin_file, "w")
        if f then
            for _, v in ipairs(cache.p_list) do f:write(v.text .. "\t" .. v.code .. "\n") end
            f:close()
        end
        context:refresh_non_confirmed_composition()
        return 1
    end
    return 2
end

-- ============================================================================
-- 过滤器 (Filter)：候选项重排与黑名单拦截
-- ============================================================================
local function filter(input, env)
    local cache, context = get_cache(env), env.engine.context
    local code = context.input
    if not cache.loaded then load_all(env) end

    local pinned_map, others, yijian_cand, count = {}, {}, nil, 0
    local is_yijian = (#code == 1 and YIJIAN[code])

    -- [阶段1] 分类与拦截：遍历候选项流并进行归类
    for cand in input:iter() do
        local pk = cand.text .. code
        local is_this_yijian = (is_yijian and cand.text == YIJIAN[code])
        local is_pinned = cache.p_set[pk]

        -- 拦截黑名单（一简与置顶词拥有豁免权）
        if not cache.d_set[pk] or is_this_yijian or is_pinned then
            if is_this_yijian then
                yijian_cand = cand
            elseif is_pinned then
                pinned_map[pk] = cand
            else
                table.insert(others, cand)
            end
        end
        -- 限制扫描深度
        if #others >= CONFIG.max_scan then break end
    end

    -- [阶段2] 顺序输出：一简 > 置顶词 > 普通词
    -- 1. 输出一级简码
    if yijian_cand then yield(yijian_cand); count = count + 1 end 
    -- 2. 输出置顶词列表
    for i = 1, #cache.p_list do 
        local v = cache.p_list[i]
        if v.code == code then
            local c = pinned_map[v.text .. code]
            -- 排除一简字防止重复，仅输出词库内存在的置顶词
            if c and not (is_yijian and v.text == YIJIAN[code]) then
                yield(Candidate(c.type, c.start, c._end, c.text, c.comment .. CONFIG.mark))
                count = count + 1
            end
        end
    end
    -- 3. 输出其他扫描到的普通词
    for i = 1, #others do yield(others[i]); count = count + 1 end 
    -- 4. 吐出剩余原始流
    for cand in input:iter() do yield(cand) end

    -- [阶段3] 焦点校正：重置选词光标位置
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