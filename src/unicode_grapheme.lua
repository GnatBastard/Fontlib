-- SPDX-License-Identifier: 0BSD
-- Unicode grapheme boundaries.
local M=fontlib
local U=M.unicode
local G=M.unicode_grapheme_properties

local function is_control(c) return c=="Control" or c=="CR" or c=="LF" end
local function no_break(items,classes,i)
    -- Boundary is between i and i+1.
    local l,r=classes[i],classes[i+1]
    -- GB3
    if l=="CR" and r=="LF" then return true end
    -- GB4/GB5
    if is_control(l) or is_control(r) then return false end
    -- GB6-GB8 Hangul syllable sequences.
    if l=="L" and (r=="L" or r=="V" or r=="LV" or r=="LVT") then return true end
    if (l=="LV" or l=="V") and (r=="V" or r=="T") then return true end
    if (l=="LVT" or l=="T") and r=="T" then return true end
    -- GB9/GB9a/GB9b
    if r=="Extend" or r=="ZWJ" or r=="SpacingMark" then return true end
    if l=="Prepend" then return true end
    -- GB9c Indic conjunct linker sequence.
    if G.incb(items[i+1].cp)=="Consonant" then
        local j=i;local linker=false
        while j>=1 do
            local p=G.incb(items[j].cp)
            if p=="Linker" then linker=true;j=j-1
            elseif p=="Extend" then j=j-1
            else break end
        end
        if linker and j>=1 and G.incb(items[j].cp)=="Consonant" then return true end
    end
    -- GB11 emoji ZWJ sequence: EP Extend* ZWJ × EP.
    if G.extended_pictographic(items[i+1].cp) and l=="ZWJ" then
        local j=i-1
        while j>=1 and classes[j]=="Extend" do j=j-1 end
        if j>=1 and G.extended_pictographic(items[j].cp) then return true end
    end
    -- GB12/GB13 regional-indicator flags pair from the start of an RI run.
    if l=="Regional_Indicator" and r=="Regional_Indicator" then
        local count=0;local j=i
        while j>=1 and classes[j]=="Regional_Indicator" do count=count+1;j=j-1 end
        if count%2==1 then return true end
    end
    return false
end

function U.grapheme_breaks(text)
    local items,err=U.decode(tostring(text or ""));if not items then return nil,err end
    local classes={};for i,it in ipairs(items) do classes[i]=G.grapheme(it.cp) end
    local out={}
    for i=1,#items-1 do if not no_break(items,classes,i) then out[#out+1]={after=i,byte=items[i].byte_end} end end
    if #items>0 then out[#out+1]={after=#items,byte=items[#items].byte_end,final=true} end
    return out
end

function U.graphemes(text)
    text=tostring(text or "");local items,err=U.decode(text);if not items then return nil,err end
    if #items==0 then return {} end
    local classes={};for i,it in ipairs(items) do classes[i]=G.grapheme(it.cp) end
    local out={};local first=1
    for i=1,#items-1 do
        if not no_break(items,classes,i) then
            out[#out+1]={text=text:sub(items[first].byte_start,items[i].byte_end),first=first,last=i,byte_start=items[first].byte_start,byte_end=items[i].byte_end}
            first=i+1
        end
    end
    out[#out+1]={text=text:sub(items[first].byte_start,items[#items].byte_end),first=first,last=#items,byte_start=items[first].byte_start,byte_end=items[#items].byte_end}
    return out
end

return U
