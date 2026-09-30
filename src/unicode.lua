-- SPDX-License-Identifier: 0BSD
-- Unicode text analysis.
local M = fontlib
local U = M.unicode or {}
M.unicode = U

U.VERSION = 1

local floor = math.floor

local function utf8_error(i, message)
    return nil, ("invalid UTF-8 at byte %d: %s"):format(i, message)
end

function U.decode(text)
    text = tostring(text or "")
    local out = {}
    local i, logical = 1, 0
    while i <= #text do
        local start = i
        local b1 = text:byte(i)
        local cp, count
        if b1 < 0x80 then
            cp, count = b1, 1
        elseif b1 >= 0xC2 and b1 <= 0xDF then
            local b2 = text:byte(i + 1)
            if not b2 or b2 < 0x80 or b2 > 0xBF then return utf8_error(i, "bad 2-byte sequence") end
            cp, count = (b1 - 0xC0) * 0x40 + (b2 - 0x80), 2
        elseif b1 >= 0xE0 and b1 <= 0xEF then
            local b2, b3 = text:byte(i + 1), text:byte(i + 2)
            if not b2 or not b3 or b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF then
                return utf8_error(i, "bad 3-byte sequence")
            end
            if b1 == 0xE0 and b2 < 0xA0 then return utf8_error(i, "overlong sequence") end
            if b1 == 0xED and b2 >= 0xA0 then return utf8_error(i, "UTF-16 surrogate") end
            cp, count = (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80), 3
        elseif b1 >= 0xF0 and b1 <= 0xF4 then
            local b2, b3, b4 = text:byte(i + 1), text:byte(i + 2), text:byte(i + 3)
            if not b2 or not b3 or not b4
                or b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF or b4 < 0x80 or b4 > 0xBF then
                return utf8_error(i, "bad 4-byte sequence")
            end
            if b1 == 0xF0 and b2 < 0x90 then return utf8_error(i, "overlong sequence") end
            if b1 == 0xF4 and b2 > 0x8F then return utf8_error(i, "codepoint past U+10FFFF") end
            cp, count = (b1 - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000
                + (b3 - 0x80) * 0x40 + (b4 - 0x80), 4
        else
            return utf8_error(i, "invalid leading byte")
        end
        logical = logical + 1
        out[#out + 1] = {
            cp = cp,
            logical_index = logical,
            byte_start = start,
            byte_end = start + count - 1,
        }
        i = i + count
    end
    return out
end

function U.codepoints(text)
    local items, err = U.decode(text)
    if not items then return nil, err end
    local out = {}
    for i = 1, #items do out[i] = items[i].cp end
    return out
end

local function in_range(cp, a, b) return cp >= a and cp <= b end

local function is_combining(cp)
    -- Once unicode_properties.lua is loaded, prefer its generated General_Category mark data.
    local props = M.unicode_properties
    if props and props.is_mark and props.is_mark(cp) then return true end
    return in_range(cp, 0x0300, 0x036F)
        or in_range(cp, 0x0483, 0x0489)
        or in_range(cp, 0x0591, 0x05BD) or cp == 0x05BF or in_range(cp, 0x05C1, 0x05C2)
        or in_range(cp, 0x05C4, 0x05C5) or cp == 0x05C7
        or in_range(cp, 0x0610, 0x061A) or in_range(cp, 0x064B, 0x065F) or cp == 0x0670
        or in_range(cp, 0x06D6, 0x06ED)
        or in_range(cp, 0x0711, 0x0711) or in_range(cp, 0x0730, 0x074A)
        or in_range(cp, 0x07A6, 0x07B0) or in_range(cp, 0x07EB, 0x07F3)
        or in_range(cp, 0x0816, 0x082D) or in_range(cp, 0x0859, 0x085B)
        or in_range(cp, 0x08D3, 0x08FF)
        or in_range(cp, 0x0900, 0x0903) or in_range(cp, 0x093A, 0x094F) or in_range(cp, 0x0951, 0x0957)
        or in_range(cp, 0x0962, 0x0963)
        or in_range(cp, 0x0981, 0x0983) or cp == 0x09BC or in_range(cp, 0x09BE, 0x09C4)
        or in_range(cp, 0x09C7, 0x09C8) or in_range(cp, 0x09CB, 0x09CD) or cp == 0x09D7
        or in_range(cp, 0x09E2, 0x09E3)
        or in_range(cp, 0x0A01, 0x0A03) or cp == 0x0A3C or in_range(cp, 0x0A3E, 0x0A42)
        or in_range(cp, 0x0A47, 0x0A48) or in_range(cp, 0x0A4B, 0x0A4D) or cp == 0x0A51
        or in_range(cp, 0x0A70, 0x0A71) or cp == 0x0A75
        or in_range(cp, 0x0A81, 0x0A83) or cp == 0x0ABC or in_range(cp, 0x0ABE, 0x0AC5)
        or in_range(cp, 0x0AC7, 0x0AC9) or in_range(cp, 0x0ACB, 0x0ACD) or in_range(cp, 0x0AE2, 0x0AE3)
        or in_range(cp, 0x0B01, 0x0B03) or cp == 0x0B3C or in_range(cp, 0x0B3E, 0x0B44)
        or in_range(cp, 0x0B47, 0x0B48) or in_range(cp, 0x0B4B, 0x0B4D) or in_range(cp, 0x0B55, 0x0B57)
        or in_range(cp, 0x0B62, 0x0B63)
        or in_range(cp, 0x0B82, 0x0B82) or in_range(cp, 0x0BBE, 0x0BC2) or in_range(cp, 0x0BC6, 0x0BC8)
        or in_range(cp, 0x0BCA, 0x0BCD) or cp == 0x0BD7
        or in_range(cp, 0x0C00, 0x0C04) or in_range(cp, 0x0C3E, 0x0C44) or in_range(cp, 0x0C46, 0x0C48)
        or in_range(cp, 0x0C4A, 0x0C4D) or in_range(cp, 0x0C55, 0x0C56) or in_range(cp, 0x0C62, 0x0C63)
        or in_range(cp, 0x0C81, 0x0C83) or cp == 0x0CBC or in_range(cp, 0x0CBE, 0x0CC4)
        or in_range(cp, 0x0CC6, 0x0CC8) or in_range(cp, 0x0CCA, 0x0CCD) or in_range(cp, 0x0CD5, 0x0CD6)
        or in_range(cp, 0x0CE2, 0x0CE3)
        or in_range(cp, 0x0D00, 0x0D03) or in_range(cp, 0x0D3B, 0x0D44) or in_range(cp, 0x0D46, 0x0D48)
        or in_range(cp, 0x0D4A, 0x0D4D) or cp == 0x0D57 or in_range(cp, 0x0D62, 0x0D63)
        or in_range(cp, 0x0D81, 0x0D83) or cp == 0x0DCA or in_range(cp, 0x0DCF, 0x0DD4)
        or cp == 0x0DD6 or in_range(cp, 0x0DD8, 0x0DDF)
        or in_range(cp, 0x1AB0, 0x1AFF) or in_range(cp, 0x1CD0, 0x1CFF)
        or in_range(cp, 0x1DC0, 0x1DFF) or in_range(cp, 0x20D0, 0x20FF) or in_range(cp, 0xFE20, 0xFE2F)
        or in_range(cp, 0x1E000, 0x1E02A)
end
U.is_combining = is_combining

function U.is_mark(cp)
    return is_combining(tonumber(cp) or -1)
end


function U.script(cp)
    cp = tonumber(cp) or 0
    if is_combining(cp) then return "Inherited" end
    if in_range(cp, 0x0041, 0x024F) or in_range(cp, 0x1E00, 0x1EFF) then return "Latin" end
    if in_range(cp, 0x0370, 0x03FF) or in_range(cp, 0x1F00, 0x1FFF) then return "Greek" end
    if in_range(cp, 0x0400, 0x052F) or in_range(cp, 0x2DE0, 0x2DFF) or in_range(cp, 0xA640, 0xA69F) then return "Cyrillic" end
    if in_range(cp, 0x0590, 0x05FF) or in_range(cp, 0xFB1D, 0xFB4F) then return "Hebrew" end
    if in_range(cp, 0x0600, 0x06FF) or in_range(cp, 0x0750, 0x077F) or in_range(cp, 0x0870, 0x089F)
        or in_range(cp, 0x08A0, 0x08FF) or in_range(cp, 0xFB50, 0xFDFF) or in_range(cp, 0xFE70, 0xFEFF)
        or in_range(cp, 0x1EE00, 0x1EEFF) then return "Arabic" end
    if in_range(cp, 0x0900, 0x097F) or in_range(cp, 0xA8E0, 0xA8FF) then return "Devanagari" end
    if in_range(cp, 0x0980, 0x09FF) then return "Bengali" end
    if in_range(cp, 0x0A00, 0x0A7F) then return "Gurmukhi" end
    if in_range(cp, 0x0A80, 0x0AFF) then return "Gujarati" end
    if in_range(cp, 0x0B00, 0x0B7F) then return "Oriya" end
    if in_range(cp, 0x0B80, 0x0BFF) then return "Tamil" end
    if in_range(cp, 0x0C00, 0x0C7F) then return "Telugu" end
    if in_range(cp, 0x0C80, 0x0CFF) then return "Kannada" end
    if in_range(cp, 0x0D00, 0x0D7F) then return "Malayalam" end
    if in_range(cp, 0x0D80, 0x0DFF) then return "Sinhala" end
    if in_range(cp, 0x1000, 0x109F) or in_range(cp, 0xA9E0, 0xA9FF) or in_range(cp, 0xAA60, 0xAA7F) then return "Myanmar" end
    if in_range(cp, 0x1780, 0x17FF) or in_range(cp, 0x19E0, 0x19FF) then return "Khmer" end
    return "Common"
end

function U.is_combining(cp)
    return is_combining(tonumber(cp) or -1)
end

local function is_ascii_letter(cp)
    return in_range(cp, 0x41, 0x5A) or in_range(cp, 0x61, 0x7A)
end

local function is_ltr_script(cp)
    local s = U.script(cp)
    return s == "Latin" or s == "Greek" or s == "Cyrillic" or s == "Devanagari" or s == "Bengali"
        or s == "Gurmukhi" or s == "Gujarati" or s == "Oriya" or s == "Tamil" or s == "Telugu"
        or s == "Kannada" or s == "Malayalam" or s == "Sinhala" or s == "Myanmar" or s == "Khmer"
end

function U.bidi_class(cp)
    cp = tonumber(cp) or 0
    -- Explicit directional controls and isolates.
    if cp == 0x202A then return "LRE" end
    if cp == 0x202B then return "RLE" end
    if cp == 0x202C then return "PDF" end
    if cp == 0x202D then return "LRO" end
    if cp == 0x202E then return "RLO" end
    if cp == 0x2066 then return "LRI" end
    if cp == 0x2067 then return "RLI" end
    if cp == 0x2068 then return "FSI" end
    if cp == 0x2069 then return "PDI" end
    if cp == 0x200E then return "L" end -- LRM
    if cp == 0x200F then return "R" end -- RLM
    if cp == 0x061C then return "AL" end -- ALM
    if cp == 0x200C or cp == 0x200D or cp == 0xFEFF then return "BN" end

    if cp == 0x000A or cp == 0x000D or cp == 0x0085 or cp == 0x2028 or cp == 0x2029 then return "B" end
    if cp == 0x0009 or cp == 0x000B or cp == 0x001F then return "S" end
    if cp == 0x0020 or cp == 0x00A0 or cp == 0x1680 or in_range(cp, 0x2000, 0x200A)
        or cp == 0x202F or cp == 0x205F or cp == 0x3000 then return "WS" end

    if is_combining(cp) then return "NSM" end
    if in_range(cp, 0x0030, 0x0039) then return "EN" end
    if in_range(cp, 0x0660, 0x0669) then return "AN" end
    if in_range(cp, 0x06F0, 0x06F9) then return "EN" end

    if cp == 0x002B or cp == 0x002D or cp == 0x2212 then return "ES" end
    if cp == 0x002C or cp == 0x002E or cp == 0x002F or cp == 0x003A or cp == 0x060C then return "CS" end
    if cp == 0x0023 or cp == 0x0024 or cp == 0x0025 or cp == 0x00A2 or cp == 0x00A3 or cp == 0x00A4
        or cp == 0x00A5 or cp == 0x058F or cp == 0x060B or cp == 0x09F2 or cp == 0x09F3
        or in_range(cp, 0x20A0, 0x20CF) then return "ET" end

    local script = U.script(cp)
    if script == "Hebrew" then return "R" end
    if script == "Arabic" then
        -- Arabic punctuation/delimiters remain neutral; letters are AL.
        if in_range(cp, 0x0600, 0x0605) or cp == 0x0609 or cp == 0x060A or cp == 0x061B or cp == 0x061D
            or cp == 0x061E or cp == 0x061F or cp == 0x066A or cp == 0x066B or cp == 0x066C
            or in_range(cp, 0x06D4, 0x06D4) then return "ON" end
        return "AL"
    end
    if is_ascii_letter(cp) or is_ltr_script(cp) then return "L" end
    return "ON"
end

local function strong_for_neutral(t)
    if t == "L" then return "L" end
    if t == "R" or t == "AN" or t == "EN" then return "R" end
    return nil
end

local function embedding_dir(level) return level % 2 == 0 and "L" or "R" end

local function resolve_scripts(items)
    local previous
    for i = 1, #items do
        local raw = U.script(items[i].cp)
        items[i].script_raw = raw
        if raw ~= "Common" and raw ~= "Inherited" then
            items[i].script = raw
            previous = raw
        elseif previous and raw == "Inherited" then
            items[i].script = previous
        else
            items[i].script = raw
        end
    end
    local following
    for i = #items, 1, -1 do
        local s = items[i].script
        if s ~= "Common" and s ~= "Inherited" then
            following = s
        elseif following then
            if s == "Inherited" or not previous then items[i].script = following end
        end
    end
    -- Common characters sandwiched by the same script belong to that run.
    for i = 1, #items do
        if items[i].script == "Common" or items[i].script == "Inherited" then
            local left, right
            for j = i - 1, 1, -1 do
                local s = items[j].script
                if s ~= "Common" and s ~= "Inherited" then left = s; break end
            end
            for j = i + 1, #items do
                local s = items[j].script
                if s ~= "Common" and s ~= "Inherited" then right = s; break end
            end
            if left and left == right then items[i].script = left
            elseif left and not right then items[i].script = left
            elseif right and not left then items[i].script = right
            elseif left and items[i].script == "Inherited" then items[i].script = left
            elseif right and items[i].script == "Inherited" then items[i].script = right
            end
        end
    end
end

local function first_strong(items, first, last)
    for i = first, last do
        local t = items[i].bidi_class
        if t == "L" then return "ltr" end
        if t == "R" or t == "AL" then return "rtl" end
    end
    return "ltr"
end

local function resolve_bidi_segment(items, first, last, base_level)
    if first > last then return {} end
    local types = {}
    local levels = {}
    local sor = embedding_dir(base_level)
    local eor = sor
    for i = first, last do
        local t = items[i].bidi_class
        -- Full explicit embeddings/isolates are a later conformance layer.
        if t == "LRE" or t == "RLE" or t == "LRO" or t == "RLO" or t == "PDF"
            or t == "LRI" or t == "RLI" or t == "FSI" or t == "PDI" then
            t = "BN"
            items[i].bidi_control = true
        end
        types[i] = t
        levels[i] = base_level
    end

    -- W1: NSM takes the previous type (or sor).
    local prev = sor
    for i = first, last do
        if types[i] == "NSM" then types[i] = prev else if types[i] ~= "BN" then prev = types[i] end end
    end
    -- W2: EN following AL becomes AN.
    for i = first, last do
        if types[i] == "EN" then
            for j = i - 1, first, -1 do
                if types[j] == "R" or types[j] == "L" or types[j] == "AL" then
                    if types[j] == "AL" then types[i] = "AN" end
                    break
                end
            end
        end
    end
    -- W3: AL becomes R.
    for i = first, last do if types[i] == "AL" then types[i] = "R" end end
    -- W4: separators between like numbers inherit that numeric type.
    for i = first + 1, last - 1 do
        if types[i] == "ES" and types[i - 1] == "EN" and types[i + 1] == "EN" then types[i] = "EN"
        elseif types[i] == "CS" and types[i - 1] == "EN" and types[i + 1] == "EN" then types[i] = "EN"
        elseif types[i] == "CS" and types[i - 1] == "AN" and types[i + 1] == "AN" then types[i] = "AN" end
    end
    -- W5: a run of ET touching EN becomes EN.
    local i = first
    while i <= last do
        if types[i] == "ET" then
            local a = i
            while i <= last and types[i] == "ET" do i = i + 1 end
            local b = i - 1
            local left = a > first and types[a - 1] or sor
            local right = i <= last and types[i] or eor
            if left == "EN" or right == "EN" then for j = a, b do types[j] = "EN" end end
        else i = i + 1 end
    end
    -- W6.
    for j = first, last do if types[j] == "ES" or types[j] == "ET" or types[j] == "CS" then types[j] = "ON" end end
    -- W7: EN preceded by strong L becomes L.
    for j = first, last do
        if types[j] == "EN" then
            local strong = sor
            for k = j - 1, first, -1 do
                if types[k] == "L" or types[k] == "R" then strong = types[k]; break end
            end
            if strong == "L" then types[j] = "L" end
        end
    end

    -- N1/N2: resolve neutral runs from surrounding strong types or embedding.
    i = first
    while i <= last do
        local t = types[i]
        local neutral = t == "B" or t == "S" or t == "WS" or t == "ON" or t == "BN"
        if neutral then
            local a = i
            while i <= last do
                local q = types[i]
                if not (q == "B" or q == "S" or q == "WS" or q == "ON" or q == "BN") then break end
                i = i + 1
            end
            local b = i - 1
            local before = sor
            for k = a - 1, first, -1 do
                local s = strong_for_neutral(types[k])
                if s then before = s; break end
            end
            local after = eor
            for k = i, last do
                local s = strong_for_neutral(types[k])
                if s then after = s; break end
            end
            local resolved = before == after and before or embedding_dir(base_level)
            for k = a, b do if types[k] ~= "BN" then types[k] = resolved end end
        else i = i + 1 end
    end

    -- I1/I2.
    for j = first, last do
        local t = types[j]
        local level = base_level
        if level % 2 == 0 then
            if t == "R" then level = level + 1
            elseif t == "AN" or t == "EN" then level = level + 2 end
        else
            if t == "L" or t == "AN" or t == "EN" then level = level + 1 end
        end
        levels[j] = level
        items[j].bidi_resolved = t
        items[j].level = level
        items[j].direction = level % 2 == 0 and "ltr" or "rtl"
    end

    local order = {}
    local highest, lowest_odd = base_level, nil
    for j = first, last do
        if not items[j].bidi_control then
            order[#order + 1] = j
            local l = levels[j]
            if l > highest then highest = l end
            if l % 2 == 1 and (not lowest_odd or l < lowest_odd) then lowest_odd = l end
        end
    end
    if lowest_odd then
        for level = highest, lowest_odd, -1 do
            local p = 1
            while p <= #order do
                if levels[order[p]] >= level then
                    local a = p
                    while p <= #order and levels[order[p]] >= level do p = p + 1 end
                    local b = p - 1
                    while a < b do order[a], order[b] = order[b], order[a]; a = a + 1; b = b - 1 end
                else p = p + 1 end
            end
        end
    end
    return order
end

local function make_runs(items)
    local runs = {}
    local start
    local last_script, last_direction
    for i = 1, #items do
        local item = items[i]
        if item.bidi_class ~= "B" and not item.bidi_control then
            local script = item.script
            local direction = item.direction or "ltr"
            if not start then
                start, last_script, last_direction = i, script, direction
            elseif script ~= last_script or direction ~= last_direction then
                runs[#runs + 1] = {first=start, last=i-1, script=last_script, direction=last_direction}
                start, last_script, last_direction = i, script, direction
            end
        elseif start then
            runs[#runs + 1] = {first=start, last=i-1, script=last_script, direction=last_direction}
            start = nil
        end
    end
    if start then runs[#runs + 1] = {first=start, last=#items, script=last_script, direction=last_direction} end
    return runs
end

function U.analyze(text, options)
    options = options or {}
    local items, err = U.decode(text)
    if not items then return nil, err end
    for i = 1, #items do items[i].bidi_class = U.bidi_class(items[i].cp) end
    resolve_scripts(items)

    local paragraphs, visual_order = {}, {}
    local first = 1
    while first <= #items do
        local last = first
        while last <= #items and items[last].bidi_class ~= "B" do last = last + 1 end
        local content_last = last - 1
        local requested = options.base_direction or "auto"
        local direction = requested == "auto" and first_strong(items, first, content_last) or requested
        if direction ~= "rtl" then direction = "ltr" end
        local level = direction == "rtl" and 1 or 0
        local order = resolve_bidi_segment(items, first, content_last, level)
        for _, idx in ipairs(order) do visual_order[#visual_order + 1] = idx end
        if last <= #items then
            items[last].level = level
            items[last].direction = direction
            items[last].bidi_resolved = "B"
            visual_order[#visual_order + 1] = last
        end
        paragraphs[#paragraphs + 1] = {
            first = first,
            last = last <= #items and last or content_last,
            content_last = content_last,
            base_direction = direction,
            base_level = level,
            visual_order = order,
        }
        first = last + 1
    end

    local result = {
        text = tostring(text or ""),
        items = items,
        paragraphs = paragraphs,
        visual_order = visual_order,
        runs = make_runs(items),
    }
    if #paragraphs == 1 then
        result.base_direction = paragraphs[1].base_direction
        result.base_level = paragraphs[1].base_level
    end
    return result
end

function U.visual_codepoints(analysis)
    local out = {}
    for _, index in ipairs(analysis.visual_order or {}) do
        local item = analysis.items[index]
        if item and not item.bidi_control then out[#out + 1] = item.cp end
    end
    return out
end
