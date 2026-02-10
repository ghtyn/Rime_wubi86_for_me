-- ============================================================================
-- 86五笔集成工具箱 (极致稳健版)
-- 功能：
--   1. 一级简码固词 (根据 YIJIAN 表强制首选)
--   2. 词条置顶 (Ctrl+t): 支持多词置顶，并在候选词后添加标记
--   3. 词条屏蔽 (Ctrl+d): 屏蔽词条，且【置顶词受保护】不可被屏蔽
-- ============================================================================

local schema_caches = {}
-- 全局状态：用于处理置顶后的焦点自动回跳
local state = { pending_text = "", needs_fix = false }

-- ----------------------------------------------------------------------------
-- 配置区：一级简码映射表 (可根据个人习惯修改引号内的汉字)
-- ----------------------------------------------------------------------------
local YIJIAN = {
    g="一", f="地", d="在", s="要", a="工", 
    h="上", j="是", k="中", l="国", m="同", 
    n="民", b="了", v="发", c="以", x="经", 
    t="和", r="的", e="有", w="人", q="我", 
    y="主", u="产", i="不", o="为", p="这"
}

-- ----------------------------------------------------------------------------
-- 内部函数：获取配置、加载/保存持久化文件
-- ----------------------------------------------------------------------------

-- 获取当前方案的配置和文件路径
local function get_cache(env)
    local sid = env.engine.schema.schema_id
    if not schema_caches[sid] then
        local config = env.engine.schema.config
        local u_dir  = rime_api.get_user_data_dir()
        schema_caches[sid] = { 
            p_list = {}, p_set = {}, d_set = {}, p_index = {}, loaded = false,
            -- 从 YAML 读取参数，若无则使用默认值
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

-- 将置顶列表写入文件
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

-- 启动时加载已有的置顶和屏蔽数据
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

-- ----------------------------------------------------------------------------
-- 处理器 (Processor)：监听快捷键按键
-- ----------------------------------------------------------------------------
function processor(key, env)
    local context, cache = env.engine.context, get_cache(env)
    if not cache.loaded then load_all(env) end
    
    -- 如果当前没在打字，不处理按键
    if not context:is_composing() then return 2 end
    
    local cand = context:get_selected_candidate()
    if not cand then return 2 end
    local key_repr = key:repr()

    -- 【置顶逻辑】
    if key_repr == cache.pin_key then
        local code, uk = context.input, cand.text .. context.input
        state.pending_text, state.needs_fix = cand.text, true 
        if cache.p_set[uk] then
            -- 如果已置顶，则取消置顶
            cache.p_set[uk] = nil
            for i = #cache.p_list, 1, -1 do
                if cache.p_list[i].text == cand.text and cache.p_list[i].code == code then table.remove(cache.p_list, i); break end 
            end
            local ilist = cache.p_index[code]
            for i = #ilist, 1, -1 do if ilist[i] == cand.text then table.remove(ilist, i); break end end
        else
            -- 如果未置顶，则加入置顶
            table.insert(cache.p_list, {text = cand.text, code = code})
            if not cache.p_index[code] then cache.p_index[code] = {} end
            table.insert(cache.p_index[code], cand.text); cache.p_set[uk] = true
        end
        save_pinned(cache)
        context:refresh_non_confirmed_composition() -- 刷新候选列表
        return 1 -- 消耗此按键，不继续下传
    
    -- 【屏蔽逻辑】
    elseif key_repr == cache.del_key then
        local uk = cand.text .. context.input
        -- 核心保护：如果此词已经在置顶名单，直接返回，不准屏蔽
        if cache.p_set[uk] then return 1 end 
        
        -- 加入屏蔽黑名单
        cache.d_set[uk] = true
        local f = io.open(cache.del_file, "a")
        if f then f:write(context.input .. "\t" .. cand.text .. "\n"); f:close() end
        context:refresh_non_confirmed_composition()
        return 1
    end
    return 2
end

-- ----------------------------------------------------------------------------
-- 过滤器 (Filter)：重新排列候选词顺序
-- ----------------------------------------------------------------------------
function filter(input, env)
    local cache, context = get_cache(env), env.engine.context
    local code = context.input
    local pinned_map, others, yijian_cand, count = {}, {}, nil, 0
    local is_yijian, p_texts = (#code == 1 and YIJIAN[code]), cache.p_index[code]

    -- 第一步：将原始候选词分类
    for cand in input:iter() do
        local t, pk = cand.text, cand.text .. code
        -- 过滤掉黑名单中的词
        if not cache.d_set[pk] then
            if is_yijian and t == YIJIAN[code] then 
                yijian_cand = cand -- 命中一简
            elseif p_texts and cache.p_set[pk] then 
                pinned_map[pk] = cand -- 命中置顶
            else
                others[#others + 1] = cand -- 普通候选
                if #others >= cache.max_scan then break end
            end
        end
    end

    -- 第二步：按优先级顺序输出候选词
    -- 1. 输出一级简码
    if yijian_cand then yield(yijian_cand); count = count + 1 end 
    
    -- 2. 输出置顶词 (并带上标记)
    if p_texts then
        for i = 1, #p_texts do
            local t = p_texts[i]
            local co = pinned_map[t .. code]
            if co then 
                yield(Candidate(co.type, co.start, co._end, t, co.comment .. cache.mark))
                count = count + 1 
            end
        end
    end
    
    -- 3. 输出其他普通词
    for i = 1, #others do yield(others[i]); count = count + 1 end 
    
    -- 4. 输出剩余的所有词
    for cand in input:iter() do yield(cand) end

    -- 第三步：自动修复焦点位置
    -- 确保按完 Ctrl+t 后，光标依然停留在刚才操作的那个词上
    if state.needs_fix then
        local menu = context.menu
        for i = 0, count do
            local c = menu:get_candidate_at(i)
            if c and c.text == state.pending_text then context.selected_index = i; break end
        end
        state.needs_fix = false
    end
end

return { processor = processor, filter = filter }