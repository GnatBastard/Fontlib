-- SPDX-License-Identifier: 0BSD
-- Rich-text paragraph layout.
local M=fontlib
local F=M.font
local U=M.unicode
local V=M.vector
local O=M.output
local E=M.effects
local T=M.typography

M.richtext=M.richtext or {}
local R=M.richtext
R.VERSION=1

local function copy(t)
    local o={};for k,v in pairs(t or {}) do o[k]=v end;return o
end
local function merge(a,b)
    local o=copy(a);for k,v in pairs(b or {}) do o[k]=v end;return o
end
local reserved={text=true,children=true,style=true,id=true,link=true,data=true,role=true,ruby=true}
local function direct_style(node)
    local s=copy(node.style)
    for k,v in pairs(node) do if not reserved[k] and type(k)~="number" then s[k]=v end end
    return s
end

local function flatten_node(node,inherited,out,meta)
    local typ=type(node)
    if typ=="string" or typ=="number" then
        local text=tostring(node);if text~="" then out[#out+1]={text=text,style=inherited,meta=meta} end;return
    end
    if typ~="table" then return end
    local ds=direct_style(node)
    local style=merge(inherited,ds)
    if ds.font==nil and M.resolve_font and (ds.family~=nil or ds.font_family~=nil or ds.weight~=nil or ds.font_weight~=nil or ds.font_style~=nil or ds.font_stretch~=nil) then
        local fam=ds.family or ds.font_family or style.family or style.font_family
        if fam then local ref=M.resolve_font(fam,{weight=style.font_weight or style.weight,style=style.font_style,stretch=style.font_stretch});if ref then style.font=ref end end
    end
    local nmeta={id=node.id,link=node.link,data=node.data,role=node.role,ruby=node.ruby}
    if nmeta.id==nil and nmeta.link==nil and nmeta.data==nil and nmeta.role==nil and nmeta.ruby==nil then nmeta=meta end
    if node.text~=nil then
        local text=tostring(node.text);if text~="" then out[#out+1]={text=text,style=style,meta=nmeta} end
    end
    if node.children then
        for _,child in ipairs(node.children) do flatten_node(child,style,out,nmeta) end
    elseif node.text==nil then
        -- A plain array is a convenient rich-text root/group.
        for _,child in ipairs(node) do flatten_node(child,style,out,nmeta) end
    end
end

function R.normalize(content,options)
    options=options or {}
    local base=copy(options.default_style or {})
    local inherit={
        "font","fallback","size","color","opacity","letter_spacing","word_spacing","line_height","language","base_direction",
        "hinting","gasp","palette","palette_index","color_glyphs","bitmap_filter","bitmap_ppi","ppi","text_mode","stroke_width",
        "background","baseline_shift","underline","overline","strikethrough","line_through","decoration_color","decoration_width","decoration_style","text_decoration_style",
        "underline_offset","strikeout_offset","tab_size","tab_width","family","font_family","font_weight","font_style","font_stretch","weight",
        "white_space","word_break","line_break","overflow_wrap","hyphens","hyphenate_limit_chars","direction","unicode_bidi",
        "features","font_features","font_feature_settings","ligatures","kerning","writing_mode","writing_direction","vertical","vertical_feature","column_spacing",
        "outline","outline_width","outline_color","shadow","shadow_x","shadow_y","shadow_blur","shadow_spread","shadow_color","glow","glow_radius","glow_color","glow_spread",
        "text_emphasis","text_emphasis_style","text_emphasis_color","text_emphasis_position","ruby_position","ruby_gap","ruby_size",
    }
    for _,k in ipairs(inherit) do if options[k]~=nil and base[k]==nil then base[k]=options[k] end end
    if base.font==nil and M.resolve_font and (base.family or base.font_family) then
        local ref=M.resolve_font(base.family or base.font_family,{weight=base.font_weight or base.weight,style=base.font_style,stretch=base.font_stretch});if ref then base.font=ref end
    end
    base.font=base.font or M.DEFAULT_FONT
    local bf=F.get(base.font);if bf and base.size==nil then base.size=bf.units_per_em end
    base.color=base.color or "#FFFFFF"
    local out={}
    if type(content)=="table" and content.text==nil and content.children==nil then
        for _,node in ipairs(content) do flatten_node(node,base,out,nil) end
    else flatten_node(content,base,out,nil) end
    return out,base
end

local function white_space_mode(style,options)
    local v=(style and style.white_space) or options.white_space or "normal"
    v=tostring(v):lower():gsub("_","-")
    return v
end
local function preprocess_whitespace(spans,options)
    local out={};local previous_collapsed_space=false
    for _,span in ipairs(spans) do
        local ns={text=span.text,style=span.style,meta=span.meta}
        local mode=white_space_mode(span.style,options)
        local text=tostring(span.text or ""):gsub("\r\n","\n"):gsub("\r","\n")
        if mode=="normal" or mode=="nowrap" then
            text=text:gsub("[ \t\n\f]+"," ")
            if previous_collapsed_space and text:sub(1,1)==" " then text=text:sub(2) end
            previous_collapsed_space=text:sub(-1)==" "
        elseif mode=="pre-line" then
            local parts={};local start=1
            while true do
                local a,b=text:find("\n",start,true);local part=(a and text:sub(start,a-1) or text:sub(start)):gsub("[ \t\f]+"," ")
                if previous_collapsed_space and part:sub(1,1)==" " then part=part:sub(2) end
                parts[#parts+1]=part
                if not a then previous_collapsed_space=part:sub(-1)==" ";break end
                parts[#parts+1]="\n";previous_collapsed_space=false;start=b+1
            end
            text=table.concat(parts)
        else
            previous_collapsed_space=false -- pre/pre-wrap/break-spaces preserve exactly
        end
        ns.text=text;if text~="" then out[#out+1]=ns end
    end
    return out
end

local function bidi_controls(style)
    local ub=tostring(style.unicode_bidi or "normal"):lower():gsub("_","-")
    local dir=tostring(style.direction or style.base_direction or "ltr"):lower()
    local rtl=dir=="rtl"
    local LRE="\226\128\170";local RLE="\226\128\171";local PDF="\226\128\172";local LRO="\226\128\173";local RLO="\226\128\174"
    local LRI="\226\129\166";local RLI="\226\129\167";local FSI="\226\129\168";local PDI="\226\129\169"
    if ub=="isolate" then return rtl and RLI or LRI,PDI
    elseif ub=="isolate-override" then return (rtl and RLI or LRI)..(rtl and RLO or LRO),PDF..PDI
    elseif ub=="bidi-override" or ub=="override" then return rtl and RLO or LRO,PDF
    elseif ub=="embed" then return rtl and RLE or LRE,PDF
    elseif ub=="plaintext" then return FSI,PDI end
    return "",""
end

local function style_metrics(style)
    local font=assert(F.get(style.font or M.DEFAULT_FONT),"unknown Fontlib font "..tostring(style.font))
    local size=tonumber(style.size) or font.units_per_em
    local line_height=style.line_height
    if line_height==nil and style.line_height_factor then
        local natural=font:get_metrics(size).line_height;line_height=natural*(tonumber(style.line_height_factor) or 1)
    end
    local m=font:get_metrics(size,line_height)
    local shift=tonumber(style.baseline_shift) or 0
    local natural=m.ascent-m.descent
    local leading=math.max(0,(m.line_height or natural)-natural)
    return font,size,m,shift,m.ascent+shift+leading/2,(-m.descent)-shift+leading/2
end

local function renderable_text(text)
    -- ZWSP and soft hyphen control wrapping but are not painted unless a soft hyphen is
    -- selected as the actual line break.
    return tostring(text or ""):gsub("\226\128\139",""):gsub("\194\173","")
end
local function count_spaces(text)
    local n=0;for _ in tostring(text):gmatch(" ") do n=n+1 end;return n
end
local function trailing_ascii_spaces(text)
    local s=tostring(text or "");local t=s:match("( +)$");return t and #t or 0
end

local function ruby_for_chunk(ch)
    local raw=ch.meta and ch.meta.ruby;if raw==nil then return nil end
    local text,extra
    if type(raw)=="table" then text=raw.text or raw[1] or "";extra=raw.style or raw
    else text=tostring(raw);extra={} end
    text=tostring(text or "");if text=="" then return nil end
    local st=merge(ch.style,extra);local base_size=tonumber(ch.style.size) or 16
    st.size=tonumber(extra and extra.size) or tonumber(ch.style.ruby_size) or math.max(1,base_size*.5)
    st.background=nil;st.outline=nil;st.shadow=nil;st.glow=nil;st.underline=nil;st.overline=nil;st.strikethrough=nil;st.line_through=nil
    local font,size=style_metrics(st);local w,h=F.measure(text,font,size,tonumber(st.letter_spacing) or 0,st.line_height,st)
    return {text=text,style=st,width=w,height=h,position=(ch.style.ruby_position or (type(raw)=="table" and raw.position) or "over"),gap=tonumber(ch.style.ruby_gap) or math.max(1,base_size*.08)}
end

local function emphasis_spec(style)
    local raw=style.text_emphasis_style or style.text_emphasis
    if raw==nil or raw==false or raw=="none" then return nil end
    local mark=raw
    if raw==true or raw=="dot" or raw=="filled dot" then mark="•"
    elseif raw=="circle" or raw=="open circle" then mark="◦"
    elseif raw=="sesame" then mark="﹅"
    elseif type(raw)=="table" then mark=raw.mark or raw.text or "•" end
    mark=tostring(mark or "•")
    return {mark=mark,color=style.text_emphasis_color or style.color or "#FFFFFF",position=style.text_emphasis_position or "over",size=math.max(1,(tonumber(style.size) or 16)*.45)}
end

local function measure_chunk(ch)
    if ch.newline or ch.is_tab then ch.width=0;ch.trim_width=0;return end
    local text=renderable_text(ch.text)
    ch.render_text=text
    if text=="" then ch.width=0;ch.trim_width=0;return end
    local st=ch.style;local font,size=style_metrics(st)
    local opts=copy(st);opts.base_direction=(ch.level or 0)%2==1 and "rtl" or "ltr"
    local w,h,_,metrics=F.measure(text,font,size,tonumber(st.letter_spacing) or 0,st.line_height,opts)
    ch.base_width=w;ch.width=w;ch.height=h;ch.metrics=metrics;ch.space_count=count_spaces(text)
    local trimmed=text:gsub(" +$","")
    if trimmed==text then ch.trim_width=w
    elseif trimmed=="" then ch.trim_width=0
    else ch.trim_width=select(1,F.measure(trimmed,font,size,tonumber(st.letter_spacing) or 0,st.line_height,opts)) end
    ch._ruby=ruby_for_chunk(ch)
    if ch._ruby then
        ch.width=math.max(ch.width,ch._ruby.width);ch.trim_width=math.max(ch.trim_width,ch._ruby.width)
        ch._base_offset=(ch.width-(ch.base_width or 0))/2;ch._ruby_offset=(ch.width-ch._ruby.width)/2
    else ch._base_offset=0 end
    ch._emphasis=emphasis_spec(st)
    local wm=st.writing_mode or st.writing_direction or (st.vertical and "vertical-rl" or nil)
    ch.vertical=(wm=="vertical" or wm=="vertical-rl" or wm=="vertical-lr")
    ch.advance=ch.vertical and h or ch.width
    ch.cross=ch.vertical and ch.width or h
end

local function tab_advance(x,ch,options)
    local st=ch.style
    local stops=st.tab_stops or options.tab_stops
    if type(stops)=="table" then
        for _,v in ipairs(stops) do v=tonumber(v);if v and v>x+1e-9 then return v-x end end
    end
    local interval=tonumber(st.tab_width or options.tab_width)
    if not interval or interval<=0 then
        local font,size=style_metrics(st)
        local sw=select(1,F.measure(" ",font,size,tonumber(st.letter_spacing) or 0,st.line_height,st))
        interval=sw*math.max(1,tonumber(st.tab_size or options.tab_size) or 4)
    end
    if interval<=0 then return 0 end
    local next_stop=(math.floor(x/interval)+1)*interval
    return math.max(0,next_stop-x)
end

local function global_items(spans,options)
    local text_parts={};local mapping={};local global=0;local original_parts={};local span_ranges={}
    local function append_piece(text,map)
        if text=="" then return end
        text_parts[#text_parts+1]=text
        local decoded,err=U.decode(text);if not decoded then error(err) end
        for _,it in ipairs(decoded) do global=global+1;mapping[global]=map and map(it) or {synthetic=true} end
    end
    for si,span in ipairs(spans) do
        original_parts[#original_parts+1]=span.text
        local prefix,suffix=bidi_controls(span.style or {})
        append_piece(prefix,function() return {span=span,span_index=si,synthetic=true,byte_start=1,byte_end=0} end)
        local first=global+1
        local decoded,err=U.decode(span.text);if not decoded then return nil,err end
        span._decoded=decoded
        text_parts[#text_parts+1]=span.text
        for _,it in ipairs(decoded) do
            global=global+1
            mapping[global]={span=span,span_index=si,byte_start=it.byte_start,byte_end=it.byte_end,local_index=_}
        end
        local last=global;span_ranges[si]={first=first,last=last}
        append_piece(suffix,function() return {span=span,span_index=si,synthetic=true,byte_start=1,byte_end=0} end)
    end
    local text=table.concat(text_parts)
    local lb,err=U._line_break_map(text);if not lb then return nil,err end
    local analysis,aerr=U.analyze(text,{base_direction=options.base_direction or "auto"});if not analysis then return nil,aerr end

    -- Grapheme boundaries are the safest universal fallback for break-all/ anywhere behavior.
    local grapheme_after={}
    local gs=U.graphemes(text) or {}
    for _,gr in ipairs(gs) do grapheme_after[gr.last]=true end

    -- Language dictionaries add word boundaries for scripts whose Unicode line breaking class
    -- alone cannot discover them (Thai/Lao/Khmer/etc.).
    if T then
        for si,span in ipairs(spans) do
            local lang=span.style and span.style.language
            local seg=lang and T.segment(lang,span.text)
            local range=span_ranges[si]
            if seg and range then for _,p in ipairs(seg) do local at=range.first+p-1;if at>=range.first and at<range.last then lb.breaks[at]=math.max(lb.breaks[at] or 0,1) end end end
        end
    end

    local function cjk_class(c) return c=="ID" or c=="CJ" or c=="JL" or c=="JV" or c=="JT" or c=="H2" or c=="H3" end
    local function japanese_nonstarter(cp)
        return cp==0x3041 or cp==0x3043 or cp==0x3045 or cp==0x3047 or cp==0x3049 or cp==0x3063 or cp==0x3083 or cp==0x3085 or cp==0x3087 or cp==0x308E or cp==0x3095 or cp==0x3096
            or cp==0x30A1 or cp==0x30A3 or cp==0x30A5 or cp==0x30A7 or cp==0x30A9 or cp==0x30C3 or cp==0x30E3 or cp==0x30E5 or cp==0x30E7 or cp==0x30EE or cp==0x30F5 or cp==0x30F6
            or (cp>=0x31F0 and cp<=0x31FF) or (cp>=0xFF67 and cp<=0xFF70) or cp==0x30FC or cp==0x3005 or cp==0x303B or cp==0x309D or cp==0x309E or cp==0x30FD or cp==0x30FE
    end
    for i=1,#lb.items-1 do
        local map=mapping[i];local nextmap=mapping[i+1]
        if map and not map.synthetic and nextmap and not nextmap.synthetic then
            local st=map.span and map.span.style or {}
            local mode=white_space_mode(st,options)
            local wb=tostring(st.word_break or options.word_break or "normal"):lower():gsub("_","-")
            local linebreak=tostring(st.line_break or options.line_break or "auto"):lower():gsub("_","-")
            local ow=tostring(st.overflow_wrap or options.overflow_wrap or "normal"):lower():gsub("_","-")
            if (mode=="nowrap" or mode=="pre") and (lb.breaks[i] or 0)<2 then lb.breaks[i]=0 end
            if grapheme_after[i] and (wb=="break-all" or linebreak=="anywhere" or ow=="anywhere") then lb.breaks[i]=math.max(lb.breaks[i] or 0,1) end
            if wb=="keep-all" and cjk_class(lb.classes[i]) and cjk_class(lb.classes[i+1]) and (lb.breaks[i] or 0)<2 then lb.breaks[i]=0 end
            local nextcp=lb.items[i+1] and lb.items[i+1].cp
            if linebreak=="strict" and nextcp and japanese_nonstarter(nextcp) and (lb.breaks[i] or 0)<2 then lb.breaks[i]=0
            elseif linebreak=="loose" and nextcp and japanese_nonstarter(nextcp) and grapheme_after[i] then lb.breaks[i]=math.max(lb.breaks[i] or 0,1) end
            if mode=="break-spaces" and lb.raw_classes[i]=="SP" then lb.breaks[i]=math.max(lb.breaks[i] or 0,1) end
        end
    end
    return {text=text,original_text=table.concat(original_parts),items=lb.items,breaks=lb.breaks,raw=lb.raw_classes,classes=lb.classes,analysis=analysis,mapping=mapping,span_ranges=span_ranges}
end

local function slice_span(span,a,b)
    return span.text:sub(a,b)
end

local function make_chunks(spans,g)
    local chunks={};local i=1;local n=#g.items
    while i<=n do
        local map=g.mapping[i];local raw=g.raw[i]
        if (map and map.synthetic) or (g.analysis.items[i] and g.analysis.items[i].bidi_control) then
            i=i+1
        elseif raw=="CR" and i<n and g.raw[i+1]=="LF" then
            chunks[#chunks+1]={newline=true,mandatory=true,cp_start=i,cp_end=i+1,style=map.span.style,span_index=map.span_index,level=g.analysis.items[i].level or 0}
            i=i+2
        elseif raw=="BK" or raw=="CR" or raw=="LF" or raw=="NL" then
            chunks[#chunks+1]={newline=true,mandatory=true,cp_start=i,cp_end=i,style=map.span.style,span_index=map.span_index,level=g.analysis.items[i].level or 0}
            i=i+1
        else
            local start=i;local span_index=map.span_index;local level=g.analysis.items[i].level or 0
            local finish=i
            while finish<n do
                local here=g.mapping[finish];local nxt=g.mapping[finish+1]
                local boundary=g.breaks[finish] or 0
                if not nxt or nxt.synthetic or boundary>0 or nxt.span_index~=span_index or (g.analysis.items[finish+1].level or 0)~=level then break end
                local nr=g.raw[finish+1]
                if nr=="BK" or nr=="CR" or nr=="LF" or nr=="NL" then break end
                finish=finish+1
            end
            local firstmap=g.mapping[start];local lastmap=g.mapping[finish];local span=firstmap.span
            local text=slice_span(span,firstmap.byte_start,lastmap.byte_end)
            local ch={text=text,style=span.style,meta=span.meta,span_index=span_index,byte_start=firstmap.byte_start,byte_end=lastmap.byte_end,
                cp_start=start,cp_end=finish,level=level,can_break=(g.breaks[finish] or 0)>0,mandatory=(g.breaks[finish] or 0)==2}
            local wsm=white_space_mode(span.style,{});if (wsm=="nowrap" or wsm=="pre") and not ch.mandatory then ch.can_break=false end
            if start==finish and g.items[start].cp==9 then ch.is_tab=true end
            if text:find("\194\173",1,true) then ch.soft_hyphen=true end
            measure_chunk(ch);chunks[#chunks+1]=ch;i=finish+1
        end
    end
    return chunks
end

local function groups_from_chunks(chunks)
    local groups={};local current={chunks={}}
    for _,ch in ipairs(chunks) do
        if ch.newline then
            if #current.chunks>0 then groups[#groups+1]=current;current={chunks={}} end
            groups[#groups+1]={newline=true,chunks={ch}}
        else
            current.chunks[#current.chunks+1]=ch
            if ch.can_break then groups[#groups+1]=current;current={chunks={}} end
        end
    end
    if #current.chunks>0 then groups[#groups+1]=current end
    return groups
end

local function group_measure(group,startx,options)
    local x=startx;local last=nil
    for _,ch in ipairs(group.chunks) do
        local w=ch.is_tab and tab_advance(x,ch,options) or (ch.width or 0)
        ch._placed_width=w;x=x+w;last=ch
    end
    local full=x-startx;local trim=full
    if last then
        if last.is_tab then trim=full-(last._placed_width or 0)
        elseif trailing_ascii_spaces(last.render_text or last.text)>0 then trim=full-((last.width or 0)-(last.trim_width or 0)) end
    end
    return full,math.max(0,trim)
end

local function split_chunk_at_positions(ch,positions,hyphenated)
    local decoded,err=U.decode(ch.text);if not decoded then error(err) end
    local cuts={};for _,p in ipairs(positions or {}) do p=math.floor(tonumber(p) or 0);if p>0 and p<#decoded then cuts[p]=true end end
    local pieces={};local a=1
    for i=1,#decoded do
        if cuts[i] or i==#decoded then
            local b=i;local first=decoded[a];local last=decoded[b]
            if first and last then
                local p=copy(ch);p.text=ch.text:sub(first.byte_start,last.byte_end)
                p.byte_start=ch.byte_start+first.byte_start-1;p.byte_end=ch.byte_start+last.byte_end-1
                p.cp_start=ch.cp_start+a-1;p.cp_end=ch.cp_start+b-1;p.can_break=(i<#decoded);p.discretionary_hyphen=hyphenated and i<#decoded or nil
                p.soft_hyphen=p.text:find("\194\173",1,true)~=nil;measure_chunk(p);pieces[#pieces+1]=p
            end
            a=i+1
        end
    end
    return pieces
end

local function hyphenate_chunk(ch,options)
    local st=ch.style or {};local mode=tostring(st.hyphens or options.hyphens or "manual"):lower()
    if mode~="auto" or not T then return nil end
    local text=renderable_text(ch.text)
    if text=="" or text:find("[%s%d%p]") then return nil end
    local limit=st.hyphenate_limit_chars or options.hyphenate_limit_chars
    local hopts={}
    if type(limit)=="table" then hopts.min_left=limit.left or limit[1];hopts.min_right=limit.right or limit[2] end
    local pos=T.hyphenate(st.language or options.language,text,hopts)
    if not pos or #pos==0 then return nil end
    return split_chunk_at_positions(ch,pos,true)
end

local function emergency_split_chunk(ch,max_width,options)
    if ch.is_tab or ch.newline then return {ch} end
    local clusters,err=U.graphemes(ch.text);if not clusters then error(err) end
    if #clusters<=1 then return {ch} end
    local pieces={}
    for _,gr in ipairs(clusters) do
        local p=copy(ch);p.text=gr.text;p.byte_start=ch.byte_start+gr.byte_start-1;p.byte_end=ch.byte_start+gr.byte_end-1
        p.cp_start=ch.cp_start+gr.first-1;p.cp_end=ch.cp_start+gr.last-1;p.can_break=true;p.soft_hyphen=p.text:find("\194\173",1,true)~=nil
        measure_chunk(p);pieces[#pieces+1]=p
    end
    return pieces
end

local function split_oversize_group(group,max_width,options)
    local out={};for _,ch in ipairs(group.chunks) do
        if (ch.width or 0)>max_width and (options.overflow_wrap or "break-word")~="normal" then
            local pieces=hyphenate_chunk(ch,options) or emergency_split_chunk(ch,max_width,options)
            for _,p in ipairs(pieces) do out[#out+1]={chunks={p}} end
        else out[#out+1]={chunks={ch}} end
    end
    return out
end

local function line_metrics(line,base_style)
    local ascent,descent=0,0;local top_extra,bottom_extra=0,0
    for _,ch in ipairs(line.chunks) do
        if not ch.newline then
            local _,size,_,shift,a,d=style_metrics(ch.style)
            -- Normal/default line boxes must contain the glyphs actually being painted, not
            -- merely trust sometimes-pathological ascender/descent metadata.
            if ch.style.line_height==nil and ch.style.line_height_factor==nil and ch.metrics then
                local ia=tonumber(ch.metrics.ink_ascent);local id=tonumber(ch.metrics.ink_descent)
                if ia then a=math.max(a,ia+(shift or 0)) end
                if id then d=math.max(d,id-(shift or 0)) end
                -- A final em-box floor handles bitmap/color glyphs for which no scalable
                -- outline bounds are available.
                if a+d<size then
                    local missing=size-(a+d);a=a+missing*.8;d=d+missing*.2
                end
            end
            ascent=math.max(ascent,a);descent=math.max(descent,d)
            if ch._ruby then
                local e=(ch._ruby.height or 0)+(ch._ruby.gap or 0)
                if tostring(ch._ruby.position):find("under",1,true) then bottom_extra=math.max(bottom_extra,e) else top_extra=math.max(top_extra,e) end
            end
            if ch._emphasis then
                local e=(ch._emphasis.size or size*.45)*.65+math.max(1,size*.06)
                if tostring(ch._emphasis.position):find("under",1,true) then bottom_extra=math.max(bottom_extra,e) else top_extra=math.max(top_extra,e) end
            end
        end
    end
    if ascent==0 and descent==0 then local _,_,_,_,a,d=style_metrics(base_style);ascent,descent=a,d end
    line.base_ascent,line.base_descent=ascent,descent
    line.top_extra,line.bottom_extra=top_extra,bottom_extra
    line.ascent,line.descent,line.height=ascent+top_extra,descent+bottom_extra,ascent+descent+top_extra+bottom_extra
end

local function reorder_visual(chunks)
    local out={};for i,ch in ipairs(chunks) do out[i]=ch end
    local high=0;local low=nil
    for _,ch in ipairs(out) do local l=ch.level or 0;if l>high then high=l end;if l%2==1 and (not low or l<low) then low=l end end
    if low then
        for level=high,low,-1 do
            local p=1
            while p<=#out do
                if (out[p].level or 0)>=level then
                    local a=p;while p<=#out and (out[p].level or 0)>=level do p=p+1 end;local b=p-1
                    while a<b do out[a],out[b]=out[b],out[a];a=a+1;b=b-1 end
                else p=p+1 end
            end
        end
    end
    return out
end

local function line_direction(line,g)
    for _,ch in ipairs(line.chunks) do
        local para
        for _,p in ipairs(g.analysis.paragraphs or {}) do if ch.cp_start and ch.cp_start>=p.first and ch.cp_start<=p.last then para=p;break end end
        if para then return para.base_direction end
    end
    return g.analysis.base_direction or "ltr"
end

local function finish_line(lines,line,base_style,g,options,is_last,forced)
    line_metrics(line,base_style);line.base_direction=line_direction(line,g);line.forced=forced==true;line.is_last=is_last==true
    -- U+00AD is normally invisible, but when its break opportunity is the one actually selected
    -- it contributes a visible hyphen to the preceding line.
    local last=line.chunks[#line.chunks]
    if last and (last.soft_hyphen or last.discretionary_hyphen) and last.can_break and not is_last and not forced then
        local st=last.style;local font,size=style_metrics(st);local opts=copy(st);opts.base_direction=(last.level or 0)%2==1 and "rtl" or "ltr"
        local hw=select(1,F.measure("-",font,size,tonumber(st.letter_spacing) or 0,st.line_height,opts))
        last._break_hyphen_width=hw;last._break_text=(last.render_text or renderable_text(last.text)).."-"
    end
    local visible=line.visible_width or line.full_width or 0
    if last and last._break_hyphen_width then visible=visible+last._break_hyphen_width end
    local maxw=tonumber(options.width or options.max_width)
    local indent=line.indent or 0;local content_w=math.max(0,visible-indent)
    local align=options.align or "start"
    if align=="start" then align=line.base_direction=="rtl" and "right" or "left" elseif align=="end" then align=line.base_direction=="rtl" and "left" or "right" end
    local x=indent
    if maxw then
        local usable=math.max(0,maxw-indent)
        if align=="center" then x=indent+(usable-content_w)/2
        elseif align=="right" then x=indent+usable-content_w end
    end
    local justify=(align=="justify") and maxw and (not is_last or options.justify_last==true) and not forced
    local slots=0
    if justify then for _,ch in ipairs(line.chunks) do if (ch.render_text or ch.text or ""):sub(-1)==" " then slots=slots+1 end end end
    local extra=(justify and slots>0) and math.max(0,(maxw-visible)/slots) or 0
    local visual=reorder_visual(line.chunks);line.fragments={};line.x=x;line.width=justify and maxw or visible
    local pen=x
    for _,ch in ipairs(visual) do
        if not ch.newline then
            local _,size,m,shift=style_metrics(ch.style)
            local w=(ch._placed_width or ch.width or 0)+(ch._break_hyphen_width or 0)
            local frag={text=ch._break_text or ch.render_text or renderable_text(ch.text),x=pen,y=0,width=w,height=m.ascent-m.descent,style=ch.style,meta=ch.meta,
                span_index=ch.span_index,byte_start=ch.byte_start,byte_end=ch.byte_end,cp_start=ch.cp_start,cp_end=ch.cp_end,level=ch.level,
                direction=(ch.level or 0)%2==1 and "rtl" or "ltr",ascent=m.ascent,descent=m.descent,
                ink_ascent=ch.metrics and ch.metrics.ink_ascent or nil,ink_descent=ch.metrics and ch.metrics.ink_descent or nil,
                ink_left=ch.metrics and ch.metrics.ink_left or nil,ink_right=ch.metrics and ch.metrics.ink_right or nil,
                baseline_shift=shift,soft_hyphen=ch.soft_hyphen,
                discretionary_hyphen=ch.discretionary_hyphen,ruby=ch._ruby,emphasis=ch._emphasis,text_offset=ch._base_offset or 0,ruby_offset=ch._ruby_offset or 0}
            line.fragments[#line.fragments+1]=frag;pen=pen+w
            if extra>0 and (ch.render_text or ch.text or ""):sub(-1)==" " then frag.justify_extra=extra;pen=pen+extra end
        end
    end
    lines[#lines+1]=line
end

local function emphasis_boundaries(fr)
    if fr.text=="" then return nil end
    if fr.vertical then
        -- Emphasis marks need grapheme-centered positions along the vertical advance axis.
        local gs=U.graphemes(fr.text) or {};local out={};local n=math.max(1,#gs)
        for i=0,n do
            local local_byte=(i<n and gs[i+1] and gs[i+1].byte_start) or (#fr.text+1)
            out[#out+1]={y=fr.y+fr.height*i/n,x=fr.x,byte=(fr.byte_start or 1)+local_byte-1}
        end
        return out
    end
    if not F._shape_lines then return {{x=fr.x+(fr.text_offset or 0),byte=fr.byte_start}} end
    local st=fr.style;local font,size=style_metrics(st);local opts=copy(st);opts.base_direction=fr.direction
    local ok,shaped,lines=pcall(F._shape_lines,font,fr.text,size,tonumber(st.letter_spacing) or 0,st.line_height,opts)
    if not ok or not lines or not lines[1] then return nil end
    local glyphs=lines[1].glyphs or {};local groups={};local pen=0
    for _,g in ipairs(glyphs) do
        pen=pen+(tonumber(g._layout_kern) or 0);local a=pen;local adv=tonumber(g._layout_advance) or 0;local b=a+adv;pen=b
        local c=math.max(1,tonumber(g.cluster) or tonumber(g.source_index) or 1)
        local gp=groups[c] or {min=math.min(a,b),max=math.max(a,b)};gp.min=math.min(gp.min,a,b);gp.max=math.max(gp.max,a,b);groups[c]=gp
    end
    local decoded=U.decode(fr.text) or {};local clusters={};for c in pairs(groups) do clusters[#clusters+1]=c end;table.sort(clusters)
    if #clusters==0 then return nil end
    local graphemes=U.graphemes(fr.text) or {};local points={};local offset=fr.x+(fr.text_offset or 0)
    local function abs_byte(local_byte)
        return (fr.byte_start or 1)+math.max(0,(local_byte or 1)-1)
    end
    for ci,c in ipairs(clusters) do
        local last=((clusters[ci+1] or (#decoded+1))-1);if last<c then last=c end
        local gp=groups[c];local bounds={c}
        for _,gr in ipairs(graphemes) do if gr.first>=c and gr.last<=last then bounds[#bounds+1]=gr.last+1 end end
        if bounds[#bounds]~=last+1 then bounds[#bounds+1]=last+1 end
        local n=math.max(1,#bounds-1)
        for j=0,n do
            local logical_index=bounds[math.min(j+1,#bounds)] or (last+1)
            local frac=j/n;if fr.direction=="rtl" then frac=1-frac end
            local x=offset+gp.min+(gp.max-gp.min)*frac
            local local_byte=(logical_index<=#decoded and decoded[logical_index].byte_start) or (#fr.text+1)
            points[#points+1]={x=x,byte=abs_byte(local_byte)}
        end
    end
    table.sort(points,function(a,b) if a.x==b.x then return a.byte<b.byte end return a.x<b.x end)
    -- Deduplicate identical visual/source boundaries produced by adjacent clusters.
    local out={};for _,pt in ipairs(points) do local q=out[#out];if not q or math.abs(q.x-pt.x)>1e-7 or q.byte~=pt.byte then out[#out+1]=pt end end
    return out
end

local function vertical_writing_mode(options)
    local wm=options and (options.writing_mode or options.writing_direction)
    if options and options.vertical==true and not wm then wm="vertical-rl" end
    if wm=="vertical" then wm="vertical-rl" end
    if wm=="vertical-rl" or wm=="vertical-lr" then return wm end
    return nil
end

local function vertical_group_measure(group)
    local a=0;for _,ch in ipairs(group.chunks or {}) do a=a+(ch.advance or ch.height or 0) end;return a
end
local function split_oversize_group_vertical(group,maxh,options)
    local out={}
    for _,ch in ipairs(group.chunks or {}) do
        if (ch.advance or 0)>maxh and (options.overflow_wrap or "break-word")~="normal" then
            local pieces=hyphenate_chunk(ch,options) or emergency_split_chunk(ch,maxh,options)
            for _,p in ipairs(pieces) do out[#out+1]={chunks={p}} end
        else out[#out+1]={chunks={ch}} end
    end
    return out
end

local function layout_vertical(content,options,wm)
    local spans,base_style=R.normalize(content,options);spans=preprocess_whitespace(spans,options)
    for _,sp in ipairs(spans) do sp.style.writing_mode=sp.style.writing_mode or wm end
    local g,err=global_items(spans,options);if not g then return nil,err end
    local chunks=make_chunks(spans,g);local groups=groups_from_chunks(chunks)
    local maxh=tonumber(options.height or options.max_height);local columns={};local col={chunks={},advance=0}
    local function finish_col(forced)
        col.forced=forced==true;columns[#columns+1]=col;col={chunks={},advance=0}
    end
    local gi=1
    while gi<=#groups do
        local group=groups[gi]
        if group.newline then finish_col(true);gi=gi+1
        else
            local adv=vertical_group_measure(group)
            if maxh and #col.chunks>0 and col.advance+adv>maxh+1e-7 then finish_col(false)
            elseif maxh and #col.chunks==0 and adv>maxh and (options.overflow_wrap or "break-word")~="normal" then
                local repl=split_oversize_group_vertical(group,maxh,options);table.remove(groups,gi);for j=#repl,1,-1 do table.insert(groups,gi,repl[j]) end
            else
                for _,ch in ipairs(group.chunks) do col.chunks[#col.chunks+1]=ch end;col.advance=col.advance+adv;gi=gi+1
            end
        end
    end
    if #col.chunks>0 or #columns==0 then finish_col(false) end
    local spacing=tonumber(options.column_spacing) or 0;local totalw=0;local tallest=0
    for _,c in ipairs(columns) do
        local cw=0;for _,ch in ipairs(c.chunks) do cw=math.max(cw,ch.cross or ch.width or 0) end
        if cw<=0 then local _,sz=style_metrics(base_style);cw=sz end
        c.width=cw;c.height=c.advance;tallest=math.max(tallest,c.height);totalw=totalw+cw
    end
    if #columns>1 then totalw=totalw+spacing*(#columns-1) end
    local targetw=tonumber(options.width or options.max_width);local targeth=maxh
    local x
    if wm=="vertical-rl" then x=(targetw or totalw) else x=0 end
    local fragments={}
    for ci,c in ipairs(columns) do
        if wm=="vertical-rl" then x=x-c.width;c.x=x else c.x=x end
        local y=0;c.y=0;c.fragments={}
        local valign=tostring(options.align or "start"):lower()
        if targeth and targeth>c.height then if valign=="center" then y=(targeth-c.height)/2 elseif valign=="end" or valign=="bottom" then y=targeth-c.height end end
        for _,ch in ipairs(c.chunks) do
            local w=ch.cross or ch.width or 0;local h=ch.advance or ch.height or 0
            local fr={text=ch.render_text or renderable_text(ch.text),x=c.x+(c.width-w)/2,y=y,width=w,height=h,style=ch.style,meta=ch.meta,
                span_index=ch.span_index,byte_start=ch.byte_start,byte_end=ch.byte_end,cp_start=ch.cp_start,cp_end=ch.cp_end,level=ch.level,
                direction=(ch.level or 0)%2==1 and "rtl" or "ltr",ruby=ch._ruby,emphasis=ch._emphasis,vertical=true,writing_mode=wm}
            c.fragments[#c.fragments+1]=fr;fr.line=c;fr.baseline=nil;fragments[#fragments+1]=fr;y=y+h
        end
        if wm=="vertical-rl" then x=x-spacing else x=x+c.width+spacing end
    end
    local layout={vertical=true,writing_mode=wm,width=targetw or totalw,height=targeth or tallest,content_width=totalw,content_height=tallest,
        lines=columns,columns=columns,fragments=fragments,spans=spans,text=g.original_text or g.text,analysis_text=g.text,base_style=base_style}
    return layout
end

local function layout_once(content,options)
    options=options or {}
    local wm=vertical_writing_mode(options);if wm then return layout_vertical(content,options,wm) end
    local spans,base_style=R.normalize(content,options)
    spans=preprocess_whitespace(spans,options)
    local g,err=global_items(spans,options);if not g then return nil,err end
    local chunks=make_chunks(spans,g);local groups=groups_from_chunks(chunks)
    local maxw=tonumber(options.width or options.max_width)
    local indent=tonumber(options.text_indent) or 0
    local lines={};local line={chunks={},full_width=indent,visible_width=indent,indent=indent};local first=true
    local function reset_line()
        first=false;line={chunks={},full_width=0,visible_width=0,indent=0}
    end
    local gi=1
    while gi<=#groups do
        local group=groups[gi]
        if group.newline then
            finish_line(lines,line,base_style,g,options,false,true);reset_line();gi=gi+1
        else
            local full,trim=group_measure(group,line.full_width,options)
            if maxw and #line.chunks>0 and line.full_width+full>maxw+1e-7 then
                finish_line(lines,line,base_style,g,options,false,false);reset_line()
            elseif maxw and #line.chunks==0 and full>maxw and (options.overflow_wrap or "break-word")~="normal" then
                local repl=split_oversize_group(group,maxw,options)
                table.remove(groups,gi);for j=#repl,1,-1 do table.insert(groups,gi,repl[j]) end
            else
                for _,ch in ipairs(group.chunks) do line.chunks[#line.chunks+1]=ch end
                line.full_width=line.full_width+full;line.visible_width=(line.full_width-full)+trim
                gi=gi+1
            end
        end
    end
    finish_line(lines,line,base_style,g,options,true,false)
    local y=0;local widest=0;local fragments={}
    for _,ln in ipairs(lines) do
        ln.y=y;ln.baseline=y+(ln.top_extra or 0)+(ln.base_ascent or ln.ascent)
        for _,fr in ipairs(ln.fragments or {}) do
            fr.baseline=ln.baseline;fr.y=ln.baseline-(fr.baseline_shift or 0)-fr.ascent;fr.line=ln
            fr.text_x=fr.x+(fr.text_offset or 0)
            fragments[#fragments+1]=fr
        end
        widest=math.max(widest,ln.width or ln.visible_width or 0);y=y+ln.height+(tonumber(options.line_spacing) or 0)
    end
    if #lines>0 then y=y-(tonumber(options.line_spacing) or 0) end
    local layout={width=maxw or widest,height=y,content_width=widest,content_height=y,lines=lines,fragments=fragments,spans=spans,text=g.original_text or g.text,analysis_text=g.text,base_style=base_style}
    return layout
end
R._layout_once=layout_once

local SCALE_KEYS={size=true,letter_spacing=true,word_spacing=true,line_height=true,baseline_shift=true,decoration_width=true,underline_offset=true,strikeout_offset=true,
    tab_width=true,column_spacing=true,ruby_gap=true,ruby_size=true,outline_width=true,shadow_x=true,shadow_y=true,shadow_blur=true,shadow_spread=true,glow_radius=true,glow_spread=true}
local function scale_effect(raw,factor)
    if type(raw)=="number" then return raw*factor end
    if type(raw)~="table" then return raw end
    local o=copy(raw)
    for _,k in ipairs({"width","radius","size","x","y","offset_x","offset_y","blur","spread"}) do if type(o[k])=="number" then o[k]=o[k]*factor end end
    if type(o.offset)=="table" then o.offset=copy(o.offset);for k,v in pairs(o.offset) do if type(v)=="number" then o.offset[k]=v*factor end end end
    return o
end
local function scaled_style(style,factor)
    local o=copy(style)
    for k in pairs(SCALE_KEYS) do if type(o[k])=="number" then o[k]=o[k]*factor end end
    o.outline=scale_effect(o.outline,factor);o.shadow=scale_effect(o.shadow,factor);o.glow=scale_effect(o.glow,factor)
    return o
end
local function scaled_ruby(raw,factor)
    if type(raw)~="table" then return raw end
    local o=copy(raw);if type(o.style)=="table" then o.style=scaled_style(o.style,factor) end
    if type(o.size)=="number" then o.size=o.size*factor end;if type(o.gap)=="number" then o.gap=o.gap*factor end
    return o
end
local function spans_content(spans,factor)
    local out={}
    for _,sp in ipairs(spans) do
        local n={text=sp.text,style=scaled_style(sp.style,factor)}
        if sp.meta then for _,k in ipairs({"id","link","data","role"}) do n[k]=sp.meta[k] end;n.ruby=scaled_ruby(sp.meta.ruby,factor) end
        out[#out+1]=n
    end
    return out
end
local function scaled_layout_options(options,factor)
    local o=copy(options);o.fit=false;o.fit_text=false;o.fit_mode=nil;o.size=nil;o.max_size=nil;o.min_size=nil
    for _,k in ipairs({"line_spacing","text_indent","tab_width","column_spacing"}) do if type(o[k])=="number" then o[k]=o[k]*factor end end
    return o
end

-- Effects do not participate in ordinary paragraph metrics (the same model CSS uses for
-- shadows).
local function fit_visual_margins(spans,vertical)
    local l,t,r,b=0,0,0,0
    for _,sp in ipairs(spans or {}) do
        local sl,st,sr,sb=0,0,0,0
        if E then sl,st,sr,sb=E.margins(sp.style or {}) end
        l=math.max(l,sl or 0);t=math.max(t,st or 0);r=math.max(r,sr or 0);b=math.max(b,sb or 0)
        if vertical then
            local rb=ruby_for_chunk({style=sp.style or {},meta=sp.meta})
            if rb then
                local ext=(rb.width or rb.height or 0)+(rb.gap or 0);local side=tostring(rb.position or "over")
                if side:find("under",1,true) or side:find("left",1,true) then l=math.max(l,ext) else r=math.max(r,ext) end
            end
            local em=emphasis_spec(sp.style or {})
            if em then
                local est=copy(sp.style or {});est.size=em.size;est.outline=nil;est.shadow=nil;est.glow=nil;est.writing_mode=nil;est.writing_direction=nil;est.vertical=false
                local ef=F.get(est.font or M.DEFAULT_FONT);local ew=ef and select(1,F.measure(em.mark,ef,em.size,0,nil,est)) or em.size
                local gap=math.max(1,(tonumber((sp.style or {}).size) or 16)*.06);local side=tostring(em.position or "over")
                if side:find("under",1,true) or side:find("left",1,true) then l=math.max(l,ew+gap) else r=math.max(r,ew+gap) end
            end
        end
    end
    return math.ceil(l),math.ceil(t),math.ceil(r),math.ceil(b)
end

local function shift_layout(layout,dx,dy)
    if (dx or 0)==0 and (dy or 0)==0 then return layout end
    dx,dy=dx or 0,dy or 0
    for _,ln in ipairs(layout.lines or {}) do
        if type(ln.x)=="number" then ln.x=ln.x+dx end
        if type(ln.y)=="number" then ln.y=ln.y+dy end
        if type(ln.baseline)=="number" then ln.baseline=ln.baseline+dy end
    end
    for _,fr in ipairs(layout.fragments or {}) do
        fr.x=(fr.x or 0)+dx;fr.y=(fr.y or 0)+dy
        if type(fr.text_x)=="number" then fr.text_x=fr.text_x+dx end
        if type(fr.baseline)=="number" then fr.baseline=fr.baseline+dy end
    end
    return layout
end

function R.fit_layout(content,options)
    options=options or {};local target_w=tonumber(options.width or options.max_width);local target_h=tonumber(options.height or options.max_height)
    if not target_w or target_w<=0 or not target_h or target_h<=0 then return nil,"fit layout requires positive width and height" end
    local seed=tonumber(options.size) or tonumber(options.max_size) or math.max(4,math.min(target_h,256))
    local max_size=tonumber(options.max_size) or seed;local min_size=tonumber(options.min_size) or math.min(4,max_size)
    if min_size<=0 then min_size=.25 end;if max_size<min_size then min_size,max_size=max_size,min_size end
    local normopts=copy(options);normopts.fit=false;normopts.size=normopts.size or seed
    local spans=R.normalize(content,normopts)
    local ref=seed
    local function at(size)
        local factor=size/ref;local scaled=spans_content(spans,factor);local o=scaled_layout_options(options,factor)
        local vertical=vertical_writing_mode(o)~=nil;local ml,mt,mr,mb=fit_visual_margins(scaled,vertical)
        local inner_w=math.max(.001,target_w-ml-mr);local inner_h=math.max(.001,target_h-mt-mb)
        o.width=inner_w;o.max_width=nil;o.height=inner_h;o.max_height=nil
        local layout,err=layout_once(scaled,o);if not layout then return nil,err end
        local fits=(layout.content_width<=inner_w+1e-6 and layout.content_height<=inner_h+1e-6)
        shift_layout(layout,ml,mt)
        layout.visual_margins={left=ml,top=mt,right=mr,bottom=mb}
        layout.content_width=layout.content_width+ml+mr;layout.content_height=layout.content_height+mt+mb
        layout.height=(layout.height or 0)+mt+mb
        layout.width=target_w
        layout.fit={size=size,scale=factor,target_width=target_w,target_height=target_h,inner_width=inner_w,inner_height=inner_h,fits=fits}
        return layout
    end
    local low_layout,err=at(min_size);if not low_layout then return nil,err end
    if not low_layout.fit.fits then low_layout.fit.overflow=true;return low_layout end
    local high_layout=assert(at(max_size));if high_layout.fit.fits then return high_layout end
    local lo,hi=min_size,max_size;local best=low_layout
    local tolerance=tonumber(options.fit_tolerance) or .125
    for _=1,24 do
        if hi-lo<=tolerance then break end
        local mid=(lo+hi)/2;local l=assert(at(mid))
        if l.fit.fits then lo=mid;best=l else hi=mid end
    end
    return best
end

function R.layout(content,options)
    options=options or {}
    local fit=options.fit or options.fit_text or options.fit_mode
    if fit and tonumber(options.width or options.max_width) and tonumber(options.height or options.max_height) then return R.fit_layout(content,options) end
    return layout_once(content,options)
end

local function decoration_flags(style)
    local u=style.underline==true;local o=style.overline==true;local s=style.strikethrough==true or style.line_through==true
    local td=style.text_decoration
    if type(td)=="string" then u=u or td:find("underline",1,true)~=nil;o=o or td:find("overline",1,true)~=nil;s=s or td:find("line%-through")~=nil end
    return u,o,s
end


local function add_decoration(scene,x,y,width,thick,color,opacity,style)
    width=math.max(0,tonumber(width) or 0);thick=math.max(1,tonumber(thick) or 1);style=tostring(style or "solid"):lower()
    if width<=0 then return end
    if style=="double" then
        V.add(scene,{type="rect",x=x,y=y-thick,width=width,height=thick,fill=color,opacity=opacity})
        V.add(scene,{type="rect",x=x,y=y+thick,width=width,height=thick,fill=color,opacity=opacity})
    elseif style=="dashed" then
        local dash=math.max(3*thick,2);local gap=math.max(2*thick,1);local p=x
        while p<x+width do local w=math.min(dash,x+width-p);V.add(scene,{type="rect",x=p,y=y,width=w,height=thick,fill=color,opacity=opacity});p=p+dash+gap end
    elseif style=="dotted" then
        local r=math.max(.5,thick/2);local step=math.max(thick*2.2,1);local p=x+r
        while p<=x+width-r+.01 do V.add(scene,{type="circle",cx=p,cy=y+thick/2,r=r,fill=color,opacity=opacity});p=p+step end
    elseif style=="wavy" then
        local amp=math.max(1,thick*1.25);local period=math.max(4,thick*6);local pts={};local steps=math.max(2,math.ceil(width/math.max(1,period/4)))
        for i=0,steps do local dx=width*i/steps;pts[#pts+1]={x=x+dx,y=y+thick/2+math.sin(dx/period*math.pi*2)*amp} end
        V.add(scene,{type="polyline",points=pts,stroke=color,stroke_width=thick,opacity=opacity})
    else
        V.add(scene,{type="rect",x=x,y=y,width=width,height=thick,fill=color,opacity=opacity})
    end
end

local function text_options(st,fr,x,y)
    return {
        x=x,y=y,font=st.font or M.DEFAULT_FONT,fallback=st.fallback,size=st.size,color=st.color or "#FFFFFF",
        opacity=st.opacity,palette=st.palette~=nil and st.palette or st.palette_index,color_glyphs=st.color_glyphs,bitmap_filter=st.bitmap_filter,
        bitmap_ppi=st.bitmap_ppi or st.ppi,hinting=st.hinting,gasp=st.gasp,letter_spacing=st.letter_spacing,word_spacing=st.word_spacing,
        line_height=st.line_height,language=st.language,features=st.features or st.font_features or st.font_feature_settings,kerning=st.kerning,ligatures=st.ligatures,
        base_direction=fr and fr.direction or st.base_direction,text_mode=st.text_mode,stroke_width=st.stroke_width,fill_rule=st.fill_rule,
        writing_mode=st.writing_mode or st.writing_direction,vertical=st.vertical,vertical_feature=st.vertical_feature,column_spacing=st.column_spacing,
    }
end

local function effect_image(fr,st)
    local l,t,r,b,fx=0,0,0,0,nil
    if E then l,t,r,b,fx=E.margins(st) end
    if not fx then return nil end
    local nominal_ascent=tonumber(fr.ascent) or 0;local nominal_descent=math.max(0,-(tonumber(fr.descent) or 0))
    local top_extra=math.max(0,(tonumber(fr.ink_ascent) or nominal_ascent)-nominal_ascent)
    local bottom_extra=math.max(0,(tonumber(fr.ink_descent) or nominal_descent)-nominal_descent)
    local w=math.max(1,math.ceil((fr.width or 0)+l+r));local h=math.max(1,math.ceil((fr.height or 0)+top_extra+bottom_extra+t+b))
    local sc=V.new_scene(w,h,{background="#00000000",supersample=st.supersample})
    V.add(sc,F.text_object(fr.text,text_options(st,fr,l+(fr.text_offset or 0),t+top_extra)))
    local cv=V.render(sc,{supersample=st.supersample});cv=E.apply(cv,fx,"#00000000")
    return {width=cv.width,height=cv.height,rgba=V.rgba(cv)},l,t+top_extra
end

local function add_ruby(scene,fr,pad,dy)
    local rb=fr.ruby;if not rb then return end
    local x,y
    if fr.vertical then
        local side=tostring(rb.position or "over")
        if side:find("under",1,true) or side:find("left",1,true) then x=pad+fr.x-(rb.width or 0)-(rb.gap or 0) else x=pad+fr.x+fr.width+(rb.gap or 0) end
        y=pad+dy+fr.y+math.max(0,(fr.height-(rb.height or 0))/2)
        local st=copy(rb.style);st.writing_mode=nil;st.writing_direction=nil;st.vertical=false
        V.add(scene,F.text_object(rb.text,text_options(st,fr,x,y)));return
    end
    x=pad+fr.x+(fr.ruby_offset or 0)
    if tostring(rb.position):find("under",1,true) then y=pad+dy+fr.y+fr.height+(rb.gap or 0)
    else y=pad+dy+fr.y-(rb.gap or 0)-(rb.height or 0) end
    V.add(scene,F.text_object(rb.text,text_options(rb.style,fr,x,y)))
end

local function add_emphasis(scene,fr,pad,dy)
    local em=fr.emphasis;if not em then return end
    local boundaries=emphasis_boundaries(fr);if not boundaries or #boundaries<2 then return end
    local st=copy(fr.style);st.size=em.size;st.color=em.color;st.outline=nil;st.shadow=nil;st.glow=nil;st.writing_mode=nil;st.writing_direction=nil;st.vertical=false
    local mf=F.get(st.font or M.DEFAULT_FONT);local mw,mh=F.measure(em.mark,mf,st.size,0,nil,st);local seen={}
    for i=1,#boundaries-1 do
        local a,b=boundaries[i],boundaries[i+1];local key=tostring(a.byte)..":"..tostring(b.byte)
        if not seen[key] then
            seen[key]=true;local gap=math.max(1,(tonumber(fr.style.size) or 16)*.06);local x,y
            if fr.vertical then
                y=pad+dy+((a.y or fr.y)+(b.y or fr.y))/2-mh/2
                if tostring(em.position):find("under",1,true) or tostring(em.position):find("left",1,true) then x=pad+fr.x-mw-gap else x=pad+fr.x+fr.width+gap end
            elseif math.abs((b.x or 0)-(a.x or 0))>1e-6 then
                x=pad+(a.x+b.x)/2-mw/2
                if tostring(em.position):find("under",1,true) then y=pad+dy+fr.y+fr.height+gap else y=pad+dy+fr.y-em.size*.65-gap end
            end
            if x and y then V.add(scene,F.text_object(em.mark,text_options(st,fr,x,y))) end
        end
    end
end

function R.scene(content,options)
    options=options or {};local layout,err=R.layout(content,options);if not layout then return nil,err end
    local pad=tonumber(options.padding) or 0
    local boxw=tonumber(options.width or options.max_width) or (layout.width or layout.content_width)
    local boxh=tonumber(options.height or options.max_height) or layout.height
    local width=math.max(1,math.ceil(boxw+pad*2));local height=math.max(1,math.ceil(boxh+pad*2))
    local valign=tostring(options.valign or options.vertical_align or "top"):lower();local dy=0
    if boxh>layout.height then if valign=="middle" or valign=="center" then dy=(boxh-layout.height)/2 elseif valign=="bottom" or valign=="end" then dy=boxh-layout.height end end
    layout.offset_y=dy
    local scene=V.new_scene(width,height,{background=options.background or "#00000000",supersample=options.supersample})
    -- Inline backgrounds first.
    for _,fr in ipairs(layout.fragments) do
        local st=fr.style;if st.background and st.background~="transparent" then
            local bx,by,bw,bh=pad+fr.x,pad+dy+(fr.vertical and fr.y or fr.line.y),fr.width+(fr.justify_extra or 0),fr.vertical and fr.height or fr.line.height
            V.add(scene,{type="rect",x=bx,y=by,width=bw,height=bh,fill=st.background,opacity=st.background_opacity})
        end
    end
    -- Text and per-span silhouette effects.
    for _,fr in ipairs(layout.fragments) do
        if fr.text~="" then
            local st=fr.style;local img,l,t=effect_image(fr,st)
            if img then
                -- Effect-backed spans are already raster images, but their placement is still
                -- ordinary paragraph geometry.
                local ix=pad+fr.x-l
                local iy=pad+dy+fr.y-t
                V.add(scene,{type="rgba_image",image=img,transform=V.translate(ix,iy),filter="nearest"})
            else
                V.add(scene,F.text_object(fr.text,text_options(st,fr,pad+(fr.text_x or fr.x),pad+dy+fr.y)))
            end
            add_ruby(scene,fr,pad,dy);add_emphasis(scene,fr,pad,dy)
        end
    end
    -- Decorations are painted above backgrounds/text, matching ordinary rich-text expectations.
    for _,fr in ipairs(layout.fragments) do
        local st=fr.style;local u,o,ss=decoration_flags(st)
        if u or o or ss then
            local font,size=style_metrics(st);local scale=size/font.units_per_em
            local thick=tonumber(st.decoration_width) or ((font.underline_thickness and math.abs(font.underline_thickness)*scale) or math.max(1,size/16))
            thick=math.max(1,thick);local color=st.decoration_color or st.color or "#FFFFFF"
            if fr.vertical then
                local function vline(x) V.add(scene,{type="rect",x=x,y=pad+dy+fr.y,width=thick,height=fr.height,fill=color,opacity=st.opacity}) end
                if u then vline(pad+fr.x+fr.width+math.max(1,size*.08)) end
                if o then vline(pad+fr.x-math.max(thick,size*.08)) end
                if ss then vline(pad+fr.x+fr.width/2-thick/2) end
            else
                local baseline=pad+dy+fr.baseline-(fr.baseline_shift or 0)
                if u then
                    local pos=tonumber(st.underline_offset);if pos==nil then pos=font.underline_position and (-font.underline_position*scale) or size*0.10 end
                    add_decoration(scene,pad+fr.x,baseline+pos,fr.width+(fr.justify_extra or 0),thick,color,st.opacity,st.decoration_style or st.text_decoration_style)
                end
                if ss then
                    local pos=tonumber(st.strikeout_offset);if pos==nil then pos=font.strikeout_position and (font.strikeout_position*scale) or size*0.30 end
                    local sthick=tonumber(st.decoration_width) or ((font.strikeout_size and math.abs(font.strikeout_size)*scale) or thick)
                    add_decoration(scene,pad+fr.x,baseline-pos,fr.width+(fr.justify_extra or 0),math.max(1,sthick),color,st.opacity,st.decoration_style or st.text_decoration_style)
                end
                if o then add_decoration(scene,pad+fr.x,baseline-fr.ascent,fr.width+(fr.justify_extra or 0),thick,color,st.opacity,st.decoration_style or st.text_decoration_style) end
            end
        end
    end
    return scene,layout
end

function R.render(content,options)
    local scene,layout=R.scene(content,options);if not scene then return nil,layout end
    return V.render(scene,options),layout
end
function R.texture(content,options)
    local canvas,layout=R.render(content,options);if not canvas then return nil,layout end
    local texture,cv=O.to_texture(canvas,options);if not texture then return nil,cv end
    return texture,cv,layout
end
function R.png(content,options)
    local canvas,layout=R.render(content,options);if not canvas then return nil,layout end
    local png,cv=O.to_png(canvas,options);if not png then return nil,cv end
    return png,cv,layout
end


-- Acyclic geometry snapshot suitable for async IPC, hit testing, links and document adapters.
function R.snapshot(layout)
    assert(type(layout)=="table","rich-text layout table required")
    local out={width=layout.width,height=layout.height,content_width=layout.content_width,content_height=layout.content_height,text=layout.text,
        vertical=layout.vertical==true,writing_mode=layout.writing_mode,fit=layout.fit and copy(layout.fit) or nil,lines={}}
    for li,ln in ipairs(layout.lines or {}) do
        local ol={index=li,x=ln.x,y=ln.y,width=ln.width,height=ln.height,baseline=ln.baseline,ascent=ln.ascent,descent=ln.descent,
            base_direction=ln.base_direction,forced=ln.forced==true,is_last=ln.is_last==true,fragments={}}
        for fi,fr in ipairs(ln.fragments or {}) do
            local of={index=fi,text=fr.text,x=fr.x,y=fr.y,width=fr.width,height=fr.height,baseline=fr.baseline,
                span_index=fr.span_index,byte_start=fr.byte_start,byte_end=fr.byte_end,cp_start=fr.cp_start,cp_end=fr.cp_end,
                direction=fr.direction,level=fr.level,justify_extra=fr.justify_extra,meta=fr.meta,vertical=fr.vertical==true}
            ol.fragments[#ol.fragments+1]=of
        end
        out.lines[#out.lines+1]=ol
    end
    return out
end

-- Box-level hit testing returns source span/range metadata only.
local function each_fragment(layout, callback)
    if type(layout.fragments)=="table" and #layout.fragments>0 then
        for _,fr in ipairs(layout.fragments) do callback(fr,fr.line) end
        return
    end
    for _,ln in ipairs(layout.lines or {}) do
        for _,fr in ipairs(ln.fragments or {}) do callback(fr,ln) end
    end
end

function R.hit_test(layout,x,y)
    x=tonumber(x) or 0;y=tonumber(y) or 0
    if layout.vertical then
        local found
        each_fragment(layout,function(fr,ln)
            if not found and x>=fr.x and x<fr.x+(fr.width or 0) and y>=fr.y and y<fr.y+(fr.height or 0) then
                found={fragment=fr,line=ln,span_index=fr.span_index,byte_start=fr.byte_start,byte_end=fr.byte_end,meta=fr.meta}
            end
        end)
        return found
    end
    local best_line
    for _,ln in ipairs(layout.lines or {}) do if y>=ln.y and y<ln.y+(ln.height or 0) then best_line=ln;break end end
    if not best_line then return nil end
    for _,fr in ipairs(best_line.fragments or {}) do
        local w=(fr.width or 0)+(fr.justify_extra or 0)
        if x>=fr.x and x<fr.x+w then
            return {line=best_line,fragment=fr,span_index=fr.span_index,byte_start=fr.byte_start,byte_end=fr.byte_end,
                cp_start=fr.cp_start,cp_end=fr.cp_end,meta=fr.meta}
        end
    end
    return {line=best_line}
end

-- Top-level aliases.
M.layout_rich_text=R.layout
M.fit_rich_text=R.fit_layout
M.fit_texture=function(content,options) local o=copy(options);o.fit=true;return R.texture(content,o) end
M.fit_png=function(content,options) local o=copy(options);o.fit=true;return R.png(content,o) end
M.rich_text_scene=R.scene
M.render_rich_text=R.render
M.rich_texture=R.texture
M.rich_png=R.png

-- Font methods.
function F._methods:layout_rich_text(content,options) local o=copy(options);o.font=self;return R.layout(content,o) end
function F._methods:rich_texture(content,options) local o=copy(options);o.font=self;return R.texture(content,o) end
function F._methods:rich_png(content,options) local o=copy(options);o.font=self;return R.png(content,o) end
function F._methods:fit_layout(content,options) local o=copy(options);o.font=self;o.fit=true;return R.layout(content,o) end
function F._methods:fit_texture(content,options) local o=copy(options);o.font=self;o.fit=true;return R.texture(content,o) end
function F._methods:fit_png(content,options) local o=copy(options);o.font=self;o.fit=true;return R.png(content,o) end
F._methods.fit=F._methods.fit_texture
F._methods.paragraph=F._methods.rich_texture

return R
