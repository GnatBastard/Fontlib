-- SPDX-License-Identifier: 0BSD
-- Font rendering and vector drawing for Luanti.
local core = assert(rawget(_G, "core") or rawget(_G, "minetest"), "Fontlib requires Luanti")

local existing = rawget(_G, "fontlib")
assert(existing == nil or type(existing) == "table", "global fontlib is already occupied")
fontlib = existing or {}
local M = fontlib

M.VERSION = "1.0.0"
M.API_VERSION = 1
M.DEFAULT_FONT = "fontlib:simple"
M.modpath = core.get_modpath(core.get_current_modname())

M.font = M.font or {}
M.vector = M.vector or {}
M.output = M.output or {}
M.effects = M.effects or {}

dofile(M.modpath .. "/src/vector.lua")
dofile(M.modpath .. "/src/effects.lua")
dofile(M.modpath .. "/src/unicode.lua")
M.unicode_properties = dofile(M.modpath .. "/src/unicode_properties.lua")
M.unicode_linebreak_properties = dofile(M.modpath .. "/src/unicode_linebreak_properties.lua")
M.unicode_grapheme_properties = dofile(M.modpath .. "/src/unicode_grapheme_properties.lua")
dofile(M.modpath .. "/src/unicode_grapheme.lua")
dofile(M.modpath .. "/src/unicode_linebreak.lua")
dofile(M.modpath .. "/src/typography.lua")
dofile(M.modpath .. "/src/font.lua")
dofile(M.modpath .. "/src/opentype_layout.lua")
dofile(M.modpath .. "/src/truetype_vm.lua")
dofile(M.modpath .. "/src/font_source.lua")
dofile(M.modpath .. "/src/shaping.lua")
dofile(M.modpath .. "/src/font_psf.lua")
dofile(M.modpath .. "/src/font_pcf.lua")
dofile(M.modpath .. "/src/registration.lua")
dofile(M.modpath .. "/src/builtin_font.lua")
dofile(M.modpath .. "/src/font_family.lua")
dofile(M.modpath .. "/src/vector_asset.lua")
dofile(M.modpath .. "/src/vector_formats.lua")
dofile(M.modpath .. "/src/output.lua")
dofile(M.modpath .. "/src/convenience.lua")
dofile(M.modpath .. "/src/richtext.lua")
dofile(M.modpath .. "/src/async.lua")
