-- SPDX-License-Identifier: 0BSD
-- Font rendering helpers.
local M = fontlib
local F = M.font
local V = M.vector
local O = M.output
local E = M.effects

local function with_font(font, options)
    local copy={}
    for k,v in pairs(options or {}) do copy[k]=v end
    copy.font=font
    return copy
end

function M.text_scene(text, options)
    options = options or {}
    local font_ref = options.font or M.DEFAULT_FONT
    local font = assert(F.get(font_ref), "unknown Fontlib font " .. tostring(font_ref))
    local size = tonumber(options.size) or font.units_per_em
    local spacing = tonumber(options.letter_spacing) or 0
    local measured_width, measured_height, _, metrics = F.measure(text, font, size, spacing, options.line_height, options)
    local padding = tonumber(options.padding) or 0
    local effect_left,effect_top,effect_right,effect_bottom,effects=E.margins(options)
    local width = math.max(1, math.ceil(tonumber(options.width) or (measured_width + padding * 2 + effect_left + effect_right)))
    local height = math.max(1, math.ceil(tonumber(options.height) or (measured_height + padding * 2 + effect_top + effect_bottom)))
    local align = options.align or "left"
    local x = padding + effect_left
    if align == "center" then
        -- Center inside the usable content box so an asymmetric shadow does not move the actual
        -- text merely because its effect extends farther right.
        x = (effect_left + (width - effect_right)) / 2
    elseif align == "right" then
        x = width - padding - effect_right
    end

    local gb=nil
    if options.gasp~=false and font._gasp_behavior then gb=font._gasp_behavior(size) end
    local auto_ss=nil
    if options.supersample==nil and gb then auto_ss=gb.gray and 2 or 1 end
    local scene = V.new_scene(width, height, {
        -- Effects need the glyph alpha silhouette, so render text onto a transparent
        -- intermediate and composite the requested background last.
        background = effects and "#00000000" or (options.background or "#00000000"),
        supersample = auto_ss,
    })
    if effects then
        scene._fontlib_text_effects=effects
        scene._fontlib_effect_background=options.background or "#00000000"
    end
    V.add(scene, F.text_object(text, {
        x = x,
        y = padding + effect_top,
        font = font,
        fallback = options.fallback,
        size = size,
        color = options.color or "#FFFFFF",
        palette = options.palette ~= nil and options.palette or options.palette_index,
        color_glyphs = options.color_glyphs,
        hinting = options.hinting,
        gasp = options.gasp,
        align = align,
        letter_spacing = spacing,
        word_spacing = options.word_spacing,
        line_height = options.line_height,
        opacity = options.opacity,
        text_mode = options.text_mode,
        stroke_width = options.stroke_width,
        bitmap_filter = options.bitmap_filter,
        bitmap_ppi = options.bitmap_ppi or options.ppi,
        language = options.language,
        features = options.features or options.font_features or options.font_feature_settings,
        kerning = options.kerning,
        ligatures = options.ligatures,
        base_direction = options.base_direction,
        writing_mode = options.writing_mode or options.writing_direction,
        vertical = options.vertical,
        vertical_feature = options.vertical_feature,
        column_spacing = options.column_spacing,
        fill_rule = options.fill_rule,
    }))
    return scene, metrics
end

function M.render_text(text, options)
    local scene, metrics = M.text_scene(text, options)
    return V.render(scene, options), metrics
end

function M.text_texture(text, options)
    local canvas, metrics = M.render_text(text, options)
    local texture, canvas_or_error = O.to_texture(canvas, options)
    if not texture then return nil, canvas_or_error end
    return texture, canvas_or_error, metrics
end

function M.publish_text(text, options, callback)
    if type(options)=="function" and callback==nil then callback=options;options={} end
    local canvas, metrics = M.render_text(text, options)
    local filename, canvas_or_error = O.publish(canvas, options, callback)
    if not filename then return nil, canvas_or_error end
    return filename, canvas_or_error, metrics
end

-- Font methods.
function F._methods:render_text(text, options) return M.render_text(text,with_font(self,options)) end
function F._methods:text_texture(text, options) return M.text_texture(text,with_font(self,options)) end
function F._methods:publish_text(text, options, callback)
    if type(options)=="function" and callback==nil then callback=options;options={} end
    return M.publish_text(text,with_font(self,options),callback)
end

-- Font aliases.
F._methods.texture = F._methods.text_texture
F._methods.publish = F._methods.publish_text
