-- SPDX-License-Identifier: 0BSD
-- Async rendering bridge.
local core = assert(rawget(_G, "core") or rawget(_G, "minetest"))
local M = fontlib
local F = M.font
local O = M.output

M.async = M.async or {}
local A = M.async
A.available = false
A.reason = nil
A._cache_generation = A._cache_generation or {}
A._lanes = A._lanes or {}

local sep = rawget(_G, "DIR_DELIM") or "/"
local MAX_STALE_RETRIES = 3

local function join(base, rel)
    rel = tostring(rel):gsub("[/\\]", sep)
    if base:sub(-1) == "/" or base:sub(-1) == "\\" then return base .. rel end
    return base .. sep .. rel
end

local function copy_serializable(value, seen, depth)
    local t = type(value)
    if t == "nil" or t == "boolean" or t == "number" or t == "string" then return value end
    if t ~= "table" then return nil, "async render options must contain only serializable Lua values (got " .. t .. ")" end
    depth = (depth or 0) + 1
    if depth > 32 then return nil, "async render option nesting is too deep" end
    seen = seen or {}
    if seen[value] then return nil, "async render options may not contain cycles" end
    seen[value] = true
    local out = {}
    for k, v in pairs(value) do
        local kt = type(k)
        if kt ~= "string" and kt ~= "number" and kt ~= "boolean" then
            seen[value] = nil
            return nil, "async render option keys must be strings, numbers, or booleans"
        end
        local cv, err = copy_serializable(v, seen, depth)
        if err then seen[value] = nil; return nil, err end
        out[k] = cv
    end
    seen[value] = nil
    return out
end

local function font_id(ref)
    if ref == nil then return M.DEFAULT_FONT end
    if type(ref) == "string" then return ref end
    if F.is_font(ref) and type(ref.id) == "string" then return ref.id end
    return nil
end

local function cache_generation(id)
    return tonumber(A._cache_generation[id]) or 0
end

local function fallback_ids(spec, collect)
    if spec == nil then return nil end
    if spec == false then return false end
    if type(spec) == "table" and not F.is_font(spec) then
        local out = {}
        for i, ref in ipairs(spec) do
            local id = font_id(ref)
            if not id then return nil, "async fallback fonts must be registered Fontlib fonts" end
            out[i] = id
            local ok, err = collect(id)
            if not ok then return nil, err end
        end
        return out
    end
    local id = font_id(spec)
    if not id then return nil, "async fallback fonts must be registered Fontlib fonts" end
    local ok, err = collect(id)
    if not ok then return nil, err end
    return id
end

local function source_options(source)
    local out = {}
    for k, v in pairs(source) do
        if k ~= "file" and k ~= "filename" and k ~= "path" and
           k ~= "modname" and k ~= "loaded" and k ~= "error" and
           k ~= "fallback" and k ~= "_revision" and k ~= "_source_epoch" and k ~= "_data" and
           k ~= "ipc_key" and k ~= "source_kind" then
            local cv, err = copy_serializable(v)
            if err then return nil, "font source option " .. tostring(k) .. ": " .. err end
            out[k] = cv
        end
    end
    return out
end

local function build_request(text, options, output)
    options = options or {}
    if type(options) ~= "table" then return nil, "options must be a table" end
    local primary = font_id(options.font)
    if not primary then return nil, "async rendering requires a registered Fontlib font ID/object" end
    if not F.get(primary) then return nil, "unknown Fontlib font " .. tostring(primary) end

    local fonts, added, visiting = {}, {}, {}
    local collect
    collect = function(id)
        if added[id] then return true end
        if visiting[id] then return true end
        visiting[id] = true
        local font = F.get(id)
        if not font then visiting[id] = nil; return nil, "unknown fallback font " .. tostring(id) end

        if id == M.DEFAULT_FONT then
            local entry = {id=id,builtin=true,revision=1,cache_generation=cache_generation(id)}
            fonts[#fonts + 1] = entry
            added[id] = entry
            visiting[id] = nil
            return true
        end

        local source = M.registered_font_sources and M.registered_font_sources[id]
        if not source then
            visiting[id] = nil
            return nil, "font " .. tostring(id) .. " is programmatic/unregistered and cannot be reconstructed in an async worker"
        end
        local opts, err = source_options(source)
        if not opts then visiting[id] = nil; return nil, err end

        local source_kind=source.source_kind or "file"
        local entry = {
            id=id,modname=source.modname,filename=source.filename,source_kind=source_kind,
            revision=tonumber(source._revision) or 1,source_epoch=tonumber(source._source_epoch) or 0,
            cache_generation=cache_generation(id),options=opts,
        }
        if source_kind=="data" then
            if type(source._data)~="string" then visiting[id]=nil;return nil,"registered in-memory font has no data: "..tostring(id) end
            entry.ipc_key=source.ipc_key or ("fontlib:fontdata:"..id)
            -- IPC is shared with persistent async workers.
            if type(core.ipc_set)=="function" then core.ipc_set(entry.ipc_key,source._data) end
        else
            local base = core.get_modpath and core.get_modpath(source.modname)
            if not base then visiting[id] = nil; return nil, "source mod is not installed: " .. tostring(source.modname) end
            if not source.filename then visiting[id]=nil;return nil,"registered file font has no filename: "..tostring(id) end
            entry.path=join(base,source.filename)
        end
        fonts[#fonts + 1] = entry
        added[id] = entry

        local fb, ferr = fallback_ids(font.fallback, collect)
        if ferr then visiting[id] = nil; return nil, ferr end
        entry.fallback = fb
        visiting[id] = nil
        return true
    end

    local ok, err = collect(primary)
    if not ok then return nil, err end

    local render_options = {}
    for k, v in pairs(options) do
        -- Publication controls/callbacks are main-environment concerns.
        if k ~= "font" and k ~= "fallback" and k ~= "to_player" and
           k ~= "prefix" and k ~= "ephemeral" and k ~= "client_cache" and
           k ~= "on_delivered" and k ~= "async_key" then
            local cv, cerr = copy_serializable(v)
            if cerr then return nil, "render option " .. tostring(k) .. ": " .. cerr end
            render_options[k] = cv
        end
    end
    render_options.font = primary

    if options.fallback ~= nil then
        local fb, ferr = fallback_ids(options.fallback, collect)
        if ferr then return nil, ferr end
        render_options.fallback = fb
    end

    return {
        kind="text",text=tostring(text or ""),output=output or "texture",
        font_id=primary,fonts=fonts,options=render_options,
    }
end


local function rich_font_ids(content,options)
    local spans,base=M.richtext.normalize(content,options or {})
    local ids,seen={},{ }
    local function add(ref)
        if ref==nil or ref==false then return true end
        if type(ref)=="table" and not F.is_font(ref) then
            for _,r in ipairs(ref) do local ok,err=add(r);if not ok then return nil,err end end
            return true
        end
        local id=font_id(ref)
        if not id then return nil,"async rich text requires registered Fontlib font IDs/objects" end
        if not seen[id] then seen[id]=true;ids[#ids+1]=id end
        return true
    end
    local primary=font_id((options or {}).font or ((options or {}).default_style or {}).font or base.font)
    if not primary then return nil,"async rich text requires a registered default font" end
    local ok,err=add(primary);if not ok then return nil,err end
    for _,span in ipairs(spans) do
        ok,err=add(span.style.font);if not ok then return nil,err end
        ok,err=add(span.style.fallback);if not ok then return nil,err end
        local rb=span.meta and span.meta.ruby
        if type(rb)=="table" then local rs=rb.style or rb;ok,err=add(rs.font);if not ok then return nil,err end;ok,err=add(rs.fallback);if not ok then return nil,err end end
    end
    return ids,primary,spans
end

local function serial_font_ref(value,label)
    if value==false then return false end
    if value==nil then return nil end
    if type(value)=="table" and not F.is_font(value) then
        local out={}
        for _,r in ipairs(value) do
            local id=font_id(r);if not id then return nil,(label or "font").." must be registered for async rendering" end
            out[#out+1]=id
        end
        return out
    end
    local id=font_id(value);if not id then return nil,(label or "font").." must be registered for async rendering" end
    return id
end

local function serial_style(style,label)
    local out={};label=label or "rich-text style"
    for k,v in pairs(style or {}) do
        if k=="font" then
            local id,err=serial_font_ref(v,label.." font");if err then return nil,err end;out.font=id
        elseif k=="fallback" then
            local ids,err=serial_font_ref(v,label.." fallback");if err then return nil,err end;out.fallback=ids
        else
            local cv,err=copy_serializable(v);if err then return nil,label.." "..tostring(k)..": "..err end;out[k]=cv
        end
    end
    return out
end

local function serial_ruby(raw)
    if type(raw)~="table" then return copy_serializable(raw) end
    local out={}
    -- Ruby accepts either {text=..., style={...}} or a flat table whose extra keys are
    -- themselves the annotation style.
    local flat_style=raw.style==nil
    for k,v in pairs(raw) do
        if k~="style" and not (flat_style and (k=="font" or k=="fallback")) then
            local cv,err=copy_serializable(v);if err then return nil,"rich-text ruby metadata "..tostring(k)..": "..err end;out[k]=cv
        end
    end
    local style_src=raw.style or raw
    local st,err=serial_style(style_src,"ruby style");if not st then return nil,err end
    if raw.style~=nil then out.style=st
    else
        for k,v in pairs(st) do
            if k~="text" and k~=1 then out[k]=v end
        end
    end
    return out
end

local function serial_rich_content(spans)
    local out={}
    for _,span in ipairs(spans or {}) do
        local st,serr=serial_style(span.style,"rich-text style");if not st then return nil,serr end
        local node={text=span.text,style=st}
        for _,k in ipairs({"id","link","data","role","ruby"}) do
            local v=span.meta and span.meta[k]
            if v~=nil then
                local cv,err
                if k=="ruby" then cv,err=serial_ruby(v) else cv,err=copy_serializable(v) end
                if err then return nil,err end;node[k]=cv
            end
        end
        out[#out+1]=node
    end
    return out
end

local function rich_render_options(options,primary)
    local out={}
    for k,v in pairs(options or {}) do
        if k~="font" and k~="fallback" and k~="default_style" and k~="to_player" and k~="prefix" and k~="ephemeral" and
           k~="client_cache" and k~="on_delivered" and k~="async_key" then
            local cv,err=copy_serializable(v);if err then return nil,"rich render option "..tostring(k)..": "..err end;out[k]=cv
        end
    end
    out.font=primary
    return out
end

local function build_rich_request(content,options,output)
    options=options or {};if type(options)~="table" then return nil,"options must be a table" end
    local ids,primary,spans=rich_font_ids(content,options);if not ids then return nil,primary end
    -- Reuse the existing plain request builder as the font-source collector.
    local collector={font=primary,fallback={}}
    for _,id in ipairs(ids) do if id~=primary then collector.fallback[#collector.fallback+1]=id end end
    local base,err=build_request("",collector,output);if not base then return nil,err end
    local serial,serr=serial_rich_content(spans);if not serial then return nil,serr end
    local ropts,oerr=rich_render_options(options,primary);if not ropts then return nil,oerr end
    base.kind="rich_text";base.text=nil;base.content=serial;base.options=ropts;base.font_id=primary;base.output=output or "texture"
    if M.typography and M.typography.export_language_data then
        local langs={};for _,sp in ipairs(spans or {}) do local l=sp.style and sp.style.language;if l then langs[tostring(l)]=true end end
        base.typography_data=M.typography.export_language_data(langs)
    end
    return base
end

local function request_fonts_current(request)
    for _, spec in ipairs(request.fonts or {}) do
        if not spec.builtin and spec.id ~= M.DEFAULT_FONT then
            local source = M.registered_font_sources and M.registered_font_sources[spec.id]
            if not source then return false, "async font was unregistered while rendering: " .. tostring(spec.id) end
            if (tonumber(source._revision) or 1) ~= (tonumber(spec.revision) or 1) or
               source.modname ~= spec.modname or source.filename ~= spec.filename or
               (source.source_kind or "file") ~= (spec.source_kind or "file") or
               (tonumber(source._source_epoch) or 0) ~= (tonumber(spec.source_epoch) or 0) then
                return false, "stale async font revision: " .. tostring(spec.id)
            end
        end
    end
    return true
end

local function cancel_native(job)
    if not job then return false end
    local ok, cancelled = pcall(function() return job:cancel() end)
    return ok and cancelled == true
end

local function stale_error(err)
    return type(err)=="string" and err:find("stale async font revision",1,true) ~= nil
end

-- Must have no upvalues: Luanti serializes this tiny function into the worker.
local function worker_entry(req)
    return fontlib_async_render_job(req)
end

local function lane_for(font_id)
    local lane=A._lanes[font_id]
    if not lane then
        lane={submitted=0,next_delivery=1,pending={}}
        A._lanes[font_id]=lane
    end
    return lane
end

-- Worker jobs are free to finish out of order, but high-level callbacks for the same primary
-- face are delivered in submission order.
local function flush_lane(lane)
    while true do
        local item=lane.pending[lane.next_delivery]
        if not item then return end
        lane.pending[lane.next_delivery]=nil
        lane.next_delivery=lane.next_delivery+1
        if not item.skip and not item.state.cancelled then
            local ok,cb_err=pcall(item.callback,item.result,item.err)
            if not ok and core.log then core.log("error","[fontlib] async render callback failed: " .. tostring(cb_err)) end
        end
    end
end

local function complete(state,callback,result,err,skip)
    if state.done then return end
    state.done=true
    state.lane.pending[state.sequence]={state=state,callback=callback,result=result,err=err,skip=skip==true}
    flush_lane(state.lane)
end

local dispatch
local function retry_or_finish(request, callback, state, attempt, err)
    if state.cancelled or state.done then return end
    if attempt < MAX_STALE_RETRIES and stale_error(err) then
        local fresh, rebuild_err
        if request.kind=="rich_text" then fresh,rebuild_err=build_rich_request(request.content,request.options,request.output)
        else fresh,rebuild_err=build_request(request.text, request.options, request.output) end
        if fresh then
            local ok, dispatch_err = dispatch(fresh, callback, state, attempt + 1)
            if ok then return end
            err = dispatch_err
        else
            err = rebuild_err
        end
    end
    complete(state,callback,nil,err,false)
end

dispatch = function(request, callback, state, attempt)
    local function finished(result)
        if state.cancelled or state.done then return end
        local current, stale_err = request_fonts_current(request)
        if not current then
            retry_or_finish(request, callback, state, attempt, stale_err)
            return
        end
        if type(result) ~= "table" or result.ok ~= true then
            local err=(type(result)=="table" and result.error) or "fontlib async worker returned an invalid result"
            retry_or_finish(request, callback, state, attempt, err)
            return
        end
        complete(state,callback,result,nil,false)
    end
    local ok, job_or_err = pcall(core.handle_async, worker_entry, finished, request)
    if not ok then return nil, tostring(job_or_err) end
    state.job = job_or_err
    return true
end

local function submit(request, callback)
    if not A.available then return nil, A.reason or "Luanti async rendering is unavailable" end
    if type(callback) ~= "function" then return nil, "async render callback must be a function" end
    local lane=lane_for(request.font_id)
    lane.submitted=lane.submitted+1
    local state={cancelled=false,done=false,job=nil,lane=lane,sequence=lane.submitted}
    local handle={}
    function handle:cancel()
        if state.cancelled or state.done then return false end
        state.cancelled=true
        local native=cancel_native(state.job)
        complete(state,callback,nil,nil,true)
        return native
    end
    local ok, err=dispatch(request,callback,state,0)
    if not ok then
        complete(state,callback,nil,nil,true)
        return nil,err
    end
    return handle
end

function M.render_async(spec, callback)
    if type(spec) ~= "table" then return nil, "render spec must be a table" end
    local kind = spec.kind or spec.type or "text"
    if kind ~= "text" and kind ~= "rich_text" then return nil, "unsupported Fontlib async render kind: "..tostring(kind) end
    local output = spec.output or "texture"
    if kind=="rich_text" then
        if output~="texture" and output~="png" and output~="layout" then return nil,"async rich-text output must be 'texture', 'png', or 'layout'" end
    elseif output ~= "texture" and output ~= "png" then return nil, "async text output must be 'texture' or 'png'" end
    local request, err
    if kind=="rich_text" then request,err=build_rich_request(spec.content or spec.text,spec.options or {},output)
    else request,err=build_request(spec.text,spec.options or {},output) end
    if not request then return nil, err end
    return submit(request, callback)
end

local function split_options_callback(options, callback)
    if type(options)=="function" and callback==nil then return {},options end
    return options or {},callback
end

function M.text_texture_async(text, options, callback)
    options,callback=split_options_callback(options,callback)
    if type(callback) ~= "function" then return nil, "async texture callback must be a function" end
    return M.render_async({kind="text",text=text,options=options,output="texture"}, function(result, err)
        if not result then callback(nil,err,nil);return end
        callback(result.texture,nil,{width=result.width,height=result.height,metrics=result.metrics})
    end)
end

function M.text_png_async(text, options, callback)
    options,callback=split_options_callback(options,callback)
    if type(callback) ~= "function" then return nil, "async PNG callback must be a function" end
    return M.render_async({kind="text",text=text,options=options,output="png"}, function(result, err)
        if not result then callback(nil,err,nil);return end
        callback(result.png,nil,{width=result.width,height=result.height,metrics=result.metrics})
    end)
end


function M.layout_rich_text_async(content,options,callback)
    options,callback=split_options_callback(options,callback)
    if type(callback)~="function" then return nil,"async rich-text layout callback must be a function" end
    return M.render_async({kind="rich_text",content=content,options=options,output="layout"},function(result,err)
        if not result then callback(nil,err);return end
        callback(result.layout,nil)
    end)
end
M.richtext.layout_async=M.layout_rich_text_async

function M.rich_texture_async(content,options,callback)
    options,callback=split_options_callback(options,callback)
    if type(callback)~="function" then return nil,"async rich-text texture callback must be a function" end
    return M.render_async({kind="rich_text",content=content,options=options,output="texture"},function(result,err)
        if not result then callback(nil,err,nil);return end
        callback(result.texture,nil,{width=result.width,height=result.height,layout=result.layout})
    end)
end
function M.rich_png_async(content,options,callback)
    options,callback=split_options_callback(options,callback)
    if type(callback)~="function" then return nil,"async rich-text PNG callback must be a function" end
    return M.render_async({kind="rich_text",content=content,options=options,output="png"},function(result,err)
        if not result then callback(nil,err,nil);return end
        callback(result.png,nil,{width=result.width,height=result.height,layout=result.layout})
    end)
end
M.richtext.texture_async=M.rich_texture_async
M.richtext.png_async=M.rich_png_async
function M.fit_texture_async(content,options,callback)
    options,callback=split_options_callback(options,callback);local o={};for k,v in pairs(options or {}) do o[k]=v end;o.fit=true
    return M.rich_texture_async(content,o,callback)
end
function M.fit_layout_async(content,options,callback)
    options,callback=split_options_callback(options,callback);local o={};for k,v in pairs(options or {}) do o[k]=v end;o.fit=true
    return M.layout_rich_text_async(content,o,callback)
end
function F._methods:layout_rich_text_async(content,options,callback)
    if type(options)=="function" and callback==nil then callback=options;options={} end
    local o={};for k,v in pairs(options or {}) do o[k]=v end;o.font=self
    return M.layout_rich_text_async(content,o,callback)
end

function F._methods:rich_texture_async(content,options,callback)
    if type(options)=="function" and callback==nil then callback=options;options={} end
    local o={};for k,v in pairs(options or {}) do o[k]=v end;o.font=self
    return M.rich_texture_async(content,o,callback)
end
function F._methods:rich_png_async(content,options,callback)
    if type(options)=="function" and callback==nil then callback=options;options={} end
    local o={};for k,v in pairs(options or {}) do o[k]=v end;o.font=self
    return M.rich_png_async(content,o,callback)
end
F._methods.paragraph_async=F._methods.rich_texture_async
function F._methods:fit_async(content,options,callback)
    if type(options)=="function" and callback==nil then callback=options;options={} end
    local o={};for k,v in pairs(options or {}) do o[k]=v end;o.font=self;o.fit=true
    return M.rich_texture_async(content,o,callback)
end
function F._methods:fit_layout_async(content,options,callback)
    if type(options)=="function" and callback==nil then callback=options;options={} end
    local o={};for k,v in pairs(options or {}) do o[k]=v end;o.font=self;o.fit=true
    return M.layout_rich_text_async(content,o,callback)
end

function M.publish_text_async(text, options, callback)
    options,callback=split_options_callback(options,callback)
    if type(callback) ~= "function" then return nil, "async publish callback must be a function" end
    local delivery_callback = options.on_delivered
    if delivery_callback ~= nil and type(delivery_callback) ~= "function" then return nil, "options.on_delivered must be a function" end
    return M.text_png_async(text, options, function(png, err, info)
        if not png then callback(nil,err,nil);return end
        local filename, perr = O.publish_png(png, options, delivery_callback)
        if not filename then callback(nil,perr,nil);return end
        callback(filename,nil,info)
    end)
end

-- Worker-local decoded-cache invalidation.
function A.clear_cache(ref)
    if ref ~= nil then
        local id = font_id(ref)
        if id then A._cache_generation[id] = cache_generation(id) + 1 end
        return 0
    end
    for _, id in ipairs(F.list()) do A._cache_generation[id] = cache_generation(id) + 1 end
    return 0
end

function M.async_available()
    return A.available, A.reason
end

-- Font methods.
function F._methods:text_texture_async(text, options, callback)
    if type(options)=="function" and callback==nil then callback=options;options={} end
    local copy={};for k,v in pairs(options or {}) do copy[k]=v end;copy.font=self
    return M.text_texture_async(text,copy,callback)
end
function F._methods:text_png_async(text, options, callback)
    if type(options)=="function" and callback==nil then callback=options;options={} end
    local copy={};for k,v in pairs(options or {}) do copy[k]=v end;copy.font=self
    return M.text_png_async(text,copy,callback)
end
function F._methods:publish_text_async(text, options, callback)
    if type(options)=="function" and callback==nil then callback=options;options={} end
    local copy={};for k,v in pairs(options or {}) do copy[k]=v end;copy.font=self
    return M.publish_text_async(text,copy,callback)
end

F._methods.texture_async = F._methods.text_texture_async
F._methods.png_async = F._methods.text_png_async
F._methods.publish_async = F._methods.publish_text_async

if type(core.handle_async) ~= "function" or type(core.register_async_dofile) ~= "function" then
    A.reason = "this Luanti build does not expose the server async environment"
elseif type(core.ipc_set) ~= "function" then
    A.reason = "this Luanti build does not expose async IPC"
else
    local ok, err = pcall(function()
        core.ipc_set("fontlib:async_modpath", M.modpath)
        core.register_async_dofile(M.modpath .. "/src/async_worker.lua")
    end)
    if ok then A.available=true
    else
        A.reason="unable to initialize Fontlib async workers: " .. tostring(err)
        if core.log then core.log("warning", "[fontlib] " .. A.reason) end
    end
end
