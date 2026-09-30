# Fontlib

Fontlib renders fonts to Luanti textures at runtime. It runs in the normal Lua sandbox and does not need trusted-mod access, FFI, native libraries, or an external font converter.

It also exposes the vector renderer used by the text engine.

## Basic use

Add `fontlib` to your mod's dependencies, then register a font during startup:

```lua
local font = assert(fontlib.register_font("my_signs:inter", {
    file = "fonts/Inter-Regular.ttf",
}))

local texture = assert(font:texture("OPEN", {
    size = 64,
    color = "#FFFFFF",
    background = "#9B1C1C",
    padding = 12,
    outline = { width = 2, color = "#000000" },
    shadow = { x = 3, y = 3, blur = 3, color = "#00000080" },
}))
```

The result is a normal Luanti `[png:]` texture string.

For text that changes while the server is running, use the async renderer:

```lua
font:texture_async("Players: 12", { size = 32 }, function(texture, err, info)
    if not texture then
        core.log("error", err)
        return
    end
    -- apply texture here
end)
```

Async work uses Luanti's worker pool. The callback runs in the main environment.

## Rich text

```lua
local texture = assert(font:paragraph({
    "Plain text, ",
    { text = "styled text", color = "#FFD166", underline = true },
    { text = " and larger text.", size = 24 },
}, {
    size = 18,
    width = 420,
    align = "start",
}))
```

Paragraph layout supports mixed fonts and sizes, wrapping, justification, bidi text, vertical text, ruby, emphasis marks, decorations, effects, tabs, hyphenation data, and fit-to-rectangle sizing.

To fit a paragraph to a fixed box:

```lua
local texture = assert(font:fit({
    { text = "TITLE", size = 24, outline = 1 },
    { text = "\nSupporting text", size = 12 },
}, {
    width = 320,
    height = 96,
    min_size = 7,
    max_size = 42,
    align = "center",
    valign = "middle",
}))
```

## Format support

All loaders run inside the Luanti Lua sandbox.

### Font containers

| Format | Support | Notes |
|---|---|---|
| TTF / TrueType OpenType | Yes | `glyf`, composites, `gvar`, `cvar`, hinting, horizontal/vertical metrics |
| OTF with TrueType outlines | Yes | Same TrueType path |
| OTF with CFF1 | Yes | Type 2 charstrings |
| OTF with CFF2 | Yes | Variable CFF2, HVAR/VVAR/MVAR, variable layout |
| WOFF 1.0 | Yes | Deflate tables |
| WOFF2 | No | Brotli and WOFF2 transforms are not available in the sandbox |
| TTC / OTC | Yes | Select with zero-based `face` / `index` |
| BDF | Yes | Bitmap fonts |
| PCF | Yes | Common X11 PCF tables/encodings |
| PSF1 / PSF2 | Yes | Unicode maps supported |
| gzip wrappers | Yes | Where used with a supported source type |
| UFO | No | Editor/source format |
| FON/FNT | No | Not implemented |
| Speedo/SNF | No | Not implemented |

### Variable fonts

Supported tables and behavior include:

- `fvar` axes and `avar` mapping
- TrueType `gvar` and `cvar`
- CFF2 `vsindex` / `blend`
- HVAR, VVAR, and MVAR
- GDEF/GPOS VariationIndex data
- GSUB/GPOS FeatureVariations, including `rvrn`
- proposed `VARC` variable composites
- proposed `avar` v2 cross-axis variation data

Pass axis values with `axes` or `variations`, for example `{ wght = 700 }`.

### Color fonts

Supported:

- CPAL v0/v1
- COLR v0/v1, including gradients, transforms, clips, variable paints, and composites
- CBDT/CBLC PNG strikes, image formats 17/18/19
- sbix PNG and common 8-bit Huffman JPEG strikes
- static SVG-in-OpenType, including gzip documents, gradients, clipping, styles, `<use>`, nested viewports, and embedded PNG/JPEG data URIs

Not supported:

- sbix TIFF
- arithmetic/lossless/CMYK JPEG variants
- legacy uncompressed EBDT-style bitmap payloads inside CBDT
- SVG animation, scripts, external resources, patterns, masks, filters, or markers

`color_glyphs = false` requests the monochrome outline when one is available.

### Text and shaping

Supported:

- strict UTF-8 decoding
- cmap formats 0, 2, 4, 6, 8, 10, 12, 13, and format 14 variation sequences
- `kern` and GPOS positioning
- GSUB lookup types 1-8
- GDEF lookup flags and mark filtering
- cursive, mark-to-base, mark-to-ligature, and mark-to-mark positioning
- Arabic joining and OpenType Arabic forms
- Indic shaping for Devanagari, Bengali, Gurmukhi, Gujarati, Odia, Tamil, Telugu, Kannada, Malayalam, and Sinhala
- Myanmar shaping
- Khmer shaping
- mixed LTR/RTL runs
- `vertical-rl` and `vertical-lr` with vertical metrics and `vrt2`/`vert`
- Unicode grapheme and line-break data used by rich-text layout
- TrueType bytecode hinting for simple and composite `glyf` outlines

Known gaps:

- full UAX #9 conformance for every explicit-control, isolate, and paired-bracket edge case
- dedicated shapers for remaining complex-script families
- UAX #50 engine-side vertical orientation and BASE-table baseline selection

### Vector files

| Format | Support | Notes |
|---|---|---|
| SVG | Yes | Static paths, shapes, groups, transforms, gradients, clipping, strokes, reuse, nested viewports, PNG/JPEG images |
| SVGZ | Yes | gzip-compressed SVG |
| ASCII DXF | Partial | LINE, CIRCLE, ARC, LWPOLYLINE |
| HP-GL / PLT / HPG | Partial | IN, PA, PR, PU, PD, CI, AA, AR |
| PDF | No | Use a PDF adapter and Fontlib's text/vector primitives |
| EPS / PS | No | Not implemented |
| AI | No | Not implemented |
| EMF / WMF | No | Not implemented |

## Embedded fonts

Use `register_font_data()` for fonts supplied as bytes, such as embedded PDF fonts:

```lua
local font = assert(fontlib.register_font_data("reader:subset", bytes, {
    filename = "subset.otf",
}))
```

Use `fontlib.unregister_font(id)` when a temporary registered font is no longer needed.

## Vector drawing

`fontlib.vector` provides a software RGBA renderer for paths, shapes, groups, transforms, text, and images. SVG/SVGZ can be loaded at runtime; small DXF and HP-GL subsets are also supported.

```lua
local V = fontlib.vector
local scene = V.new_scene(256, 128)
V.add(scene, {
    type = "rect",
    x = 8, y = 8, width = 240, height = 112,
    fill = "#202020",
})
local texture = assert(fontlib.output.to_texture(scene))
```

## Installation

Install the `fontlib` directory as a Luanti mod and add:

```text
depends = fontlib
```

to the consuming mod's `mod.conf`.

## API reference

Consumer mods should declare `fontlib` in `depends`. The public global is `fontlib`.

### Version

```lua
fontlib.VERSION
fontlib.API_VERSION
fontlib.DEFAULT_FONT -- "fontlib:simple"
```

### Registering fonts

#### `fontlib.register_font(id, definition)`

Registers a file-backed font and returns a Font object, or `nil, error`.

```lua
local font = assert(fontlib.register_font("my_mod:inter", {
    file = "fonts/Inter-Regular.ttf",
}))
```

`id` must be `modname:name`. The file must be below that mod's directory.

Common fields:

- `file` / `filename` / `path` — relative source path
- `face` / `index` — zero-based TTC/OTC face index
- `family`, `style` — metadata overrides
- `fallback` — font ID, Font object, or ordered array
- `variations` / `axes` — variable-font axes, for example `{ wght=700 }`

Absolute paths and `..` path segments are rejected.

#### `fontlib.register_font_data(id, bytes[, definition])`

Registers a font from a binary string.

```lua
local font = assert(fontlib.register_font_data("reader:subset", bytes, {
    filename = "subset.otf",
}))
```

`definition` accepts the same face, variation, and fallback fields as `register_font()`.

Other registration calls:

```lua
fontlib.load_font_data(bytes[, options])
fontlib.unregister_font(id)
fontlib.get_font(id_or_font)
fontlib.get_font_source(id)
fontlib.reload_font(id)
fontlib.register_on_fonts_loaded(callback)
```

Registries:

```lua
fontlib.registered_fonts
fontlib.registered_font_sources
```

### Font families

```lua
fontlib.register_font_family("Inter", {
    regular = "my_mod:inter_regular",
    bold = "my_mod:inter_bold",
    italic = "my_mod:inter_italic",
    bold_italic = "my_mod:inter_bold_italic",
    aliases = { "sans-serif" },
})

local face = fontlib.resolve_font("Inter", {
    weight = 700,
    style = "italic",
    stretch = 100,
})
```

The general family form is:

```lua
faces = {
    { font="my_mod:regular", weight=400, style="normal", stretch=100 },
    { font="my_mod:bold", weight=700, style="normal", stretch=100 },
}
```

### Font object

Useful fields include:

```lua
font.id
font.family
font.style
font.full_name
font.postscript_name
font.units_per_em
font.ascent
font.descent
font.line_gap
font.source_format
font.outline_format
font.variable
font.variation_axes
font.variations
font.metrics_source
font.x_height
font.cap_height
```

Fields prefixed with `_` are internal.

#### Glyphs and metrics

```lua
font:get_glyph(codepoint)
font:has_glyph(codepoint)
font:measure(text, size[, options])
font:get_metrics(size[, line_height])
font:get_vertical_metrics(glyph_id[, size])
font:get_palette([index])
font:gasp_behavior(ppem)
font:clear_cache()
```

`measure()` returns:

```lua
width, height, line_count, metrics
```

Common measurement options:

- `letter_spacing`
- `line_height`
- `writing_mode = "vertical-rl" | "vertical-lr"`
- `column_spacing`

`get_vertical_metrics()` returns a table containing advance, bearings, origin, scale, and a `synthesized` flag when the font has no vertical tables.

`get_palette()` uses a zero-based CPAL palette index.

#### Text objects

```lua
font:text_object(text[, options])
```

Creates a vector-scene text object. Common options:

- `x`, `y`, `size`, `color`, `opacity`
- `palette` / `palette_index`
- `color_glyphs`
- `bitmap_filter = "bilinear" | "nearest"`
- `bitmap_ppi` / `ppi`
- `align`
- `writing_mode = "vertical-rl" | "vertical-lr"`
- `vertical_feature = "vrt2" | "vert"`
- `column_spacing`
- `letter_spacing`, `line_height`
- `text_mode = "fill" | "stroke"`, `stroke_width`
- vector transform fields

#### Positioned glyph runs

```lua
font:glyph_run_object(glyphs[, options])
```

Use this when glyph IDs and positions are already known.

```lua
local object = font:glyph_run_object({
    { gid=37, x_advance=512 },
    { gid=52, x_advance=488, x_offset=-8 },
}, {
    x=120, y=240, size=12,
    color="#000000",
    transform=text_matrix,
})
```

Glyph entries may use `gid`, `x_advance` / `advance`, `y_advance`, `x_offset`, `y_offset`, and optional source metadata. Positions are font units unless `position_units = "output"` or `"pixels"` is set.

### Plain text rendering

Top-level calls:

```lua
fontlib.text_scene(text, options)
fontlib.render_text(text, options)
fontlib.text_texture(text, options)
fontlib.publish_text(text, options[, callback])
```

Font-object forms:

```lua
font:render_text(text[, options])
font:texture(text[, options])
font:text_texture(text[, options])
font:publish(text[, options[, callback]])
font:publish_text(text[, options[, callback]])
```

Common options:

- `font` — ID or Font object; omitted on Font methods
- `fallback` — per-call fallback chain
- `size`, `color`, `background`, `padding`
- `width`, `height`, `align`
- `letter_spacing`, `line_height`
- `writing_mode`, `vertical_feature`, `column_spacing`
- `palette`, `color_glyphs`, `bitmap_filter`, `bitmap_ppi`
- `opacity`, `text_mode`, `stroke_width`
- `outline`
- `shadow`
- `glow`

Effect examples:

```lua
outline = { width=2, color="#000000", opacity=1 }
shadow  = { x=3, y=3, blur=3, spread=0, color="#00000080", opacity=1 }
glow    = { radius=4, spread=0, color="#FFFFFF80", opacity=1 }
```

`outline` also accepts `true`, a width number, or a color string. `shadow` and `glow` accept `true` and their short forms.

`text_texture()` returns `texture, canvas, metrics` or `nil, error`.

### Rich text

Content may be a string, span, or nested array of spans:

```lua
local content = {
    "Plain ",
    { text="large", size=24, color="#66AAFF" },
    { style={underline=true}, children={" linked text"}, link="doc://target" },
}
```

Main calls:

```lua
fontlib.layout_rich_text(content, options)
fontlib.rich_text_scene(content, options)
fontlib.render_rich_text(content, options)
fontlib.rich_texture(content, options)
fontlib.rich_png(content, options)

font:layout_rich_text(content, options)
font:rich_texture(content, options)
font:rich_png(content, options)
font:paragraph(content, options) -- rich_texture alias
```

Fit-to-rectangle calls:

```lua
fontlib.fit_rich_text(content, options)
fontlib.fit_texture(content, options)
fontlib.fit_png(content, options)

font:fit_layout(content, options)
font:fit_texture(content, options)
font:fit_png(content, options)
font:fit(content, options) -- fit_texture alias
```

Fit options require `width` and `height`; `min_size` and `max_size` bound the search. `layout.fit.size` is the chosen base size. `layout.fit.overflow` is true if `min_size` still does not fit.

Common rich-text controls include:

- font/fallback/family/weight/style/stretch
- size, color, opacity
- language, direction, `unicode_bidi`
- OpenType `features`, kerning, ligatures
- letter/word spacing, line height, baseline shift
- tabs and tab stops
- background and text decorations
- outline, shadow, glow
- ruby and emphasis marks
- indentation, alignment, justification, vertical alignment
- horizontal, `vertical-rl`, and `vertical-lr` writing
- `white_space`, `word_break`, `line_break`, `overflow_wrap`
- `id`, `link`, `role`, `data` metadata

Geometry helpers:

```lua
fontlib.richtext.snapshot(layout)
fontlib.richtext.hit_test(layout, x, y)
```

`hit_test()` returns line/fragment/source-span metadata.

Language data:

```lua
fontlib.register_word_dictionary(language, words)
fontlib.unregister_word_dictionary(language)
fontlib.register_hyphenation_patterns(language, spec)
fontlib.unregister_hyphenation_patterns(language)
```


### Async rendering

Availability:

```lua
local available, reason = fontlib.async_available()
```

Plain text:

```lua
fontlib.text_texture_async(text[, options], callback)
fontlib.text_png_async(text[, options], callback)
fontlib.publish_text_async(text[, options], callback)

font:texture_async(text[, options], callback)
font:text_png_async(text[, options], callback)
font:publish_async(text[, options], callback)
```

Rich text:

```lua
fontlib.layout_rich_text_async(content[, options], callback)
fontlib.rich_texture_async(content[, options], callback)
fontlib.rich_png_async(content[, options], callback)
fontlib.fit_texture_async(content, options, callback)
fontlib.fit_layout_async(content, options, callback)

font:layout_rich_text_async(content[, options], callback)
font:rich_texture_async(content[, options], callback)
font:rich_png_async(content[, options], callback)
font:fit_async(content, options, callback)
font:fit_layout_async(content, options, callback)
```

Plain texture callbacks receive:

```lua
texture, error, info
```

Rich-text render callbacks place the layout snapshot in `info.layout`. Layout-only callbacks receive `layout, error`.

Low-level submission:

```lua
local request = fontlib.render_async(spec, callback)
request:cancel()
```

`spec.kind` is `"text"` or `"rich_text"`. `spec.output` is `"texture"`, `"png"`, or `"layout"` where supported.

Async fonts must be registered from a file, font bytes, or the bundled fallback face.

### Shaping and Unicode

```lua
local shaped = font:shape(text, options)
local shaped = fontlib.shaping.shape(text, font, options)
```

The result contains positioned glyphs, paragraph data, and Unicode analysis.

Unicode analysis:

```lua
local analysis = fontlib.unicode.analyze(text, {
    base_direction = "auto", -- auto/ltr/rtl
})
```

Helpers:

```lua
fontlib.unicode.decode(text)
fontlib.unicode.codepoints(text)
fontlib.unicode.script(codepoint)
fontlib.unicode.bidi_class(codepoint)
fontlib.unicode.is_combining(codepoint)
fontlib.unicode.visual_codepoints(analysis)
```

See [Text and shaping](#text-and-shaping) for coverage and known gaps.

### TrueType VM diagnostics

```lua
local state, err = font:prepare_truetype_vm(16, 16, {
    point_size = 12 * 64,
    rotated = false,
    stretched = false,
    grayscale = true,
})

local info = font:truetype_vm_diagnostics()
```

The normal renderer prepares and runs the VM automatically. These calls are for diagnostics and low-level integrations.

### Vector API

```lua
local V = fontlib.vector
```

Canvas and scenes:

```lua
V.new_canvas(width, height[, background])
V.clear(canvas[, background])
V.new_scene(width, height[, options])
V.add(scene, object)
V.draw(canvas, object[, transform])
V.render(scene[, options])
V.rgba(canvas)
```

Colors:

```lua
V.color("#RRGGBB")
V.color("#RRGGBBAA")
V.color({r=255,g=0,b=0,a=255})
```

Transforms:

```lua
V.identity()
V.multiply(a, b)
V.translate(x, y)
V.scale(x[, y])
V.rotate(degrees)
V.transform_point(matrix, x, y)
V.inverse(matrix)
```

Scene object types include `rect`, `circle`, `ellipse`, `line`, `polyline`, `polygon`, `path`, `group`, `text`, and `rgba_image`.

Paths:

```lua
V.parse_path(svg_path_string)
```

SVG M/L/H/V/Q/T/C/S/A/Z commands and relative forms are supported.

### Vector assets

```lua
fontlib.register_vector("my_mod:logo", {
    file = "art/logo.svg",
})

local scene = fontlib.get_vector("my_mod:logo")
```

Low-level source loader:

```lua
fontlib.vector.source.load(path)
```

See [Vector files](#vector-files) for file-format support.

### Output

```lua
local O = fontlib.output

O.to_png(canvas_or_scene[, options])
O.to_texture(canvas_or_scene[, options])
O.publish(canvas_or_scene[, options[, callback]])
O.publish_png(png_bytes[, options[, callback]])
```

`to_texture()` returns a Luanti `[png:]` texture string. `publish()` and `publish_png()` use dynamic media when supported by the engine.

### Low-level font helpers

The same core operations are available under `fontlib.font`:

```lua
fontlib.font.get(ref)
fontlib.font.list()
fontlib.font.is_font(value)
fontlib.font.has_glyph(ref, codepoint)
fontlib.font.get_glyph(ref, codepoint)
fontlib.font.get_palette(ref, index)
fontlib.font.get_vertical_metrics(ref, glyph_id, size)
fontlib.font.measure(text, ref, size, letter_spacing, line_height)
fontlib.font.text_object(text, options)
```

`fontlib.font.register(id, font_table)` is for programmatically-created Font objects. Normal font files should use `fontlib.register_font()`.

### Cache management

```lua
font:clear_cache()
fontlib.clear_cache("my_mod:face")
fontlib.clear_cache()
```

This drops lazy decoded data without unregistering the font.

## License

Fontlib code is licensed under 0BSD. See `LICENSE`.

The generated Unicode property tables in `src/unicode_properties.lua`, `src/unicode_grapheme_properties.lua`, and `src/unicode_linebreak_properties.lua` are derived from Unicode data and are distributed under the Unicode License v3 (`Unicode-3.0`). See `LICENSE-UNICODE`.
