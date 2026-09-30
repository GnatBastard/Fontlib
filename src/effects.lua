-- SPDX-License-Identifier: 0BSD
-- Text outline, shadow, and glow effects.
local M = fontlib
local V = M.vector
local E = M.effects or {}
M.effects = E

local floor, ceil, min, max, abs = math.floor, math.ceil, math.min, math.max, math.abs
local unpack_rgba = V._unpack_rgba
local blend = V._blend

local function copy_table(t)
    local out = {}
    if type(t) == "table" then for k,v in pairs(t) do out[k]=v end end
    return out
end

local function normalize_outline(options)
    local raw = options.outline
    if raw == nil and (options.outline_width ~= nil or options.outline_color ~= nil) then
        raw = {width=options.outline_width, color=options.outline_color}
    end
    if raw == nil or raw == false then return nil end
    local out
    if raw == true then out = {width=1}
    elseif type(raw) == "number" then out = {width=raw}
    elseif type(raw) == "string" then out = {width=1,color=raw}
    elseif type(raw) == "table" then out = copy_table(raw)
    else return nil end
    out.width = max(0, tonumber(out.width or out.radius or out.size) or 1)
    if out.width <= 0 then return nil end
    out.color = out.color or "#000000"
    out.opacity = max(0,min(1,tonumber(out.opacity) or 1))
    return out
end

local function normalize_shadow(options)
    local raw = options.shadow
    if raw == nil and (options.shadow_x ~= nil or options.shadow_y ~= nil or options.shadow_blur ~= nil or options.shadow_color ~= nil) then
        raw = {x=options.shadow_x,y=options.shadow_y,blur=options.shadow_blur,color=options.shadow_color,spread=options.shadow_spread}
    end
    if raw == nil or raw == false then return nil end
    local out
    if raw == true then out = {x=2,y=2,blur=2}
    elseif type(raw) == "number" then out = {x=raw,y=raw,blur=2}
    elseif type(raw) == "string" then out = {x=2,y=2,blur=2,color=raw}
    elseif type(raw) == "table" then out = copy_table(raw)
    else return nil end
    if type(out.offset) == "table" then
        out.x = out.x ~= nil and out.x or out.offset.x or out.offset[1]
        out.y = out.y ~= nil and out.y or out.offset.y or out.offset[2]
    end
    out.x = tonumber(out.x or out.offset_x) or 2
    out.y = tonumber(out.y or out.offset_y) or 2
    out.blur = max(0,tonumber(out.blur or out.radius) or 2)
    out.spread = max(0,tonumber(out.spread) or 0)
    out.color = out.color or "#00000080"
    out.opacity = max(0,min(1,tonumber(out.opacity) or 1))
    return out
end

local function normalize_glow(options)
    local raw = options.glow
    if raw == nil and (options.glow_radius ~= nil or options.glow_color ~= nil) then
        raw = {radius=options.glow_radius,color=options.glow_color,spread=options.glow_spread}
    end
    if raw == nil or raw == false then return nil end
    local out
    if raw == true then out = {radius=4}
    elseif type(raw) == "number" then out = {radius=raw}
    elseif type(raw) == "string" then out = {radius=4,color=raw}
    elseif type(raw) == "table" then out = copy_table(raw)
    else return nil end
    out.radius = max(0,tonumber(out.radius or out.blur) or 4)
    out.spread = max(0,tonumber(out.spread) or 0)
    out.color = out.color or "#FFFFFF80"
    out.opacity = max(0,min(1,tonumber(out.opacity) or 1))
    if out.radius <= 0 and out.spread <= 0 then return nil end
    return out
end

function E.normalize(options)
    options = options or {}
    if options._fontlib_effects_normalized then return options end
    local out = {
        outline = normalize_outline(options),
        shadow = normalize_shadow(options),
        glow = normalize_glow(options),
        _fontlib_effects_normalized = true,
    }
    if not out.outline and not out.shadow and not out.glow then return nil end
    return out
end

function E.margins(options)
    local fx = E.normalize(options)
    if not fx then return 0,0,0,0,nil end
    local left,top,right,bottom=0,0,0,0
    if fx.outline then
        local e=ceil(fx.outline.width)
        left=max(left,e);top=max(top,e);right=max(right,e);bottom=max(bottom,e)
    end
    if fx.shadow then
        local e=ceil(fx.shadow.blur+fx.shadow.spread)
        left=max(left,e-fx.shadow.x);right=max(right,e+fx.shadow.x)
        top=max(top,e-fx.shadow.y);bottom=max(bottom,e+fx.shadow.y)
    end
    if fx.glow then
        local e=ceil(fx.glow.radius+fx.glow.spread)
        left=max(left,e);top=max(top,e);right=max(right,e);bottom=max(bottom,e)
    end
    return max(0,ceil(left)),max(0,ceil(top)),max(0,ceil(right)),max(0,ceil(bottom)),fx
end

local function alpha_mask(canvas)
    local out={}
    for i,p in ipairs(canvas.pixels) do
        local _,_,_,a=unpack_rgba(p);out[i]=a
    end
    return out
end

-- Fast chamfer-distance expansion.
local function spread_mask(src,w,h,radius)
    radius=tonumber(radius) or 0
    if radius<=0 then
        local out={};for i,v in ipairs(src) do out[i]=v end;return out
    end
    local inf=1e30;local diag=1.4142135623730951;local d={}
    for i,a in ipairs(src) do d[i]=(a or 0)>4 and 0 or inf end
    for y=0,h-1 do for x=0,w-1 do
        local i=y*w+x+1;local v=d[i]
        if x>0 then v=min(v,d[i-1]+1) end
        if y>0 then
            v=min(v,d[i-w]+1)
            if x>0 then v=min(v,d[i-w-1]+diag) end
            if x+1<w then v=min(v,d[i-w+1]+diag) end
        end
        d[i]=v
    end end
    for y=h-1,0,-1 do for x=w-1,0,-1 do
        local i=y*w+x+1;local v=d[i]
        if x+1<w then v=min(v,d[i+1]+1) end
        if y+1<h then
            v=min(v,d[i+w]+1)
            if x+1<w then v=min(v,d[i+w+1]+diag) end
            if x>0 then v=min(v,d[i+w-1]+diag) end
        end
        d[i]=v
    end end
    local out={};local edge=radius+.5
    for i,dist in ipairs(d) do
        local a=src[i] or 0
        if dist<=edge then
            local cov=max(0,min(1,edge-dist))*255
            out[i]=max(a,cov)
        else out[i]=a end
    end
    return out
end

local function box_blur(src,w,h,radius)
    radius=max(0,floor((tonumber(radius) or 0)+.5));if radius<=0 then local o={};for i,v in ipairs(src) do o[i]=v end;return o end
    local span=radius*2+1;local tmp,out={},{}
    for y=0,h-1 do
        local sum=0;local base=y*w
        for k=-radius,radius do if k>=0 and k<w then sum=sum+(src[base+k+1] or 0) end end
        for x=0,w-1 do
            tmp[base+x+1]=sum/span
            local remove=x-radius;if remove>=0 and remove<w then sum=sum-(src[base+remove+1] or 0) end
            local add=x+radius+1;if add>=0 and add<w then sum=sum+(src[base+add+1] or 0) end
        end
    end
    for x=0,w-1 do
        local sum=0
        for k=-radius,radius do if k>=0 and k<h then sum=sum+(tmp[k*w+x+1] or 0) end end
        for y=0,h-1 do
            out[y*w+x+1]=sum/span
            local remove=y-radius;if remove>=0 and remove<h then sum=sum-(tmp[remove*w+x+1] or 0) end
            local add=y+radius+1;if add>=0 and add<h then sum=sum+(tmp[add*w+x+1] or 0) end
        end
    end
    return out
end

local function blend_mask(dst,mask,color,dx,dy,opacity)
    local c=V.color(color,opacity);dx=floor((tonumber(dx) or 0)+.5);dy=floor((tonumber(dy) or 0)+.5)
    local w,h=dst.width,dst.height
    for y=0,h-1 do
        local ty=y+dy
        if ty>=0 and ty<h then
            local base=y*w
            for x=0,w-1 do
                local tx=x+dx
                if tx>=0 and tx<w then
                    local a=mask[base+x+1] or 0
                    if a>0 then blend(dst,tx,ty,{c[1],c[2],c[3],c[4]*a/255}) end
                end
            end
        end
    end
end

local function blend_canvas(dst,src)
    for y=0,src.height-1 do for x=0,src.width-1 do
        local r,g,b,a=V.pixel(src,x,y);if a>0 then blend(dst,x,y,{r,g,b,a}) end
    end end
end

function E.apply(canvas,effects,background)
    local fx=effects and E.normalize(effects) or nil
    if not fx then return canvas end
    local w,h=canvas.width,canvas.height;local source=alpha_mask(canvas)
    local out=V.new_canvas(w,h,background or "#00000000")

    if fx.shadow then
        local mask=source
        if fx.shadow.spread>0 then mask=spread_mask(mask,w,h,fx.shadow.spread) end
        if fx.shadow.blur>0 then mask=box_blur(mask,w,h,fx.shadow.blur) end
        blend_mask(out,mask,fx.shadow.color,fx.shadow.x,fx.shadow.y,fx.shadow.opacity)
    end
    if fx.glow then
        local mask=source
        if fx.glow.spread>0 then mask=spread_mask(mask,w,h,fx.glow.spread) end
        if fx.glow.radius>0 then mask=box_blur(mask,w,h,fx.glow.radius) end
        blend_mask(out,mask,fx.glow.color,0,0,fx.glow.opacity)
    end
    if fx.outline then
        local expanded=spread_mask(source,w,h,fx.outline.width)
        local ring={}
        for i,a in ipairs(expanded) do ring[i]=max(0,(a or 0)-(source[i] or 0)) end
        blend_mask(out,ring,fx.outline.color,0,0,fx.outline.opacity)
    end
    blend_canvas(out,canvas)
    return out
end

return E
