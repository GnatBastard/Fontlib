-- SPDX-License-Identifier: 0BSD
-- Software vector renderer.
local G=fontlib.vector
local floor,ceil,min,max,abs,sqrt,cos,sin,pi=math.floor,math.ceil,math.min,math.max,math.abs,math.sqrt,math.cos,math.sin,math.pi

local named={
    transparent='#00000000',black='#000000',white='#FFFFFF',red='#FF0000',green='#00FF00',blue='#0000FF',
    yellow='#FFFF00',cyan='#00FFFF',magenta='#FF00FF',gray='#808080',grey='#808080',
    darkblue='#00008B',purple='#800080',orchid='#DA70D6',orange='#FFA500',navy='#000080',
    lime='#00FF00',silver='#C0C0C0',maroon='#800000',olive='#808000',teal='#008080',aqua='#00FFFF',fuchsia='#FF00FF'
}
local function clamp8(v) return max(0,min(255,floor((tonumber(v) or 0)+.5))) end
function G.color(v,opacity)
    if type(v)=='table' then
        local r=v.r or v[1] or 0;local g=v.g or v[2] or 0;local b=v.b or v[3] or 0;local a=v.a or v[4] or 255
        if opacity then a=a*opacity end
        return {clamp8(r),clamp8(g),clamp8(b),clamp8(a)}
    end
    v=tostring(v or '#000000');v=named[v:lower()] or v
    local hex=v:match('^#([%x]+)$')
    if not hex then return {0,0,0,255} end
    local r,g,b,a
    if #hex==3 or #hex==4 then
        r=tonumber(hex:sub(1,1):rep(2),16);g=tonumber(hex:sub(2,2):rep(2),16);b=tonumber(hex:sub(3,3):rep(2),16)
        a=#hex==4 and tonumber(hex:sub(4,4):rep(2),16) or 255
    elseif #hex==6 or #hex==8 then
        r=tonumber(hex:sub(1,2),16);g=tonumber(hex:sub(3,4),16);b=tonumber(hex:sub(5,6),16)
        a=#hex==8 and tonumber(hex:sub(7,8),16) or 255
    else return {0,0,0,255} end
    if opacity then a=a*opacity end
    return {r,g,b,clamp8(a)}
end

local function pack(r,g,b,a) r,g,b,a=clamp8(r),clamp8(g),clamp8(b),clamp8(a);return r*16777216+g*65536+b*256+a end
local function unpack_rgba(v)
    local r=floor(v/16777216)%256;local g=floor(v/65536)%256;local b=floor(v/256)%256;local a=v%256
    return r,g,b,a
end
function G.new_canvas(width,height,background)
    width=floor(tonumber(width) or 0);height=floor(tonumber(height) or 0)
    assert(width>0 and height>0,'fontlib vector canvas dimensions must be positive')
    local c=G.color(background or '#00000000');local p=pack(c[1],c[2],c[3],c[4]);local pixels={}
    for i=1,width*height do pixels[i]=p end
    return {width=width,height=height,pixels=pixels}
end
function G.clear(canvas,background)
    assert(type(canvas)=='table' and canvas.width and canvas.height and canvas.pixels,'canvas required')
    local c=G.color(background or '#00000000');local p=pack(c[1],c[2],c[3],c[4])
    for i=1,canvas.width*canvas.height do canvas.pixels[i]=p end
    return canvas
end
function G.new_scene(width,height,options)
    options=options or {}
    return {width=assert(tonumber(width),'scene width required'),height=assert(tonumber(height),'scene height required'),background=options.background or '#00000000',viewbox=options.viewbox,supersample=options.supersample,objects={}}
end
function G.add(scene,object)
    assert(type(scene)=='table','scene required');assert(type(object)=='table','fontlib vector object required')
    scene.objects=scene.objects or {};scene.objects[#scene.objects+1]=object;return object,scene
end
local function blend(canvas,x,y,color)
    x=floor(x);y=floor(y);if x<0 or y<0 or x>=canvas.width or y>=canvas.height then return end
    local sa=color[4];if sa<=0 then return end
    local idx=y*canvas.width+x+1
    if sa>=255 then canvas.pixels[idx]=pack(color[1],color[2],color[3],255);return end
    local dr,dg,db,da=unpack_rgba(canvas.pixels[idx])
    if da<=0 then canvas.pixels[idx]=pack(color[1],color[2],color[3],sa);return end
    local oa=sa+da*(255-sa)/255
    local keep=da*(255-sa)/255
    local r=(color[1]*sa+dr*keep)/oa;local g=(color[2]*sa+dg*keep)/oa;local b=(color[3]*sa+db*keep)/oa
    canvas.pixels[idx]=pack(clamp8(r),clamp8(g),clamp8(b),clamp8(oa))
end
function G.pixel(canvas,x,y) return unpack_rgba(canvas.pixels[floor(y)*canvas.width+floor(x)+1] or 0) end

-- Draw a straight-alpha RGBA image through an arbitrary affine transform.
local function rgba_at(image,x,y)
    x=max(0,min(image.width-1,x));y=max(0,min(image.height-1,y))
    local p=(y*image.width+x)*4+1
    local r,g,b,a=image.rgba:byte(p,p+3)
    return r or 0,g or 0,b or 0,a or 0
end
local function sample_rgba_bilinear(image,x,y)
    -- x/y address texel centres: source pixel 0 has its centre at 0.5.
    local sx=x-.5;local sy=y-.5;local x0=floor(sx);local y0=floor(sy)
    local tx=sx-x0;local ty=sy-y0;local x1=x0+1;local y1=y0+1
    local r00,g00,b00,a00=rgba_at(image,x0,y0);local r10,g10,b10,a10=rgba_at(image,x1,y0)
    local r01,g01,b01,a01=rgba_at(image,x0,y1);local r11,g11,b11,a11=rgba_at(image,x1,y1)
    local function mix(a,b,t)return a+(b-a)*t end
    local function premul(c,a)return c*a/255 end
    local a0=mix(a00,a10,tx);local a1=mix(a01,a11,tx);local a=mix(a0,a1,ty)
    if a<=1e-12 then return {0,0,0,0} end
    local function ch(c00,c10,c01,c11)
        local p0=mix(premul(c00,a00),premul(c10,a10),tx)
        local p1=mix(premul(c01,a01),premul(c11,a11),tx)
        return clamp8(mix(p0,p1,ty)*255/a)
    end
    return {ch(r00,r10,r01,r11),ch(g00,g10,g01,g11),ch(b00,b10,b01,b11),clamp8(a)}
end
function G._draw_rgba_image(canvas,image,matrix,opacity,filter,clip_test)
    if type(image)~='table' or not image.width or not image.height or type(image.rgba)~='string' then return false end
    matrix=matrix or G.identity();local inv=G.inverse(matrix);if not inv then return false end
    opacity=max(0,min(1,tonumber(opacity) or 1));filter=filter or 'bilinear'
    local corners={{0,0},{image.width,0},{image.width,image.height},{0,image.height}}
    local minx,miny,maxx,maxy
    for _,q in ipairs(corners) do local x,y=G.transform_point(matrix,q[1],q[2]);minx=minx and min(minx,x) or x;miny=miny and min(miny,y) or y;maxx=maxx and max(maxx,x) or x;maxy=maxy and max(maxy,y) or y end
    local x0=max(0,floor(minx or 0));local y0=max(0,floor(miny or 0));local x1=min(canvas.width-1,ceil(maxx or -1)-1);local y1=min(canvas.height-1,ceil(maxy or -1)-1)
    for py=y0,y1 do for px=x0,x1 do
        local sx,sy=G.transform_point(inv,px+.5,py+.5)
        if sx>=0 and sy>=0 and sx<image.width and sy<image.height and (not clip_test or clip_test(px+.5,py+.5)) then
            local c
            if filter=='nearest' then local r,g,b,a=rgba_at(image,floor(sx),floor(sy));c={r,g,b,a}
            else c=sample_rgba_bilinear(image,sx,sy) end
            if opacity~=1 then c[4]=clamp8(c[4]*opacity) end
            blend(canvas,px,py,c)
        end
    end end
    return true
end
G._blend=blend
G._pack_rgba=pack
G._unpack_rgba=unpack_rgba

function G.identity() return {1,0,0,1,0,0} end
function G.multiply(a,b)
    return {a[1]*b[1]+a[3]*b[2],a[2]*b[1]+a[4]*b[2],a[1]*b[3]+a[3]*b[4],a[2]*b[3]+a[4]*b[4],a[1]*b[5]+a[3]*b[6]+a[5],a[2]*b[5]+a[4]*b[6]+a[6]}
end
function G.translate(x,y) return {1,0,0,1,x or 0,y or 0} end
function G.scale(x,y) x=x or 1;return {x,0,0,y or x,0,0} end
function G.rotate(degrees)
    local r=(degrees or 0)*pi/180;local c,s=cos(r),sin(r);return {c,s,-s,c,0,0}
end
function G.transform_point(m,x,y) return m[1]*x+m[3]*y+m[5],m[2]*x+m[4]*y+m[6] end
function G.inverse(m)
    local det=m[1]*m[4]-m[2]*m[3]
    if abs(det)<1e-12 then return nil end
    local a,d=m[4]/det,m[1]/det;local b,c=-m[2]/det,-m[3]/det
    return {a,b,c,d,-a*m[5]-c*m[6],-b*m[5]-d*m[6]}
end
local function object_matrix(o)
    if type(o.transform)=='table' and #o.transform>=6 then return o.transform end
    local m=G.identity()
    if o.translate then m=G.multiply(m,G.translate(o.translate.x or o.translate[1] or 0,o.translate.y or o.translate[2] or 0)) end
    if o.rotate then
        local ox,oy=0,0;if o.origin then ox=o.origin.x or o.origin[1] or 0;oy=o.origin.y or o.origin[2] or 0 end
        m=G.multiply(m,G.translate(ox,oy));m=G.multiply(m,G.rotate(o.rotate));m=G.multiply(m,G.translate(-ox,-oy))
    end
    if o.scale then
        local sx,sy;if type(o.scale)=='table' then sx=o.scale.x or o.scale[1] or 1;sy=o.scale.y or o.scale[2] or sx else sx=o.scale;sy=o.scale end
        m=G.multiply(m,G.scale(sx,sy))
    end
    return m
end

local function number_token(s,i)
    local rest=s:sub(i);local tok=rest:match('^[-+]?%d*%.?%d+[eE][-+]?%d+') or rest:match('^[-+]?%d*%.?%d+')
    if not tok then return nil,i end
    return tonumber(tok),i+#tok
end
local function tokens(path)
    local out={};local i=1
    while i<=#path do
        local ch=path:sub(i,i)
        if ch:match('[%a]') then out[#out+1]=ch;i=i+1
        elseif ch:match('[,%s]') then i=i+1
        else local n,j=number_token(path,i);if not n then error('invalid fontlib path near '..path:sub(i,i+20)) end;out[#out+1]=n;i=j end
    end
    return out
end
local function curve_steps(points,base)
    local length=0
    for i=2,#points do local dx=points[i].x-points[i-1].x;local dy=points[i].y-points[i-1].y;length=length+sqrt(dx*dx+dy*dy) end
    return max(base or 8,min(48,ceil(length/2)))
end
local function arc_points(x1,y1,rx,ry,rotation,large_arc,sweep,x2,y2)
    rx,ry=abs(rx),abs(ry)
    if rx==0 or ry==0 or (x1==x2 and y1==y2) then return {{x=x2,y=y2}} end
    local phi=(rotation or 0)*pi/180
    local cphi,sphi=cos(phi),sin(phi)
    local dx=(x1-x2)/2;local dy=(y1-y2)/2
    local xp=cphi*dx+sphi*dy;local yp=-sphi*dx+cphi*dy
    local lambda=(xp*xp)/(rx*rx)+(yp*yp)/(ry*ry)
    if lambda>1 then local k=sqrt(lambda);rx=rx*k;ry=ry*k end
    local rx2,ry2=rx*rx,ry*ry;local xp2,yp2=xp*xp,yp*yp
    local denom=rx2*yp2+ry2*xp2
    local factor=0
    if denom>0 then
        local term=max(0,(rx2*ry2-rx2*yp2-ry2*xp2)/denom)
        factor=sqrt(term)
        if (large_arc and 1 or 0)==(sweep and 1 or 0) then factor=-factor end
    end
    local cxp=factor*(rx*yp/ry);local cyp=factor*(-ry*xp/rx)
    local cx=cphi*cxp-sphi*cyp+(x1+x2)/2
    local cy=sphi*cxp+cphi*cyp+(y1+y2)/2
    local function angle(ux,uy,vx,vy)
        local dot=ux*vx+uy*vy;local det=ux*vy-uy*vx
        return math.atan2(det,dot)
    end
    local ux=(xp-cxp)/rx;local uy=(yp-cyp)/ry
    local vx=(-xp-cxp)/rx;local vy=(-yp-cyp)/ry
    local theta1=angle(1,0,ux,uy);local delta=angle(ux,uy,vx,vy)
    if not sweep and delta>0 then delta=delta-2*pi elseif sweep and delta<0 then delta=delta+2*pi end
    local approx=max(rx,ry)*abs(delta)
    local steps=max(8,min(96,ceil(approx/2)))
    local out={}
    for n=1,steps do
        local theta=theta1+delta*(n/steps)
        local ct,st=cos(theta),sin(theta)
        out[#out+1]={x=cx+cphi*rx*ct-sphi*ry*st,y=cy+sphi*rx*ct+cphi*ry*st}
    end
    return out
end
function G.parse_path(path)
    if type(path)=='table' then return path end
    local t=tokens(path or '');local i=1;local cmd;local x,y=0,0;local sx,sy=0,0;local last_ctrl=nil;local last_curve=nil;local subpaths={};local current=nil
    local function begin(px,py) current={{x=px,y=py}};subpaths[#subpaths+1]=current;sx,sy=px,py end
    local function add(px,py) if not current then begin(px,py) else current[#current+1]={x=px,y=py} end;x,y=px,py end
    local function num() local v=t[i];assert(type(v)=='number','fontlib path missing numeric parameter');i=i+1;return v end
    while i<=#t do
        if type(t[i])=='string' then cmd=t[i];i=i+1 end
        assert(cmd,'fontlib path must begin with a command')
        local lower=cmd:lower();local rel=cmd==lower
        if lower=='z' then
            if current and (#current==1 or current[#current].x~=sx or current[#current].y~=sy) then current[#current+1]={x=sx,y=sy} end;x,y=sx,sy;last_ctrl=nil;last_curve=nil;cmd=nil
        elseif lower=='m' then
            local nx,ny=num(),num();if rel then nx,ny=x+nx,y+ny end;begin(nx,ny);x,y=nx,ny;last_ctrl=nil;last_curve=nil
            cmd=rel and 'l' or 'L'
        elseif lower=='l' then local nx,ny=num(),num();if rel then nx,ny=x+nx,y+ny end;add(nx,ny);last_ctrl=nil;last_curve=nil
        elseif lower=='h' then local nx=num();if rel then nx=x+nx end;add(nx,y);last_ctrl=nil;last_curve=nil
        elseif lower=='v' then local ny=num();if rel then ny=y+ny end;add(x,ny);last_ctrl=nil;last_curve=nil
        elseif lower=='q' or lower=='t' then
            local cx,cy,nx,ny
            if lower=='q' then cx,cy,nx,ny=num(),num(),num(),num();if rel then cx,cy,nx,ny=x+cx,y+cy,x+nx,y+ny end
            else cx,cy=x,y;if last_curve=='q' and last_ctrl then cx,cy=2*x-last_ctrl.x,2*y-last_ctrl.y end;nx,ny=num(),num();if rel then nx,ny=x+nx,y+ny end end
            local x0,y0=x,y;local steps=curve_steps({{x=x0,y=y0},{x=cx,y=cy},{x=nx,y=ny}},8)
            for n=1,steps do local u=n/steps;local v=1-u;add(v*v*x0+2*v*u*cx+u*u*nx,v*v*y0+2*v*u*cy+u*u*ny) end
            last_ctrl={x=cx,y=cy};last_curve='q'
        elseif lower=='c' or lower=='s' then
            local c1x,c1y,c2x,c2y,nx,ny
            if lower=='c' then c1x,c1y,c2x,c2y,nx,ny=num(),num(),num(),num(),num(),num();if rel then c1x,c1y,c2x,c2y,nx,ny=x+c1x,y+c1y,x+c2x,y+c2y,x+nx,y+ny end
            else c1x,c1y=x,y;if last_curve=='c' and last_ctrl then c1x,c1y=2*x-last_ctrl.x,2*y-last_ctrl.y end;c2x,c2y,nx,ny=num(),num(),num(),num();if rel then c2x,c2y,nx,ny=x+c2x,y+c2y,x+nx,y+ny end end
            local x0,y0=x,y;local steps=curve_steps({{x=x0,y=y0},{x=c1x,y=c1y},{x=c2x,y=c2y},{x=nx,y=ny}},10)
            for n=1,steps do local u=n/steps;local v=1-u;add(v*v*v*x0+3*v*v*u*c1x+3*v*u*u*c2x+u*u*u*nx,v*v*v*y0+3*v*v*u*c1y+3*v*u*u*c2y+u*u*u*ny) end
            last_ctrl={x=c2x,y=c2y};last_curve='c'
        elseif lower=='a' then
            local rx,ry,rotation,large_flag,sweep_flag,nx,ny=num(),num(),num(),num(),num(),num(),num()
            if rel then nx,ny=x+nx,y+ny end
            for _,p in ipairs(arc_points(x,y,rx,ry,rotation,large_flag~=0,sweep_flag~=0,nx,ny)) do add(p.x,p.y) end
            last_ctrl=nil;last_curve=nil
        else error('unsupported fontlib path command '..tostring(cmd)) end
    end
    return subpaths
end

local function transformed(contours,m)
    local out={}
    for _,contour in ipairs(contours or {}) do local c={};for _,p in ipairs(contour) do local x,y=G.transform_point(m,p.x,p.y);c[#c+1]={x=x,y=y} end;out[#out+1]=c end
    return out
end
local function fill_contours_binary(canvas,contours,color,fill_rule)
    local miny,maxy=math.huge,-math.huge;fill_rule=fill_rule or 'evenodd'
    for _,c in ipairs(contours) do for _,p in ipairs(c) do miny=min(miny,p.y);maxy=max(maxy,p.y) end end
    if miny==math.huge then return end
    local y0=max(0,floor(miny));local y1=min(canvas.height-1,ceil(maxy)-1)
    local function span(py,xa,xb)
        if not xa or not xb or xb<=xa then return end
        local first=max(0,ceil(xa-.5));local last=min(canvas.width-1,floor(xb-.5))
        for px=first,last do blend(canvas,px,py,color) end
    end
    for py=y0,y1 do
        local sy=py+.5;local hits={}
        for _,c in ipairs(contours) do
            local function edge(a,b)
                if a.y<=sy and b.y>sy then hits[#hits+1]={x=a.x+(sy-a.y)*(b.x-a.x)/(b.y-a.y),w=1}
                elseif b.y<=sy and a.y>sy then hits[#hits+1]={x=a.x+(sy-a.y)*(b.x-a.x)/(b.y-a.y),w=-1} end
            end
            for j=1,#c-1 do edge(c[j],c[j+1]) end
            if #c>2 then local a,b=c[#c],c[1];if not (a.x==b.x and a.y==b.y) then edge(a,b) end end
        end
        table.sort(hits,function(a,b) return a.x<b.x end)
        if fill_rule=='nonzero' then
            local winding=0;local prev=nil
            for _,hit in ipairs(hits) do if prev and winding~=0 then span(py,prev,hit.x) end;winding=winding+hit.w;prev=hit.x end
        else
            for k=1,#hits-1,2 do span(py,hits[k].x,hits[k+1].x) end
        end
    end
end

-- Edge-aware grayscale scan conversion.
local function fill_contours_coverage(canvas,contours,color,fill_rule,quality)
    fill_rule=fill_rule or 'evenodd';quality=max(1,min(8,floor(tonumber(quality) or 4)))
    local miny,maxy=math.huge,-math.huge
    for _,c in ipairs(contours or {}) do for _,p in ipairs(c) do miny=min(miny,p.y);maxy=max(maxy,p.y) end end
    if miny==math.huge then return end
    local y0=max(0,floor(miny));local y1=min(canvas.height-1,ceil(maxy)-1);if y1<y0 then return end
    local eps=1e-9

    -- Build the edge table once, then bucket it by destination row.
    local row_edges,row_cuts={},{}
    local function add_edge(a,b)
        if abs(a.y-b.y)<=eps then return end
        local ymin,ymax,x0,slope,w
        if a.y<b.y then ymin,ymax,x0,slope,w=a.y,b.y,a.x,(b.x-a.x)/(b.y-a.y),1
        else ymin,ymax,x0,slope,w=b.y,a.y,b.x,(a.x-b.x)/(a.y-b.y),-1 end
        local r0=max(y0,floor(ymin));local r1=min(y1,ceil(ymax)-1)
        if r1<r0 then return end
        local e={ymin=ymin,ymax=ymax,x0=x0,slope=slope,w=w}
        for r=r0,r1 do local q=row_edges[r];if not q then q={};row_edges[r]=q end;q[#q+1]=e end
    end
    for _,c in ipairs(contours or {}) do
        for j=1,#c-1 do add_edge(c[j],c[j+1]) end
        if #c>2 then local a,b=c[#c],c[1];if a.x~=b.x or a.y~=b.y then add_edge(a,b) end end
        for _,p in ipairs(c) do
            local r=floor(p.y)
            if r>=y0 and r<=y1 and p.y>r+eps and p.y<r+1-eps then
                local q=row_cuts[r];if not q then q={};row_cuts[r]=q end;q[#q+1]=p.y
            end
        end
    end

    local function hits_at(sy,edges)
        local hits={}
        for _,e in ipairs(edges or {}) do
            -- Half-open vertical intervals reproduce the binary converter's vertex ownership
            -- rule and prevent double-counting shared nodes.
            if e.ymin<=sy and e.ymax>sy then hits[#hits+1]={x=e.x0+(sy-e.ymin)*e.slope,w=e.w} end
        end
        table.sort(hits,function(a,b) return a.x<b.x end);return hits
    end

    local function add_span(acc,xa,xb,weight)
        if not xa or not xb or xb<=xa then return end
        local first=max(0,floor(xa));local last=min(canvas.width-1,ceil(xb)-1)
        for px=first,last do
            local overlap=min(xb,px+1)-max(xa,px)
            if overlap>0 then acc[px]=(acc[px] or 0)+overlap*weight end
        end
    end

    local function accumulate_scan(acc,sy,weight,edges)
        local hits=hits_at(sy,edges);if #hits<2 then return end
        if fill_rule=='nonzero' then
            local winding=0;local prev=nil;local i=1
            while i<=#hits do
                local x=hits[i].x
                if prev and winding~=0 then add_span(acc,prev,x,weight) end
                local dw=0
                repeat dw=dw+hits[i].w;i=i+1 until i>#hits or abs(hits[i].x-x)>eps
                winding=winding+dw;prev=x
            end
        else
            local parity=0;local prev=nil;local i=1
            while i<=#hits do
                local x=hits[i].x
                if prev and parity==1 then add_span(acc,prev,x,weight) end
                local count=0
                repeat count=count+1;i=i+1 until i>#hits or abs(hits[i].x-x)>eps
                parity=(parity+count)%2;prev=x
            end
        end
    end

    for py=y0,y1 do
        local cuts={py,py+1};local extra=row_cuts[py]
        if extra then for _,v in ipairs(extra) do cuts[#cuts+1]=v end end
        table.sort(cuts)
        local uniq={};local last
        for _,v in ipairs(cuts) do if last==nil or abs(v-last)>eps then uniq[#uniq+1]=v;last=v end end
        local acc={};local edges=row_edges[py]
        for ci=1,#uniq-1 do
            local ya,yb=uniq[ci],uniq[ci+1];local h=yb-ya
            if h>eps then
                local n=max(1,ceil(h*quality-eps));local sh=h/n
                for si=1,n do accumulate_scan(acc,ya+(si-.5)*sh,sh,edges) end
            end
        end
        for px,cov in pairs(acc) do
            cov=max(0,min(1,cov))
            if cov>0 then blend(canvas,px,py,{color[1],color[2],color[3],clamp8(color[4]*cov)}) end
        end
    end
end

local function fill_contours(canvas,contours,color,fill_rule)
    if (canvas._fontlib_supersample or 1)>1 and canvas._fontlib_coverage_aa~=false then
        local q=canvas._fontlib_coverage_quality
        if q==nil then q=(canvas._fontlib_supersample or 1)>=4 and 2 or 4 end
        return fill_contours_coverage(canvas,contours,color,fill_rule,q)
    end
    return fill_contours_binary(canvas,contours,color,fill_rule)
end
local function point_in_contours(contours,x,y,fill_rule)
    fill_rule=fill_rule or 'evenodd';local winding=0;local crossings=0
    for _,c in ipairs(contours or {}) do
        local function edge(a,b)
            if (a.y<=y and b.y>y) or (b.y<=y and a.y>y) then
                local ix=a.x+(y-a.y)*(b.x-a.x)/(b.y-a.y)
                if ix>x then
                    crossings=crossings+1
                    if a.y<=y and b.y>y then winding=winding+1 else winding=winding-1 end
                end
            end
        end
        for j=1,#c-1 do edge(c[j],c[j+1]) end
        if #c>2 then local a,b=c[#c],c[1];if a.x~=b.x or a.y~=b.y then edge(a,b) end end
    end
    if fill_rule=='nonzero' then return winding~=0 end
    return crossings%2==1
end

local function fill_contours_shader(canvas,contours,shader,fill_rule,clip_test)
    local miny,maxy=math.huge,-math.huge;fill_rule=fill_rule or 'evenodd'
    for _,c in ipairs(contours or {}) do for _,p in ipairs(c) do miny=min(miny,p.y);maxy=max(maxy,p.y) end end
    if miny==math.huge then return end
    local y0=max(0,floor(miny));local y1=min(canvas.height-1,ceil(maxy)-1)
    local function span(py,xa,xb)
        if not xa or not xb or xb<=xa then return end
        local first=max(0,ceil(xa-.5));local last=min(canvas.width-1,floor(xb-.5))
        for px=first,last do
            local sx,sy=px+.5,py+.5
            if not clip_test or clip_test(sx,sy) then local color=shader(sx,sy);if color then blend(canvas,px,py,color) end end
        end
    end
    for py=y0,y1 do
        local sy=py+.5;local hits={}
        for _,c in ipairs(contours or {}) do
            local function edge(a,b)
                if a.y<=sy and b.y>sy then hits[#hits+1]={x=a.x+(sy-a.y)*(b.x-a.x)/(b.y-a.y),w=1}
                elseif b.y<=sy and a.y>sy then hits[#hits+1]={x=a.x+(sy-a.y)*(b.x-a.x)/(b.y-a.y),w=-1} end
            end
            for j=1,#c-1 do edge(c[j],c[j+1]) end
            if #c>2 then local a,b=c[#c],c[1];if not (a.x==b.x and a.y==b.y) then edge(a,b) end end
        end
        table.sort(hits,function(a,b) return a.x<b.x end)
        if fill_rule=='nonzero' then
            local winding=0;local prev=nil
            for _,hit in ipairs(hits) do if prev and winding~=0 then span(py,prev,hit.x) end;winding=winding+hit.w;prev=hit.x end
        else
            for k=1,#hits-1,2 do span(py,hits[k].x,hits[k+1].x) end
        end
    end
end

-- TrueType dropout repair for the binary (1x) scan-conversion path.
local function dropout_candidates(contours,fill_rule,horizontal)
    local min_a,max_a=math.huge,-math.huge
    for _,c in ipairs(contours or {}) do for _,p in ipairs(c) do
        local v=horizontal and p.y or p.x;min_a=min(min_a,v);max_a=max(max_a,v)
    end end
    if min_a==math.huge then return {},{} end
    local first=floor(min_a)-1;local last=ceil(max_a)
    local list,map={},{}
    local function intersections(scan)
        local hits={}
        for _,c in ipairs(contours or {}) do
            local function edge(a,b)
                local av=horizontal and a.y or a.x;local bv=horizontal and b.y or b.x
                if (av<=scan and bv>scan) or (bv<=scan and av>scan) then
                    local t=(scan-av)/(bv-av)
                    hits[#hits+1]=(horizontal and (a.x+t*(b.x-a.x)) or (a.y+t*(b.y-a.y)))
                end
            end
            for j=1,#c-1 do edge(c[j],c[j+1]) end
            if #c>2 then local a,b=c[#c],c[1];if a.x~=b.x or a.y~=b.y then edge(a,b) end end
        end
        table.sort(hits);return hits
    end
    for ai=first,last do
        local scan=ai+.5;local hits=intersections(scan)
        for h=1,#hits-1 do
            local lo,hi=hits[h],hits[h+1]
            if hi-lo>1e-9 then
                local mid=(lo+hi)/2
                local inside=horizontal and point_in_contours(contours,mid,scan,fill_rule) or point_in_contours(contours,scan,mid,fill_rule)
                if inside then
                    -- If there is a pixel centre in this interior span, Rule 1 already covers
                    -- it and this is not a dropout candidate.
                    local centre_first=ceil(lo-.5);local centre_last=floor(hi-.5)
                    if centre_first>centre_last then
                        local gap=centre_first-1
                        local key=ai..":"..gap
                        local q={axis=ai,gap=gap,lo=lo,hi=hi,mid=mid,horizontal=horizontal,key=key}
                        list[#list+1]=q;map[key]=true
                    end
                end
            end
        end
    end
    return list,map
end

local function apply_dropout(canvas,contours,color,fill_rule,mode)
    if not mode or not contours or #contours==0 then return 0 end
    local smart=mode.smart==true;local exclude_stubs=mode.exclude_stubs==true;local added=0
    local function apply_axis(horizontal)
        local list,map=dropout_candidates(contours,fill_rule,horizontal)
        for _,q in ipairs(list) do
            local keep=true
            if exclude_stubs then
                keep=map[(q.axis-1)..":"..q.gap] and map[(q.axis+1)..":"..q.gap] or false
            end
            if keep then
                local px,py
                if horizontal then
                    local left=q.gap;local right=q.gap+1
                    if smart then
                        local dl=abs(q.mid-(left+.5));local dr=abs(q.mid-(right+.5));px=(dr<dl) and right or left
                    else px=left end
                    py=q.axis
                else
                    local top=q.gap;local bottom=q.gap+1
                    px=q.axis
                    if smart then
                        local dt=abs(q.mid-(top+.5));local db=abs(q.mid-(bottom+.5));py=(db<dt) and bottom or top
                    else py=bottom end -- TrueType simple rule chooses bottom-most pixel.
                end
                if px>=0 and py>=0 and px<canvas.width and py<canvas.height then
                    local cx,cy=px+.5,py+.5
                    if not point_in_contours(contours,cx,cy,fill_rule) then blend(canvas,px,py,color);added=added+1 end
                end
            end
        end
    end
    apply_axis(true);apply_axis(false);return added
end
G._apply_dropout=apply_dropout

local function composite_rgba(src,dst,mode)
    local sr,sg,sb,sa=(src[1] or 0)/255,(src[2] or 0)/255,(src[3] or 0)/255,(src[4] or 0)/255
    local dr,dg,db,da=(dst[1] or 0)/255,(dst[2] or 0)/255,(dst[3] or 0)/255,(dst[4] or 0)/255
    local function pd(fa,fb)
        local oa=sa*fa+da*fb;if oa<=1e-12 then return {0,0,0,0} end
        local r=(sr*sa*fa+dr*da*fb)/oa;local g=(sg*sa*fa+dg*da*fb)/oa;local b=(sb*sa*fa+db*da*fb)/oa
        return {clamp8(r*255),clamp8(g*255),clamp8(b*255),clamp8(oa*255)}
    end
    if mode==0 then return {0,0,0,0} elseif mode==1 then return pd(1,0) elseif mode==2 then return pd(0,1)
    elseif mode==3 then return pd(1,1-sa) elseif mode==4 then return pd(1-da,1)
    elseif mode==5 then return pd(da,0) elseif mode==6 then return pd(0,sa)
    elseif mode==7 then return pd(1-da,0) elseif mode==8 then return pd(0,1-sa)
    elseif mode==9 then return pd(da,1-sa) elseif mode==10 then return pd(1-da,sa)
    elseif mode==11 then return pd(1-da,1-sa)
    elseif mode==12 then
        local oa=min(1,sa+da);local pr=min(1,sr*sa+dr*da);local pg=min(1,sg*sa+dg*da);local pb=min(1,sb*sa+db*da)
        if oa<=1e-12 then return {0,0,0,0} end
        return {clamp8(pr/oa*255),clamp8(pg/oa*255),clamp8(pb/oa*255),clamp8(oa*255)}
    end
    local function tolin(c) if c<=0.04045 then return c/12.92 end return ((c+0.055)/1.055)^2.4 end
    local function tos(c) c=max(0,min(1,c));if c<=0.0031308 then return 12.92*c end return 1.055*(c^(1/2.4))-0.055 end
    local S={tolin(sr),tolin(sg),tolin(sb)};local B={tolin(dr),tolin(dg),tolin(db)}
    local function blendch(b,s)
        if mode==13 then return b+s-b*s
        elseif mode==14 then return b<=.5 and 2*b*s or 1-2*(1-b)*(1-s)
        elseif mode==15 then return min(b,s) elseif mode==16 then return max(b,s)
        elseif mode==17 then return s>=1 and 1 or min(1,b/(1-s))
        elseif mode==18 then return s<=0 and 0 or 1-min(1,(1-b)/s)
        elseif mode==19 then return s<=.5 and 2*b*s or 1-2*(1-b)*(1-s)
        elseif mode==20 then
            if s<=.5 then return b-(1-2*s)*b*(1-b) end
            local d=b<=.25 and ((16*b-12)*b+4)*b or sqrt(b);return b+(2*s-1)*(d-b)
        elseif mode==21 then return abs(b-s) elseif mode==22 then return b+s-2*b*s elseif mode==23 then return b*s end
        return s
    end
    local function lum(c) return .3*c[1]+.59*c[2]+.11*c[3] end
    local function sat(c) return max(c[1],c[2],c[3])-min(c[1],c[2],c[3]) end
    local function clip_color(c)
        local l=lum(c);local n=min(c[1],c[2],c[3]);local x=max(c[1],c[2],c[3])
        if n<0 and l~=n then for i=1,3 do c[i]=l+(c[i]-l)*l/(l-n) end end
        if x>1 and x~=l then for i=1,3 do c[i]=l+(c[i]-l)*(1-l)/(x-l) end end
        return c
    end
    local function set_lum(c,l) local d=l-lum(c);return clip_color({c[1]+d,c[2]+d,c[3]+d}) end
    local function set_sat(c,s)
        local idx={1,2,3};table.sort(idx,function(i,j)return c[i]<c[j] end);local mn,md,mx=idx[1],idx[2],idx[3]
        local out={c[1],c[2],c[3]};if c[mx]>c[mn] then out[md]=(c[md]-c[mn])*s/(c[mx]-c[mn]);out[mx]=s else out[md],out[mx]=0,0 end;out[mn]=0;return out
    end
    local C
    if mode>=24 and mode<=27 then
        if mode==24 then C=set_lum(set_sat({S[1],S[2],S[3]},sat(B)),lum(B))
        elseif mode==25 then C=set_lum(set_sat({B[1],B[2],B[3]},sat(S)),lum(B))
        elseif mode==26 then C=set_lum({S[1],S[2],S[3]},lum(B))
        else C=set_lum({B[1],B[2],B[3]},lum(S)) end
    else C={blendch(B[1],S[1]),blendch(B[2],S[2]),blendch(B[3],S[3])} end
    local oa=sa+da-sa*da;if oa<=1e-12 then return {0,0,0,0} end
    local out={};for i=1,3 do local v=((1-sa)*B[i]*da+(1-da)*S[i]*sa+sa*da*C[i])/oa;out[i]=clamp8(tos(v)*255) end;out[4]=clamp8(oa*255);return out
end

local function composite_canvas(dst,src,mode)
    mode=mode or 3
    local n=min(#dst.pixels,#src.pixels)
    -- Do not skip transparent source pixels: several Porter-Duff operators (for example SRC,
    -- SRC_IN and SRC_OUT) clear the backdrop where the source is transparent.
    for i=1,n do
        local sr,sg,sb,sa=unpack_rgba(src.pixels[i])
        local dr,dg,db,da=unpack_rgba(dst.pixels[i])
        local c=composite_rgba({sr,sg,sb,sa},{dr,dg,db,da},mode)
        dst.pixels[i]=pack(c[1],c[2],c[3],c[4])
    end
    return dst
end

local function stroke_segment(canvas,a,b,width,color,clip_test)
    local half=width/2;local minx=max(0,floor(min(a.x,b.x)-half));local maxx=min(canvas.width-1,ceil(max(a.x,b.x)+half))
    local miny=max(0,floor(min(a.y,b.y)-half));local maxy=min(canvas.height-1,ceil(max(a.y,b.y)+half))
    local dx,dy=b.x-a.x,b.y-a.y;local l2=dx*dx+dy*dy
    for py=miny,maxy do for px=minx,maxx do local qx,qy=px+.5,py+.5;local t=0
        if l2>0 then t=((qx-a.x)*dx+(qy-a.y)*dy)/l2;t=max(0,min(1,t)) end
        local ex,ey=qx-(a.x+t*dx),qy-(a.y+t*dy)
        if ex*ex+ey*ey<=half*half and (not clip_test or clip_test(qx,qy)) then blend(canvas,px,py,color) end
    end end
end
local function stroke_contours(canvas,contours,width,color,closed,clip_test)
    for _,c in ipairs(contours) do
        for i=1,#c-1 do stroke_segment(canvas,c[i],c[i+1],width,color,clip_test) end
        if closed and #c>2 then local a,b=c[#c],c[1];if a.x~=b.x or a.y~=b.y then stroke_segment(canvas,a,b,width,color,clip_test) end end
    end
end

-- SVG needs more stroke geometry than the historical vector API exposed.
local function stroke_fill(canvas,contours,paint,clip_test)
    if type(paint)=='function' then
        fill_contours_shader(canvas,contours,paint,'nonzero',clip_test)
    elseif clip_test then
        fill_contours_shader(canvas,contours,function() return paint end,'nonzero',clip_test)
    else
        fill_contours(canvas,contours,paint,'nonzero')
    end
end
local function stroke_circle(canvas,x,y,r,paint,clip_test)
    if r<=0 then return end
    local n=max(20,min(96,ceil(r*pi)));local c={}
    for i=0,n do local a=2*pi*i/n;c[#c+1]={x=x+cos(a)*r,y=y+sin(a)*r} end
    stroke_fill(canvas,{c},paint,clip_test)
end
local function stroke_polygon(canvas,pts,paint,clip_test)
    if #pts>=3 then stroke_fill(canvas,{pts},paint,clip_test) end
end
local function line_intersection(px,py,dx,dy,qx,qy,ex,ey)
    local den=dx*ey-dy*ex;if abs(den)<1e-12 then return nil end
    local t=((qx-px)*ey-(qy-py)*ex)/den
    return px+t*dx,py+t*dy
end
local function dash_polyline(points,dashes,offset,closed)
    if type(dashes)~='table' or #dashes==0 then return {{points=points,closed=closed}} end
    local arr={};local total=0
    for _,v in ipairs(dashes) do v=max(0,tonumber(v) or 0);arr[#arr+1]=v;total=total+v end
    if #arr%2==1 then local n=#arr;for i=1,n do arr[#arr+1]=arr[i];total=total+arr[i] end end
    if total<=1e-12 then return {} end
    offset=(tonumber(offset) or 0)%total;if offset<0 then offset=offset+total end
    local di,remain=1,arr[1]
    while offset>remain and #arr>0 do offset=offset-remain;di=di%#arr+1;remain=arr[di] end
    remain=remain-offset;local on=di%2==1;local out,current={},nil
    local function emit(x,y)
        if on then current=current or {};local last=current[#current];if not last or abs(last.x-x)>1e-9 or abs(last.y-y)>1e-9 then current[#current+1]={x=x,y=y} end end
    end
    local function flush() if current and #current>=2 then out[#out+1]={points=current,closed=false} end;current=nil end
    local seq={};for i,p in ipairs(points) do seq[i]={x=p.x,y=p.y} end
    if closed and #seq>2 then local a,b=seq[#seq],seq[1];if abs(a.x-b.x)>1e-9 or abs(a.y-b.y)>1e-9 then seq[#seq+1]={x=b.x,y=b.y} end end
    for si=1,#seq-1 do
        local a,b=seq[si],seq[si+1];local dx,dy=b.x-a.x,b.y-a.y;local len=sqrt(dx*dx+dy*dy)
        if len>1e-12 then
            local pos=0;while pos<len-1e-12 do
                while remain<=1e-12 do if on then flush() end;di=di%#arr+1;remain=arr[di];on=di%2==1 end
                local step=min(remain,len-pos);local t0=pos/len;local t1=(pos+step)/len
                if on then emit(a.x+dx*t0,a.y+dy*t0);emit(a.x+dx*t1,a.y+dy*t1) end
                pos=pos+step;remain=remain-step
                if remain<=1e-12 then if on then flush() end;di=di%#arr+1;remain=arr[di];on=di%2==1 end
            end
        end
    end
    if on then flush() end
    return out
end
local function stroke_polyline_style(canvas,pts,width,paint,closed,clip_test,opts)
    if #pts<2 or width<=0 then return end
    opts=opts or {};local cap=(opts.linecap or 'butt'):lower();local join=(opts.linejoin or 'miter'):lower();local mlimit=max(1,tonumber(opts.miterlimit) or 4);local h=width/2
    local p={};for i,q in ipairs(pts) do p[i]={x=q.x,y=q.y} end
    if closed and #p>2 then local a,b=p[#p],p[1];if abs(a.x-b.x)<1e-9 and abs(a.y-b.y)<1e-9 then table.remove(p) end end
    local n=#p;if n<2 then return end
    local segs={}
    local segcount=closed and n or n-1
    for i=1,segcount do
        local a=p[i];local b=p[i%n+1];local dx,dy=b.x-a.x,b.y-a.y;local L=sqrt(dx*dx+dy*dy)
        if L>1e-12 then segs[i]={a=a,b=b,ux=dx/L,uy=dy/L,nx=-dy/L,ny=dx/L} end
    end
    -- Segment rectangles. Square caps extend only the exterior endpoints.
    for i=1,segcount do local s=segs[i];if s then
        local e0,e1=0,0
        if not closed and cap=='square' then if i==1 then e0=h end;if i==segcount then e1=h end end
        local ax=s.a.x-s.ux*e0;local ay=s.a.y-s.uy*e0;local bx=s.b.x+s.ux*e1;local by=s.b.y+s.uy*e1
        stroke_polygon(canvas,{{x=ax+s.nx*h,y=ay+s.ny*h},{x=bx+s.nx*h,y=by+s.ny*h},{x=bx-s.nx*h,y=by-s.ny*h},{x=ax-s.nx*h,y=ay-s.ny*h}},paint,clip_test)
    end end
    -- Joins fill the outer wedge between adjacent segment rectangles.
    local first,last=closed and 1 or 2,closed and n or n-1
    for i=first,last do
        local prev=segs[((i-2)%n)+1];local nexts=segs[((i-1)%n)+1]
        if prev and nexts then
            local v=p[i];local cross=prev.ux*nexts.uy-prev.uy*nexts.ux
            if abs(cross)>1e-10 then
                local side=cross>0 and 1 or -1
                local p1x,p1y=v.x+prev.nx*h*side,v.y+prev.ny*h*side
                local p2x,p2y=v.x+nexts.nx*h*side,v.y+nexts.ny*h*side
                if join=='round' then stroke_circle(canvas,v.x,v.y,h,paint,clip_test)
                elseif join=='miter' then
                    local ix,iy=line_intersection(p1x,p1y,prev.ux,prev.uy,p2x,p2y,nexts.ux,nexts.uy)
                    local ok=false;if ix then local dx,dy=ix-v.x,iy-v.y;ok=sqrt(dx*dx+dy*dy)<=mlimit*h+1e-9 end
                    if ok then stroke_polygon(canvas,{{x=p1x,y=p1y},{x=ix,y=iy},{x=p2x,y=p2y}},paint,clip_test)
                    else stroke_polygon(canvas,{{x=p1x,y=p1y},{x=v.x,y=v.y},{x=p2x,y=p2y}},paint,clip_test) end
                else stroke_polygon(canvas,{{x=p1x,y=p1y},{x=v.x,y=v.y},{x=p2x,y=p2y}},paint,clip_test) end
            end
        end
    end
    if not closed and cap=='round' then stroke_circle(canvas,p[1].x,p[1].y,h,paint,clip_test);stroke_circle(canvas,p[n].x,p[n].y,h,paint,clip_test) end
end
local function stroke_contours_style(canvas,contours,width,paint,closed,clip_test,opts)
    opts=opts or {};local dashes=opts.dasharray;local offset=opts.dashoffset or 0
    for _,c in ipairs(contours or {}) do
        local cc=closed
        if cc==nil and #c>2 then local a,b=c[1],c[#c];cc=abs(a.x-b.x)<1e-9 and abs(a.y-b.y)<1e-9 end
        local runs=dash_polyline(c,dashes,offset,cc and true or false)
        for _,run in ipairs(runs) do stroke_polyline_style(canvas,run.points,width,paint,run.closed,clip_test,opts) end
    end
end
local function ellipse_contour(cx,cy,rx,ry)
    local n=max(24,min(128,ceil(max(rx,ry)*1.5)));local c={}
    for i=0,n do local a=2*pi*i/n;c[#c+1]={x=cx+cos(a)*rx,y=cy+sin(a)*ry} end
    return {c}
end
local function rect_contour(x,y,w,h,rx,ry)
    rx=max(0,min(tonumber(rx) or 0,abs(w)/2));ry=max(0,min(tonumber(ry) or rx,abs(h)/2))
    if rx<=0 or ry<=0 then return {{{x=x,y=y},{x=x+w,y=y},{x=x+w,y=y+h},{x=x,y=y+h}}} end
    local c={};local function arc(cx,cy,start)
        for i=0,8 do local a=start+(pi/2)*i/8;c[#c+1]={x=cx+cos(a)*rx,y=cy+sin(a)*ry} end
    end
    arc(x+w-rx,y+ry,-pi/2);arc(x+w-rx,y+h-ry,0);arc(x+rx,y+h-ry,pi/2);arc(x+rx,y+ry,pi)
    return {c}
end

local function scale_width(m,w)
    local sx=sqrt(m[1]*m[1]+m[2]*m[2]);local sy=sqrt(m[3]*m[3]+m[4]*m[4]);return (sx+sy)*.5*w
end
local function shape_contours(o)
    local contours;local typ=o.type or 'path'
    if typ=='path' then contours=G.parse_path(o.path or o.d or '')
    elseif typ=='rect' then local rx=o.radius_x or o.rx or o.radius or o.r or 0;local ry=o.radius_y or o.ry or o.radius or o.r or rx;contours=rect_contour(o.x or 0,o.y or 0,o.width or o.w or 0,o.height or o.h or 0,rx,ry)
    elseif typ=='circle' then contours=ellipse_contour(o.cx or o.x or 0,o.cy or o.y or 0,o.r or o.radius or 0,o.r or o.radius or 0)
    elseif typ=='ellipse' then contours=ellipse_contour(o.cx or o.x or 0,o.cy or o.y or 0,o.rx or 0,o.ry or 0)
    elseif typ=='line' then contours={{{x=o.x1 or 0,y=o.y1 or 0},{x=o.x2 or 0,y=o.y2 or 0}}}
    elseif typ=='polyline' or typ=='polygon' then
        local c={};for _,p in ipairs(o.points or {}) do c[#c+1]={x=p.x or p[1] or 0,y=p.y or p[2] or 0} end;contours={c}
    else return nil end
    return contours,typ
end

local function draw_shape(canvas,o,m)
    local contours,typ=shape_contours(o);if not contours then return false end
    contours=transformed(contours,m)
    local opacity=tonumber(o.opacity) or 1
    if o.fill and typ~='line' and typ~='polyline' then fill_contours(canvas,contours,G.color(o.fill,opacity),o.fill_rule) end
    if o.stroke then stroke_contours(canvas,contours,scale_width(m,tonumber(o.stroke_width) or 1),G.color(o.stroke,opacity),typ=='polygon' or typ=='rect' or typ=='circle' or typ=='ellipse' or o.closed) end
    return true
end

G._draw_shape=draw_shape
G._shape_contours=shape_contours
G._fill_contours=fill_contours
G._fill_contours_binary=fill_contours_binary
G._fill_contours_coverage=fill_contours_coverage
G._fill_contours_shader=fill_contours_shader
G._point_in_contours=point_in_contours
G._composite_rgba=composite_rgba
G._composite_canvas=composite_canvas
G._stroke_contours=stroke_contours
G._stroke_contours_style=stroke_contours_style
G._transformed=transformed
G._scale_width=scale_width

local function draw_object(canvas,o,parent_matrix)
    if o.visible==false then return true end
    local m=G.multiply(parent_matrix or G.identity(),object_matrix(o))
    if o.type=='group' then
        for _,child in ipairs(o.objects or {}) do draw_object(canvas,child,m) end
        return true
    elseif o.type=='text' and G._draw_text then
        G._draw_text(canvas,o,m);return true
    elseif o.type=='rgba_image' then
        -- Unlike vector shapes and text, an RGBA image's pixel data has no intrinsic
        -- scene-space origin.
        local ix,iy=tonumber(o.x) or 0,tonumber(o.y) or 0
        if ix~=0 or iy~=0 then m=G.multiply(m,G.translate(ix,iy)) end
        local image=o.image or o;return G._draw_rgba_image(canvas,image,m,o.opacity,o.filter or "bilinear")
    elseif o.type=='svg_document' and G._draw_svg_document then
        return G._draw_svg_document(canvas,o,m)
    end
    return draw_shape(canvas,o,m)
end
function G.draw(canvas,object,transform)
    assert(type(canvas)=='table' and canvas.pixels,'canvas required')
    assert(type(object)=='table','fontlib vector object required')
    return draw_object(canvas,object,transform or G.identity())
end

local function downsample(src,ss)
    if ss==1 then return src end
    local dst=G.new_canvas(src.width/ss,src.height/ss,'#00000000');local denom=ss*ss
    for y=0,dst.height-1 do for x=0,dst.width-1 do local pr,pg,pb,aa=0,0,0,0
        for oy=0,ss-1 do for ox=0,ss-1 do local r,g,b,a=G.pixel(src,x*ss+ox,y*ss+oy);pr=pr+r*a;pg=pg+g*a;pb=pb+b*a;aa=aa+a end end
        local oa=aa/denom;local r,g,b=0,0,0
        if aa>0 then r=pr/aa;g=pg/aa;b=pb/aa end
        dst.pixels[y*dst.width+x+1]=pack(clamp8(r),clamp8(g),clamp8(b),clamp8(oa))
    end end
    return dst
end
function G.rgba(canvas)
    local chunks={};local batch={};local n=0
    for i,v in ipairs(canvas.pixels) do local r,g,b,a=unpack_rgba(v);n=n+1;batch[n]=string.char(r,g,b,a)
        if n>=4096 then chunks[#chunks+1]=table.concat(batch);batch={};n=0 end
    end
    if n>0 then chunks[#chunks+1]=table.concat(batch) end
    return table.concat(chunks)
end
function G.render(scene,options)
    assert(type(scene)=='table','fontlib vector scene must be a table')
    local width=floor(scene.width or (options and options.width) or 0);local height=floor(scene.height or (options and options.height) or 0)
    assert(width>0 and height>0,'fontlib vector scene requires width and height')
    local max_pixels=(options and options.max_pixels) or 1048576
    assert(width*height<=max_pixels,'fontlib vector scene exceeds the default one-megapixel render budget')
    local ss=floor((options and options.supersample) or scene.supersample or 2);ss=max(1,min(4,ss))
    local max_samples=(options and options.max_samples) or 4194304
    if width*height*ss*ss>max_samples then ss=max(1,floor(sqrt(max_samples/(width*height)))) end
    local canvas=G.new_canvas(width*ss,height*ss,scene.background or '#00000000');canvas._fontlib_supersample=ss
    local coverage_aa=scene.coverage_aa~=false
    if options and options.coverage_aa~=nil then coverage_aa=options.coverage_aa~=false end
    canvas._fontlib_coverage_aa=coverage_aa
    canvas._fontlib_coverage_quality=(options and options.coverage_quality) or scene.coverage_quality
    local vb=scene.viewbox or {x=0,y=0,width=width,height=height}
    local vx=vb.x or vb[1] or 0;local vy=vb.y or vb[2] or 0;local vw=vb.width or vb.w or vb[3] or width;local vh=vb.height or vb.h or vb[4] or height
    assert(vw~=0 and vh~=0,'fontlib vector scene viewbox dimensions must be non-zero')
    local sx=width/vw;local sy=height/vh
    local base=G.multiply(G.scale(ss*sx,ss*sy),G.translate(-vx,-vy))
    for _,o in ipairs(scene.objects or scene) do if type(o)=='table' then draw_object(canvas,o,base) end end
    local out=downsample(canvas,ss);out.scene_width=width;out.scene_height=height
    if scene._fontlib_text_effects and fontlib.effects and fontlib.effects.apply then
        out=fontlib.effects.apply(out,scene._fontlib_text_effects,scene._fontlib_effect_background)
        out.scene_width=width;out.scene_height=height
    end
    return out
end
