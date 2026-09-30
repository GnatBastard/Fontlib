-- SPDX-License-Identifier: 0BSD
-- Language segmentation and hyphenation.
local M=fontlib
local U=M.unicode
M.typography=M.typography or {}
local T=M.typography
T.VERSION=1
T._word_dictionaries=T._word_dictionaries or {}
T._hyphenators=T._hyphenators or {}

local function langkey(lang)
    lang=tostring(lang or "und"):lower():gsub("_","-")
    return lang:match("^[^-]+") or "und"
end
local function cpchars(text)
    local items,err=U.decode(tostring(text or ""));if not items then return nil,err end
    local out={}
    for i,it in ipairs(items) do out[i]={cp=it.cp,text=text:sub(it.byte_start,it.byte_end),byte_start=it.byte_start,byte_end=it.byte_end} end
    return out
end
local function lower(s) return tostring(s or ""):lower() end

function T.register_word_dictionary(language,words)
    assert(type(words)=="table","word dictionary must be an array/table")
    local key=langkey(language);local set={};local maxcp=0
    for k,v in pairs(words) do
        local w=type(k)=="string" and v==true and k or v
        if type(w)=="string" and w~="" then
            w=lower(w);set[w]=true
            local c=cpchars(w);if c and #c>maxcp then maxcp=#c end
        end
    end
    T._word_dictionaries[key]={words=set,maxcp=maxcp}
    return true
end
function T.unregister_word_dictionary(language) T._word_dictionaries[langkey(language)]=nil return true end

-- Greedy maximal matching is the primitive here.
function T.segment(language,text)
    local dict=T._word_dictionaries[langkey(language)];if not dict then return nil end
    local chars,err=cpchars(text);if not chars then return nil,err end
    local breaks={};local i=1
    while i<=#chars do
        local best
        local maxj=math.min(#chars,i+math.max(1,dict.maxcp)-1)
        for j=maxj,i,-1 do
            local s={};for k=i,j do s[#s+1]=chars[k].text end
            if dict.words[lower(table.concat(s))] then best=j;break end
        end
        if not best then best=i end
        if best<#chars then breaks[#breaks+1]=best end
        i=best+1
    end
    return breaks
end

local function parse_pattern(pat)
    local letters={};local values={0};local slot=1
    local i=1
    while i<=#pat do
        local b=pat:byte(i)
        if b>=48 and b<=57 then values[slot]=b-48;i=i+1
        else
            local n=1
            if b>=0xF0 then n=4 elseif b>=0xE0 then n=3 elseif b>=0xC0 then n=2 end
            letters[#letters+1]=pat:sub(i,i+n-1);slot=slot+1;values[slot]=values[slot] or 0;i=i+n
        end
    end
    return table.concat(letters),values
end
local function trie_insert(root,letters,values)
    local chars=cpchars(letters);if not chars then return end
    local node=root
    for _,c in ipairs(chars) do node.children=node.children or {};node.children[c.text]=node.children[c.text] or {};node=node.children[c.text] end
    node.values=values
end
local function exception_positions(word)
    local clean={};local pos={};local n=0;local i=1
    while i<=#word do
        local b=word:byte(i)
        if b==45 then pos[#pos+1]=n;i=i+1
        else
            local len=1
            if b>=0xF0 then len=4 elseif b>=0xE0 then len=3 elseif b>=0xC0 then len=2 end
            clean[#clean+1]=word:sub(i,i+len-1);n=n+1;i=i+len
        end
    end
    return table.concat(clean),pos
end

function T.register_hyphenation_patterns(language,spec)
    spec=spec or {};assert(type(spec)=="table","hyphenation spec must be a table")
    local root={};local patterns=spec.patterns or spec
    if type(patterns)=="string" then local a={};for p in patterns:gmatch("%S+") do a[#a+1]=p end;patterns=a end
    if type(patterns)=="table" then
        for _,p in ipairs(patterns) do if type(p)=="string" then local l,v=parse_pattern(p);trie_insert(root,l,v) end end
    end
    local exceptions={}
    for k,v in pairs(spec.exceptions or {}) do
        if type(k)=="string" and type(v)=="table" then exceptions[lower(k)]=v
        elseif type(v)=="string" then local clean,pos=exception_positions(v);exceptions[lower(clean)]=pos end
    end
    T._hyphenators[langkey(language)]={trie=root,exceptions=exceptions,min_left=tonumber(spec.min_left) or 2,min_right=tonumber(spec.min_right) or 2}
    return true
end
function T.unregister_hyphenation_patterns(language) T._hyphenators[langkey(language)]=nil return true end

function T.hyphenate(language,word,options)
    local h=T._hyphenators[langkey(language)];if not h then return nil end
    local key=lower(word);local ex=h.exceptions[key]
    if ex then local out={};for _,p in ipairs(ex) do out[#out+1]=p end;return out end
    local chars=cpchars(key);if not chars or #chars<2 then return {} end
    local padded={{text="."}};for _,c in ipairs(chars) do padded[#padded+1]=c end;padded[#padded+1]={text="."}
    local scores={};for i=1,#padded+1 do scores[i]=0 end
    for i=1,#padded do
        local node=h.trie
        for j=i,#padded do
            node=node.children and node.children[padded[j].text] or nil;if not node then break end
            if node.values then for k,v in ipairs(node.values) do local at=i+k-1;if v>(scores[at] or 0) then scores[at]=v end end end
        end
    end
    local left=tonumber(options and options.min_left) or h.min_left
    local right=tonumber(options and options.min_right) or h.min_right
    local out={}
    -- score slots are boundaries in ".word."; convert back to codepoint counts.
    for p=left,#chars-right do local slot=p+2;if (scores[slot] or 0)%2==1 then out[#out+1]=p end end
    return out
end

function T.export_language_data(languages)
    local out={word_dictionaries={},hyphenators={}}
    for lang in pairs(languages or {}) do
        local k=langkey(lang);local d=T._word_dictionaries[k]
        if d then
            local words={};for w in pairs(d.words) do words[#words+1]=w end;table.sort(words);out.word_dictionaries[k]=words
        else out.word_dictionaries[k]=false end
        local h=T._hyphenators[k]
        -- The built trie is ordinary acyclic Lua data, so workers can import it directly.
        out.hyphenators[k]=h or false
    end
    return out
end
function T.import_language_data(data)
    if type(data)~="table" then return end
    for lang,words in pairs(data.word_dictionaries or {}) do
        if words==false then T._word_dictionaries[langkey(lang)]=nil else T.register_word_dictionary(lang,words) end
    end
    for lang,h in pairs(data.hyphenators or {}) do
        if h==false then T._hyphenators[langkey(lang)]=nil else T._hyphenators[langkey(lang)]=h end
    end
end

M.register_word_dictionary=T.register_word_dictionary
M.unregister_word_dictionary=T.unregister_word_dictionary
M.register_hyphenation_patterns=T.register_hyphenation_patterns
M.unregister_hyphenation_patterns=T.unregister_hyphenation_patterns
return T
