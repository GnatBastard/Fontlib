-- SPDX-License-Identifier: 0BSD
-- Font-family resolution.
local M=fontlib
local F=M.font
M.font_families=M.font_families or {}
M.family=M.family or {}
local A=M.family

local function norm_name(v) return tostring(v or ""):lower():gsub("^%s+",""):gsub("%s+$","") end
local function norm_weight(v)
    if type(v)=="string" then
        local s=v:lower();if s=="normal" then return 400 elseif s=="bold" then return 700 elseif s=="lighter" then return 300 elseif s=="bolder" then return 700 end
    end
    local n=tonumber(v) or 400;return math.max(1,math.min(1000,n))
end
local function norm_style(v)
    v=norm_name(v);if v=="italic" or v=="oblique" then return v end;return "normal"
end
local function norm_stretch(v)
    if type(v)=="string" then
        local names={ultra_condensed=50,extra_condensed=62.5,condensed=75,semi_condensed=87.5,normal=100,semi_expanded=112.5,expanded=125,extra_expanded=150,ultra_expanded=200}
        local key=v:lower():gsub("%-","_");if names[key] then return names[key] end
        local p=v:match("^%s*([%d%.]+)%%%s*$");if p then return tonumber(p) end
    end
    return tonumber(v) or 100
end
local function add_face(out,font,weight,style,stretch)
    if not font then return end
    out[#out+1]={font=font,weight=norm_weight(weight),style=norm_style(style),stretch=norm_stretch(stretch)}
end
local function normalize_faces(def)
    local out={}
    if type(def.faces)=="table" then
        for _,f in ipairs(def.faces) do if type(f)=="table" then add_face(out,f.font or f.id,f.weight,f.style or f.slant,f.stretch) end end
    end
    add_face(out,def.regular or def.normal,400,"normal",100)
    add_face(out,def.medium,500,"normal",100)
    add_face(out,def.semibold or def.semi_bold,600,"normal",100)
    add_face(out,def.bold,700,"normal",100)
    add_face(out,def.italic,400,"italic",100)
    add_face(out,def.oblique,400,"oblique",100)
    add_face(out,def.bold_italic or def.bolditalic,700,"italic",100)
    add_face(out,def.bold_oblique or def.boldoblique,700,"oblique",100)
    return out
end

function M.register_font_family(name,def)
    assert(type(name)=="string" and name~="","font family name required")
    assert(type(def)=="table","font family definition must be a table")
    local key=norm_name(name);assert(key~="","font family name required")
    local faces=normalize_faces(def);assert(#faces>0,"font family needs at least one face")
    local family={name=name,key=key,faces=faces,fallback=def.fallback or def.fallbacks}
    M.font_families[key]=family
    for _,alias in ipairs(def.aliases or {}) do M.font_families[norm_name(alias)]=family end
    return family
end

local function family_list(family)
    if type(family)=="table" then return family end
    if type(family)=="string" then
        local out={};for part in family:gmatch("[^,]+") do
            part=part:gsub("^%s+",""):gsub("%s+$","")
            local q=part:sub(1,1);if (q=="'" or q=='"') and part:sub(-1)==q and #part>=2 then part=part:sub(2,-2) end
            if part~="" then out[#out+1]=part end
        end
        return out
    end
    return {}
end
local function face_score(face,want)
    local style_penalty
    if face.style==want.style then style_penalty=0
    elseif (face.style=="italic" or face.style=="oblique") and (want.style=="italic" or want.style=="oblique") then style_penalty=250
    else style_penalty=2500 end
    -- Stretch is considered before weight in CSS matching; use a stronger coefficient while
    -- still allowing a close weight to break ties.
    return style_penalty+math.abs(face.stretch-want.stretch)*12+math.abs(face.weight-want.weight)
end

function M.resolve_font(family,attrs)
    attrs=attrs or {};local want={weight=norm_weight(attrs.weight or attrs.font_weight),style=norm_style(attrs.style or attrs.font_style),stretch=norm_stretch(attrs.stretch or attrs.font_stretch)}
    for _,name in ipairs(family_list(family)) do
        local fam=M.font_families[norm_name(name)]
        if fam then
            local best,score
            for _,face in ipairs(fam.faces) do
                local s=face_score(face,want)
                if not score or s<score then best,score=face,s end
            end
            if best then return best.font,best,fam end
        else
            -- A concrete registered font ID is also a valid one-item family.
            if F.get(name) or (M.registered_font_sources and M.registered_font_sources[name]) then return name,{font=name,weight=400,style="normal",stretch=100},nil end
        end
    end
    return nil,"unknown font family: "..tostring(type(family)=="table" and table.concat(family,",") or family)
end

A.register=M.register_font_family
A.resolve=M.resolve_font
A.get=function(name) return M.font_families[norm_name(name)] end
A.list=function() local out={};local seen={};for _,f in pairs(M.font_families) do if not seen[f] then seen[f]=true;out[#out+1]=f.name end end;table.sort(out);return out end

return A
