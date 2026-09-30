-- SPDX-License-Identifier: 0BSD
-- PNG, texture, and dynamic-media output.
local core = assert(rawget(_G, "core") or rawget(_G, "minetest"))
local M = fontlib
local V = M.vector
local O = M.output

O._published = O._published or {}
O._publish_serial = O._publish_serial or 0

local function adler32(data)
    local a, b = 1, 0
    for i = 1, #data do
        a = (a + data:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return string.format("%08x", b * 65536 + a)
end

local function as_canvas(canvas_or_scene, options)
    assert(type(canvas_or_scene) == "table", "canvas or scene required")
    return canvas_or_scene.pixels and canvas_or_scene or V.render(canvas_or_scene, options)
end

function O.to_png(canvas_or_scene, options)
    options = options or {}
    if type(options) == "number" then
        options = {compression = options}
    end
    if not core.encode_png then
        return nil, "this Luanti build does not expose core.encode_png"
    end
    local canvas = as_canvas(canvas_or_scene, options)
    return core.encode_png(canvas.width, canvas.height, V.rgba(canvas), options.compression or 6), canvas
end

function O.to_texture(canvas_or_scene, options)
    options = options or {}
    if not core.encode_base64 then
        return nil, "this Luanti build does not expose core.encode_base64"
    end
    local png, canvas = O.to_png(canvas_or_scene, options)
    if not png then
        return nil, canvas
    end
    return "[png:" .. core.encode_base64(png), canvas
end

function O.publish_png(png, options, callback)
    options = options or {}
    if type(png) ~= "string" then return nil, "PNG bytes required" end
    if not core.dynamic_add_media then
        return nil, "this Luanti build does not expose core.dynamic_add_media"
    end
    if core.has_feature and not core.has_feature("dynamic_add_media_filepath") then
        return nil, "publishing generated in-memory media requires Luanti 5.9+; use to_texture() on older engines"
    end

    local hash = (core.sha256 and core.sha256(png):sub(1, 24)) or adler32(png)
    local prefix = (options.prefix or "fontlib"):gsub("[^%w_.-]", "_")
    local ephemeral = options.ephemeral == true
    local filename
    if ephemeral then
        -- Ephemeral media is removed after delivery, so every publication must have a distinct
        -- name.
        O._publish_serial = O._publish_serial + 1
        filename = string.format("%s_%s_e%d.png", prefix, hash, O._publish_serial)
    else
        filename = prefix .. "_" .. hash .. ".png"
    end

    local target = options.to_player or "*"
    local cache_key = filename .. "\0" .. target
    if not ephemeral then
        local state = O._published[cache_key]
        if state then
            if callback then
                if state == true or state.ready then
                    callback(options.to_player, filename)
                else
                    state.callbacks[#state.callbacks + 1] = callback
                end
            end
            return filename
        end
        state = {ready = false, callbacks = {}}
        if callback then state.callbacks[1] = callback end
        O._published[cache_key] = state
    end

    local function delivered(player_name)
        if ephemeral then
            if callback then callback(player_name, filename) end
            return
        end
        local state = O._published[cache_key]
        if type(state) ~= "table" then return end
        state.ready = true
        local callbacks = state.callbacks
        state.callbacks = {}
        for i = 1, #callbacks do
            callbacks[i](player_name, filename)
        end
    end

    local media_options = {
        filename = filename,
        filedata = png,
        to_player = options.to_player,
        ephemeral = ephemeral,
    }
    if options.client_cache ~= nil then
        media_options.client_cache = options.client_cache == true
    end

    local ok, accepted = pcall(core.dynamic_add_media, media_options, callback and delivered or nil)
    if not ok or not accepted then
        if not ephemeral then O._published[cache_key] = nil end
        return nil, "Luanti rejected generated media " .. filename
    end
    if not ephemeral and not callback then
        local state = O._published[cache_key]
        if type(state) == "table" then state.ready = true end
    end
    return filename
end

function O.publish(canvas_or_scene, options, callback)
    options = options or {}
    local png, canvas = O.to_png(canvas_or_scene, options)
    if not png then return nil, canvas end
    local filename, err = O.publish_png(png, options, callback)
    if not filename then return nil, err end
    return filename, canvas
end
