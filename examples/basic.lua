-- Add `depends = fontlib` to mod.conf.

local font = assert(fontlib.register_font("my_signs:label", {
    file = "fonts/MyFont.ttf",
}))

local width, height = font:measure("OPEN", 64)
core.log("action", ("OPEN measures %.1f x %.1f"):format(width, height))

local texture = assert(font:texture("OPEN", {
    size = 64,
    color = "#FFFFFF",
    background = "#A11D1D",
    padding = 12,
    outline = 2,
    shadow = true,
}))

-- `texture` is now an ordinary Luanti texture string, e.g.

-- Use async rendering for changing text.
font:texture_async("Players: 12", {
    size = 32,
    outline = {width=1, color="#000000"},
    shadow = {x=2, y=2, blur=2, color="#00000080"},
}, function(runtime_texture, err)
    if not runtime_texture then
        core.log("error", "font render failed: " .. tostring(err))
        return
    end
    -- apply runtime_texture here
end)
