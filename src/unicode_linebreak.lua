-- SPDX-License-Identifier: 0BSD
-- Unicode line breaking.
local M=fontlib
local U=M.unicode
local G=M.unicode_linebreak_properties
local P=M.unicode_properties or U

local function hard(c) return c=="BK" or c=="CR" or c=="LF" or c=="NL" end
local function in_set(v,...)
    for i=1,select('#',...) do if v==select(i,...) then return true end end
    return false
end
local function east_asian(cp)
    local e=G.east_asian(cp);return e=="F" or e=="W" or e=="H"
end
local function resolved_class(cp)
    local c=G.line_break(cp)
    if c=="AI" or c=="SG" or c=="XX" then return "AL" end
    if c=="SA" then return (P.is_mark and P.is_mark(cp)) and "CM" or "AL" end
    if c=="CJ" then return "NS" end
    return c
end

function U.line_break_class(cp) return G.line_break(tonumber(cp) or -1) end

local function classify(items)
    local raw,cls={},{}
    for i,it in ipairs(items) do raw[i]=G.line_break(it.cp);cls[i]=resolved_class(it.cp) end
    -- LB9/LB10.
    local eff={}
    for i,c in ipairs(cls) do
        local r=raw[i]
        if (r=="CM" or r=="ZWJ") and i>1 and not hard(raw[i-1]) and raw[i-1]~="SP" and raw[i-1]~="ZW" then
            eff[i]=eff[i-1] or "AL"
        elseif r=="CM" or r=="ZWJ" then eff[i]="AL"
        else eff[i]=c end
    end
    return raw,eff
end

local function previous_non_space(raw,i)
    while i>=1 and raw[i]=="SP" do i=i-1 end
    return i
end
local function next_index(items,i) return (i<=#items) and i or nil end

local function break_map(items)
    local n=#items;local raw,c=classify(items);local out={}
    if n==0 then return out,raw,c end
    for i=1,n-1 do
        local j=i+1;local l,r=c[i],c[j];local lr,rr=raw[i],raw[j]
        local allow=true
        local mandatory=false
        -- LB4-LB6
        if lr=="BK" then allow=true;mandatory=true
        elseif lr=="CR" and rr=="LF" then allow=false
        elseif lr=="CR" or lr=="LF" or lr=="NL" then allow=true;mandatory=true
        elseif hard(rr) then allow=false
        -- LB7
        elseif rr=="SP" or rr=="ZW" then allow=false
        else
            -- LB8: ZW SP* ÷
            local k=previous_non_space(raw,i)
            if k>=1 and raw[k]=="ZW" then allow=true
            -- LB8a
            elseif lr=="ZWJ" then allow=false
            -- LB9 plus grapheme-safe tailoring: never split before CM/ZWJ.
            elseif rr=="CM" or rr=="ZWJ" then allow=false
            -- LB11-LB13
            elseif l=="WJ" or r=="WJ" then allow=false
            elseif l=="GL" then allow=false
            elseif r=="GL" and not in_set(l,"SP","HY","HH") then allow=false
            elseif in_set(r,"CL","CP","EX","SY") then allow=false
            else
                local p=previous_non_space(raw,i)
                local pc=p>=1 and c[p] or nil
                -- LB14 OP SP* ×
                if pc=="OP" then allow=false
                else
                    -- LB15a initial quotation SP* ×
                    local q=p
                    if q>=1 and raw[q]=="QU" and G.is_initial_punctuation(items[q].cp) then
                        local before=q-1;local bc=before>=1 and c[before] or nil;local br=before>=1 and raw[before] or nil
                        if before<1 or hard(br) or in_set(bc,"OP","QU","GL","SP","ZW") then allow=false end
                    end
                    if allow then
                        -- LB15b: × final quotation when it is followed by closing/prohibited context.
                        if rr=="QU" and G.is_final_punctuation(items[j].cp) then
                            local nc=(j+1<=n) and c[j+1] or nil;local nr=(j+1<=n) and raw[j+1] or nil
                            if j==n or hard(nr) or in_set(nc,"SP","GL","WJ","CL","QU","CP","EX","IS","SY","ZW") then allow=false end
                        end
                    end
                    if allow then
                        -- LB15c/LB15d
                        if l=="SP" and r=="IS" and j+1<=n and c[j+1]=="NU" then allow=true
                        elseif r=="IS" then allow=false
                        -- LB16/LB17
                        elseif (pc=="CL" or pc=="CP") and r=="NS" then allow=false
                        elseif pc=="B2" and r=="B2" then allow=false
                        -- LB18
                        elseif l=="SP" then allow=true
                        else
                            -- LB19/LB19a.
                            if r=="QU" and (not G.is_initial_punctuation(items[j].cp) or not east_asian(items[i].cp)) then allow=false
                            elseif l=="QU" and (not G.is_final_punctuation(items[i].cp) or not east_asian(items[j].cp)) then allow=false
                            -- LB20
                            elseif l=="CB" or r=="CB" then allow=true
                            else
                                -- LB20a word-initial hyphen.
                                if (l=="HY" or l=="HH") and (r=="AL" or r=="HL") then
                                    local bi=i-1;local bc=bi>=1 and c[bi] or nil;local br=bi>=1 and raw[bi] or nil
                                    if bi<1 or hard(br) or in_set(bc,"SP","ZW","CB","GL") then allow=false end
                                end
                                -- LB21/LB21a/LB21b/LB22
                                if allow and in_set(r,"BA","HH","HY","NS") then allow=false end
                                if allow and l=="BB" then allow=false end
                                if allow and (l=="HY" or l=="HH") and r~="HL" and i>1 and c[i-1]=="HL" then allow=false end
                                if allow and l=="SY" and r=="HL" then allow=false end
                                if allow and r=="IN" then allow=false end
                                -- LB23/LB23a/LB24
                                if allow and ((in_set(l,"AL","HL") and r=="NU") or (l=="NU" and in_set(r,"AL","HL"))) then allow=false end
                                if allow and l=="PR" and in_set(r,"ID","EB","EM") then allow=false end
                                if allow and in_set(l,"ID","EB","EM") and r=="PO" then allow=false end
                                if allow and in_set(l,"PR","PO") and in_set(r,"AL","HL") then allow=false end
                                if allow and in_set(l,"AL","HL") and in_set(r,"PR","PO") then allow=false end
                                -- LB25 numeric expressions.
                                if allow and in_set(r,"PO","PR") then
                                    local z=i
                                    while z>=1 and in_set(c[z],"SY","IS") do z=z-1 end
                                    if z>=1 and c[z]=="NU" then allow=false end
                                end
                                if allow and in_set(l,"PO","PR") then
                                    if r=="NU" then allow=false
                                    elseif r=="OP" then
                                        local z=j+1;if z<=n and c[z]=="IS" then z=z+1 end
                                        if z<=n and c[z]=="NU" then allow=false end
                                    end
                                end
                                if allow and (l=="HY" or l=="IS") and r=="NU" then allow=false end
                                if allow and r=="NU" then
                                    local z=i
                                    while z>=1 and in_set(c[z],"SY","IS") do z=z-1 end
                                    if z>=1 and c[z]=="NU" then allow=false end
                                end
                                -- LB26/LB27 Hangul syllable blocks.
                                if allow and l=="JL" and in_set(r,"JL","JV","H2","H3") then allow=false end
                                if allow and in_set(l,"JV","H2") and in_set(r,"JV","JT") then allow=false end
                                if allow and in_set(l,"JT","H3") and r=="JT" then allow=false end
                                if allow and in_set(l,"JL","JV","JT","H2","H3") and r=="PO" then allow=false end
                                if allow and l=="PR" and in_set(r,"JL","JV","JT","H2","H3") then allow=false end
                                -- LB28
                                if allow and in_set(l,"AL","HL") and in_set(r,"AL","HL") then allow=false end
                                -- LB28a Brahmic orthographic syllables.
                                local lcp,rcp=items[i].cp,items[j].cp
                                local lbase=in_set(l,"AK","AS") or lcp==0x25CC
                                local rbase=in_set(r,"AK","AS") or rcp==0x25CC
                                if allow and l=="AP" and rbase then allow=false end
                                if allow and lbase and in_set(r,"VF","VI") then allow=false end
                                if allow and l=="VI" and rbase and i>1 then
                                    local pp=c[i-1];local pcp=items[i-1].cp
                                    if in_set(pp,"AK","AS") or pcp==0x25CC then allow=false end
                                end
                                if allow and lbase and rbase and j+1<=n and c[j+1]=="VF" then allow=false end
                                -- LB29
                                if allow and l=="IS" and in_set(r,"AL","HL") then allow=false end
                                -- LB30 (exclude East-Asian OP/CP).
                                if allow and in_set(l,"AL","HL","NU") and r=="OP" and not east_asian(items[j].cp) then allow=false end
                                if allow and l=="CP" and not east_asian(items[i].cp) and in_set(r,"AL","HL","NU") then allow=false end
                                -- LB30a regional indicator pairs.
                                if allow and l=="RI" and r=="RI" then
                                    local count=0;local z=i
                                    while z>=1 and c[z]=="RI" do count=count+1;z=z-1 end
                                    if count%2==1 then allow=false end
                                end
                                -- LB30b emoji base + modifier, including unassigned extended
                                -- pictographic bases reserved for future emoji.
                                if allow and r=="EM" and (l=="EB" or G.is_extended_pictographic(items[i].cp)) then allow=false end
                            end
                        end
                    end
                end
            end
        end
        out[i]=mandatory and 2 or (allow and 1 or 0)
    end
    out[n]=1 -- LB3: eot is always a legal final boundary.
    return out,raw,c
end

-- Return a compact boundary list.
function U.line_breaks(text)
    local items,err=U.decode(text);if not items then return nil,err end
    local map=break_map(items);local out={}
    for i,kind in ipairs(map) do
        if kind and kind>0 then out[#out+1]={after=i,byte=items[i].byte_end,mandatory=kind==2} end
    end
    return out
end

function U._line_break_map(text)
    local items,err=U.decode(text);if not items then return nil,err end
    local map,raw,classes=break_map(items)
    return {items=items,breaks=map,raw_classes=raw,classes=classes}
end

return U
