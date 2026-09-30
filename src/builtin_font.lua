-- SPDX-License-Identifier: 0BSD
-- Bundled fallback font.
local M = fontlib
local F, V = M.font, M.vector
local font = {
    family = 'Fontlib Simple',
    style = 'Regular',
    full_name = 'Fontlib Simple',
    postscript_name = 'FontlibSimple',
    units_per_em = 8.0,
    ascent = 8.0,
    descent = 0.0,
    default_advance = 6.0,
    line_gap = 2.0,
    stroke_width = 0.62,
    mode = 'stroke',
    fill_rule = "nonzero", glyphs = {}, aliases = {}, kern = {}, source_format = "lua-builtin",
}
font.glyphs[32] = { advance = 4.0 }
font.glyphs[65] = { advance = 6.0, contours = V.parse_path('M 0 7 L 2.5 0 L 5 7 M 1 4.2 L 4 4.2') }
font.glyphs[66] = { advance = 6.0, contours = V.parse_path('M 0 0 L 0 7 M 0 0 L 3.5 0 L 5 1.2 L 5 2.5 L 3.5 3.5 L 0 3.5 M 0 3.5 L 3.7 3.5 L 5 4.5 L 5 5.8 L 3.5 7 L 0 7') }
font.glyphs[67] = { advance = 6.0, contours = V.parse_path('M 5 1 L 4 0 L 1.5 0 L 0 1.5 L 0 5.5 L 1.5 7 L 4 7 L 5 6') }
font.glyphs[68] = { advance = 6.0, contours = V.parse_path('M 0 0 L 0 7 L 3 7 L 5 5 L 5 2 L 3 0 L 0 0') }
font.glyphs[69] = { advance = 6.0, contours = V.parse_path('M 5 0 L 0 0 L 0 7 L 5 7 M 0 3.5 L 4 3.5') }
font.glyphs[70] = { advance = 6.0, contours = V.parse_path('M 0 7 L 0 0 L 5 0 M 0 3.5 L 4 3.5') }
font.glyphs[71] = { advance = 6.0, contours = V.parse_path('M 5 1 L 4 0 L 1.5 0 L 0 1.5 L 0 5.5 L 1.5 7 L 4 7 L 5 6 L 5 4 L 3 4') }
font.glyphs[72] = { advance = 6.0, contours = V.parse_path('M 0 0 L 0 7 M 5 0 L 5 7 M 0 3.5 L 5 3.5') }
font.glyphs[73] = { advance = 4.0, contours = V.parse_path('M 0 0 L 3 0 M 1.5 0 L 1.5 7 M 0 7 L 3 7') }
font.glyphs[74] = { advance = 6.0, contours = V.parse_path('M 5 0 L 5 5.5 L 3.5 7 L 1.5 7 L 0 5.8') }
font.glyphs[75] = { advance = 6.0, contours = V.parse_path('M 0 0 L 0 7 M 5 0 L 0 4 L 5 7') }
font.glyphs[76] = { advance = 6.0, contours = V.parse_path('M 0 0 L 0 7 L 5 7') }
font.glyphs[77] = { advance = 7.0, contours = V.parse_path('M 0 7 L 0 0 L 3 3 L 6 0 L 6 7') }
font.glyphs[78] = { advance = 6.0, contours = V.parse_path('M 0 7 L 0 0 L 5 7 L 5 0') }
font.glyphs[79] = { advance = 6.0, contours = V.parse_path('M 1.5 0 L 3.5 0 L 5 1.5 L 5 5.5 L 3.5 7 L 1.5 7 L 0 5.5 L 0 1.5 L 1.5 0') }
font.glyphs[80] = { advance = 6.0, contours = V.parse_path('M 0 7 L 0 0 L 3.5 0 L 5 1.2 L 5 2.6 L 3.5 3.8 L 0 3.8') }
font.glyphs[81] = { advance = 6.0, contours = V.parse_path('M 1.5 0 L 3.5 0 L 5 1.5 L 5 5.5 L 3.5 7 L 1.5 7 L 0 5.5 L 0 1.5 L 1.5 0 M 3.2 5 L 5.5 7.5') }
font.glyphs[82] = { advance = 6.0, contours = V.parse_path('M 0 7 L 0 0 L 3.5 0 L 5 1.2 L 5 2.6 L 3.5 3.8 L 0 3.8 M 3 3.8 L 5.2 7') }
font.glyphs[83] = { advance = 6.0, contours = V.parse_path('M 5 1 L 4 0 L 1.2 0 L 0 1.2 L 0 2.5 L 1.2 3.5 L 4 3.5 L 5 4.5 L 5 5.8 L 3.8 7 L 1 7 L 0 6') }
font.glyphs[84] = { advance = 6.0, contours = V.parse_path('M 0 0 L 5 0 M 2.5 0 L 2.5 7') }
font.glyphs[85] = { advance = 6.0, contours = V.parse_path('M 0 0 L 0 5.5 L 1.5 7 L 3.5 7 L 5 5.5 L 5 0') }
font.glyphs[86] = { advance = 6.0, contours = V.parse_path('M 0 0 L 2.5 7 L 5 0') }
font.glyphs[87] = { advance = 8.0, contours = V.parse_path('M 0 0 L 1.5 7 L 3.5 3.5 L 5.5 7 L 7 0') }
font.glyphs[88] = { advance = 6.0, contours = V.parse_path('M 0 0 L 5 7 M 5 0 L 0 7') }
font.glyphs[89] = { advance = 6.0, contours = V.parse_path('M 0 0 L 2.5 3.5 L 5 0 M 2.5 3.5 L 2.5 7') }
font.glyphs[90] = { advance = 6.0, contours = V.parse_path('M 0 0 L 5 0 L 0 7 L 5 7') }
font.glyphs[48] = { advance = 6.0, contours = V.parse_path('M 1.5 0 L 3.5 0 L 5 1.5 L 5 5.5 L 3.5 7 L 1.5 7 L 0 5.5 L 0 1.5 L 1.5 0 M 1 6 L 4 1') }
font.glyphs[49] = { advance = 6.0, contours = V.parse_path('M 1 1.5 L 2.5 0 L 2.5 7 M 1 7 L 4 7') }
font.glyphs[50] = { advance = 6.0, contours = V.parse_path('M 0 1.3 L 1.2 0 L 3.8 0 L 5 1.3 L 5 2.4 L 0 7 L 5 7') }
font.glyphs[51] = { advance = 6.0, contours = V.parse_path('M 0 0 L 4 0 L 5 1.2 L 5 2.6 L 4 3.5 L 2 3.5 M 4 3.5 L 5 4.4 L 5 5.8 L 4 7 L 0 7') }
font.glyphs[52] = { advance = 6.0, contours = V.parse_path('M 4 7 L 4 0 L 0 4.8 L 5 4.8') }
font.glyphs[53] = { advance = 6.0, contours = V.parse_path('M 5 0 L 0 0 L 0 3.3 L 3.8 3.3 L 5 4.5 L 5 5.8 L 3.8 7 L 1 7 L 0 6') }
font.glyphs[54] = { advance = 6.0, contours = V.parse_path('M 5 1 L 4 0 L 1.5 0 L 0 1.5 L 0 5.5 L 1.5 7 L 3.7 7 L 5 5.7 L 5 4.4 L 3.7 3.3 L 0 3.3') }
font.glyphs[55] = { advance = 6.0, contours = V.parse_path('M 0 0 L 5 0 L 1.7 7') }
font.glyphs[56] = { advance = 6.0, contours = V.parse_path('M 1.3 0 L 3.7 0 L 5 1.2 L 5 2.4 L 3.7 3.5 L 1.3 3.5 L 0 2.4 L 0 1.2 L 1.3 0 M 1.3 3.5 L 3.7 3.5 L 5 4.6 L 5 5.8 L 3.7 7 L 1.3 7 L 0 5.8 L 0 4.6 L 1.3 3.5') }
font.glyphs[57] = { advance = 6.0, contours = V.parse_path('M 5 3.7 L 1.3 3.7 L 0 2.5 L 0 1.2 L 1.3 0 L 3.5 0 L 5 1.5 L 5 5.5 L 3.5 7 L 1 7 L 0 6') }
font.glyphs[46] = { advance = 3.0, contours = V.parse_path('M 1.5 6.7 L 1.5 7') }
font.glyphs[44] = { advance = 3.0, contours = V.parse_path('M 1.7 6.5 L 1.2 7.6') }
font.glyphs[58] = { advance = 3.0, contours = V.parse_path('M 1.5 2 L 1.5 2.3 M 1.5 6.2 L 1.5 6.5') }
font.glyphs[59] = { advance = 3.0, contours = V.parse_path('M 1.5 2 L 1.5 2.3 M 1.7 6.2 L 1.2 7.3') }
font.glyphs[33] = { advance = 3.0, contours = V.parse_path('M 1.5 0 L 1.5 5.2 M 1.5 6.7 L 1.5 7') }
font.glyphs[63] = { advance = 6.0, contours = V.parse_path('M 0 1.3 L 1.2 0 L 3.8 0 L 5 1.3 L 5 2.4 L 2.5 4.2 L 2.5 5.2 M 2.5 6.7 L 2.5 7') }
font.glyphs[45] = { advance = 5.0, contours = V.parse_path('M 0 3.5 L 4 3.5') }
font.glyphs[95] = { advance = 6.0, contours = V.parse_path('M 0 7.5 L 5 7.5') }
font.glyphs[43] = { advance = 6.0, contours = V.parse_path('M 0 3.5 L 5 3.5 M 2.5 1 L 2.5 6') }
font.glyphs[61] = { advance = 6.0, contours = V.parse_path('M 0 2.6 L 5 2.6 M 0 4.6 L 5 4.6') }
font.glyphs[47] = { advance = 6.0, contours = V.parse_path('M 0 7 L 5 0') }
font.glyphs[92] = { advance = 6.0, contours = V.parse_path('M 0 0 L 5 7') }
font.glyphs[124] = { advance = 3.0, contours = V.parse_path('M 1.5 0 L 1.5 7') }
font.glyphs[40] = { advance = 4.0, contours = V.parse_path('M 3 0 L 1.5 1.2 L 1 3.5 L 1.5 5.8 L 3 7') }
font.glyphs[41] = { advance = 4.0, contours = V.parse_path('M 0 0 L 1.5 1.2 L 2 3.5 L 1.5 5.8 L 0 7') }
font.glyphs[91] = { advance = 4.0, contours = V.parse_path('M 3 0 L 1 0 L 1 7 L 3 7') }
font.glyphs[93] = { advance = 4.0, contours = V.parse_path('M 0 0 L 2 0 L 2 7 L 0 7') }
font.glyphs[60] = { advance = 6.0, contours = V.parse_path('M 5 1 L 0 3.5 L 5 6') }
font.glyphs[62] = { advance = 6.0, contours = V.parse_path('M 0 1 L 5 3.5 L 0 6') }
font.glyphs[34] = { advance = 4.0, contours = V.parse_path('M 1 0 L 1 2 M 3 0 L 3 2') }
font.glyphs[39] = { advance = 3.0, contours = V.parse_path('M 1.5 0 L 1.5 2') }
font.glyphs[35] = { advance = 7.0, contours = V.parse_path('M 2 0 L 1 7 M 5 0 L 4 7 M 0 2.3 L 6 2.3 M 0 4.8 L 6 4.8') }
font.glyphs[37] = { advance = 7.0, contours = V.parse_path('M 0 7 L 6 0 M 1.2 0 L 2.2 0 L 2.7 0.7 L 2.7 1.7 L 2.2 2.4 L 1.2 2.4 L 0.7 1.7 L 0.7 0.7 L 1.2 0 M 3.8 4.6 L 4.8 4.6 L 5.3 5.3 L 5.3 6.3 L 4.8 7 L 3.8 7 L 3.3 6.3 L 3.3 5.3 L 3.8 4.6') }
font.glyphs[38] = { advance = 7.0, contours = V.parse_path('M 5.8 7 L 1.2 2.6 L 0.8 1.6 L 1.5 0 L 3 0 L 4 1 L 4 2 L 0 5.7 L 1.2 7 L 3 7 L 5.5 4.4') }
font.glyphs[64] = { advance = 8.0, contours = V.parse_path('M 6.5 5.7 L 6.5 2 L 5 0 L 2 0 L 0 2 L 0 5 L 2 7 L 5 7 M 5.5 2 L 5.5 5 L 3 5 L 2 4 L 2 2.8 L 3 2 L 5.5 2 L 5.5 6') }
font.glyphs[42] = { advance = 6.0, contours = V.parse_path('M 2.5 1 L 2.5 6 M 0.5 2 L 4.5 5 M 4.5 2 L 0.5 5') }
F.register(M.DEFAULT_FONT, F._normalize(font))
return font
