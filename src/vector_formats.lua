-- SPDX-License-Identifier: 0BSD
-- DXF and HP-GL loaders.
local M=fontlib
local V=M.vector
local old_load=assert(V.source.load)
local min,max,abs,cos,sin,pi=math.min,math.max,math.abs,math.cos,math.sin,math.pi

local function read(path)
    local f,e=io.open(path,"rb");if not f then return nil,e end;local d=f:read("*a");f:close();return d
end
local function scene_from_objects(objects,b)
    if not b.minx then b={minx=0,miny=0,maxx=1,maxy=1} end
    local w=max(1,b.maxx-b.minx);local h=max(1,b.maxy-b.miny)
    local s=V.new_scene(w,h,{viewbox={x=b.minx,y=b.miny,width=w,height=h},background="#00000000"});s.objects=objects;return s
end
local function include(b,x,y)
    if not x or not y then return end;b.minx=b.minx and min(b.minx,x) or x;b.maxx=b.maxx and max(b.maxx,x) or x;b.miny=b.miny and min(b.miny,y) or y;b.maxy=b.maxy and max(b.maxy,y) or y
end

function V.source.parse_dxf(data)
    local pairs={};local lines={};for line in (data.."\n"):gmatch("(.-)\r?\n") do lines[#lines+1]=line end
    for i=1,#lines-1,2 do pairs[#pairs+1]={tonumber(lines[i]:match("^%s*(.-)%s*$")),lines[i+1]:match("^%s*(.-)%s*$")} end
    local in_entities=false;local objects={};local b={};local i=1
    local function fields(start)
        local f={};local j=start
        while j<=#pairs and pairs[j][1]~=0 do local code,val=pairs[j][1],pairs[j][2];f[code]=f[code] or {};f[code][#f[code]+1]=val;j=j+1 end
        return f,j
    end
    local function n(f,c,k) return f[c] and tonumber(f[c][k or 1]) end
    local function add(o) objects[#objects+1]=o end
    while i<=#pairs do
        local code,val=pairs[i][1],pairs[i][2]
        if code==0 and val=="SECTION" and pairs[i+1] and pairs[i+1][1]==2 and pairs[i+1][2]=="ENTITIES" then in_entities=true;i=i+2
        elseif code==0 and val=="ENDSEC" and in_entities then break
        elseif in_entities and code==0 then
            local typ=val;local f,nexti=fields(i+1)
            if typ=="LINE" then local x1,y1,x2,y2=n(f,10),n(f,20),n(f,11),n(f,21);if x1 and y1 and x2 and y2 then y1=-y1;y2=-y2;add({type="line",x1=x1,y1=y1,x2=x2,y2=y2,stroke="#FFFFFF",stroke_width=1});include(b,x1,y1);include(b,x2,y2) end
            elseif typ=="CIRCLE" then local x,y,r=n(f,10),n(f,20),n(f,40);if x and y and r then y=-y;add({type="circle",cx=x,cy=y,r=r,fill=nil,stroke="#FFFFFF",stroke_width=1});include(b,x-r,y-r);include(b,x+r,y+r) end
            elseif typ=="ARC" then local x,y,r,a1,a2=n(f,10),n(f,20),n(f,40),n(f,50),n(f,51);if x and y and r and a1 and a2 then
                local pts={};local sweep=(a2-a1)%360;if sweep==0 then sweep=360 end;local steps=max(4,math.ceil(sweep/10));for k=0,steps do local a=(a1+sweep*k/steps)*pi/180;local px=x+cos(a)*r;local py=-(y+sin(a)*r);pts[#pts+1]={px,py};include(b,px,py) end;add({type="polyline",points=pts,stroke="#FFFFFF",stroke_width=1}) end
            elseif typ=="LWPOLYLINE" then local xs=f[10] or {};local ys=f[20] or {};local pts={};for k=1,min(#xs,#ys) do local x,y=tonumber(xs[k]),-tonumber(ys[k]);pts[#pts+1]={x,y};include(b,x,y) end;if #pts>1 then local flags=n(f,70) or 0;add({type=(flags%2==1) and "polygon" or "polyline",points=pts,fill=nil,stroke="#FFFFFF",stroke_width=1}) end
            end
            i=nexti
        else i=i+1 end
    end
    if #objects==0 then return nil,"DXF contains no supported ENTITIES (LINE/CIRCLE/ARC/LWPOLYLINE)" end
    return scene_from_objects(objects,b)
end

function V.source.parse_hpgl(data)
    local objects={};local b={};local x,y=0,0;local absolute=true;local pen=false;local current=nil
    local function point(px,py) include(b,px,-py);return {px,-py} end
    local function flush() if current and #current>1 then objects[#objects+1]={type="polyline",points=current,stroke="#FFFFFF",stroke_width=1} end;current=nil end
    local function coords(arg)
        local n={};for v in arg:gmatch("[-+]?[%d%.]+") do n[#n+1]=tonumber(v) end;return n
    end
    for cmd,arg in data:gmatch("([A-Za-z][A-Za-z])([^;]*);?") do cmd=cmd:upper();local n=coords(arg)
        if cmd=="IN" then flush();x,y=0,0;absolute=true;pen=false
        elseif cmd=="PA" or cmd=="PR" then absolute=(cmd=="PA");if #n>=2 then
            for i=1,#n-1,2 do local nx,ny=n[i],n[i+1];if not absolute then nx,ny=x+nx,y+ny end;if pen then current=current or {point(x,y)};current[#current+1]=point(nx,ny) else flush() end;x,y=nx,ny end end
        elseif cmd=="PU" or cmd=="PD" then local newpen=cmd=="PD";if not newpen then flush() end;pen=newpen;if #n>=2 then
            for i=1,#n-1,2 do local nx,ny=n[i],n[i+1];if not absolute then nx,ny=x+nx,y+ny end;if pen then current=current or {point(x,y)};current[#current+1]=point(nx,ny) end;x,y=nx,ny end end
        elseif cmd=="CI" and n[1] then flush();local r=abs(n[1]);objects[#objects+1]={type="circle",cx=x,cy=-y,r=r,fill=nil,stroke="#FFFFFF",stroke_width=1};include(b,x-r,-y-r);include(b,x+r,-y+r)
        elseif (cmd=="AA" or cmd=="AR") and #n>=3 then flush();local cx,cy=n[1],n[2];if cmd=="AR" then cx,cy=x+cx,y+cy end;local sweep=n[3];local a0=math.atan2(y-cy,x-cx);local r=((x-cx)^2+(y-cy)^2)^0.5;local steps=max(4,math.ceil(abs(sweep)/10));local pts={};for k=0,steps do local a=a0+sweep*pi/180*k/steps;local px,py=cx+cos(a)*r,cy+sin(a)*r;pts[#pts+1]=point(px,py);if k==steps then x,y=px,py end end;objects[#objects+1]={type="polyline",points=pts,stroke="#FFFFFF",stroke_width=1}
        end
    end
    flush();if #objects==0 then return nil,"HP-GL contains no supported drawing commands" end;return scene_from_objects(objects,b)
end

function V.source.load(path)
    local ext=type(path)=="string" and path:lower():match("%.([a-z0-9]+)$")
    if ext=="dxf" or ext=="plt" or ext=="hpgl" or ext=="hpg" then
        local data,e=read(path);if not data then return nil,e end
        if ext=="dxf" then return V.source.parse_dxf(data) end
        return V.source.parse_hpgl(data)
    end
    return old_load(path)
end
return V.source
