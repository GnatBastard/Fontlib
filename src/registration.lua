-- SPDX-License-Identifier: 0BSD
-- Font registration.
local core = assert(rawget(_G, "core") or rawget(_G, "minetest"))
local M = fontlib
local F = M.font
local sep = rawget(_G, "DIR_DELIM") or "/"

M.registered_fonts = F._registry
M.registered_font_sources = M.registered_font_sources or {}
M._font_source_epoch = tonumber(M._font_source_epoch) or 0
M._font_registry_epoch = tonumber(M._font_registry_epoch) or 0
local ACTIVE_SOURCES_IPC = "fontlib:active_font_sources"
local ACTIVE_SOURCES_EPOCH_IPC = "fontlib:active_font_sources_epoch"
local callbacks = {}

local function next_source_epoch()
    M._font_source_epoch=M._font_source_epoch+1;return M._font_source_epoch
end
local function publish_active_sources()
    if type(core.ipc_set)~="function" then return end
    local state={}
    for id,source in pairs(M.registered_font_sources) do state[id]=tonumber(source._source_epoch) or 0 end
    M._font_registry_epoch=M._font_registry_epoch+1
    core.ipc_set(ACTIVE_SOURCES_IPC,state)
    core.ipc_set(ACTIVE_SOURCES_EPOCH_IPC,M._font_registry_epoch)
end
local mods_loaded = false

local function valid_id(id)
    local owner, name = type(id) == "string" and id:match("^([a-z0-9_]+):([a-z0-9_]+)$")
    return owner, name
end

local function safe_relative(path)
    if type(path) ~= "string" or path == "" then return false end
    if path:sub(1,1) == "/" or path:sub(1,1) == "\\" or path:match("^%a:[/\\]") then return false end
    for part in path:gmatch("[^/\\]+") do if part == ".." then return false end end
    return true
end

local function join(base, rel)
    rel = rel:gsub("[/\\]", sep)
    if base:sub(-1) == "/" or base:sub(-1) == "\\" then return base .. rel end
    return base .. sep .. rel
end

local function load_one(id, source)
    local font, err
    if source.source_kind=="data" then
        font,err=F.source.load_data(source._data,source,source.filename or source.path_hint)
    else
        local base = core.get_modpath(source.modname)
        if not base then return nil, "source mod is not installed: " .. source.modname end
        local path = join(base, source.filename)
        font,err=F.source.load(path, source)
    end
    if not font then return nil, err end
    font.id = id
    font.source_mod = source.modname
    font.source_path = source.filename
    font.source_kind = source.source_kind or "file"
    font.source_face = source.face or source.index
    if source.family then font.family = source.family end
    if source.style then font.style = source.style end
    if source.fallback then font.fallback = source.fallback end
    F._registry[id] = font
    return font
end

local function load_registered()
    local ids = {}
    for id in pairs(M.registered_font_sources) do ids[#ids+1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local source = M.registered_font_sources[id]
        if not source.loaded then
            local font, err = load_one(id, source)
            if font then
                source.loaded = true
                source.error = nil
            else
                source.error = tostring(err)
                if core.log then core.log("error", "[fontlib] failed to load " .. id .. ": " .. tostring(err)) end
            end
        end
    end
    for _, cb in ipairs(callbacks) do
        local ok, err = pcall(cb, M.registered_fonts)
        if not ok and core.log then core.log("error", "[fontlib] fonts-loaded callback failed: " .. tostring(err)) end
    end
end

function M.register_font(id, def)
    local owner = valid_id(id)
    assert(owner, "font id must use the Luanti-style namespace 'modname:font_name'")
    assert(type(def) == "table", "font definition must be a table")
    -- get_current_modname() is unavailable from nested library calls.
    local filename = def.filename or def.file or def.path
    assert(safe_relative(filename), "font filename must be a relative path inside the owning mod")
    assert(not M.registered_font_sources[id] and not F._registry[id], "font already registered: " .. id)
    local source = {}
    for k,v in pairs(def) do source[k] = v end
    source.filename = filename
    source.modname = owner
    source.loaded = false
    source._revision = 1
    source._source_epoch = next_source_epoch()
    M.registered_font_sources[id] = source
    publish_active_sources()

    -- Parse the container immediately so registration behaves like Luanti's other registries.
    local font, err = load_one(id, source)
    if not font then
        source.error = tostring(err)
        if core.log then core.log("error", "[fontlib] failed to register " .. id .. ": " .. tostring(err)) end
        return nil, err
    end
    source.loaded = true
    source.error = nil
    return font
end


function M.load_font_data(data, options)
    return F.source.load_data(data, options or {}, (options or {}).filename or (options or {}).path_hint)
end

function M.register_font_data(id, data, def)
    local owner = valid_id(id)
    assert(owner, "font id must use the Luanti-style namespace 'modname:font_name'")
    assert(type(data)=="string", "font data must be a binary string")
    def=def or {};assert(type(def)=="table", "font definition must be a table")
    assert(not M.registered_font_sources[id] and not F._registry[id], "font already registered: " .. id)
    local source={}
    for k,v in pairs(def) do source[k]=v end
    source.modname=owner;source.source_kind="data";source._data=data;source.loaded=false;source._revision=1;source._source_epoch=next_source_epoch()
    source.filename=source.filename or source.path_hint
    source.ipc_key="fontlib:fontdata:"..id
    if type(core.ipc_set)=="function" then core.ipc_set(source.ipc_key,data) end
    M.registered_font_sources[id]=source
    publish_active_sources()
    local font,err=load_one(id,source)
    if not font then source.error=tostring(err);return nil,err end
    source.loaded=true;source.error=nil
    return font
end

function M.unregister_font(id)
    local source=M.registered_font_sources[id]
    M.registered_font_sources[id]=nil
    publish_active_sources()
    if source and source.source_kind=="data" and source.ipc_key and type(core.ipc_set)=="function" then
        -- Release the shared source bytes; workers that already parsed this face purge it
        -- opportunistically from their private registries on later jobs.
        pcall(core.ipc_set,source.ipc_key,nil)
    end
    return F.unregister(id),source
end

function M.get_font(id)
    return F.get(id)
end

function M.get_font_source(id)
    return M.registered_font_sources[id]
end

function M.register_on_fonts_loaded(callback)
    assert(type(callback) == "function", "callback must be a function")
    callbacks[#callbacks+1] = callback
    if mods_loaded then callback(M.registered_fonts) end
end

function M.reload_font(id)
    local source = M.registered_font_sources[id]
    if not source then return nil, "font is not a registered source: " .. tostring(id) end
    local font, err = load_one(id, source)
    if not font then source.error = tostring(err); return nil, err end
    source.loaded = true; source.error = nil
    source._revision = (tonumber(source._revision) or 1) + 1
    return font
end

if core.register_on_mods_loaded then
    core.register_on_mods_loaded(function()
        mods_loaded = true
        load_registered()
    end)
else
    mods_loaded = true
    load_registered()
end
