-- SPDX-License-Identifier: 0BSD
-- Runtime SVG/SVGZ loading.
local core = assert(rawget(_G, "core") or rawget(_G, "minetest"))
local M = fontlib
local V = M.vector
local sep = rawget(_G, "DIR_DELIM") or "/"

V.registered_assets = V.registered_assets or {}
V.source = V.source or {}

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local d=f:read("*a"); f:close(); return d
end

local function xml_unescape(s)
    return (s or ""):gsub("&#x([%x]+);",function(h)return string.char(tonumber(h,16) or 63)end)
        :gsub("&#(%d+);",function(d)local n=tonumber(d) or 63;return n<256 and string.char(n) or "?" end)
        :gsub("&quot;",'"'):gsub("&apos;","'"):gsub("&lt;","<"):gsub("&gt;",">"):gsub("&amp;","&")
end

local function attrs(text)
    local out={}
    for k,q,v in text:gmatch("([:%w_%-]+)%s*=%s*([\"'])(.-)%2") do out[k]=xml_unescape(v) end
    if out.style then for k,v in out.style:gmatch("([%w%-]+)%s*:%s*([^;]+)") do if out[k]==nil then out[k]=v:match("^%s*(.-)%s*$") end end end
    return out
end

local function points(s)
    local nums={}; for n in (s or ""):gmatch("[-+]?%d*%.?%d+[eE]?[-+]?%d*") do nums[#nums+1]=tonumber(n) end
    local out={}; for i=1,#nums-1,2 do out[#out+1]={nums[i],nums[i+1]} end; return out
end

local function parse_transform(s)
    local m=V.identity()
    for name,args in (s or ""):gmatch("([%a]+)%s*%(([^)]*)%)") do
        local a={}; for n in args:gmatch("[-+]?%d*%.?%d+[eE]?[-+]?%d*") do a[#a+1]=tonumber(n) end
        local t=V.identity()
        if name=="matrix" and #a>=6 then t={a[1],a[2],a[3],a[4],a[5],a[6]}
        elseif name=="translate" then t=V.translate(a[1] or 0,a[2] or 0)
        elseif name=="scale" then t=V.scale(a[1] or 1,a[2] or a[1] or 1)
        elseif name=="rotate" then
            if a[2] and a[3] then t=V.multiply(V.translate(a[2],a[3]),V.multiply(V.rotate(a[1] or 0),V.translate(-a[2],-a[3]))) else t=V.rotate(a[1] or 0) end
        elseif name=="skewX" then t={1,0,math.tan((a[1] or 0)*math.pi/180),1,0,0}
        elseif name=="skewY" then t={1,math.tan((a[1] or 0)*math.pi/180),0,1,0,0} end
        m=V.multiply(m,t)
    end
    return m
end

local function gunzip(data)
    if data:byte(1)~=0x1F or data:byte(2)~=0x8B then return data end
    local flg=data:byte(4) or 0; local p=11
    if math.floor(flg/4)%2==1 then local xlen=(data:byte(p) or 0)+(data:byte(p+1) or 0)*256;p=p+2+xlen end
    if math.floor(flg/8)%2==1 then while p<=#data and data:byte(p)~=0 do p=p+1 end;p=p+1 end
    if math.floor(flg/16)%2==1 then while p<=#data and data:byte(p)~=0 do p=p+1 end;p=p+1 end
    if math.floor(flg/2)%2==1 then p=p+2 end
    if p>#data-8 then return nil,"truncated gzip stream" end
    local compressed=data:sub(p,#data-8)
    local ok,out=pcall(core.decompress,compressed,"raw_deflate")
    if not ok or type(out)~="string" then return nil,"SVGZ needs Luanti raw_deflate support" end
    return out
end

-- OpenType SVG glyph rendering ------------------------------------------------
local function svg_local_name(name)
    name=tostring(name or ""):lower();return name:match("([^:]+)$") or name
end

local function svg_trim(s) return tostring(s or ""):match("^%s*(.-)%s*$") end

local function svg_dom(data)
    data=tostring(data or ""):gsub("<!%-%-.-%-%->","")
    local roots,stack,ids={}, {}, {}
    local pos=1
    while true do
        local a,b,closing,name,body,selfclose=data:find("<(%/?)([%w:_%-]+)(.-)(/?)>",pos)
        if not a then
            if #stack>0 and pos<=#data then stack[#stack].text=(stack[#stack].text or "")..data:sub(pos) end
            break
        end
        if #stack>0 and a>pos then stack[#stack].text=(stack[#stack].text or "")..data:sub(pos,a-1) end
        name=svg_local_name(name)
        if closing=="/" then
            for i=#stack,1,-1 do
                local n=stack[i];table.remove(stack)
                if n.name==name then break end
            end
        else
            local n={name=name,attrs=attrs(body),children={},text=""}
            local parent=stack[#stack]
            if parent then parent.children[#parent.children+1]=n;n.parent=parent else roots[#roots+1]=n end
            if n.attrs.id and n.attrs.id~="" then ids[n.attrs.id]=n end
            if selfclose~="/" then stack[#stack+1]=n end
        end
        pos=b+1
    end
    local root
    for _,n in ipairs(roots) do if n.name=="svg" then root=n;break end end
    return root,ids
end

local function svg_declarations(s)
    local out={}
    for k,v in tostring(s or ""):gmatch("([%w_%-]+)%s*:%s*([^;]+)") do out[k:lower()]=svg_trim(v):gsub("%s*!important%s*$","") end
    return out
end

local function svg_css_rules(data)
    local rules={}
    for css in tostring(data or ""):gmatch("<style[^>]*>(.-)</style%s*>") do
        css=css:gsub("<!%[CDATA%[",""):gsub("%]%]>",""):gsub("/%*.-%*/","")
        for selectors,body in css:gmatch("([^{}]+){([^{}]*)}") do
            local decl=svg_declarations(body)
            for sel in selectors:gmatch("[^,]+") do
                sel=svg_trim(sel)
                if sel~="" then rules[#rules+1]={selector=sel,declarations=decl} end
            end
        end
    end
    return rules
end

local function svg_rule_matches(node,selector)
    -- SVG color fonts in practice overwhelmingly use simple selectors.
    if selector:find("[%s>%+~%[]") then return false end
    local tag=selector:match("^([%w:_%-]+)")
    if tag and svg_local_name(tag)~=node.name then return false end
    local id=selector:match("#([%w:_%-]+)");if id and node.attrs.id~=id then return false end
    local cls=selector:match("%.([%w_%-]+)")
    if cls then
        local found=false;for c in tostring(node.attrs.class or ""):gmatch("[%w_%-]+") do if c==cls then found=true;break end end
        if not found then return false end
    end
    return tag~=nil or id~=nil or cls~=nil
end

local inherited_svg_props={fill=true,stroke=true,["stroke-width"]=true,["stroke-linecap"]=true,["stroke-linejoin"]=true,["stroke-miterlimit"]=true,["stroke-dasharray"]=true,["stroke-dashoffset"]=true,["fill-rule"]=true,["clip-rule"]=true,["fill-opacity"]=true,["stroke-opacity"]=true,color=true,visibility=true}
local svg_presentation_props={"fill","stroke","stroke-width","stroke-linecap","stroke-linejoin","stroke-miterlimit","stroke-dasharray","stroke-dashoffset","fill-rule","fill-opacity","stroke-opacity","opacity","color","display","visibility","stop-color","stop-opacity","clip-path","clip-rule"}

local function svg_style(node,parent,rules)
    local s={}
    for k,v in pairs(parent or {}) do if inherited_svg_props[k] then s[k]=v end end
    for _,r in ipairs(rules or {}) do if svg_rule_matches(node,r.selector) then for k,v in pairs(r.declarations) do s[k]=v end end end
    for _,k in ipairs(svg_presentation_props) do if node.attrs[k]~=nil then s[k]=node.attrs[k] end end
    if node.attrs.style then for k,v in pairs(svg_declarations(node.attrs.style)) do s[k]=v end end
    return s
end

local css_named={
    aliceblue="#F0F8FF",antiquewhite="#FAEBD7",aqua="#00FFFF",aquamarine="#7FFFD4",azure="#F0FFFF",
    beige="#F5F5DC",bisque="#FFE4C4",black="#000000",blanchedalmond="#FFEBCD",blue="#0000FF",
    blueviolet="#8A2BE2",brown="#A52A2A",burlywood="#DEB887",cadetblue="#5F9EA0",chartreuse="#7FFF00",
    chocolate="#D2691E",coral="#FF7F50",cornflowerblue="#6495ED",cornsilk="#FFF8DC",crimson="#DC143C",
    cyan="#00FFFF",darkblue="#00008B",darkcyan="#008B8B",darkgoldenrod="#B8860B",darkgray="#A9A9A9",
    darkgreen="#006400",darkgrey="#A9A9A9",darkkhaki="#BDB76B",darkmagenta="#8B008B",darkolivegreen="#556B2F",
    darkorange="#FF8C00",darkorchid="#9932CC",darkred="#8B0000",darksalmon="#E9967A",darkseagreen="#8FBC8F",
    darkslateblue="#483D8B",darkslategray="#2F4F4F",darkslategrey="#2F4F4F",darkturquoise="#00CED1",darkviolet="#9400D3",
    deeppink="#FF1493",deepskyblue="#00BFFF",dimgray="#696969",dimgrey="#696969",dodgerblue="#1E90FF",
    firebrick="#B22222",floralwhite="#FFFAF0",forestgreen="#228B22",fuchsia="#FF00FF",gainsboro="#DCDCDC",
    ghostwhite="#F8F8FF",gold="#FFD700",goldenrod="#DAA520",gray="#808080",green="#008000",
    greenyellow="#ADFF2F",grey="#808080",honeydew="#F0FFF0",hotpink="#FF69B4",indianred="#CD5C5C",
    indigo="#4B0082",ivory="#FFFFF0",khaki="#F0E68C",lavender="#E6E6FA",lavenderblush="#FFF0F5",
    lawngreen="#7CFC00",lemonchiffon="#FFFACD",lightblue="#ADD8E6",lightcoral="#F08080",lightcyan="#E0FFFF",
    lightgoldenrodyellow="#FAFAD2",lightgray="#D3D3D3",lightgreen="#90EE90",lightgrey="#D3D3D3",lightpink="#FFB6C1",
    lightsalmon="#FFA07A",lightseagreen="#20B2AA",lightskyblue="#87CEFA",lightslategray="#778899",lightslategrey="#778899",
    lightsteelblue="#B0C4DE",lightyellow="#FFFFE0",lime="#00FF00",limegreen="#32CD32",linen="#FAF0E6",
    magenta="#FF00FF",maroon="#800000",mediumaquamarine="#66CDAA",mediumblue="#0000CD",mediumorchid="#BA55D3",
    mediumpurple="#9370DB",mediumseagreen="#3CB371",mediumslateblue="#7B68EE",mediumspringgreen="#00FA9A",mediumturquoise="#48D1CC",
    mediumvioletred="#C71585",midnightblue="#191970",mintcream="#F5FFFA",mistyrose="#FFE4E1",moccasin="#FFE4B5",
    navajowhite="#FFDEAD",navy="#000080",oldlace="#FDF5E6",olive="#808000",olivedrab="#6B8E23",
    orange="#FFA500",orangered="#FF4500",orchid="#DA70D6",palegoldenrod="#EEE8AA",palegreen="#98FB98",
    paleturquoise="#AFEEEE",palevioletred="#DB7093",papayawhip="#FFEFD5",peachpuff="#FFDAB9",peru="#CD853F",
    pink="#FFC0CB",plum="#DDA0DD",powderblue="#B0E0E6",purple="#800080",red="#FF0000",
    rosybrown="#BC8F8F",royalblue="#4169E1",saddlebrown="#8B4513",salmon="#FA8072",sandybrown="#F4A460",
    seagreen="#2E8B57",seashell="#FFF5EE",sienna="#A0522D",silver="#C0C0C0",skyblue="#87CEEB",
    slateblue="#6A5ACD",slategray="#708090",slategrey="#708090",snow="#FFFAFA",springgreen="#00FF7F",
    steelblue="#4682B4",tan="#D2B48C",teal="#008080",thistle="#D8BFD8",tomato="#FF6347",
    turquoise="#40E0D0",violet="#EE82EE",wheat="#F5DEB3",white="#FFFFFF",whitesmoke="#F5F5F5",
    yellow="#FFFF00",yellowgreen="#9ACD32",
    transparent="#00000000"
}

local function svg_color_value(value,ctx,opacity)
    value=svg_trim(value)
    if value=="" or value:lower()=="none" then return nil end
    local lower=value:lower()
    if lower=="currentcolor" or lower=="context-fill" or lower=="context-stroke" then value=ctx.current_color or ctx.foreground or "#000000"
    else
        local idx,fallback=value:match("^var%s*%(%s*%-%-color(%d+)%s*,%s*(.-)%s*%)%s*$")
        if not idx then idx=value:match("^var%s*%(%s*%-%-color(%d+)%s*%)%s*$") end
        if idx then
            local c=ctx.palette and ctx.palette[tonumber(idx)+1]
            if c then value={c[1],c[2],c[3],c[4]} elseif fallback and fallback~="" then return svg_color_value(fallback,ctx,opacity) else return nil end
        else
            local body=lower:match("^rgb%s*%((.-)%)$") or lower:match("^rgba%s*%((.-)%)$")
            if body then
                local vals={};for q in body:gmatch("[^,%s]+") do vals[#vals+1]=q end
                if #vals>=3 then
                    local c={}
                    for i=1,3 do local q=vals[i];local n=tonumber(q:match("[-+]?[%d%.]+")) or 0;c[i]=q:find("%",1,true) and math.max(0,math.min(255,n*2.55)) or math.max(0,math.min(255,n)) end
                    c[4]=255;if #vals>=4 then local a=tonumber(vals[4]) or 1;c[4]=a<=1 and a*255 or a end
                    value=c
                else value="#000000" end
            else value=css_named[lower] or value end
        end
    end
    local c=V.color(value)
    c[4]=math.max(0,math.min(255,(c[4] or 255)*(tonumber(opacity) or 1)))
    return c
end

local function svg_length(v,reference,default,profile)
    if v==nil then return default end
    local s=svg_trim(v);local n=tonumber(s:match("^[-+]?%d*%.?%d+[eE]?[-+]?%d*"));if not n then return default end
    local unit=s:match("[%a%%]+%s*$") or "";unit=unit:lower():gsub("%s","")
    if unit=="%" then return n*(reference or 1)/100 end
    if profile=="opentype" and (unit=="em" or unit=="ex") then return default end
    -- SVG 1.1 absolute CSS units. Unitless and px are user units.
    if unit=="in" then return n*96 elseif unit=="cm" then return n*96/2.54 elseif unit=="mm" then return n*96/25.4
    elseif unit=="pt" then return n*96/72 elseif unit=="pc" then return n*16 end
    return n
end

local function svg_viewbox(node)
    local a=node and node.attrs or {};local raw=a.viewBox or a.viewbox;if not raw then return nil end
    local nums={};for n in tostring(raw):gmatch("[-+]?%d*%.?%d+[eE]?[-+]?%d*") do nums[#nums+1]=tonumber(n) end
    if #nums>=4 and nums[3]>0 and nums[4]>0 then return {nums[1],nums[2],nums[3],nums[4]} end
end
local function svg_fit_viewbox(vb,vw,vh,par)
    if not vb then return V.identity() end
    local sx,sy=vw/vb[3],vh/vb[4];par=svg_trim(par or "xMidYMid meet");local low=par:lower()
    if low:match("^none") then return {sx,0,0,sy,-vb[1]*sx,-vb[2]*sy} end
    local sc=(low:find("slice",1,true) and math.max(sx,sy) or math.min(sx,sy));local rw,rh=vb[3]*sc,vb[4]*sc;local ax,ay=.5,.5
    if low:find("xmin",1,true) then ax=0 elseif low:find("xmax",1,true) then ax=1 end
    if low:find("ymin",1,true) then ay=0 elseif low:find("ymax",1,true) then ay=1 end
    return {sc,0,0,sc,(vw-rw)*ax-vb[1]*sc,(vh-rh)*ay-vb[2]*sc}
end
local function svg_viewbox_matrix(root,viewport_w,viewport_h)
    local vb=svg_viewbox(root)
    if not vb then return V.identity(),viewport_w,viewport_h end
    return svg_fit_viewbox(vb,viewport_w,viewport_h,root.attrs.preserveAspectRatio or root.attrs.preserveaspectratio),vb[3],vb[4]
end

local function svg_shape(node,ctx)
    local a=node.attrs;local name=node.name;local o
    local rw=(ctx and ctx.viewport_w) or 1;local rh=(ctx and ctx.viewport_h) or 1
    local rd=math.sqrt((rw*rw+rh*rh)/2)
    local function lx(v,d)return svg_length(v,rw,d,ctx and ctx.profile)end
    local function ly(v,d)return svg_length(v,rh,d,ctx and ctx.profile)end
    local function lr(v,d)return svg_length(v,rd,d,ctx and ctx.profile)end
    if name=="path" and a.d then o={type="path",d=a.d}
    elseif name=="rect" then
        local rx=a.rx and lx(a.rx,0) or nil;local ry=a.ry and ly(a.ry,0) or nil
        if rx==nil then rx=ry or 0 end;if ry==nil then ry=rx or 0 end
        o={type="rect",x=lx(a.x,0),y=ly(a.y,0),width=lx(a.width,0),height=ly(a.height,0),radius_x=rx,radius_y=ry}
    elseif name=="circle" then o={type="circle",cx=lx(a.cx,0),cy=ly(a.cy,0),r=lr(a.r,0)}
    elseif name=="ellipse" then o={type="ellipse",cx=lx(a.cx,0),cy=ly(a.cy,0),rx=lx(a.rx,0),ry=ly(a.ry,0)}
    elseif name=="line" then o={type="line",x1=lx(a.x1,0),y1=ly(a.y1,0),x2=lx(a.x2,0),y2=ly(a.y2,0)}
    elseif name=="polyline" or name=="polygon" then o={type=name,points=points(a.points)} end
    return o
end

local function svg_bounds(contours)
    local x0,y0,x1,y1
    for _,c in ipairs(contours or {}) do for _,p in ipairs(c) do
        x0=x0 and math.min(x0,p.x) or p.x;y0=y0 and math.min(y0,p.y) or p.y;x1=x1 and math.max(x1,p.x) or p.x;y1=y1 and math.max(y1,p.y) or p.y
    end end
    if not x0 then return nil end;return {x=x0,y=y0,w=math.max(1e-12,x1-x0),h=math.max(1e-12,y1-y0)}
end

local function svg_href(node) return node.attrs.href or node.attrs["xlink:href"] end

local function svg_gradient(id,ids,ctx,depth)
    depth=(depth or 0)+1;if depth>32 then return nil end
    local node=ids[id];if not node or (node.name~="lineargradient" and node.name~="radialgradient") then return nil end
    local base
    local href=svg_href(node);if href and href:sub(1,1)=="#" then base=svg_gradient(href:sub(2),ids,ctx,depth) end
    local g={kind=node.name=="lineargradient" and "linear" or "radial",attrs={},stops={}}
    if base then for k,v in pairs(base.attrs or {}) do g.attrs[k]=v end;for i,v in ipairs(base.stops or {}) do g.stops[i]=v end end
    for k,v in pairs(node.attrs or {}) do g.attrs[k]=v end
    local stops={}
    for _,ch in ipairs(node.children or {}) do if ch.name=="stop" then
        local st=svg_style(ch,{},ctx.css_rules);local off=svg_length(ch.attrs.offset,1,0);off=math.max(0,math.min(1,off))
        local cval=st["stop-color"] or ch.attrs["stop-color"] or "black";local op=tonumber(st["stop-opacity"] or 1) or 1
        stops[#stops+1]={offset=off,color_value=cval,opacity=op}
    end end
    if #stops>0 then g.stops=stops end
    table.sort(g.stops,function(a,b)return a.offset<b.offset end)
    return g
end

local function svg_spread(t,method)
    method=(method or "pad"):lower()
    if method=="repeat" then return t-math.floor(t)
    elseif method=="reflect" then local q=t%2;if q<0 then q=q+2 end;return q<=1 and q or 2-q end
    return math.max(0,math.min(1,t))
end

local function svg_stop_color(g,t,ctx,opacity)
    local stops=g.stops or {};if #stops==0 then return nil end;t=svg_spread(t,g.attrs.spreadMethod or g.attrs.spreadmethod)
    if t<=stops[1].offset then return svg_color_value(stops[1].color_value,ctx,(stops[1].opacity or 1)*opacity) end
    local last=stops[#stops];if t>=last.offset then return svg_color_value(last.color_value,ctx,(last.opacity or 1)*opacity) end
    local a,b=stops[1],last
    for i=1,#stops-1 do if t>=stops[i].offset and t<=stops[i+1].offset then a,b=stops[i],stops[i+1];break end end
    local d=b.offset-a.offset;local q=d==0 and 1 or (t-a.offset)/d
    local ca=svg_color_value(a.color_value,ctx,(a.opacity or 1)*opacity) or {0,0,0,0};local cb=svg_color_value(b.color_value,ctx,(b.opacity or 1)*opacity) or {0,0,0,0}
    local out={};for i=1,4 do out[i]=(ca[i] or 0)+((cb[i] or 0)-(ca[i] or 0))*q end;return out
end

local function svg_gradient_shader(g,local_matrix,bbox,ctx,opacity)
    local ga=g.attrs or {};local units=(ga.gradientUnits or ga.gradientunits or "objectBoundingBox"):lower();local gm=V.identity()
    local function gv(v,axis,default)
        if units=="objectboundingbox" then
            if v==nil then return default end;local s=svg_trim(v);local n=tonumber(s:match("[-+]?%d*%.?%d+[eE]?[-+]?%d*")) or default;return s:find("%",1,true) and n/100 or n
        end
        return svg_length(v,axis=="x" and ctx.viewport_w or ctx.viewport_h,default)
    end
    if units=="objectboundingbox" then gm=V.multiply(V.translate(bbox.x,bbox.y),V.scale(bbox.w,bbox.h)) end
    gm=V.multiply(gm,parse_transform(ga.gradientTransform or ga.gradienttransform))
    local inv_shape=V.inverse(local_matrix);local inv_grad=V.inverse(gm);if not inv_shape or not inv_grad then return function()return nil end end
    local x1,y1,x2,y2,cx,cy,r,fx,fy
    if g.kind=="linear" then x1=gv(ga.x1,"x",0);y1=gv(ga.y1,"y",0);x2=gv(ga.x2,"x",1);y2=gv(ga.y2,"y",0)
    else cx=gv(ga.cx,"x",0.5);cy=gv(ga.cy,"y",0.5);r=gv(ga.r,"x",0.5);fx=gv(ga.fx,"x",cx);fy=gv(ga.fy,"y",cy) end
    return function(px,py)
        local lx,ly=V.transform_point(inv_shape,px,py);local x,y=V.transform_point(inv_grad,lx,ly);local t
        if g.kind=="linear" then local dx,dy=x2-x1,y2-y1;local den=dx*dx+dy*dy;t=den>1e-20 and ((x-x1)*dx+(y-y1)*dy)/den or 0
        else
            local dx,dy=x-fx,y-fy;local ox,oy=fx-cx,fy-cy;local A=dx*dx+dy*dy;local B=2*(ox*dx+oy*dy);local C=ox*ox+oy*oy-r*r
            local disc=B*B-4*A*C;local u
            if A>1e-20 and disc>=0 then local sd=math.sqrt(disc);local u1=(-B+sd)/(2*A);local u2=(-B-sd)/(2*A);if u1>0 and u2>0 then u=math.max(u1,u2) else u=math.max(u1,u2) end end
            t=(u and u>1e-20) and 1/u or (r>0 and math.sqrt((x-cx)^2+(y-cy)^2)/r or 0)
        end
        return svg_stop_color(g,t,ctx,opacity)
    end
end

local b64chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64map={};for i=1,#b64chars do b64map[b64chars:sub(i,i)]=i-1 end
local function svg_base64(s)
    s=tostring(s or ""):gsub("%s","");local out={};local acc,bits=0,0
    for i=1,#s do local ch=s:sub(i,i);if ch=="=" then break end;local v=b64map[ch];if v then
        acc=acc*64+v;bits=bits+6
        if bits>=8 then bits=bits-8;local b=math.floor(acc/(2^bits))%256;out[#out+1]=string.char(b);acc=acc%(2^bits) end
    end end
    return table.concat(out)
end

local function svg_draw_image(canvas,node,matrix,ctx,style)
    local href=svg_href(node);if not href then return false end
    -- External resources and nested SVG images are not fetched.
    local mime,payload=href:match("^data:([^;,]+);base64,(.*)$");if not payload then return false end
    mime=tostring(mime or ""):lower();local raw=svg_base64(payload);local source=fontlib.font.source or {};local dec
    if mime=="image/png" or mime=="image/x-png" then dec=source._decode_png_rgba
    elseif mime=="image/jpeg" or mime=="image/jpg" then dec=source._decode_jpeg_rgba
    else return false end
    local image=dec and dec(raw);if type(image)~="table" then return false end
    local x=svg_length(node.attrs.x,ctx.viewport_w,0,ctx.profile);local y=svg_length(node.attrs.y,ctx.viewport_h,0,ctx.profile)
    local w=svg_length(node.attrs.width,ctx.viewport_w,image.width,ctx.profile);local h=svg_length(node.attrs.height,ctx.viewport_h,image.height,ctx.profile)
    if not w or not h or w<=0 or h<=0 then return false end
    local par=svg_trim(node.attrs.preserveAspectRatio or node.attrs.preserveaspectratio or "xMidYMid meet");local low=par:lower();local im,extra_clip
    if low:match("^none") then im=V.multiply(matrix,V.multiply(V.translate(x,y),V.scale(w/image.width,h/image.height)))
    else
        local slice=low:find("slice",1,true)~=nil;local sc=slice and math.max(w/image.width,h/image.height) or math.min(w/image.width,h/image.height)
        local rw,rh=image.width*sc,image.height*sc;local ax,ay=.5,.5
        if low:find("xmin",1,true) then ax=0 elseif low:find("xmax",1,true) then ax=1 end
        if low:find("ymin",1,true) then ay=0 elseif low:find("ymax",1,true) then ay=1 end
        im=V.multiply(matrix,V.multiply(V.translate(x+(w-rw)*ax,y+(h-rh)*ay),V.scale(sc,sc)))
        if slice then
            local inv=V.inverse(matrix);if inv then extra_clip=function(px,py)local lx,ly=V.transform_point(inv,px,py);return lx>=x and ly>=y and lx<=x+w and ly<=y+h end end
        end
    end
    local clip=ctx.clip_test
    if extra_clip then if clip then local prior=clip;clip=function(px,py)return prior(px,py) and extra_clip(px,py) end else clip=extra_clip end end
    return V._draw_rgba_image(canvas,image,im,ctx.opacity,ctx.bitmap_filter or "bilinear",clip)
end

local function svg_combine_clip(a,b)
    if a and b then return function(x,y)return a(x,y) and b(x,y) end end
    return a or b
end

-- Compile an SVG <clipPath> into a cheap point predicate in canvas space.
local function svg_clip_test(value,ids,matrix,bbox,ctx)
    local id=tostring(value or ""):match("^url%s*%(%s*#([^%)%s]+)%s*%)")
    if not id then return nil end
    local root=ids[id];if not root or root.name~="clippath" then return nil end
    local units=tostring(root.attrs.clipPathUnits or root.attrs.clippathunits or "userSpaceOnUse"):lower()
    local base=matrix
    local clipctx={viewport_w=ctx.viewport_w,viewport_h=ctx.viewport_h,css_rules=ctx.css_rules,ids=ids,active={},profile=ctx.profile}
    if units=="objectboundingbox" then
        if not bbox or not bbox.w or not bbox.h or bbox.w==0 or bbox.h==0 then return nil end
        base=V.multiply(matrix,V.multiply(V.translate(bbox.x,bbox.y),V.scale(bbox.w,bbox.h)))
        clipctx.viewport_w,clipctx.viewport_h=1,1
    end
    base=V.multiply(base,parse_transform(root.attrs.transform))
    local pieces={}
    local function walk(node,m,parent_style,depth)
        depth=(depth or 0)+1;if depth>64 or not node then return end
        local st=svg_style(node,parent_style,clipctx.css_rules)
        if tostring(st.display or ""):lower()=="none" or tostring(st.visibility or ""):lower()=="hidden" then return end
        local nm=V.multiply(m,parse_transform(node.attrs.transform));local name=node.name
        if (clipctx.profile=="opentype" and (name=="a" or name=="text" or name=="foreignobject" or name=="switch" or name=="script" or name=="view")) or name=="animate" or name=="animatetransform" or name=="animatemotion" or name=="animatecolor" or name=="set" then return end
        if name=="use" then
            local href=svg_href(node);local ref=href and href:sub(1,1)=="#" and ids[href:sub(2)] or nil
            if ref and not clipctx.active[ref] then
                clipctx.active[ref]=true
                walk(ref,V.multiply(nm,V.translate(svg_length(node.attrs.x,clipctx.viewport_w,0,clipctx.profile),svg_length(node.attrs.y,clipctx.viewport_h,0,clipctx.profile))),st,depth)
                clipctx.active[ref]=nil
            end
            return
        end
        local sh=svg_shape(node,clipctx)
        if sh then
            local ok,contours=pcall(V._shape_contours,sh)
            if ok and contours then pieces[#pieces+1]={contours=V._transformed(contours,nm),rule=st["clip-rule"] or st["fill-rule"] or "nonzero"} end
            return
        end
        if name=="g" or name=="a" or name=="symbol" or name=="clippath" then
            for _,ch in ipairs(node.children or {}) do walk(ch,nm,st,depth) end
        end
    end
    local rootstyle=svg_style(root,{},clipctx.css_rules)
    for _,ch in ipairs(root.children or {}) do walk(ch,base,rootstyle,0) end
    if #pieces==0 then return function()return false end end
    return function(x,y)
        for _,p in ipairs(pieces) do if V._point_in_contours(p.contours,x,y,p.rule) then return true end end
        return false
    end
end

local svg_static_animation_nodes={animate=true,animatecolor=true,animatemotion=true,animatetransform=true,set=true,mpath=true}
local svg_ot_restricted_nodes={text=true,tspan=true,tref=true,textpath=true,font=true,["font-face"]=true,["font-face-src"]=true,["font-face-uri"]=true,["font-face-format"]=true,["font-face-name"]=true,glyph=true,["missing-glyph"]=true,foreignobject=true,switch=true,script=true,a=true,view=true}
local svg_definition_nodes={defs=true,lineargradient=true,radialgradient=true,stop=true,style=true,metadata=true,title=true,desc=true,clippath=true,filter=true,pattern=true,mask=true,marker=true}

local function svg_compile(data)
    local inflated,err=gunzip(data);if not inflated then return nil,err end
    local root,ids=svg_dom(inflated);if not root then return nil,"not an SVG document" end
    return {data=inflated,root=root,ids=ids,css_rules=svg_css_rules(inflated)}
end
V.source._compile_svg=svg_compile

local function svg_dasharray(value,reference,profile)
    value=svg_trim(value);if value=="" or value:lower()=="none" then return nil end
    local out={};for tok in value:gmatch("[^,%s]+") do
        local v=svg_length(tok,reference,nil,profile);if not v or v<0 then return nil end;out[#out+1]=v
    end
    if #out==0 then return nil end;local sum=0;for _,v in ipairs(out) do sum=sum+v end;if sum<=1e-12 then return nil end
    return out
end

local function svg_paint(value,ids,ctx,matrix,bbox,opacity)
    if value==nil then return nil end
    local url=tostring(value):match("^url%s*%(%s*#([^%)%s]+)%s*%)")
    if url and bbox then
        local g=svg_gradient(url,ids,ctx,0);if g then return svg_gradient_shader(g,matrix,bbox,ctx,opacity) end
        return nil
    end
    return svg_color_value(value,ctx,opacity)
end

local function svg_child_viewport(node,context)
    local x=svg_length(node.attrs.x,context.viewport_w,0,context.profile)
    local y=svg_length(node.attrs.y,context.viewport_h,0,context.profile)
    local w=svg_length(node.attrs.width,context.viewport_w,context.viewport_w,context.profile)
    local h=svg_length(node.attrs.height,context.viewport_h,context.viewport_h,context.profile)
    if not w or not h or w<=0 or h<=0 then return nil end
    local vb=svg_viewbox(node);local fit=svg_fit_viewbox(vb,w,h,node.attrs.preserveAspectRatio or node.attrs.preserveaspectratio)
    return V.multiply(V.translate(x,y),fit),vb and vb[3] or w,vb and vb[4] or h
end

local function svg_symbol_matrix(node,use_node,context)
    local w=svg_length(use_node.attrs.width,context.viewport_w,context.viewport_w,context.profile)
    local h=svg_length(use_node.attrs.height,context.viewport_h,context.viewport_h,context.profile)
    local vb=svg_viewbox(node);if not vb or not w or not h or w<=0 or h<=0 then return V.identity(),context.viewport_w,context.viewport_h end
    return svg_fit_viewbox(vb,w,h,node.attrs.preserveAspectRatio or node.attrs.preserveaspectratio),vb[3],vb[4]
end

local function svg_composite_alpha(dst,src,opacity)
    opacity=math.max(0,math.min(1,tonumber(opacity) or 1))
    for y=0,math.min(dst.height,src.height)-1 do for x=0,math.min(dst.width,src.width)-1 do
        local r,g,b,a=V.pixel(src,x,y);if a>0 then V._blend(dst,x,y,{r,g,b,a*opacity}) end
    end end
end

local function svg_render(canvas,doc,target,base,options)
    options=options or {};local root,ids=doc.root,doc.ids;local profile=options.profile or "general"
    local root_pre_style=svg_style(root,{},doc.css_rules)
    local overall_opacity=math.max(0,math.min(1,(tonumber(options.opacity) or 1)*(tonumber(root_pre_style.opacity) or 1)))
    local render_canvas=canvas;if overall_opacity<1 then render_canvas=V.new_canvas(canvas.width,canvas.height,"#00000000") end
    local ctx={matrix=base or V.identity(),style={},opacity=1,foreground=options.foreground or "#000000",current_color=options.foreground or "#000000",palette=options.palette,ids=ids,css_rules=doc.css_rules,viewport_w=options.viewport_w or 100,viewport_h=options.viewport_h or 100,bitmap_filter=options.bitmap_filter,active={},clip_test=nil,profile=profile}

    local function apply_context(node,context,bbox,extra_matrix,suppress_own_opacity)
        local style=svg_style(node,context.style,context.css_rules)
        if tostring(style.display or ""):lower()=="none" or tostring(style.visibility or ""):lower()=="hidden" then return style,nil,true end
        local opacity=context.opacity*(suppress_own_opacity and 1 or (tonumber(style.opacity) or 1));if opacity<=0 then return style,nil,true end
        local current_color=context.current_color
        if style.color then local cc=svg_color_value(style.color,context,1);if cc then current_color=cc end end
        local matrix=V.multiply(context.matrix,parse_transform(node.attrs.transform))
        if extra_matrix then matrix=V.multiply(matrix,extra_matrix) end
        local child={matrix=matrix,style=style,opacity=opacity,foreground=context.foreground,current_color=current_color,palette=context.palette,ids=context.ids,css_rules=context.css_rules,viewport_w=context.viewport_w,viewport_h=context.viewport_h,bitmap_filter=context.bitmap_filter,active=context.active,clip_test=context.clip_test,profile=context.profile}
        local own=svg_clip_test(style["clip-path"],ids,matrix,bbox,child)
        child.clip_test=svg_combine_clip(context.clip_test,own)
        return style,child,false
    end

    local render_node
    render_node=function(node,context,depth,target_canvas,suppress_own_opacity)
        target_canvas=target_canvas or render_canvas;depth=(depth or 0)+1;if depth>96 or not node then return false end
        local name=node.name
        local pre_style=svg_style(node,context.style,context.css_rules);local own_opacity=tonumber(pre_style.opacity) or 1
        if not suppress_own_opacity and own_opacity<1 and own_opacity>0 then
            local tmp=V.new_canvas(target_canvas.width,target_canvas.height,"#00000000")
            local ok=render_node(node,context,depth-1,tmp,true);svg_composite_alpha(target_canvas,tmp,own_opacity);return ok
        elseif own_opacity<=0 then return true end
        if svg_static_animation_nodes[name] then return true end
        if profile=="opentype" and svg_ot_restricted_nodes[name] then return true end
        if svg_definition_nodes[name] then return true end
        -- Security-sensitive general SVG content is static and sandboxed too.
        if name=="script" or name=="foreignobject" or name=="text" or name=="font" or name=="switch" then return true end

        local shape=svg_shape(node,context);local local_bbox
        if shape then local ok,c=pcall(V._shape_contours,shape);if ok and c then local_bbox=svg_bounds(c) end end
        local image_bbox
        if name=="image" then
            local x=svg_length(node.attrs.x,context.viewport_w,0,profile);local y=svg_length(node.attrs.y,context.viewport_h,0,profile)
            local w=svg_length(node.attrs.width,context.viewport_w,0,profile);local h=svg_length(node.attrs.height,context.viewport_h,0,profile)
            if w and h then image_bbox={x=x,y=y,w=w,h=h} end
        end
        local extra,child_vw,child_vh
        if name=="use" then extra=V.translate(svg_length(node.attrs.x,context.viewport_w,0,profile),svg_length(node.attrs.y,context.viewport_h,0,profile))
        elseif name=="svg" then extra,child_vw,child_vh=svg_child_viewport(node,context);if not extra then return true end end
        local style,childctx,hidden=apply_context(node,context,local_bbox or image_bbox,extra,suppress_own_opacity)
        if hidden then return true end
        if child_vw then childctx.viewport_w,childctx.viewport_h=child_vw,child_vh end
        local matrix=childctx.matrix;local opacity=childctx.opacity

        if name=="use" then
            local href=svg_href(node);if not href or href:sub(1,1)~="#" then return true end
            local ref=context.ids[href:sub(2)];if not ref or context.active[ref] then return true end
            context.active[ref]=true
            if ref.name=="symbol" then
                local sm,svw,svh=svg_symbol_matrix(ref,node,childctx);local sub={};for k,v in pairs(childctx) do sub[k]=v end;sub.matrix=V.multiply(childctx.matrix,sm);sub.viewport_w,sub.viewport_h=svw,svh
                for _,ch in ipairs(ref.children or {}) do render_node(ch,sub,depth,target_canvas,false) end
                context.active[ref]=nil;return true
            end
            local ok=render_node(ref,childctx,depth,target_canvas,false);context.active[ref]=nil;return ok
        elseif name=="image" then return svg_draw_image(target_canvas,node,matrix,childctx,style)
        end

        if shape then
            local ok,contours=pcall(V._shape_contours,shape);if not ok or not contours then return false end
            local transformed=V._transformed(contours,matrix);local clip=childctx.clip_test
            local fill=style.fill;if fill==nil then fill="black" end
            if fill and tostring(fill):lower()~="none" and name~="line" then
                local paint=svg_paint(fill,ids,childctx,matrix,local_bbox,(tonumber(style["fill-opacity"]) or 1)*opacity)
                if type(paint)=="function" then V._fill_contours_shader(target_canvas,transformed,paint,style["fill-rule"] or "nonzero",clip)
                elseif paint then
                    if clip then V._fill_contours_shader(target_canvas,transformed,function()return paint end,style["fill-rule"] or "nonzero",clip)
                    else V._fill_contours(target_canvas,transformed,paint,style["fill-rule"] or "nonzero") end
                end
            end
            local stroke=style.stroke
            if stroke and tostring(stroke):lower()~="none" then
                local rd=math.sqrt((childctx.viewport_w^2+childctx.viewport_h^2)/2)
                local sw=svg_length(style["stroke-width"],rd,1,profile);sw=V._scale_width(matrix,sw or 1)
                local paint=svg_paint(stroke,ids,childctx,matrix,local_bbox,(tonumber(style["stroke-opacity"]) or 1)*opacity)
                if paint and sw>0 then
                    local scale=V._scale_width(matrix,1);local dash=svg_dasharray(style["stroke-dasharray"],rd,profile);if dash then for i=1,#dash do dash[i]=dash[i]*scale end end
                    local doff=svg_length(style["stroke-dashoffset"],rd,0,profile)*scale
                    if V._stroke_contours_style then
                        V._stroke_contours_style(target_canvas,transformed,sw,paint,(name=="polygon" or name=="rect" or name=="circle" or name=="ellipse") and true or (name=="polyline" or name=="line") and false or nil,clip,{linecap=style["stroke-linecap"] or "butt",linejoin=style["stroke-linejoin"] or "miter",miterlimit=tonumber(style["stroke-miterlimit"]) or 4,dasharray=dash,dashoffset=doff})
                    elseif type(paint)~="function" then V._stroke_contours(target_canvas,transformed,sw,paint,name=="polygon" or name=="rect" or name=="circle" or name=="ellipse",clip) end
                end
            end
            return true
        end

        if name=="svg" or name=="g" or (name=="a" and profile~="opentype") then
            local any=false;for _,ch in ipairs(node.children or {}) do if render_node(ch,childctx,depth,target_canvas,false) then any=true end end;return any
        end
        -- Symbols are definitions and render only through <use>.
        return true
    end

    -- Root presentation properties apply to the synthetic <use> used by the OpenType SVG glyph
    -- model, but an element selected by glyph ID does not inherit transforms/styles from its
    local rootstyle,rootctx,hidden=apply_context(root,ctx,nil,nil,true);if hidden or not rootctx then return true end
    rootctx.style=rootstyle
    local result
    if target==root then
        local any=false;for _,ch in ipairs(root.children or {}) do if render_node(ch,rootctx,0,render_canvas,false) then any=true end end;result=any
    else result=render_node(target,rootctx,0,render_canvas,false) end
    if overall_opacity<1 then svg_composite_alpha(canvas,render_canvas,overall_opacity) end
    return result
end

function V._draw_svg_document(canvas,object,parent_matrix)
    local doc=object.document;if not doc and type(object.data)=="string" then doc=svg_compile(object.data);object.document=doc end
    if not doc then return false end
    local vw=tonumber(object.viewport_width) or tonumber(object.width) or 300;local vh=tonumber(object.viewport_height) or tonumber(object.height) or 150
    local vm,user_w,user_h=svg_viewbox_matrix(doc.root,vw,vh)
    local base=V.multiply(parent_matrix or V.identity(),vm)
    return svg_render(canvas,doc,doc.root,base,{profile="general",viewport_w=user_w,viewport_h=user_h,foreground=object.foreground or object.color or "#000000",opacity=object.opacity or 1,palette=object.palette,bitmap_filter=object.bitmap_filter})
end

function V._draw_svg_glyph(canvas,entry,gid,glyph_matrix,options)
    if type(entry)~="table" or type(entry.data)~="string" then return false end
    options=options or {};local doc=entry._svg_document
    if not doc then local compiled=svg_compile(entry.data);if not compiled then return false end;entry._svg_document=compiled;doc=compiled end
    local target=doc.ids["glyph"..tostring(gid)];if not target then return false end
    local upem=tonumber(options.units_per_em) or 1000;local ascent=tonumber(options.ascent) or upem
    local root=doc.root;local vb=svg_viewbox(root)
    if not vb then
        local rw=svg_length(root.attrs.width,upem,upem,"opentype");local rh=svg_length(root.attrs.height,upem,upem,"opentype")
        if not rw or rw<=0 then rw=upem end;if not rh or rh<=0 then rh=upem end;vb={0,0,rw,rh}
    end
    local vm=svg_fit_viewbox(vb,upem,upem,root.attrs.preserveAspectRatio or root.attrs.preserveaspectratio)
    local base=V.multiply(glyph_matrix,V.multiply(V.translate(0,ascent),vm))
    return svg_render(canvas,doc,target,base,{profile="opentype",viewport_w=vb[3],viewport_h=vb[4],palette=options.palette,foreground=options.foreground or "#000000",opacity=options.opacity or 1,bitmap_filter=options.bitmap_filter})
end

function V.source.parse_svg(data)
    local doc,err=svg_compile(data);if not doc then return nil,err end
    local root=doc.root;local vb=svg_viewbox(root)
    local w=svg_length(root.attrs.width,vb and vb[3] or 300,vb and vb[3] or 300,"general")
    local h=svg_length(root.attrs.height,vb and vb[4] or 150,vb and vb[4] or 150,"general")
    if not w or w<=0 then w=vb and vb[3] or 300 end;if not h or h<=0 then h=vb and vb[4] or 150 end
    local scene=V.new_scene(w,h,{viewbox={x=0,y=0,width=w,height=h},background="#00000000"})
    scene.objects[1]={type="svg_document",document=doc,viewport_width=w,viewport_height=h}
    scene.svg_document=doc
    return scene
end

function V.source.load(path)
    local data,err=read_file(path);if not data then return nil,err end
    if data:find("<svg",1,true) or (data:byte(1)==0x1F and data:byte(2)==0x8B) then return V.source.parse_svg(data) end
    return nil,"unsupported runtime vector format (currently SVG/SVGZ)"
end

local function safe_relative(path)
    if type(path)~="string" or path=="" or path:sub(1,1)=="/" or path:sub(1,1)=="\\" or path:match("^%a:[/\\]") then return false end
    for part in path:gmatch("[^/\\]+") do if part==".." then return false end end
    return true
end
local function join(base,rel) rel=rel:gsub("[/\\]",sep);if base:sub(-1)=="/" or base:sub(-1)=="\\" then return base..rel end;return base..sep..rel end

function M.register_vector(id,def)
    local owner=type(id)=="string" and id:match("^([a-z0-9_]+):[a-z0-9_]+$");assert(owner,"vector id must be namespaced like 'modname:asset_name'")
    assert(type(def)=="table","vector definition must be a table");local filename=def.filename or def.file or def.path;assert(safe_relative(filename),"vector filename must be relative to the registering mod")
    -- Nested library calls cannot securely discover the calling mod. The namespace owns the source.
    local base=core.get_modpath(owner);assert(base,"unknown source mod: "..owner)
    local scene,err=V.source.load(join(base,filename));if not scene then return nil,err end
    V.registered_assets[id]=scene;return scene
end

function M.get_vector(id) return V.registered_assets[id] end
