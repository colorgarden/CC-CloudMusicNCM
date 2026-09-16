-- UTF-8 Display Library for ComputerCraft (完整修正版)
-- 文件名: utf8display.lua

local utf8display = {}

local DEFAULT_FONT_URL = "https://git.liulikeji.cn/xingluo/ComputerCraft-Utf8/raw/branch/main/fonts/fusion-pixel-8px-proportional-zh_hans.lua"

-- 配置参数
utf8display.config = {
    fontUrl = DEFAULT_FONT_URL,
    fontPath = nil,
    cacheFont = true,
    autoScroll = true
}

-- 内部状态
local state = {
    font = nil,
    fontHeight = 8,
    loadedFonts = {}
}

-- 字体管理模块
local fontManager = {}

function fontManager.loadRemoteFont(url)
    if state.loadedFonts[url] then
        return state.loadedFonts[url]
    end

    local response = http.get(url)
    if not response then
        return nil, "无法连接到字体服务器: " .. url
    end

    if response.getResponseCode() ~= 200 then
        return nil, "字体服务器返回错误: " .. response.getResponseCode()
    end

    local content = response.readAll()
    response.close()

    local sandbox = {}
    local chunk, err = load(content, "=remoteFont", "t", sandbox)
    if not chunk then
        return nil, "加载字体失败: " .. err
    end

    local success, result = pcall(chunk)
    if not success then
        return nil, "执行字体脚本失败: " .. result
    end

    local fontData = sandbox.font or sandbox[1] or result
    if utf8display.config.cacheFont then
        state.loadedFonts[url] = fontData
    end

    return fontData
end

function fontManager.loadLocalFont(path)
    if state.loadedFonts[path] then
        return state.loadedFonts[path]
    end

    if not fs.exists(path) then
        return nil, "字体文件不存在: " .. path
    end

    local file = fs.open(path, "r")
    local content = file.readAll()
    file.close()

    local sandbox = {}
    local chunk, err = load(content, "=localFont", "t", sandbox)
    if not chunk then
        return nil, "加载本地字体失败: " .. err
    end

    local success, result = pcall(chunk)
    if not success then
        return nil, "执行本地字体脚本失败: " .. result
    end

    local fontData = sandbox.font or sandbox[1] or result
    if utf8display.config.cacheFont then
        state.loadedFonts[path] = fontData
    end

    return fontData
end

function fontManager.getFont()
    if not state.font then
        local success, err = utf8display.loadFont()
        if not success then
            error("字体加载失败: " .. err)
        end
    end
    return state.font
end

function fontManager.getFontHeight()
    local font = fontManager.getFont()
    if font and font[72] then -- 'H' (ASCII 72) 表示最大高度
        return #font[72]
    elseif font and font[32] then
        return #font[32]
    end
    return state.fontHeight
end

-- 渲染引擎模块
local renderer = {}

function renderer.utf8Decode(str)
    local i = 1
    return function()
        if i > #str then return end

        local b1 = string.byte(str, i)
        i = i + 1

        if b1 < 0x80 then
            return b1
        elseif b1 >= 0xC0 and b1 < 0xE0 then
            local b2 = string.byte(str, i) or 0
            i = i + 1
            return (b1 - 0xC0) * 64 + (b2 - 0x80)
        elseif b1 >= 0xE0 and b1 < 0xF0 then
            local b2 = string.byte(str, i) or 0
            i = i + 1
            local b3 = string.byte(str, i) or 0
            i = i + 1
            return (b1 - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
        else
            return 32
        end
    end
end

-- 公共API函数
function utf8display.setConfig(key, value)
    if utf8display.config[key] ~= nil then
        utf8display.config[key] = value
        return true
    end
    return false, "配置项不存在"
end

function utf8display.getConfig(key)
    if utf8display.config[key] ~= nil then
        return utf8display.config[key]
    end
    return nil, "配置项不存在"
end

function utf8display.loadFont()
    if utf8display.config.fontPath then
        state.font, err = fontManager.loadLocalFont(utf8display.config.fontPath)
        if not state.font then
            return false, err
        end
    elseif utf8display.config.fontUrl == DEFAULT_FONT_URL and _G.utf8display_8px_fontfile then
        state.font = _G.utf8display_8px_fontfile
    else
        state.font, err = fontManager.loadRemoteFont(utf8display.config.fontUrl)
        if not state.font then
            return false, err
        end
        if utf8display.config.fontUrl == DEFAULT_FONT_URL then
            _G.utf8display_8px_fontfile = state.font
        end
    end
    state.fontHeight = fontManager.getFontHeight()
    return true
end

-- 将字符串转换为bimg格式（完整修正版，支持逐字颜色）
function utf8display.strToBimg(str, textColor, backgroundColor, width)
    str = tostring(str)
    local font = fontManager.getFont()
    local fontHeight = fontManager.getFontHeight()
    
    -- 判断颜色参数类型
    local textIsString = type(textColor) == "string"
    local bgIsString = type(backgroundColor) == "string"
    
    -- 获取默认颜色
    local defaultTextColor = term.getTextColor()
    local defaultBgColor = term.getBackgroundColor()
    
    -- 处理统一颜色（数字）或逐字颜色（字符串）
    local uniformTextBlit, uniformBgBlit
    if not textIsString then
        uniformTextBlit = colors.toBlit(type(textColor) == "number" and textColor or defaultTextColor)
    end
    if not bgIsString then
        uniformBgBlit = colors.toBlit(type(backgroundColor) == "number" and backgroundColor or defaultBgColor)
    end
    
    -- 初始化bimg结构
    local bimg = {}
    
    -- 处理换行符
    local lines = {}
    local start = 1
    while start <= #str do
        local nl_pos = str:find("\n", start, true)
        if nl_pos then
            local line = str:sub(start, nl_pos - 1)
            table.insert(lines, line)
            start = nl_pos + 1
        else
            -- 到末尾了
            local line = str:sub(start)
            table.insert(lines, line)
            break
        end
    end
    
    for _, lineStr in ipairs(lines) do
        -- 收集该行所有字符信息
        local allChars = {}
        for code in renderer.utf8Decode(lineStr) do
            local charMap = font[code] or font[32]
            local charWidth = #charMap[1]
            table.insert(allChars, {code = code, map = charMap, width = charWidth})
        end
        
        if width then
            -- 有宽度限制，需要处理自动换行
            local segments = {}
            local currentSegment = {}
            local currentLineWidth = 0
            
            -- 遍历字符
            for i, charInfo in ipairs(allChars) do
                -- 检查是否需要换行
                if currentLineWidth + charInfo.width > width then
                    -- 将当前段添加到segments
                    if #currentSegment > 0 then
                        table.insert(segments, currentSegment)
                    end
                    
                    -- 开始新段
                    currentSegment = {}
                    currentLineWidth = 0
                end
                
                -- 添加字符到当前段
                table.insert(currentSegment, charInfo)
                currentLineWidth = currentLineWidth + charInfo.width
            end
            
            -- 添加最后一段（如果存在）
            if #currentSegment > 0 then
                table.insert(segments, currentSegment)
            end
            
            -- 渲染每个段（每个段高度 = fontHeight）
            for _, segment in ipairs(segments) do
                -- 为该段构建每行的 text/colors/bg
                for row = 1, fontHeight do
                    local lineText = ""
                    local lineTextColors = ""
                    local lineBgColors = ""
                    
                    -- 为每个字符计算颜色（如果使用字符串颜色）
                    local charIndexInLine = 1
                    for _, char in ipairs(segment) do
                        local fgBlit, bgBlit
                        
                        if textIsString then
                            local colorChar = string.sub(textColor, charIndexInLine, charIndexInLine)
                            fgBlit = colorChar ~= "" and colorChar or "f"  -- 默认白色
                        else
                            fgBlit = uniformTextBlit
                        end
                        
                        if bgIsString then
                            local colorChar = string.sub(backgroundColor, charIndexInLine, charIndexInLine)
                            bgBlit = colorChar ~= "" and colorChar or "0"  -- 默认黑色
                        else
                            bgBlit = uniformBgBlit
                        end
                        
                        -- 处理该字符的当前行
                        if row <= #char.map then
                            local rowStr = char.map[row]
                            for col = 1, #rowStr do
                                local byte = string.byte(rowStr, col)
                                local displayByte
                                if byte < 128 then
                                    -- 颜色反转
                                    displayByte = byte + 128
                                    lineText = lineText .. string.char(displayByte)
                                    lineTextColors = lineTextColors .. bgBlit  -- 原背景色变前景
                                    lineBgColors = lineBgColors .. fgBlit    -- 原前景色变背景
                                else
                                    -- 正常
                                    displayByte = byte
                                    lineText = lineText .. string.char(displayByte)
                                    lineTextColors = lineTextColors .. fgBlit
                                    lineBgColors = lineBgColors .. bgBlit
                                end
                            end
                        end
                        
                        charIndexInLine = charIndexInLine + 1
                    end
                    
                    table.insert(bimg, {lineText, lineTextColors, lineBgColors})
                end
            end
        else
            -- 无宽度限制，整行处理
            if #allChars > 0 then
                -- 为该行构建每行的 text/colors/bg
                for row = 1, fontHeight do
                    local lineText = ""
                    local lineTextColors = ""
                    local lineBgColors = ""
                    
                    -- 为每个字符计算颜色（如果使用字符串颜色）
                    local charIndexInLine = 1
                    for _, char in ipairs(allChars) do
                        local fgBlit, bgBlit
                        
                        if textIsString then
                            local colorChar = string.sub(textColor, charIndexInLine, charIndexInLine)
                            fgBlit = colorChar ~= "" and colorChar or "f"  -- 默认白色
                        else
                            fgBlit = uniformTextBlit
                        end
                        
                        if bgIsString then
                            local colorChar = string.sub(backgroundColor, charIndexInLine, charIndexInLine)
                            bgBlit = colorChar ~= "" and colorChar or "0"  -- 默认黑色
                        else
                            bgBlit = uniformBgBlit
                        end
                        
                        -- 处理该字符的当前行
                        if row <= #char.map then
                            local rowStr = char.map[row]
                            for col = 1, #rowStr do
                                local byte = string.byte(rowStr, col)
                                local displayByte
                                if byte < 128 then
                                    -- 颜色反转
                                    displayByte = byte + 128
                                    lineText = lineText .. string.char(displayByte)
                                    lineTextColors = lineTextColors .. bgBlit  -- 原背景色变前景
                                    lineBgColors = lineBgColors .. fgBlit    -- 原前景色变背景
                                else
                                    -- 正常
                                    displayByte = byte
                                    lineText = lineText .. string.char(displayByte)
                                    lineTextColors = lineTextColors .. fgBlit
                                    lineBgColors = lineBgColors .. bgBlit
                                end
                            end
                        end
                        
                        charIndexInLine = charIndexInLine + 1
                    end
                    
                    table.insert(bimg, {lineText, lineTextColors, lineBgColors})
                end
            else
                -- 空行也需要保留
                table.insert(bimg, {"", "", ""})
            end
        end
    end
    
    -- 如果没有内容，创建一个空行
    if #bimg == 0 then
        table.insert(bimg, {"", "", ""})
    end
    
    -- 将所有行包装在第一帧中
    return {{unpack(bimg)}}
end


local function clampCursorPos(x, y, width, height)
    return math.min(math.max(x, 1), width), math.min(math.max(y, 1), height)
end

function utf8display.write(raw_str, textColor, backgroundColor)
    local str = tostring(raw_str)
    str = string.gsub(str, "\n", " ")  -- 替换换行为空格

    local startX, startY = term.getCursorPos()
    local termWidth, termHeight = term.getSize()

    -- 获取 bimg（无宽度限制，所以不会自动换行）
    local bimg = utf8display.strToBimg(str, textColor, backgroundColor)
    local frame = bimg[1]

    if #frame == 0 then
        -- 空内容，直接返回
        return true, { charCount = 0, overflowX = false, overflowY = false }
    end

    local firstLineWidth = #frame[1][1]
    local totalHeight = #frame

    -- 渲染每一行
    for i, row in ipairs(frame) do
        local drawY = startY + i - 1
        if drawY > termHeight then
            -- 超出底部，跳过绘制
            break
        end
        term.setCursorPos(startX, drawY)
        term.blit(row[1], row[2], row[3])
    end

    -- 判断是否纵向溢出
    local verticalOverflow = (startY + totalHeight - 1) > termHeight
    local horizontalOverflow = firstLineWidth >= termWidth

    local finalX, finalY

    if verticalOverflow then
        -- 情况3：纵向溢出 → 回退到起点
        finalX, finalY = startX, startY
    elseif horizontalOverflow then
        -- 情况2：宽但不高 → 光标移到块下方
        finalX, finalY = startX, startY + totalHeight
    else
        -- 情况1：窄且不高 → 横向推进（仅第一行宽度）
        finalX, finalY = startX + firstLineWidth, startY
    end

    finalX, finalY = clampCursorPos(finalX, finalY, termWidth, termHeight)
    term.setCursorPos(finalX, finalY)

    return true, {
        startX = startX,
        startY = startY,
        endX = finalX,
        endY = finalY,
        charCount = utf8.len(str),  -- 假设有 utf8.len，或可估算
        fontHeight = fontManager.getFontHeight(),
        overflowX = horizontalOverflow,
        overflowY = verticalOverflow
    }
end

function utf8display.blit(raw_str, textColorStr, backgroundColorStr)
    local str = tostring(raw_str)
    str = string.gsub(str, "\n", " ")

    local startX, startY = term.getCursorPos()
    local termWidth, termHeight = term.getSize()

    -- 直接传入颜色字符串
    local bimg = utf8display.strToBimg(str, textColorStr, backgroundColorStr)
    local frame = bimg[1]

    if #frame == 0 then
        return true, { charCount = 0, overflowX = false, overflowY = false }
    end

    local firstLineWidth = #frame[1][1]
    local totalHeight = #frame

    -- 渲染
    for i, row in ipairs(frame) do
        local drawY = startY + i - 1
        if drawY > termHeight then
            break
        end
        term.setCursorPos(startX, drawY)
        term.blit(row[1], row[2], row[3])
    end

    local verticalOverflow = (startY + totalHeight - 1) > termHeight
    local horizontalOverflow = firstLineWidth >= termWidth

    local finalX, finalY

    if verticalOverflow then
        finalX, finalY = startX, startY
    elseif horizontalOverflow then
        finalX, finalY = startX, startY + totalHeight
    else
        finalX, finalY = startX + firstLineWidth, startY
    end

    finalX, finalY = clampCursorPos(finalX, finalY, termWidth, termHeight)
    term.setCursorPos(finalX, finalY)

    return true, {
        startX = startX,
        startY = startY,
        endX = finalX,
        endY = finalY,
        charCount = utf8.len(str),
        fontHeight = fontManager.getFontHeight(),
        overflowX = horizontalOverflow,
        overflowY = verticalOverflow
    }
end

function utf8display.print(raw_str, textColor, backgroundColor)
    local str = tostring(raw_str)

    local startX, startY = term.getCursorPos()
    local width, height = term.getSize()

    -- 获取颜色
    local useTextColor = textColor
    local useBackgroundColor = backgroundColor
    if useTextColor == nil then useTextColor = term.getTextColor() end
    if useBackgroundColor == nil then useBackgroundColor = term.getBackgroundColor() end

    -- 生成 bimg（传入宽度以启用自动换行）
    local bimg = utf8display.strToBimg(str, useTextColor, useBackgroundColor, width)
    local frame = bimg[1]

    local totalLines = #frame
    local availableLines = height - startY + 1


    -- 渲染
    for i, rowData in ipairs(frame) do
        local drawY = startY + i - 1
        
        if drawY >= height then term.setCursorPos(1, height) else term.setCursorPos(1, drawY) end
        term.blit(rowData[1], rowData[2], rowData[3])
        if drawY >= height then term.scroll(1) end
    end

    -- 光标移到下一行开头
    local finalY = startY + totalLines
    local finalX = 1
    finalX, finalY = clampCursorPos(finalX, finalY, width, height)
    term.setCursorPos(finalX, finalY)

    return true, {
        startX = startX,
        startY = startY,
        endX = finalX,
        endY = finalY,
        lineCount = totalLines
    }
end

-- 自动初始化（第一次使用时）
setmetatable(utf8display, {
    __index = function(self, key)
        if key == "write" or key == "print" or key == "blit" then
            if not utf8display.isInitialized() then
                local success, err = utf8display.loadFont()
                if not success then
                    error("自动初始化失败: " .. err)
                end
            end
            return rawget(self, key)
        end
        return rawget(self, key)
    end
})

return utf8display