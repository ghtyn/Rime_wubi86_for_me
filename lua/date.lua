-- lua/date.lua
local function translator(input, seg, env)
    local now = os.time() 

    -- 1. 输入日期 (date 或 rq)
    if (input == "date" or input == "rq") then
        local formats = {"%Y-%m-%d", "%Y年%m月%d日", "%Y.%m.%d", "%Y/%m/%d", "%Y%m%d"}
        for _, fmt in ipairs(formats) do
            yield(Candidate("date", seg.start, seg._end, os.date(fmt, now), ""))
        end
    end

    -- 2. 输入时间 (time 或 sj)
    if (input == "time" or input == "sj") then
        yield(Candidate("time", seg.start, seg._end, os.date("%H:%M", now), ""))
        yield(Candidate("time", seg.start, seg._end, os.date("%H:%M:%S", now), ""))
        yield(Candidate("time", seg.start, seg._end, os.date("%H时%M分", now), ""))
    end

    -- 3. 输入星期 (week 或 xq)
    if (input == "week" or input == "xq") then
        local weakTab = {'日', '一', '二', '三', '四', '五', '六'}
        local w = os.date("%w", now) + 1
        yield(Candidate("week", seg.start, seg._end, "周" .. weakTab[w], ""))
        yield(Candidate("week", seg.start, seg._end, "星期" .. weakTab[w], ""))
        yield(Candidate("week", seg.start, seg._end, os.date("%A", now), ""))
    end

    -- 4. 输入月份 (month 或 yf)
    if (input == "month" or input == "yf") then
        local m_num = tonumber(os.date("%m", now))
        local ChineseTab = {'一', '二', '三', '四', '五', '六', '七', '八', '九', '十', '十一', '十二'}
        yield(Candidate("month", seg.start, seg._end, m_num .. "月", ""))
        yield(Candidate("month", seg.start, seg._end, ChineseTab[m_num] .. "月", ""))
        yield(Candidate("month", seg.start, seg._end, os.date("%B", now), ""))
        yield(Candidate("month", seg.start, seg._end, os.date("%b", now), ""))
    end
end

return translator
