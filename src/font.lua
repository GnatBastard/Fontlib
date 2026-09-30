-- SPDX-License-Identifier: 0BSD
-- Font objects and glyph rendering.
local core = assert(rawget(_G, "core") or rawget(_G, "minetest"))
local M = fontlib
local F = M.font
local V = M.vector

F._registry = F._registry or {}
F._methods = F._methods or {}
F._font_mt = F._font_mt or {__index = F._methods}

local function clear_table(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for k in pairs(t) do t[k] = nil; n = n + 1 end
    return n
end

-- Internal cache registration.
function F._track_cache(font, cache)
    assert(type(font) == "table" and type(cache) == "table", "font/cache table required")
    font._cache_tables = font._cache_tables or {}
    font._cache_tables[#font._cache_tables + 1] = cache
    return cache
end

local function valid_font_id(id)
    if type(id) ~= "string" then
        return false
    end
    local owner, name = id:match("^([a-z0-9_]+):([a-z0-9_]+)$")
    return owner ~= nil and name ~= nil
end

local function normalize(font)
    assert(type(font) == "table", "font definition required")
    font._fontlib_font = true
    font.format = "fontlib.font"
    font.object_version = tonumber(font.object_version) or 1
    font.family = font.family or font.name or "Unnamed Font"
    font.style = font.style or "Regular"
    font.full_name = font.full_name or font.family
    font.units_per_em = tonumber(font.units_per_em or font.units) or 1000
    font.ascent = tonumber(font.ascent) or font.units_per_em
    font.descent = tonumber(font.descent) or 0
    font.line_gap = tonumber(font.line_gap) or 0
    font.default_advance = tonumber(font.default_advance or font.advance) or font.units_per_em * 0.5
    font.stroke_width = tonumber(font.stroke_width) or font.units_per_em * 0.075
    font.mode = font.mode or "fill"
    font.fill_rule = font.fill_rule or "nonzero"
    font.glyphs = font.glyphs or {}
    if font._static_glyphs == nil then
        font._static_glyphs = {}
        for cp, g in pairs(font.glyphs) do font._static_glyphs[cp] = g end
    end
    font.aliases = font.aliases or {}
    font.kern = font.kern or {}
    if getmetatable(font) == nil then
        setmetatable(font, F._font_mt)
    end
    return font
end
F._normalize = normalize

function F.is_font(value)
    return type(value) == "table" and value._fontlib_font == true
end

function F.register(id, font)
    assert(valid_font_id(id), "font id must be lowercase and namespaced like 'my_mod:my_font'")
    assert(F._registry[id] == nil, "font already registered: " .. id)
    font = normalize(font)
    font.id = id
    F._registry[id] = font
    return font
end

function F.unregister(id)
    local old = F._registry[id]
    F._registry[id] = nil
    return old
end

function F.get(ref)
    if F.is_font(ref) then
        return ref
    end
    if ref == nil then
        ref = M.DEFAULT_FONT
    end
    return F._registry[ref]
end

function F.list()
    local out = {}
    for id in pairs(F._registry) do
        out[#out + 1] = id
    end
    table.sort(out)
    return out
end

function F.clear_cache(ref)
    local font = F.get(ref)
    if not font then return nil, "unknown font" end
    local released = 0

    -- glyphs contains lazily resolved glyph objects for runtime sources.
    released = released + clear_table(font.glyphs)
    for cp, g in pairs(font._static_glyphs or {}) do font.glyphs[cp] = g end

    released = released + clear_table(font._missing_glyphs)
    font._missing_fallback_checked = nil
    font._missing_fallback_glyph = nil
    font._tt_hint_last_error = nil
    font._tt_hint_last_warning = nil

    for _, cache in ipairs(font._cache_tables or {}) do
        released = released + clear_table(cache)
    end
    collectgarbage("step")
    return released
end

function F._methods:clear_cache()
    local released, err = F.clear_cache(self)
    if released and M.async and M.async.clear_cache then M.async.clear_cache(self) end
    return released, err
end

function M.clear_cache(ref)
    if ref ~= nil then
        local released, err = F.clear_cache(ref)
        if released and M.async and M.async.clear_cache then M.async.clear_cache(ref) end
        return released, err
    end
    local total = 0
    for _, id in ipairs(F.list()) do
        local n = F.clear_cache(id)
        if n then total = total + n end
    end
    -- Publication bookkeeping is *not* cleared here: Luanti keeps non-ephemeral dynamic media
    -- registered for the server lifetime, and we must remember those names so we do not try to
    if M.async and M.async.clear_cache then total = total + (M.async.clear_cache() or 0) end
    return total
end

M.clear_caches = M.clear_cache

function F.has_glyph(ref, codepoint)
    local font = F.get(ref)
    local cp = tonumber(codepoint) or -1
    if not font then return false end
    local seen = {}
    while font.aliases and font.aliases[cp] and not seen[cp] do
        seen[cp] = true
        cp = font.aliases[cp]
    end
    if font.glyphs[cp] ~= nil then return true end
    if font._lookup_gid then return (font._lookup_gid(cp) or 0) ~= 0 end
    return false
end

local function utf8_codes(text)
    local codes, err = M.unicode.codepoints(text)
    assert(codes, err)
    return codes
end

local function glyph(font, cp)
    local seen = {}
    while font.aliases[cp] and not seen[cp] do
        seen[cp] = true
        cp = font.aliases[cp]
    end
    local g = font.glyphs[cp]
    if g == nil and font._get_glyph and not (font._missing_glyphs and font._missing_glyphs[cp]) then
        g = font:_get_glyph(cp)
        if g then
            font.glyphs[cp] = g
        else
            font._missing_glyphs = font._missing_glyphs or {}
            font._missing_glyphs[cp] = true
        end
    end
    if g then return g end
    -- Prefer an explicit replacement character or question mark when the font actually maps
    -- one.
    for _, fallback in ipairs({0xFFFD, 63}) do
        if fallback ~= cp then
            local fg = font.glyphs[fallback]
            if fg == nil and font._get_glyph and not (font._missing_glyphs and font._missing_glyphs[fallback]) then
                fg = font:_get_glyph(fallback)
                if fg then font.glyphs[fallback] = fg else font._missing_glyphs = font._missing_glyphs or {}; font._missing_glyphs[fallback] = true end
            end
            if fg then return fg end
        end
    end
    if font._get_missing_glyph then
        local fg = font._missing_fallback_glyph
        if fg == nil and not font._missing_fallback_checked then
            font._missing_fallback_checked = true
            fg = font:_get_missing_glyph()
            font._missing_fallback_glyph = fg or false
        elseif fg == false then
            fg = nil
        end
        if fg then return fg end
    end
    -- Legacy/non-SFNT sources may not define a .notdef glyph.
    local fallback=32
    if fallback~=cp then
        local fg=font.glyphs[fallback]
        if fg==nil and font._get_glyph and not (font._missing_glyphs and font._missing_glyphs[fallback]) then
            fg=font:_get_glyph(fallback)
            if fg then font.glyphs[fallback]=fg else font._missing_glyphs=font._missing_glyphs or {};font._missing_glyphs[fallback]=true end
        end
        if fg then return fg end
    end
    return nil
end

function F.get_glyph(font_ref, codepoint)
    local font = F.get(font_ref)
    if not font then return nil, "unknown font" end
    local cp = tonumber(codepoint)
    if not cp then return nil, "codepoint must be a number" end
    return glyph(font, cp)
end

function F._methods:get_glyph(codepoint)
    return F.get_glyph(self, codepoint)
end

function F._methods:has_glyph(codepoint)
    return F.has_glyph(self, codepoint)
end

function F.get_vertical_metrics(font_ref,glyph_id,size)
    local font=F.get(font_ref);if not font then return nil,"unknown font" end
    local gid=tonumber(glyph_id);if not gid then return nil,"glyph_id must be a number" end
    if not font._vertical_metrics_for_gid then return nil,"font has no vertical metric resolver" end
    local vm=font:_vertical_metrics_for_gid(gid);if not vm then return nil end
    local scale=tonumber(size) and tonumber(size)/font.units_per_em or 1
    return {
        advance=vm.advance*scale,top_side_bearing=vm.top_side_bearing*scale,bottom_side_bearing=vm.bottom_side_bearing*scale,
        origin_x=vm.origin_x*scale,origin_y=vm.origin_y*scale,synthesized=vm.synthesized==true,scale=scale,
    }
end

function F._methods:get_vertical_metrics(glyph_id,size) return F.get_vertical_metrics(self,glyph_id,size) end

local function kerning(font, left, right)
    if not left or not right then return 0 end
    local direct = font.kern[left .. ":" .. right]
    if direct then return direct end
    if font._lookup_gid then
        local lg = font._lookup_gid(left) or 0
        local rg = font._lookup_gid(right) or 0
        local amount = font._kern_glyphs and (font._kern_glyphs[lg .. ":" .. rg] or 0) or 0
        if amount == 0 and font._gpos_kern then amount = font._gpos_kern(lg, rg) or 0 end
        return amount
    end
    return 0
end

local function kerning_items(font, left, right)
    if not left or not right or left.newline or right.newline then return 0 end
    if font._lookup_gid and left.gid and right.gid then
        local amount = font._kern_glyphs and (font._kern_glyphs[left.gid .. ":" .. right.gid] or 0) or 0
        if amount == 0 and font._gpos_kern then amount = font._gpos_kern(left.gid, right.gid) or 0 end
        return amount
    end
    return kerning(font, left.cp, right.cp)
end

local function metrics(font, size, line_height)
    local scale = size / font.units_per_em
    local glyph_height = (font.ascent - font.descent) * scale
    local default_line_height = (font.ascent - font.descent + font.line_gap) * scale
    return scale, glyph_height, tonumber(line_height) or default_line_height
end

local function writing_mode(options)
    options=options or {};local wm=options.writing_mode or options.writing_direction
    if options.vertical==true and not wm then wm="vertical-rl" end
    if options.direction=="ttb" and not wm then wm="vertical-rl" end
    if wm=="vertical" then wm="vertical-rl" end
    if wm=="vertical-rl" or wm=="vertical-lr" then return wm end
    return nil
end

local function vertical_metrics(font,size,column_spacing)
    local scale=size/font.units_per_em
    local va=tonumber(font.vertical_ascent);local vd=tonumber(font.vertical_descent);local vg=tonumber(font.vertical_line_gap) or 0
    local cell=(va and vd) and (va-vd)*scale or size
    if cell<=0 then cell=size end
    local advance=(va and vd) and (va-vd+vg)*scale or size
    advance=tonumber(column_spacing) or advance
    return scale,cell,advance
end

local function shape_text(font,text,options)
    -- PDF and other document formats may already provide glyph IDs and exact advances/offsets.
    if options and type(options._glyph_run)=="table" then
        return {glyphs=options._glyph_run,positioned=true,prepositioned=true}
    end
    if M.shaping and M.shaping.shape then
        local shaped,err=M.shaping.shape(tostring(text or ""),font,options or {})
        if shaped then return shaped end
        error(err)
    end
    -- Bootstrap fallback; normally shaping.lua is loaded before this is called.
    local gs={}
    for _,cp in ipairs(utf8_codes(tostring(text or ""))) do
        if cp==10 then gs[#gs+1]={newline=true,cp=cp,advance=0}
        else local g=glyph(font,cp);gs[#gs+1]={cp=cp,advance=g and g.advance or font.default_advance} end
    end
    return {glyphs=gs}
end

local hint_shaped_items

local function item_font(primary,item)
    return (item and item._font) or primary
end

local function is_word_space(cp)
    if type(cp)~="number" then return false end
    return cp==0x20 or cp==0xA0 or cp==0x1680 or (cp>=0x2000 and cp<=0x200A) or cp==0x202F or cp==0x205F or cp==0x3000
end

local function shaped_lines(font,text,size,letter_spacing,line_height,shape_options)
    local wm=writing_mode(shape_options)
    local word_spacing=tonumber((shape_options or {}).word_spacing) or 0
    local shape_opts={}
    for k,v in pairs(shape_options or {}) do shape_opts[k]=v end
    if shape_opts.ppem==nil then shape_opts.ppem=size end
    if wm then shape_opts.writing_mode=wm end
    local shaped=shape_text(font,text,shape_opts)
    hint_shaped_items(font,shaped,size,shape_options,wm~=nil)
    if wm then
        local scale,cell_width,column_advance=vertical_metrics(font,size,(shape_options or {}).column_spacing or line_height)
        local columns={{glyphs={},height=0}};local column=columns[1]
        for _,item in ipairs(shaped.glyphs) do
            if item.newline then
                if #column.glyphs>0 then column.height=math.max(0,column.height-letter_spacing) end
                column={glyphs={},height=0};columns[#columns+1]=column
            else
                local ifont=item_font(font,item);local iscale=size/ifont.units_per_em
                local yadv=tonumber(item.y_advance)
                if yadv==nil then
                    local vm=ifont._vertical_metrics_for_gid and ifont:_vertical_metrics_for_gid(item.gid or 0) or nil
                    yadv=-((vm and vm.advance) or ifont.units_per_em)
                end
                item._layout_scale=iscale
                item._layout_x_advance=(tonumber(item.x_advance) or 0)*iscale
                item._layout_y_advance=-yadv*iscale+letter_spacing
                item._layout_x_offset=(tonumber(item.x_offset) or 0)*iscale
                item._layout_y_offset=(tonumber(item.y_offset) or 0)*iscale
                column.height=column.height+item._layout_y_advance
                column.glyphs[#column.glyphs+1]=item
            end
        end
        if #column.glyphs>0 then column.height=math.max(0,column.height-letter_spacing) end
        return shaped,columns,scale,cell_width,column_advance,{vertical=true,writing_mode=wm,cell_width=cell_width,column_advance=column_advance}
    end

    local scale,glyph_height,resolved_line_height=metrics(font,size,line_height)
    local max_ascent=font.ascent*scale;local min_descent=font.descent*scale
    local max_default_line=(font.ascent-font.descent+font.line_gap)*scale
    local lines={{glyphs={},width=0}}
    local line=lines[1]
    local previous
    for _,item in ipairs(shaped.glyphs) do
        if item.newline then
            if #line.glyphs>0 then line.width=math.max(0,line.width-letter_spacing) end
            line={glyphs={},width=0};lines[#lines+1]=line;previous=nil
        else
            local ifont=item_font(font,item);local iscale=size/ifont.units_per_em
            max_ascent=math.max(max_ascent,ifont.ascent*iscale)
            min_descent=math.min(min_descent,ifont.descent*iscale)
            max_default_line=math.max(max_default_line,(ifont.ascent-ifont.descent+ifont.line_gap)*iscale)
            local pfont=previous and item_font(font,previous) or nil
            local positioned=ifont._gpos~=nil
            local kern=(not positioned and previous and pfont==ifont) and (kerning_items(ifont,previous,item)*iscale) or 0
            local adv_units=tonumber(item.x_advance or item.advance) or ifont.default_advance
            item._layout_scale=iscale
            item._layout_kern=kern
            item._layout_advance=adv_units*iscale+letter_spacing+(is_word_space(item.cp) and word_spacing or 0)
            item._layout_x_offset=(tonumber(item.x_offset) or 0)*iscale
            item._layout_y_offset=(tonumber(item.y_offset) or 0)*iscale
            line.width=line.width+kern+item._layout_advance
            line.glyphs[#line.glyphs+1]=item
            previous=item
        end
    end
    if #line.glyphs>0 then line.width=math.max(0,line.width-letter_spacing) end
    glyph_height=max_ascent-min_descent
    if line_height==nil then resolved_line_height=max_default_line end
    return shaped,lines,scale,glyph_height,resolved_line_height,{vertical=false,ascent=max_ascent,descent=min_descent}
end
F._shape_lines = shaped_lines

local function item_design_ink_bounds(ifont,item)
    if not ifont or not item or not item.gid or item.gid==0 then return nil end
    -- TrueType-backed faces expose authoritative y-up design bounds directly.
    if ifont._design_bounds_for_gid then
        local ok,xmin,ymin,xmax,ymax=pcall(ifont._design_bounds_for_gid,item.gid)
        if ok and xmin~=nil and ymin~=nil and xmax~=nil and ymax~=nil then
            return xmin,ymin,xmax,ymax,true
        end
    end
    -- CFF/static faces may only expose Fontlib's cached y-down outlines.
    local contours=ifont._outline_for_gid and ifont._outline_for_gid(item.gid) or nil
    if not contours and item.cp then
        local g=ifont.glyphs and ifont.glyphs[item.cp]
        contours=g and g.contours or nil
    end
    if contours then
        local minx,miny,maxx,maxy
        for _,c in ipairs(contours or {}) do for _,pt in ipairs(c or {}) do
            local x,y=pt.x or 0,pt.y or 0
            minx=minx and math.min(minx,x) or x;maxx=maxx and math.max(maxx,x) or x
            miny=miny and math.min(miny,y) or y;maxy=maxy and math.max(maxy,y) or y
        end end
        if minx~=nil then return minx,miny,maxx,maxy,false end
    end
    return nil
end

local function horizontal_ink_metrics(font,lines,size,layout)
    if not lines or not lines[1] or not layout or layout.vertical then return nil end
    local minx,maxx,min_top,max_bottom
    for _,line in ipairs(lines) do
        local pen=0
        for _,item in ipairs(line.glyphs or {}) do
            pen=pen+(tonumber(item._layout_kern) or 0)
            local ifont=item_font(font,item);local iscale=item._layout_scale or (size/ifont.units_per_em)
            local xoff=tonumber(item._layout_x_offset) or 0;local yoff=tonumber(item._layout_y_offset) or 0
            local xmin,ymin,xmax,ymax,yup=item_design_ink_bounds(ifont,item)
            if xmin~=nil then
                local left=pen+xoff+xmin*iscale
                local right=pen+xoff+xmax*iscale
                local ascent,descent
                if yup then
                    ascent=ymax*iscale+yoff
                    descent=-ymin*iscale-yoff
                else
                    -- Fontlib outline coordinates are y-down with the baseline at ifont.ascent.
                    ascent=(ifont.ascent-ymin)*iscale+yoff
                    descent=(ymax-ifont.ascent)*iscale-yoff
                end
                ascent=math.max(0,ascent);descent=math.max(0,descent)
                minx=minx and math.min(minx,left) or left;maxx=maxx and math.max(maxx,right) or right
                min_top=min_top and math.max(min_top,ascent) or ascent
                max_bottom=max_bottom and math.max(max_bottom,descent) or descent
            end
            pen=pen+(tonumber(item._layout_advance) or 0)
        end
    end
    if min_top==nil then return nil end
    return {ink_left=minx or 0,ink_right=maxx or 0,ink_ascent=min_top or 0,ink_descent=max_bottom or 0}
end

function F.measure(text, font_ref, size, letter_spacing, line_height, shape_options)
    local font = assert(F.get(font_ref), "unknown Fontlib font " .. tostring(font_ref))
    size = tonumber(size) or font.units_per_em
    letter_spacing = tonumber(letter_spacing) or 0
    local _,lines,scale,glyph_extent,resolved_line_height,layout=shaped_lines(font,text,size,letter_spacing,line_height,shape_options)
    if layout and layout.vertical then
        local max_height=0;for _,column in ipairs(lines) do if column.height>max_height then max_height=column.height end end
        local width=(#lines-1)*layout.column_advance+layout.cell_width
        return width,max_height,#lines,{
            width=width,height=max_height,lines=#lines,columns=#lines,vertical=true,writing_mode=layout.writing_mode,
            column_width=layout.cell_width,column_advance=layout.column_advance,line_height=layout.column_advance,scale=scale,
            vertical_ascent=(font.vertical_ascent or font.ascent)*scale,vertical_descent=(font.vertical_descent or font.descent)*scale,
        }
    end
    local max_width=0
    for _,line in ipairs(lines) do if line.width>max_width then max_width=line.width end end
    local height=(#lines-1)*resolved_line_height+glyph_extent
    local ink=horizontal_ink_metrics(font,lines,size,layout) or {}
    return max_width,height,#lines,{
        width=max_width,height=height,lines=#lines,line_height=resolved_line_height,scale=scale,
        ascent=(layout and layout.ascent) or font.ascent*scale,descent=(layout and layout.descent) or font.descent*scale,
        ink_left=ink.ink_left,ink_right=ink.ink_right,ink_ascent=ink.ink_ascent,ink_descent=ink.ink_descent,
    }
end

function F._methods:measure(text, size, options)
    options = options or {}
    return F.measure(text, self, size, options.letter_spacing, options.line_height, options)
end

function F._methods:get_metrics(size, line_height)
    size = tonumber(size) or self.units_per_em
    local scale, glyph_height, resolved_line_height = metrics(self, size, line_height)
    return {
        scale = scale,
        units_per_em = self.units_per_em,
        ascent = self.ascent * scale,
        descent = self.descent * scale,
        line_gap = self.line_gap * scale,
        glyph_height = glyph_height,
        line_height = resolved_line_height,
        vertical_ascent = self.vertical_ascent and self.vertical_ascent * scale or nil,
        vertical_descent = self.vertical_descent and self.vertical_descent * scale or nil,
        vertical_line_gap = self.vertical_line_gap and self.vertical_line_gap * scale or nil,
        has_vertical_metrics = self.has_vertical_metrics == true,
    }
end

function F.get_palette(font_ref,index)
    local font=F.get(font_ref);if not font or not font.color_palettes then return nil end
    index=math.floor(tonumber(index) or 0)
    local palette=font.color_palettes[index+1] or font.color_palettes[1]
    if not palette then return nil end
    local out={}
    for i,c in ipairs(palette) do out[i]={c[1],c[2],c[3],c[4]} end
    return out
end

function F._methods:get_palette(index) return F.get_palette(self,index) end

function F.text_object(text, options)
    options = options or {}
    return {
        type = "text",
        x = options.x or 0,
        y = options.y or 0,
        text = tostring(text or ""),
        font = options.font or M.DEFAULT_FONT,
        fallback = options.fallback,
        size = options.size,
        color = options.color or options.fill or "#FFFFFF",
        palette = options.palette ~= nil and options.palette or options.palette_index,
        color_glyphs = options.color_glyphs,
        bitmap_filter = options.bitmap_filter,
        bitmap_ppi = options.bitmap_ppi or options.ppi,
        hinting = options.hinting,
        gasp = options.gasp,
        align = options.align or "left",
        letter_spacing = options.letter_spacing,
        word_spacing = options.word_spacing,
        line_height = options.line_height,
        language = options.language,
        features = options.features or options.font_features or options.font_feature_settings,
        kerning = options.kerning,
        ligatures = options.ligatures,
        base_direction = options.base_direction,
        writing_mode = options.writing_mode or options.writing_direction,
        vertical = options.vertical,
        vertical_feature = options.vertical_feature,
        column_spacing = options.column_spacing,
        opacity = options.opacity,
        text_mode = options.text_mode,
        stroke_width = options.stroke_width,
        fill_rule = options.fill_rule,
        transform = options.transform,
        translate = options.translate,
        scale = options.scale,
        rotate = options.rotate,
        origin = options.origin,
    }
end

function F._methods:text_object(text, options)
    options = options or {}
    local copy = {}
    for k, v in pairs(options) do copy[k] = v end
    copy.font = self
    return F.text_object(text, copy)
end

-- Low-level positioned-glyph object for PDF/text extractors that already know glyph IDs.
function F.glyph_run_object(glyphs,options)
    options=options or {};assert(type(glyphs)=="table","glyph run must be an array")
    local primary=assert(F.get(options.font or M.DEFAULT_FONT),"unknown Fontlib font "..tostring(options.font))
    local size=tonumber(options.size) or primary.units_per_em
    local out={}
    for i,spec in ipairs(glyphs) do
        assert(type(spec)=="table","glyph run entry "..i.." must be a table")
        if spec.newline then out[#out+1]={newline=true,cp=10,advance=0,x_advance=0,y_advance=0}
        else
            local ifont=assert(F.get(spec.font or primary),"unknown glyph-run font at entry "..i)
            local gid=assert(tonumber(spec.gid),"glyph run entry "..i.." needs gid")
            gid=math.floor(gid)
            local scale=size/ifont.units_per_em
            local output_units=options.position_units=="output" or options.position_units=="pixels" or spec.position_units=="output" or spec.position_units=="pixels"
            local function du(v)
                if v==nil then return nil end
                v=tonumber(v) or 0
                return output_units and (scale~=0 and v/scale or v) or v
            end
            local adv=du(spec.x_advance or spec.advance)
            if adv==nil then adv=(ifont._advance_for_gid and ifont:_advance_for_gid(gid)) or (ifont._advances and ifont._advances[gid]) or ifont.default_advance end
            out[#out+1]={gid=gid,cp=spec.cp,cluster=spec.cluster or i,source_index=spec.source_index or i,_font=ifont,
                x_advance=adv,advance=adv,y_advance=du(spec.y_advance) or 0,x_offset=du(spec.x_offset) or 0,y_offset=du(spec.y_offset) or 0,
                direction=spec.direction or options.direction or "ltr",script=spec.script or "Unknown",level=tonumber(spec.level) or 0,
                vertical_origin_x=du(spec.vertical_origin_x),vertical_origin_y=du(spec.vertical_origin_y)}
        end
    end
    local obj=F.text_object("",options);obj._glyph_run=out;obj.type="text";return obj
end

function F._methods:glyph_run_object(glyphs,options)
    local o={};for k,v in pairs(options or {}) do o[k]=v end;o.font=self
    return F.glyph_run_object(glyphs,o)
end

local function gasp_behavior(font,size,options)
    if options and options.gasp==false then return nil end
    if font and font._gasp_behavior then return font._gasp_behavior(size) end
    return nil
end

local function hinting_enabled(font,size,options)
    options=options or {}
    if options.hinting~=nil then return options.hinting~=false end
    local g=gasp_behavior(font,size,options)
    if g then return g.gridfit==true end
    return true
end

function F.gasp_behavior(font_ref,ppem)
    local font=F.get(font_ref);if not font or not font._gasp_behavior then return nil end
    local g=font._gasp_behavior(ppem);if not g then return nil end
    local out={};for k,v in pairs(g) do out[k]=v end;return out
end
function F._methods:gasp_behavior(ppem) return F.gasp_behavior(self,ppem) end

local function tt_vm_options(options)
    options=options or {}
    return {grayscale=options._tt_grayscale~=false,rotated=options._tt_rotated==true,stretched=options._tt_stretched==true}
end

local function tt_dropout_mode(hinted)
    if not hinted or not hinted.graphics then return nil end
    local gs=hinted.graphics;local sc=math.floor(tonumber(gs.scan_control) or 0)%65536
    if sc==0 then return nil end
    local ppem=math.max(tonumber(hinted.ppem_x) or 0,tonumber(hinted.ppem_y) or 0)
    local threshold=sc%256
    local size_cond=(threshold==255) or (threshold>0 and ppem<=threshold)
    local rotated=hinted.rotated==true;local stretched=hinted.stretched==true
    local function bit(n) return math.floor(sc/(2^n))%2==1 end
    local active=(bit(8) and size_cond) or (bit(9) and rotated) or (bit(10) and stretched)
    if not active then return nil end
    if bit(11) and not size_cond then return nil end
    if bit(12) and not rotated then return nil end
    if bit(13) and not stretched then return nil end
    local st=math.floor(tonumber(gs.scan_type) or 0)%65536
    if st==0 then return {smart=false,exclude_stubs=false,scan_type=st}
    elseif st==1 then return {smart=false,exclude_stubs=true,scan_type=st}
    elseif st==4 then return {smart=true,exclude_stubs=false,scan_type=st}
    elseif st==5 then return {smart=true,exclude_stubs=true,scan_type=st} end
    return nil -- 2/3/6/7 and unknown modes use the fast scan converter.
end
F._tt_dropout_mode=tt_dropout_mode

local function contours_for_item(font,item,size,options)
    options=options or {}
    if item._tt_hinted then return item._tt_hinted.contours end
    if hinting_enabled(font,size,options) and not item._tt_hint_attempted and font._hinted_glyph_for_gid and item.gid and item.gid~=0 then
        item._tt_hint_attempted=true
        local hinted,err=font:_hinted_glyph_for_gid(item.gid,size,size,tt_vm_options(options))
        if hinted then item._tt_hinted=hinted;return hinted.contours end
        -- VM failures are diagnostic-only here: rendering falls back to the valid scalable
        -- outline rather than dropping the glyph.
        if err then font._tt_hint_last_error=err end
    end
    if font._outline_for_gid and item.gid and item.gid~=0 then return font._outline_for_gid(item.gid) end
    local g=item.cp and glyph(font,item.cp) or nil
    return g and g.contours or nil
end

hint_shaped_items=function(font,shaped,size,options,vertical)
    options=options or {}
    for _,item in ipairs((shaped and shaped.glyphs) or {}) do
        local ifont=item_font(font,item)
        if not item.newline and item.gid and item.gid~=0 and hinting_enabled(ifont,size,options) and ifont._hinted_glyph_for_gid then
            item._tt_hint_attempted=true
            local hinted,err=ifont:_hinted_glyph_for_gid(item.gid,size,size,tt_vm_options(options))
            if hinted then
                item._tt_hinted=hinted
                if not vertical and hinted.advance~=nil then
                    local base=(ifont._advance_for_gid and ifont:_advance_for_gid(item.gid)) or (ifont._advances and ifont._advances[item.gid]) or ifont.default_advance
                    local current=tonumber(item.x_advance or item.advance)
                    -- Marks/join controls may have their advance zeroed by shaping even when
                    -- hmtx is non-zero.
                    if current~=nil and not (current==0 and base~=0) then
                        local adjusted=current+(hinted.advance-base)
                        item.x_advance=adjusted;item.advance=adjusted
                    end
                end
            elseif err then
                ifont._tt_hint_last_error=err
            end
        end
    end
end

local function contour_bounds(contours)
    local minx,miny,maxx,maxy
    for _,c in ipairs(contours or {}) do for _,pt in ipairs(c or {}) do
        local x,y=pt.x or 0,pt.y or 0
        minx=minx and math.min(minx,x) or x;maxx=maxx and math.max(maxx,x) or x
        miny=miny and math.min(miny,y) or y;maxy=maxy and math.max(maxy,y) or y
    end end
    return minx,miny,maxx,maxy
end

local function colr_color(palette,index,foreground,alpha,opacity)
    alpha=math.max(0,math.min(1,tonumber(alpha) or 1));opacity=tonumber(opacity) or 1
    if index==0xFFFF then return V.color(foreground,alpha*opacity) end
    local entry=palette and palette[(index or 0)+1]
    if not entry then return V.color(foreground,alpha*opacity) end
    return V.color(entry,alpha*opacity)
end

local function colr_srgb_to_linear(c) c=c/255;if c<=0.04045 then return c/12.92 end;return ((c+0.055)/1.055)^2.4 end
local function colr_linear_to_srgb(c) c=math.max(0,math.min(1,c));if c<=0.0031308 then return 12.92*c*255 end;return (1.055*(c^(1/2.4))-0.055)*255 end
local function colr_mix(a,b,t)
    t=math.max(0,math.min(1,t));local aa=(a[4] or 0)/255;local ba=(b[4] or 0)/255;local oa=aa+(ba-aa)*t
    if oa<=1e-12 then return {0,0,0,0} end
    local out={}
    for i=1,3 do
        local av=colr_srgb_to_linear(a[i] or 0)*aa;local bv=colr_srgb_to_linear(b[i] or 0)*ba
        out[i]=math.floor(colr_linear_to_srgb((av+(bv-av)*t)/oa)+.5)
    end
    out[4]=math.floor(oa*255+.5);return out
end

local function colr_sample_line(line,t,palette,foreground,opacity)
    local stops=line and line.stops or {};if #stops==0 then return {0,0,0,0} end
    local function stop_color(s) return colr_color(palette,s.palette_index,foreground,s.alpha,opacity) end
    if #stops==1 then return stop_color(stops[1]) end
    local lo,hi=stops[1].offset,stops[#stops].offset
    if hi==lo then
        if (line.extend or 0)~=0 then return nil end
        return t<lo and stop_color(stops[1]) or stop_color(stops[#stops])
    end
    if t<lo or t>hi then
        local ext=line.extend or 0
        if ext==0 then t=math.max(lo,math.min(hi,t))
        else
            local span=hi-lo;local v=(t-lo)/span;local q=math.floor(v);local f=v-q
            if ext==2 and q%2~=0 then f=1-f end
            t=lo+f*span
        end
    end
    if t<=lo then return stop_color(stops[1]) end
    if t>=hi then return stop_color(stops[#stops]) end
    local upper=2
    while upper<=#stops and stops[upper].offset<=t do upper=upper+1 end
    if upper>#stops then return stop_color(stops[#stops]) end
    local a,b=stops[upper-1],stops[upper];local d=b.offset-a.offset
    if d<=1e-12 then return stop_color(b) end
    return colr_mix(stop_color(a),stop_color(b),(t-a.offset)/d)
end

local function colr_design_matrix_to_font(m,ascent)
    local flip={1,0,0,-1,0,ascent or 0}
    return V.multiply(flip,V.multiply(m,flip))
end

local function colr_clip_test(clip,fill_rule)
    if not clip then return nil end
    return function(x,y)
        local c=clip
        while c do if not V._point_in_contours(c.contours,x,y,fill_rule) then return false end;c=c.parent end
        return true
    end
end

local function draw_colr_v1(canvas,font,root,glyph_matrix,palette,foreground,opacity,fill_rule,base_gid)
    if not root then return false end
    local identity=V.identity();local ascent=font.ascent or font.units_per_em or 0
    local roots=font._colr_v1 or {};local pi=math.pi
    local function full_matrix(ctm) return V.multiply(glyph_matrix,ctm or identity) end
    local function clip_box_contours(gid,ctm)
        local box=font._colr_clip_for_gid and font._colr_clip_for_gid(gid) or nil
        if not box then return nil end
        -- COLR clip boxes use normal font design coordinates (Y up), while Fontlib stores
        -- outlines in its ascent-relative Y-down space.
        local x1,x2=box.x_min,box.x_max
        local y1,y2=ascent-box.y_max,ascent-box.y_min
        local c={{{x=x1,y=y1},{x=x2,y=y1},{x=x2,y=y2},{x=x1,y=y2},{x=x1,y=y1}}}
        return V._transformed(c,full_matrix(ctm))
    end
    local function push_clip_box(clip,gid,ctm)
        local contours=clip_box_contours(gid,ctm)
        return contours and {contours=contours,parent=clip} or clip
    end
    local function leaf_contours(clip)
        if clip then return clip.contours,colr_clip_test(clip.parent,fill_rule) end
        return {{{x=0,y=0},{x=canvas.width,y=0},{x=canvas.width,y=canvas.height},{x=0,y=canvas.height},{x=0,y=0}}},nil
    end
    local function gradient_shader(node,ctm)
        local inv=V.inverse(full_matrix(ctm));if not inv then return function()return nil end end
        return function(sx,sy)
            local x,fy=V.transform_point(inv,sx,sy);local y=ascent-fy;local t
            if node.kind=="linear" then
                local rx,ry=node.x2-node.x0,node.y2-node.y0;local vx,vy=node.x1-node.x0,node.y1-node.y0
                local den=vx*ry-vy*rx;if math.abs(den)<1e-12 then return nil end
                t=((x-node.x0)*ry-(y-node.y0)*rx)/den
            elseif node.kind=="radial" then
                local qx,qy=x-node.x0,y-node.y0;local dx,dy=node.x1-node.x0,node.y1-node.y0;local dr=node.r1-node.r0
                local A=dx*dx+dy*dy-dr*dr;local B=-2*(qx*dx+qy*dy+node.r0*dr);local C=qx*qx+qy*qy-node.r0*node.r0
                local roots2={}
                if math.abs(A)<1e-12 then if math.abs(B)<1e-12 then return nil else roots2[1]=-C/B end
                else local disc=B*B-4*A*C;if disc<0 then return nil end;local sd=math.sqrt(math.max(0,disc));roots2[1]=(-B+sd)/(2*A);roots2[2]=(-B-sd)/(2*A) end
                local best=nil;for _,w in ipairs(roots2) do if node.r0+dr*w>0 and (not best or w>best) then best=w end end
                if not best then return nil end;t=best
            else
                local a=math.atan2(y-node.cy,x-node.cx)*180/pi;if a<0 then a=a+360 end
                local d=node.end_angle-node.start_angle;if math.abs(d)<1e-12 then return nil end;t=(a-node.start_angle)/d
            end
            return colr_sample_line(node.color_line,t,palette,foreground,opacity)
        end
    end
    local render
    render=function(node,target,ctm,clip,depth)
        if not node or (depth or 0)>96 then return end;ctm=ctm or identity;depth=(depth or 0)+1
        if node.kind=="layers" then
            for _,ch in ipairs(node.children or {}) do render(ch,target,ctm,clip,depth) end
        elseif node.kind=="solid" then
            local contours,test=leaf_contours(clip);local c=colr_color(palette,node.palette_index,foreground,node.alpha,opacity)
            V._fill_contours_shader(target,contours,function()return c end,fill_rule,test)
        elseif node.kind=="linear" or node.kind=="radial" or node.kind=="sweep" then
            local contours,test=leaf_contours(clip);V._fill_contours_shader(target,contours,gradient_shader(node,ctm),fill_rule,test)
        elseif node.kind=="glyph" then
            local outline=font._outline_for_gid and font._outline_for_gid(node.gid) or nil
            if outline then local sc=V._transformed(outline,full_matrix(ctm));render(node.child,target,ctm,{contours=sc,parent=clip},depth) end
        elseif node.kind=="colr_glyph" then
            -- A reused color glyph carries its own ClipList bounds.
            render(roots[node.gid],target,ctm,push_clip_box(clip,node.gid,ctm),depth)
        elseif node.kind=="transform" then
            local cm=colr_design_matrix_to_font(node.matrix or identity,ascent);render(node.child,target,V.multiply(ctm,cm),clip,depth)
        elseif node.kind=="composite" then
            local back=V.new_canvas(target.width,target.height,"#00000000");local src=V.new_canvas(target.width,target.height,"#00000000")
            render(node.backdrop,back,ctm,clip,depth);render(node.source,src,ctm,clip,depth);V._composite_canvas(back,src,node.mode or 3);V._composite_canvas(target,back,3)
        end
    end
    render(root,canvas,identity,push_clip_box(nil,base_gid,identity),0);return true
end

function V._draw_text(canvas, object, matrix)
    local font = assert(F.get(object.font), "unknown Fontlib font " .. tostring(object.font))
    local size = tonumber(object.size) or font.units_per_em
    local spacing = tonumber(object.letter_spacing) or 0
    local runtime_options={};for k,v in pairs(object) do runtime_options[k]=v end
    local m1,m2,m3,m4=matrix[1] or 1,matrix[2] or 0,matrix[3] or 0,matrix[4] or 1
    local lx=math.sqrt(m1*m1+m2*m2);local ly=math.sqrt(m3*m3+m4*m4);local eps=1e-7
    runtime_options._tt_rotated=math.abs(m2)>eps or math.abs(m3)>eps
    runtime_options._tt_stretched=math.abs(lx-ly)>eps*math.max(1,lx,ly)
    runtime_options._tt_grayscale=(canvas._fontlib_supersample or 1)>1
    local _,lines,scale,_,line_height,layout=shaped_lines(font,object.text,size,spacing,object.line_height,runtime_options)
    local x0=tonumber(object.x) or 0;local y0=tonumber(object.y) or 0
    local align=object.align or (layout and layout.vertical and "top" or "left")
    local vertical=layout and layout.vertical
    for line_index,line in ipairs(lines) do
        local pen_x,pen_y
        if vertical then
            local sign=(layout.writing_mode=="vertical-lr") and 1 or -1
            pen_x=x0+(line_index-1)*layout.column_advance*sign;pen_y=y0
            if align=="center" then pen_y=y0-line.height/2 elseif align=="bottom" or align=="right" then pen_y=y0-line.height end
        else
            pen_x=x0
            if align=="center" then pen_x=x0-line.width/2 elseif align=="right" then pen_x=x0-line.width end
            pen_y=y0+(line_index-1)*line_height
        end
        for _,item in ipairs(line.glyphs) do
            if not vertical then pen_x=pen_x+(item._layout_kern or 0) end
            local ifont=item_font(font,item);local iscale=item._layout_scale or (size/ifont.units_per_em)
            local contours=contours_for_item(ifont,item,size,runtime_options)
            local color_root=object.color_glyphs~=false and item.gid and ifont._colr_v1 and ifont._colr_v1[item.gid] or nil
            local color_layers=object.color_glyphs~=false and not color_root and item.gid and ifont._colr_layers and ifont._colr_layers[item.gid] or nil
            local svg_entry=object.color_glyphs~=false and not color_root and not color_layers and item.gid and ifont._svg_for_gid and ifont._svg_for_gid(item.gid) or nil
            -- Prefer scalable color representations before fixed bitmap strikes: COLR v1/v0 ->
            -- SVG-in-OpenType -> CBDT/sbix -> monochrome outline.
            local bitmap=object.color_glyphs~=false and not color_root and not color_layers and not svg_entry and item.gid and ifont._bitmap_for_gid and ifont._bitmap_for_gid(item.gid,size,object.bitmap_ppi) or nil
            if contours or color_root or color_layers or svg_entry or bitmap then
                local origin_canvas_x=pen_x+(item._layout_x_offset or 0)
                local origin_canvas_y
                if vertical then origin_canvas_y=pen_y-(item._layout_y_offset or 0)
                else
                    -- Outline coordinates are top-of-em based.
                    origin_canvas_y=pen_y+(layout.ascent or font.ascent*scale)-ifont.ascent*iscale-(item._layout_y_offset or 0)
                end
                local gx,gy
                if vertical then
                    local vox=(tonumber(item.vertical_origin_x) or ifont.default_advance/2)*iscale
                    local voy=tonumber(item.vertical_origin_y) or ifont.ascent
                    gx=origin_canvas_x-vox
                    gy=origin_canvas_y-(ifont.ascent-voy)*iscale
                else
                    gx=origin_canvas_x;gy=origin_canvas_y
                end
                local glyph_matrix=V.multiply(matrix,V.multiply(V.translate(gx,gy),V.scale(iscale,iscale)))
                local opacity=tonumber(object.opacity) or 1
                local color=object.color or object.fill or object.stroke or "#FFFFFF"
                local rendered=false
                local palette_index=math.floor(tonumber(object.palette) or 0)
                local palette=ifont.color_palettes and (ifont.color_palettes[palette_index+1] or ifont.color_palettes[1]) or nil
                if color_root and palette then
                    draw_colr_v1(canvas,ifont,color_root,glyph_matrix,palette,color,opacity,object.fill_rule or ifont.fill_rule,item.gid);rendered=true
                elseif color_layers and palette then
                    for _,layer in ipairs(color_layers) do
                        local lc=ifont._outline_for_gid and ifont._outline_for_gid(layer.gid) or nil
                        if lc then
                            local layer_color
                            if layer.palette_index==0xFFFF then layer_color=V.color(color,opacity)
                            else
                                local entry=palette and palette[layer.palette_index+1]
                                layer_color=entry and V.color(entry,opacity) or V.color(color,opacity)
                            end
                            V._fill_contours(canvas,V._transformed(lc,glyph_matrix),layer_color,object.fill_rule or ifont.fill_rule)
                        end
                    end
                    rendered=true
                elseif svg_entry and V._draw_svg_glyph then
                    rendered=V._draw_svg_glyph(canvas,svg_entry,item.gid,glyph_matrix,{units_per_em=ifont.units_per_em,ascent=ifont.ascent,palette=palette,foreground=color,opacity=opacity,bitmap_filter=object.bitmap_filter}) and true or false
                end
                -- If an SVG document is malformed or uses unsupported content, fall through to
                -- the font's embedded bitmap or outline rather than dropping the glyph
                if not rendered and object.color_glyphs~=false and item.gid and ifont._bitmap_for_gid then bitmap=ifont._bitmap_for_gid(item.gid,size,object.bitmap_ppi) end
                if not rendered and bitmap then
                    local sx=size/math.max(1,bitmap.ppem_x or size);local sy=size/math.max(1,bitmap.ppem_y or bitmap.ppem_x or size)
                    if bitmap.bitmap_format=="sbix" then
                        local base_x=gx;local base_bottom=gy+ifont.ascent*iscale
                        local _,_,_,cmaxy=contour_bounds(contours)
                        local cminx=contour_bounds(contours)
                        if cminx and cmaxy then base_x=gx+cminx*iscale;base_bottom=gy+cmaxy*iscale end
                        local bx=base_x+(bitmap.origin_offset_x or 0)*sx
                        local bottom=base_bottom-(bitmap.origin_offset_y or 0)*sy
                        local by=bottom-bitmap.height*sy
                        local bitmap_matrix=V.multiply(matrix,V.multiply(V.translate(bx,by),V.scale(sx,sy)))
                        V._draw_rgba_image(canvas,bitmap,bitmap_matrix,opacity,object.bitmap_filter or "bilinear")
                        if ifont._sbix_draw_outlines and contours and #contours>0 then
                            local transformed=V._transformed(contours,glyph_matrix)
                            if (object.text_mode or ifont.mode)=="fill" then
                                V._fill_contours(canvas,transformed,V.color(color,opacity),object.fill_rule or ifont.fill_rule)
                            else
                                local stroke_width=tonumber(object.stroke_width) or ifont.stroke_width
                                V._stroke_contours(canvas,transformed,V._scale_width(glyph_matrix,stroke_width),V.color(color,opacity),false)
                            end
                        end
                    else
                        local bm=bitmap.metrics or {};local bx,by
                        if vertical and bm.kind=="big" and bm.vert_bearing_x~=nil and bm.vert_bearing_y~=nil then
                            -- BigGlyphMetrics includes placement from the vertical origin
                            -- directly in strike pixels.
                            bx=origin_canvas_x+(bm.vert_bearing_x or 0)*sx
                            by=origin_canvas_y-(bm.vert_bearing_y or 0)*sy
                        else
                            local baseline_y=gy+ifont.ascent*iscale
                            bx=gx+(bm.bearing_x or 0)*sx;by=baseline_y-(bm.bearing_y or 0)*sy
                        end
                        local bitmap_matrix=V.multiply(matrix,V.multiply(V.translate(bx,by),V.scale(sx,sy)))
                        V._draw_rgba_image(canvas,bitmap,bitmap_matrix,opacity,object.bitmap_filter or "bilinear")
                    end
                    rendered=true
                end
                if not rendered and contours then
                    local transformed=V._transformed(contours,glyph_matrix)
                    if (object.text_mode or ifont.mode)=="fill" then
                        local fc=V.color(color,opacity);local fr=object.fill_rule or ifont.fill_rule
                        V._fill_contours(canvas,transformed,fc,fr)
                        if (canvas._fontlib_supersample or 1)==1 and item._tt_hinted and V._apply_dropout then
                            local dm=tt_dropout_mode(item._tt_hinted);if dm then V._apply_dropout(canvas,transformed,fc,fr,dm) end
                        end
                    else
                        local stroke_width=tonumber(object.stroke_width) or ifont.stroke_width
                        V._stroke_contours(canvas,transformed,V._scale_width(glyph_matrix,stroke_width),V.color(color,opacity),false)
                    end
                end
            end
            if vertical then
                pen_x=pen_x+(item._layout_x_advance or 0)
                pen_y=pen_y+(item._layout_y_advance or 0)
            else
                pen_x=pen_x+(item._layout_advance or 0)
            end
        end
    end
end

-- Built-in fallback font is registered from src/builtin_font.lua.
