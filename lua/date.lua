-- lua/date.lua
local function translator(input, seg, env)
    local now = os.time()

    local start_pos = seg.start
    local end_pos = seg._end  -- 小狼毫下这是稳定可用的

    -- 1. 输入日期 (date 或 rq)
    if input == "date" or input == "rq" then
        local formats = {
            "%Y-%m-%d",
            "%Y年%m月%d日",
            "%Y.%m.%d",
            "%Y/%m/%d",
            "%Y%m%d"
        }
        for i = 1, #formats do
            yield(Candidate(
                "date",
                start_pos,
                end_pos,
                os.date(formats[i], now),
                ""
            ))
        end
    end

    -- 2. 输入时间 (time 或 sj)
    if input == "time" or input == "sj" then
        yield(Candidate("time", start_pos, end_pos, os.date("%H:%M", now), ""))
        yield(Candidate("time", start_pos, end_pos, os.date("%H:%M:%S", now), ""))
        yield(Candidate("time", start_pos, end_pos, os.date("%H时%M分", now), ""))
    end

    -- 3. 输入星期 (week 或 xq)
    if input == "week" or input == "xq" then
        local weekTab = {'日', '一', '二', '三', '四', '五', '六'}
        local w = tonumber(os.date("%w", now)) + 1
        yield(Candidate("week", start_pos, end_pos, "周" .. weekTab[w], ""))
        yield(Candidate("week", start_pos, end_pos, "星期" .. weekTab[w], ""))
        yield(Candidate("week", start_pos, end_pos, os.date("%A", now), ""))
    end

    -- 4. 输入月份 (month 或 yf)
    if input == "month" or input == "yf" then
        local m = tonumber(os.date("%m", now))
        local cnMonth = {'一','二','三','四','五','六','七','八','九','十','十一','十二'}
        yield(Candidate("month", start_pos, end_pos, m .. "月", ""))
        yield(Candidate("month", start_pos, end_pos, cnMonth[m] .. "月", ""))
        yield(Candidate("month", start_pos, end_pos, os.date("%B", now), ""))
        yield(Candidate("month", start_pos, end_pos, os.date("%b", now), ""))
    end
end

return translator
