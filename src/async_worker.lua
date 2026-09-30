-- SPDX-License-Identifier: 0BSD
-- Async worker entry point.
local core = assert(rawget(_G, "core") or rawget(_G, "minetest"))
local modpath = core.ipc_get and core.ipc_get("fontlib:async_modpath")
if type(modpath) ~= "string" or modpath == "" then
    local dbg = rawget(_G, "debug")
    local src = dbg and dbg.getinfo and dbg.getinfo(1, "S").source or ""
    src = src:sub(1,1) == "@" and src:sub(2) or src
    modpath = src:match("^(.*)/src/async_worker%.lua$")
end
assert(type(modpath) == "string" and modpath ~= "", "fontlib async worker cannot resolve mod path")

-- Async workers have isolated globals.
fontlib = {
    VERSION = "1.0.0",
    API_VERSION = 1,
    DEFAULT_FONT = "fontlib:simple",
    modpath = modpath,
    font = {},
    vector = {},
    output = {},
    effects = {},
}

local M = fontlib
local function src(name) return modpath .. "/src/" .. name .. ".lua" end

dofile(src("vector"))
dofile(src("effects"))
dofile(src("unicode"))
M.unicode_properties = dofile(src("unicode_properties"))
M.unicode_linebreak_properties = dofile(src("unicode_linebreak_properties"))
M.unicode_grapheme_properties = dofile(src("unicode_grapheme_properties"))
dofile(src("unicode_grapheme"))
dofile(src("unicode_linebreak"))
dofile(src("typography"))
dofile(src("font"))
dofile(src("opentype_layout"))
dofile(src("truetype_vm"))
dofile(src("font_source"))
dofile(src("shaping"))
dofile(src("font_psf"))
dofile(src("font_pcf"))
dofile(src("builtin_font"))
dofile(src("font_family"))
dofile(src("vector_asset"))
dofile(src("vector_formats"))
dofile(src("output"))
dofile(src("convenience"))
dofile(src("richtext"))

local F, O = M.font, M.output

local function apply_cache_generation(font, spec)
    local requested = tonumber(spec.cache_generation) or 0
    local current = tonumber(font._fontlib_async_cache_generation) or 0
    if requested > current then
        F.clear_cache(font)
        font._fontlib_async_cache_generation = requested
    end
end

local active_sources_epoch=-1
local function purge_inactive_fonts()
    if type(core.ipc_get)~="function" then return end
    local epoch=tonumber(core.ipc_get("fontlib:active_font_sources_epoch")) or 0
    if epoch==active_sources_epoch then return end
    local state=core.ipc_get("fontlib:active_font_sources")
    if type(state)~="table" then return end
    local remove={}
    for id,font in pairs(F._registry) do
        local source_epoch=font and font._fontlib_async_source_epoch
        if source_epoch~=nil and tonumber(state[id])~=tonumber(source_epoch) then remove[#remove+1]=id end
    end
    for _,id in ipairs(remove) do F._registry[id]=nil end
    active_sources_epoch=epoch
end

local function load_font(spec)
    if spec.id == M.DEFAULT_FONT or spec.builtin then
        local builtin = F.get(M.DEFAULT_FONT)
        if not builtin then return nil, "missing builtin font" end
        builtin._fontlib_async_revision = 1
        apply_cache_generation(builtin, spec)
        return builtin
    end

    local requested_revision = tonumber(spec.revision) or 1
    local old = F.get(spec.id)
    if old then
        local old_revision = tonumber(old._fontlib_async_revision) or 0
        if requested_revision < old_revision then
            return nil, "stale async font revision: " .. tostring(spec.id)
        end
        if requested_revision == old_revision then
            if tonumber(old._fontlib_async_source_epoch or 0)~=tonumber(spec.source_epoch or 0) then
                return nil, "conflicting async font source generation: " .. tostring(spec.id)
            end
            local source_token=(spec.source_kind=="data") and spec.ipc_key or spec.path
            if old._fontlib_async_source_token ~= source_token then
                return nil, "conflicting async font source at revision " .. tostring(requested_revision) .. ": " .. tostring(spec.id)
            end
            apply_cache_generation(old, spec)
            return old
        end
    end

    local font, err
    local source_token
    if spec.source_kind=="data" then
        source_token=spec.ipc_key
        local data=core.ipc_get and core.ipc_get(spec.ipc_key)
        if type(data)~="string" then return nil,"missing async in-memory font data for "..tostring(spec.id) end
        font,err=F.source.load_data(data,spec.options or {},spec.filename)
    else
        source_token=spec.path
        font,err=F.source.load(spec.path, spec.options or {})
    end
    if not font then return nil, err end
    font.id = spec.id
    font.source_mod = spec.modname
    font.source_path = spec.filename
    font._fontlib_async_revision = requested_revision
    font._fontlib_async_source_token = source_token
    font._fontlib_async_source_epoch = tonumber(spec.source_epoch) or 0
    font._fontlib_async_cache_generation = tonumber(spec.cache_generation) or 0
    F._registry[spec.id] = font
    return font
end

local function prepare_fonts(request)
    for _, spec in ipairs(request.fonts or {}) do
        local font, err = load_font(spec)
        if not font then return nil, "unable to load async font " .. tostring(spec.id) .. ": " .. tostring(err) end
    end
    -- Do this after all faces exist so recursive fallback IDs resolve normally.
    for _, spec in ipairs(request.fonts or {}) do
        local font = F.get(spec.id)
        if font then font.fallback = spec.fallback end
    end
    return F.get(request.font_id)
end

local function render(request)
    assert(type(request) == "table", "fontlib async request table required")
    assert(request.kind == "text" or request.kind=="rich_text", "unsupported fontlib async render kind")
    purge_inactive_fonts()
    local font, ferr = prepare_fonts(request)
    if not font then error(ferr or ("unknown async font " .. tostring(request.font_id))) end

    local options = request.options or {}
    options.font = request.font_id

    if request.kind=="rich_text" then
        if M.typography and M.typography.import_language_data then M.typography.import_language_data(request.typography_data) end
        if request.output=="layout" then
            local layout,lerr=M.layout_rich_text(request.content or {},options)
            if not layout then error(lerr) end
            local snap=M.richtext.snapshot(layout)
            return {ok=true,output="layout",width=snap.width,height=snap.height,layout=snap}
        end
        if request.output=="texture" then
            local texture,canvas,layout=M.rich_texture(request.content or {},options)
            if not texture then error(canvas) end
            return {ok=true,output="texture",texture=texture,width=canvas.width,height=canvas.height,layout=M.richtext.snapshot(layout)}
        end
        local png,canvas,layout=M.rich_png(request.content or {},options)
        if not png then error(canvas) end
        return {ok=true,output="png",png=png,width=canvas.width,height=canvas.height,layout=M.richtext.snapshot(layout)}
    end

    if request.output == "texture" then
        local texture, canvas, metrics = M.text_texture(request.text or "", options)
        if not texture then error(canvas) end
        return {
            ok = true,
            output = "texture",
            texture = texture,
            width = canvas.width,
            height = canvas.height,
            metrics = metrics,
        }
    end

    local canvas, metrics = M.render_text(request.text or "", options)
    local png, encoded_canvas = O.to_png(canvas, options)
    if not png then error(encoded_canvas) end
    canvas = encoded_canvas
    return {
        ok = true,
        output = "png",
        png = png,
        width = canvas.width,
        height = canvas.height,
        metrics = metrics,
    }
end

-- Must remain a global with no main-environment upvalues.
function fontlib_async_render_job(request)
    local ok, result = pcall(render, request)
    if ok then return result end
    return {ok = false, error = tostring(result)}
end
