-- SPDX-License-Identifier: 0BSD
-- Runtime font loaders.
local core = assert(rawget(_G, "core") or rawget(_G, "minetest"))
local M = fontlib
local F = M.font
local V = M.vector

local S = {}
F.source = S

local floor, ceil, sqrt, abs, max, min = math.floor, math.ceil, math.sqrt, math.abs, math.max, math.min

local function fail(msg) return nil, msg end


local function gunzip(data)
    if data:byte(1) ~= 0x1F or data:byte(2) ~= 0x8B then return data end
    local flg=data:byte(4) or 0; local p=11
    if math.floor(flg/4)%2==1 then local xlen=(data:byte(p) or 0)+(data:byte(p+1) or 0)*256;p=p+2+xlen end
    if math.floor(flg/8)%2==1 then while p<=#data and data:byte(p)~=0 do p=p+1 end;p=p+1 end
    if math.floor(flg/16)%2==1 then while p<=#data and data:byte(p)~=0 do p=p+1 end;p=p+1 end
    if math.floor(flg/2)%2==1 then p=p+2 end
    if p>#data-8 then return nil,"truncated gzip stream" end
    local ok,out=pcall(core.decompress,data:sub(p,#data-8),"raw_deflate")
    if not ok or type(out)~="string" then return nil,"gzip source requires Luanti raw_deflate support" end
    return out
end

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local data = f:read("*a")
    f:close()
    return data
end

local function sub(data, pos, len)
    return data:sub(pos, pos + len - 1)
end

local function u8(data, p)
    return data:byte(p) or 0
end
local function s8(data,p)
    local n=u8(data,p);return n>=0x80 and n-0x100 or n
end
local function u16(data, p)
    local a,b = data:byte(p,p+1)
    if not b then return nil end
    return a*256+b
end
local function s16(data,p)
    local n=u16(data,p); if not n then return nil end
    return n>=0x8000 and n-0x10000 or n
end
local function u24(data,p)
    local a,b,c=data:byte(p,p+2); if not c then return nil end
    return a*65536+b*256+c
end
local function u32(data,p)
    local a,b,c,d=data:byte(p,p+3); if not d then return nil end
    return ((a*256+b)*256+c)*256+d
end
local function s32(data,p)
    local n=u32(data,p); if not n then return nil end
    return n>=0x80000000 and n-0x100000000 or n
end
local function fixed16_16(data,p)
    local n=s32(data,p);if not n then return nil end;return n/65536
end
local function f2dot14(data,p)
    return (s16(data,p) or 0)/16384
end

local function utf8_char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + floor(cp/64), 0x80 + cp%64)
    end
    if cp < 0x10000 then
        return string.char(0xE0 + floor(cp/4096), 0x80 + floor(cp/64)%64, 0x80 + cp%64)
    end
    if cp <= 0x10FFFF then
        return string.char(0xF0 + floor(cp/262144), 0x80 + floor(cp/4096)%64,
            0x80 + floor(cp/64)%64, 0x80 + cp%64)
    end
    return "?"
end

local function decode_utf16be(data)
    local out={}; local i=1
    while i+1<=#data do
        local cp=u16(data,i); i=i+2
        if cp>=0xD800 and cp<=0xDBFF and i+1<=#data then
            local lo=u16(data,i)
            if lo>=0xDC00 and lo<=0xDFFF then
                cp=0x10000+(cp-0xD800)*0x400+(lo-0xDC00); i=i+2
            end
        end
        out[#out+1]=utf8_char(cp)
    end
    return table.concat(out)
end

local function decode_name_string(platform, encoding, data)
    if platform==0 or platform==3 then return decode_utf16be(data) end
    -- Macintosh Roman is not UTF-8, but ASCII subset is enough for metadata fallback.
    return data:gsub("[%z\1-\31\127-\255]", "")
end

local function table_map_from_sfnt(data, offset)
    offset = offset or 1
    if #data < offset+11 then return fail("truncated sfnt header") end
    local num=u16(data,offset+4)
    if not num then return fail("invalid sfnt table count") end
    local tables={}
    local p=offset+12
    for _=1,num do
        if p+15>#data then return fail("truncated sfnt table directory") end
        local tag=sub(data,p,4)
        local off=u32(data,p+8)
        local len=u32(data,p+12)
        if not off or not len or off+len>#data then return fail("invalid sfnt table "..tag) end
        tables[tag]=sub(data,off+1,len)
        p=p+16
    end
    return tables
end

local function table_map_from_woff(data)
    if #data<44 then return fail("truncated WOFF header") end
    local num=u16(data,13)
    local tables={}
    local p=45
    for _=1,num do
        if p+19>#data then return fail("truncated WOFF directory") end
        local tag=sub(data,p,4)
        local off=u32(data,p+4); local clen=u32(data,p+8); local olen=u32(data,p+12)
        if not off or not clen or not olen or off+clen>#data then return fail("invalid WOFF table "..tag) end
        local bytes=sub(data,off+1,clen)
        if clen<olen then
            local ok, dec=pcall(core.decompress, bytes, "deflate")
            if not ok or type(dec)~="string" or #dec~=olen then
                return fail("unable to inflate WOFF table "..tag)
            end
            bytes=dec
        end
        tables[tag]=bytes
        p=p+20
    end
    return tables
end

local function choose_sfnt(data, face)
    local sig=sub(data,1,4)
    if sig=="wOFF" then
        local t,e=table_map_from_woff(data); return t,e,"woff"
    elseif sig=="wOF2" then
        return fail("WOFF2 is not yet supported by the pure-Lua runtime loader (Brotli + WOFF2 transforms are required)")
    elseif sig=="ttcf" then
        local count=u32(data,9) or 0
        face=tonumber(face) or 0
        if face<0 or face>=count then return fail("font collection face index out of range") end
        local off=u32(data,13+face*4)
        if not off then return fail("truncated font collection") end
        local t,e=table_map_from_sfnt(data,off+1); return t,e,"collection"
    elseif sig=="OTTO" or sig=="true" or sig=="typ1" or data:byte(1)==0 and data:byte(2)==1 and data:byte(3)==0 and data:byte(4)==0 then
        local t,e=table_map_from_sfnt(data,1); return t,e,(sig=="OTTO" and "otf" or "ttf")
    end
    return fail("not an SFNT/WOFF font")
end

local function parse_names(t)
    local data=t["name"]; if not data then return {} end
    local count=u16(data,3) or 0; local storage=u16(data,5) or 0
    local best={}
    local function score(platform,lang)
        if platform==3 and (lang==0x0409 or lang==0) then return 4 end
        if platform==0 then return 3 end
        if platform==3 then return 2 end
        if platform==1 then return 1 end
        return 0
    end
    local wanted={[1]="family",[2]="style",[4]="full_name",[6]="postscript_name"}
    for i=0,count-1 do
        local p=7+i*12
        local platform=u16(data,p); local encoding=u16(data,p+2); local lang=u16(data,p+4)
        local id=u16(data,p+6); local len=u16(data,p+8); local off=u16(data,p+10)
        local key=wanted[id]
        if key and off and len and storage+off+len<=#data then
            local sc=score(platform,lang)
            if not best[key] or sc>best[key].score then
                local raw=sub(data,storage+off+1,len)
                local value=decode_name_string(platform,encoding,raw)
                if value~="" then best[key]={score=sc,value=value} end
            end
        end
    end
    local out={}; for k,v in pairs(best) do out[k]=v.value end; return out
end

local function cmap_binary_group(groups, cp, constant)
    local lo,hi=1,#groups
    while lo<=hi do
        local m=floor((lo+hi)/2);local g=groups[m]
        if cp<g[1] then hi=m-1 elseif cp>g[2] then lo=m+1
        else return constant and g[3] or (g[3]+cp-g[1]) end
    end
    return 0
end

local function parse_cmap_mapping(data,p,format)
    if format==0 then
        local length=u16(data,p+2) or 0
        if length<262 or p+length-1>#data then return nil,"truncated cmap format 0" end
        return function(cp) if cp>=0 and cp<256 then return u8(data,p+6+cp) end return 0 end
    elseif format==2 then
        local length=u16(data,p+2) or 0
        if length<526 or p+length-1>#data then return nil,"truncated cmap format 2" end
        local keys={};local max_key=0
        for i=0,255 do
            local key=u16(data,p+6+i*2)
            if not key or key%8~=0 then return nil,"invalid cmap format 2 subHeaderKey" end
            keys[i]=key;if key>max_key then max_key=key end
        end
        local sub_count=max_key/8+1;local sub_base=p+518
        if sub_base+sub_count*8-1>p+length-1 then return nil,"truncated cmap format 2 subHeaders" end
        local subs={}
        for i=0,sub_count-1 do
            local q=sub_base+i*8
            subs[i]={first=u16(data,q) or 0,count=u16(data,q+2) or 0,delta=s16(data,q+4) or 0,range=u16(data,q+6) or 0,range_pos=q+6}
        end
        return function(cp)
            if cp<0 or cp>0xFFFF then return 0 end
            local high=floor(cp/256);local low=cp%256;local idx
            if high==0 then idx=0 else
                local key=keys[high] or 0
                if key==0 then return 0 end
                idx=key/8
            end
            local sh=subs[idx];if not sh or low<sh.first or low>=sh.first+sh.count then return 0 end
            local gp=sh.range_pos+sh.range+(low-sh.first)*2
            if gp+1>p+length-1 then return 0 end
            local gid=u16(data,gp) or 0
            if gid~=0 then gid=(gid+sh.delta)%65536 end
            return gid
        end
    elseif format==4 then
        local length=u16(data,p+2) or 0
        if length<16 or p+length-1>#data then return nil,"truncated cmap format 4" end
        local segCountX2=u16(data,p+6) or 0
        if segCountX2==0 or segCountX2%2~=0 then return nil,"invalid cmap format 4 segment count" end
        local segCount=segCountX2/2
        local endp=p+14;local startp=endp+segCount*2+2;local deltap=startp+segCount*2;local rangep=deltap+segCount*2
        if rangep+segCount*2-1>p+length-1 then return nil,"truncated cmap format 4 arrays" end
        return function(cp)
            if cp<0 or cp>0xFFFF then return 0 end
            local lo,hi=0,segCount-1
            while lo<=hi do
                local m=floor((lo+hi)/2);local ending=u16(data,endp+m*2) or 0
                if cp>ending then lo=m+1 else hi=m-1 end
            end
            local i=lo;if i>=segCount then return 0 end
            local starting=u16(data,startp+i*2) or 0
            if cp<starting then return 0 end
            local delta=s16(data,deltap+i*2) or 0;local ro=u16(data,rangep+i*2) or 0
            if ro==0 then return (cp+delta)%65536 end
            local wordpos=rangep+i*2;local gp=wordpos+ro+(cp-starting)*2
            if gp+1>p+length-1 then return 0 end
            local gid=u16(data,gp) or 0;if gid~=0 then gid=(gid+delta)%65536 end;return gid
        end
    elseif format==6 then
        local length=u16(data,p+2) or 0
        if length<10 or p+length-1>#data then return nil,"truncated cmap format 6" end
        local first=u16(data,p+6) or 0;local count=u16(data,p+8) or 0
        if p+10+count*2-1>p+length-1 then return nil,"truncated cmap format 6 glyph array" end
        return function(cp)
            if cp<first or cp>=first+count then return 0 end
            return u16(data,p+10+(cp-first)*2) or 0
        end
    elseif format==8 then
        local length=u32(data,p+4) or 0
        if length<8208 or p+length-1>#data then return nil,"truncated cmap format 8" end
        local function is32word(word)
            local b=u8(data,p+12+floor(word/8));local bit=7-(word%8)
            return floor(b/(2^bit))%2==1
        end
        local ng=u32(data,p+8204) or 0;local group_base=p+8208
        if group_base+ng*12-1>p+length-1 then return nil,"truncated cmap format 8 groups" end
        local groups={}
        for i=0,ng-1 do local q=group_base+i*12;groups[#groups+1]={u32(data,q) or 0,u32(data,q+4) or 0,u32(data,q+8) or 0} end
        return function(cp)
            if cp<0 or cp>0x10FFFF or (cp>=0xD800 and cp<=0xDFFF) then return 0 end
            local code
            if cp>=0x10000 then
                local v=cp-0x10000;local hi=0xD800+floor(v/0x400);local lo=0xDC00+(v%0x400)
                if not is32word(hi) then return 0 end
                code=hi*65536+lo
            else
                if is32word(cp) then return 0 end
                code=cp
            end
            return cmap_binary_group(groups,code,false)
        end
    elseif format==10 then
        local length=u32(data,p+4) or 0
        if length<20 or p+length-1>#data then return nil,"truncated cmap format 10" end
        local first=u32(data,p+12) or 0;local count=u32(data,p+16) or 0
        if p+20+count*2-1>p+length-1 then return nil,"truncated cmap format 10 glyph array" end
        return function(cp)
            if cp<first or cp>=first+count then return 0 end
            return u16(data,p+20+(cp-first)*2) or 0
        end
    elseif format==12 or format==13 then
        local length=u32(data,p+4) or 0
        if length<16 or p+length-1>#data then return nil,"truncated cmap format "..format end
        local ng=u32(data,p+12) or 0;local group_base=p+16
        if group_base+ng*12-1>p+length-1 then return nil,"truncated cmap format "..format.." groups" end
        local groups={}
        for i=0,ng-1 do local q=group_base+i*12;groups[#groups+1]={u32(data,q) or 0,u32(data,q+4) or 0,u32(data,q+8) or 0} end
        local constant=(format==13)
        return function(cp)
            if cp<0 or cp>0x10FFFF or (cp>=0xD800 and cp<=0xDFFF) then return 0 end
            return cmap_binary_group(groups,cp,constant)
        end
    end
    return nil,"unsupported cmap format "..tostring(format)
end

local function parse_cmap14(data,p,base_lookup)
    local length=u32(data,p+2) or 0
    if length<10 or p+length-1>#data then return nil,"truncated cmap format 14" end
    local n=u32(data,p+6) or 0;local rec_base=p+10
    if rec_base+n*11-1>p+length-1 then return nil,"truncated cmap format 14 records" end
    local records={}
    for i=0,n-1 do
        local q=rec_base+i*11
        records[#records+1]={selector=u24(data,q) or 0,default_off=u32(data,q+3) or 0,nondefault_off=u32(data,q+7) or 0}
    end
    local function find_record(selector)
        local lo,hi=1,#records
        while lo<=hi do local m=floor((lo+hi)/2);local r=records[m]
            if selector<r.selector then hi=m-1 elseif selector>r.selector then lo=m+1 else return r end end
    end
    local function default_contains(off,cp)
        if off==0 then return false end
        local q=p+off;if q+3>p+length-1 then return false end
        local count=u32(data,q) or 0;local base=q+4
        if base+count*4-1>p+length-1 then return false end
        local lo,hi=0,count-1
        while lo<=hi do local m=floor((lo+hi)/2);local r=base+m*4;local first=u24(data,r) or 0;local last=first+u8(data,r+3)
            if cp<first then hi=m-1 elseif cp>last then lo=m+1 else return true end end
        return false
    end
    local function nondefault_gid(off,cp)
        if off==0 then return nil end
        local q=p+off;if q+3>p+length-1 then return nil end
        local count=u32(data,q) or 0;local base=q+4
        if base+count*5-1>p+length-1 then return nil end
        local lo,hi=0,count-1
        while lo<=hi do local m=floor((lo+hi)/2);local r=base+m*5;local c=u24(data,r) or 0
            if cp<c then hi=m-1 elseif cp>c then lo=m+1 else return u16(data,r+3) or 0 end end
        return nil
    end
    return function(cp,selector)
        local r=find_record(selector);if not r then return nil,false end
        local gid=nondefault_gid(r.nondefault_off,cp)
        if gid~=nil then return gid,true,"nondefault" end
        if default_contains(r.default_off,cp) then return base_lookup(cp) or 0,true,"default" end
        return nil,false
    end
end

local function parse_cmap(t)
    local data=t["cmap"];if not data then return nil,"font has no cmap table" end
    local n=u16(data,3) or 0;local best;local variation_pos
    local format_score={[12]=900,[10]=850,[8]=800,[13]=750,[4]=700,[6]=600,[2]=500,[0]=400}
    for i=0,n-1 do
        local p=5+i*8;local platform=u16(data,p);local enc=u16(data,p+2);local off=u32(data,p+4)
        if off and off+2<=#data then
            local pos=off+1;local format=u16(data,pos)
            if format==14 and platform==0 and enc==5 then variation_pos=variation_pos or pos
            elseif format_score[format] then
                local unicode=false;local bonus=0
                if platform==0 then unicode=true;bonus=40
                elseif platform==3 and enc==10 then unicode=true;bonus=50
                elseif platform==3 and (enc==1 or enc==0) then unicode=true;bonus=30 end
                if unicode then
                    local score=format_score[format]+bonus
                    if not best or score>best.score then best={format=format,pos=pos,score=score,platform=platform,encoding=enc} end
                end
            end
        end
    end
    if not best then return nil,"no supported Unicode cmap subtable" end
    local lookup,err=parse_cmap_mapping(data,best.pos,best.format);if not lookup then return nil,err end
    local variation
    if variation_pos then variation,err=parse_cmap14(data,variation_pos,lookup);if not variation then return nil,err end end
    return lookup,nil,variation,{base_format=best.format,platform=best.platform,encoding=best.encoding,has_variations=variation~=nil}
end

-- Internal cmap parser entry point.
S._test_parse_cmap_table=function(data) return parse_cmap({cmap=data}) end

local function make_metrics(t,numGlyphs)
    local hhea=t["hhea"]; local hmtx=t["hmtx"]
    if not hhea or not hmtx then return nil,"font lacks horizontal metrics" end
    local count=u16(hhea,35) or 0
    if count<1 or count>numGlyphs then return nil,"invalid hhea numberOfHMetrics" end
    local advances,lsbs={},{}; local last=0
    for gid=0,numGlyphs-1 do
        if gid<count then
            local q=1+gid*4
            last=u16(hmtx,q) or last
            lsbs[gid]=s16(hmtx,q+2) or 0
        else
            local q=1+count*4+(gid-count)*2
            lsbs[gid]=s16(hmtx,q) or 0
        end
        advances[gid]=last
    end
    return advances,nil,lsbs
end

-- Vertical metrics mirror hhea/hmtx.
local function make_vertical_metrics(t,numGlyphs)
    local vhea=t["vhea"]; local vmtx=t["vmtx"]
    if not vhea or not vmtx then return nil,nil end
    local count=u16(vhea,35) or 0
    if count<1 or count>numGlyphs then return nil,nil,"invalid vhea numOfLongVerMetrics" end
    local advances,tsbs={},{}; local last=0
    for gid=0,numGlyphs-1 do
        if gid<count then
            local q=1+gid*4
            last=u16(vmtx,q) or last
            tsbs[gid]=s16(vmtx,q+2) or 0
        else
            local q=1+count*4+(gid-count)*2
            tsbs[gid]=s16(vmtx,q) or 0
        end
        advances[gid]=last
    end
    return advances,tsbs
end

local function flatten_quad(out,x0,y0,cx,cy,x1,y1)
    local length=sqrt((cx-x0)^2+(cy-y0)^2)+sqrt((x1-cx)^2+(y1-cy)^2)
    local steps=max(4,min(24,ceil(length/80)))
    for i=1,steps do local tt=i/steps; local q=1-tt
        out[#out+1]={x=q*q*x0+2*q*tt*cx+tt*tt*x1,y=q*q*y0+2*q*tt*cy+tt*tt*y1}
    end
end

local function flatten_cubic(out,x0,y0,c1x,c1y,c2x,c2y,x1,y1)
    local length=sqrt((c1x-x0)^2+(c1y-y0)^2)+sqrt((c2x-c1x)^2+(c2y-c1y)^2)+sqrt((x1-c2x)^2+(y1-c2y)^2)
    local steps=max(5,min(32,ceil(length/80)))
    for i=1,steps do local tt=i/steps; local q=1-tt
        out[#out+1]={x=q*q*q*x0+3*q*q*tt*c1x+3*q*tt*tt*c2x+tt*tt*tt*x1,
            y=q*q*q*y0+3*q*q*tt*c1y+3*q*tt*tt*c2y+tt*tt*tt*y1}
    end
end

local function quadratic_contour(points)
    if #points==0 then return {} end
    local seq={}
    for i=1,#points do
        local a=points[i]; local b=points[i%#points+1]
        seq[#seq+1]=a
        if not a.on and not b.on then seq[#seq+1]={x=(a.x+b.x)/2,y=(a.y+b.y)/2,on=true} end
    end
    local start
    for i,p in ipairs(seq) do if p.on then start=i; break end end
    if not start then return {} end
    local rot={}; for k=0,#seq-1 do rot[#rot+1]=seq[(start-1+k)%#seq+1] end
    local out={{x=rot[1].x,y=rot[1].y}}; local cx,cy=rot[1].x,rot[1].y; local i=2
    while i<=#rot do
        local p=rot[i]
        if p.on then out[#out+1]={x=p.x,y=p.y}; cx,cy=p.x,p.y; i=i+1
        else
            local e=(i<#rot) and rot[i+1] or rot[1]
            flatten_quad(out,cx,cy,p.x,p.y,e.x,e.y); cx,cy=e.x,e.y; i=i+2
        end
    end
    local first=out[1]; local last=out[#out]
    if not last or last.x~=first.x or last.y~=first.y then out[#out+1]={x=first.x,y=first.y} end
    return out
end


-- TrueType glyph-variation decoding -----------------------------------------
local function gvar_tuple_scalar(peak,start_tuple,end_tuple,coords)
    local scalar=1
    for i=1,#peak do
        local pk=peak[i] or 0
        if pk~=0 then
            local st,fin
            if start_tuple and end_tuple then st=start_tuple[i] or 0;fin=end_tuple[i] or 0
            elseif pk>0 then st,fin=0,1 else st,fin=-1,0 end
            local c=coords[i] or 0
            if st>pk or pk>fin or (st<0 and fin>0) then
                -- Malformed axis tents impose no restriction, matching the OpenType
                -- variation-store rule used elsewhere in this loader.
            elseif c==pk then
                -- full contribution on this axis
            elseif c<=st or c>=fin then return 0
            elseif c<pk then
                if pk==st then return 0 end
                scalar=scalar*(c-st)/(pk-st)
            else
                if fin==pk then return 0 end
                scalar=scalar*(fin-c)/(fin-pk)
            end
        end
    end
    return scalar
end

local function gvar_unpack_points(data,p,limit)
    if p>limit then return nil,p,false end
    local first=u8(data,p);p=p+1
    if first==0 then return nil,p,true end -- nil means "all points"
    local count
    if first>=0x80 then
        if p>limit then return nil,p,false end
        count=(first%0x80)*256+u8(data,p);p=p+1
    else count=first end
    local out={};local current=0
    while #out<count do
        if p>limit then return nil,p,false end
        local control=u8(data,p);p=p+1
        local words=control>=0x80;local run=control%0x80+1
        for _=1,run do
            if #out>=count then break end
            local d
            if words then if p+1>limit then return nil,p,false end;d=u16(data,p) or 0;p=p+2
            else if p>limit then return nil,p,false end;d=u8(data,p);p=p+1 end
            current=current+d;out[#out+1]=current
        end
    end
    return out,p,true
end

local function gvar_unpack_deltas(data,p,count,limit)
    local out={}
    while #out<count do
        if p>limit then return nil,p,false end
        local control=u8(data,p);p=p+1
        local zero=control>=0x80;local words=(control%0x80)>=0x40;local run=control%0x40+1
        for _=1,run do
            if #out>=count then break end
            local v=0
            if not zero then
                if words then if p+1>limit then return nil,p,false end;v=s16(data,p) or 0;p=p+2
                else if p>limit then return nil,p,false end;v=s8(data,p);p=p+1 end
            end
            out[#out+1]=v
        end
    end
    return out,p,true
end

local function iup_value(coord,c1,d1,c2,d2)
    if c1==c2 then return d1==d2 and d1 or 0 end
    local lo,hi=math.min(c1,c2),math.max(c1,c2)
    if coord<=lo then return c1<c2 and d1 or d2 end
    if coord>=hi then return c1>c2 and d1 or d2 end
    local q=(coord-c1)/(c2-c1)
    return d1+q*(d2-d1)
end

local function gvar_iup_axis(base_points,contours,explicit,axis)
    local out={};for k,v in pairs(explicit) do out[k]=v end
    for _,range in ipairs(contours or {}) do
        local first,last=range[1],range[2];local touched={}
        for i=first,last do if explicit[i]~=nil then touched[#touched+1]=i end end
        if #touched==1 then
            local d=explicit[touched[1]] or 0
            for i=first,last do if out[i]==nil then out[i]=d end end
        elseif #touched>1 then
            for ti=1,#touched do
                local a=touched[ti];local b=touched[ti%#touched+1]
                local i=a
                while true do
                    i=i+1;if i>last then i=first end
                    if i==b then break end
                    if out[i]==nil then
                        local pa,pb,pt=base_points[a+1],base_points[b+1],base_points[i+1]
                        if pa and pb and pt then
                            local ca=axis=="x" and pa.x or pa.y;local cb=axis=="x" and pb.x or pb.y;local ct=axis=="x" and pt.x or pt.y
                            out[i]=iup_value(ct,ca,explicit[a] or 0,cb,explicit[b] or 0)
                        end
                    end
                end
            end
        end
    end
    return out
end

local function parse_gvar_source(t,variation,numGlyphs)
    local data=t["gvar"];if not data or not variation then return nil end
    if (u16(data,1) or 0)~=1 then return nil end
    local axis_count=u16(data,5) or 0;local shared_count=u16(data,7) or 0
    if axis_count~=#(variation.axes or {}) then return nil end
    local shared_off=u32(data,9) or 0;local glyph_count=u16(data,13) or 0;local flags=u16(data,15) or 0;local array_off=u32(data,17) or 0
    if glyph_count==0 or array_off<=0 then return nil end
    local shared={};local sp=shared_off+1
    for i=1,shared_count do local tuple={};for a=1,axis_count do tuple[a]=f2dot14(data,sp);sp=sp+2 end;shared[i]=tuple end
    local long_offsets=flags%2==1;local offsets={};local op=21
    for gid=0,glyph_count do
        local v;if long_offsets then v=u32(data,op) or 0;op=op+4 else v=(u16(data,op) or 0)*2;op=op+2 end
        offsets[gid]=v
    end
    local array_base=array_off+1
    local cache={}
    local function tuple_deltas(gid,target_count,base_points,contour_ranges,is_composite,coords_override)
        if gid<0 or gid>=math.min(glyph_count,numGlyphs or glyph_count) then return nil,nil end
        local a,b=offsets[gid] or 0,offsets[gid+1] or 0;if b<=a then return nil,nil end
        -- Results depend only on this font instance and glyph topology; cache the net deltas
        -- after the first decode.
        local coords=coords_override or variation.normalized or {}
        local ck=tostring(gid)..":"..tostring(target_count)..":"..(is_composite and "c" or "s")
        for ai=1,axis_count do ck=ck..":"..string.format("%.8g",coords[ai] or 0) end
        if cache[ck] then return cache[ck][1],cache[ck][2] end
        local base=array_base+a;local limit=array_base+b-1
        if base+3>limit then return nil,nil end
        local count_field=u16(data,base) or 0;local tuple_count=count_field%0x1000;local shared_points_flag=count_field>=0x8000
        local data_off=u16(data,base+2) or 0;local hp=base+4;local headers={}
        for _=1,tuple_count do
            if hp+3>limit then break end
            local size=u16(data,hp) or 0;local index=u16(data,hp+2) or 0;hp=hp+4
            local embedded=index>=0x8000;local intermediate=(index%0x8000)>=0x4000;local private=(index%0x4000)>=0x2000
            local peak
            if embedded then peak={};for ai=1,axis_count do peak[ai]=f2dot14(data,hp);hp=hp+2 end
            else peak=shared[(index%0x1000)+1] end
            if not peak then peak={};for ai=1,axis_count do peak[ai]=0 end end
            local st,fin
            if intermediate then
                st={};fin={};for ai=1,axis_count do st[ai]=f2dot14(data,hp);hp=hp+2 end
                for ai=1,axis_count do fin[ai]=f2dot14(data,hp);hp=hp+2 end
            end
            headers[#headers+1]={size=size,peak=peak,start_tuple=st,end_tuple=fin,private=private}
        end
        local dp=base+data_off;local shared_points
        if shared_points_flag then local ok;shared_points,dp,ok=gvar_unpack_points(data,dp,limit);if not ok then return nil,nil end end
        local netx,nety={},{}
        for _,h in ipairs(headers) do
            local run_start=dp;local run_end=math.min(limit,run_start+h.size-1);dp=run_start+h.size
            local scalar=gvar_tuple_scalar(h.peak,h.start_tuple,h.end_tuple,coords)
            if scalar~=0 and run_start<=run_end then
                local p=run_start;local points=shared_points;local ok=true
                if h.private then points,p,ok=gvar_unpack_points(data,p,run_end) end
                if ok then
                    local n=points and #points or target_count;local xd,yd
                    xd,p,ok=gvar_unpack_deltas(data,p,n,run_end);if ok then yd,p,ok=gvar_unpack_deltas(data,p,n,run_end) end
                    if ok then
                        local ex,ey={},{}
                        if points then
                            for j,idx in ipairs(points) do ex[idx]=(ex[idx] or 0)+(xd[j] or 0);ey[idx]=(ey[idx] or 0)+(yd[j] or 0) end
                        else
                            for idx=0,target_count-1 do ex[idx]=xd[idx+1] or 0;ey[idx]=yd[idx+1] or 0 end
                        end
                        if not is_composite and points then
                            ex=gvar_iup_axis(base_points,contour_ranges,ex,"x");ey=gvar_iup_axis(base_points,contour_ranges,ey,"y")
                        end
                        for idx=0,target_count-1 do
                            local dx=ex[idx] or 0;local dy=ey[idx] or 0
                            if dx~=0 then netx[idx]=(netx[idx] or 0)+dx*scalar end
                            if dy~=0 then nety[idx]=(nety[idx] or 0)+dy*scalar end
                        end
                    end
                end
            end
        end
        cache[ck]={netx,nety};return netx,nety
    end
    return tuple_deltas, cache
end

local function parse_glyf_source(t, font, variation)
    local head=t["head"]; local loca=t["loca"]; local glyf=t["glyf"]
    if not head or not loca or not glyf then return nil,"TrueType outline tables are incomplete" end
    local format=s16(head,51) or 0; local numGlyphs=font._num_glyphs
    local offsets={}
    for gid=0,numGlyphs do offsets[gid]=(format==0 and (u16(loca,1+gid*2) or 0)*2 or (u32(loca,1+gid*4) or 0)) end
    local gvar_deltas,gvar_cache=parse_gvar_source(t,variation,numGlyphs)
    if gvar_cache then F._track_cache(font,gvar_cache) end

    local function flag(v,bit) return floor(v/bit)%2==1 end
    local function glyph_data(gid)
        if gid<0 or gid>=numGlyphs then return nil end
        local a,b=offsets[gid] or 0,offsets[gid+1] or 0
        if b<=a then return "",0,0 end
        return sub(glyf,a+1,b-a),a,b
    end

    -- USE_MY_METRICS changes the unhinted advance/side bearings too.
    local metric_source_cache={}
    F._track_cache(font,metric_source_cache)
    local metric_scanning={}
    local function metric_source(gid)
        local cached=metric_source_cache[gid];if cached~=nil then return cached end
        if metric_scanning[gid] then return gid end
        metric_scanning[gid]=true
        local d=glyph_data(gid);local chosen
        if d and #d>=10 and (s16(d,1) or 0)<0 then
            local p=11;local more=true
            while more and p+3<=#d do
                local flags=u16(d,p) or 0;local cg=u16(d,p+2) or 0;p=p+4
                p=p+(flag(flags,1) and 4 or 2)
                if flag(flags,8) then p=p+2 elseif flag(flags,64) then p=p+4 elseif flag(flags,128) then p=p+8 end
                if flag(flags,512) then chosen=cg end
                more=flag(flags,32)
            end
        end
        local resolved=chosen and metric_source(chosen) or gid
        metric_scanning[gid]=nil;metric_source_cache[gid]=resolved;return resolved
    end

    local raw_cache={};local decoding={}
    F._track_cache(font,raw_cache)
    local function coords_key(coords)
        coords=coords or variation.normalized or {};local k={}
        for i=1,#(variation.axes or {}) do k[#k+1]=string.format("%.8g",coords[i] or 0) end
        return table.concat(k,",")
    end
    local function flat_points(contours)
        local out={};for _,c in ipairs(contours or {}) do for _,pt in ipairs(c) do out[#out+1]=pt end end;return out
    end
    local function metric_phantoms(obj,gid)
        local mg=metric_source(gid);local aw=font._advances[mg] or font._advances[gid] or 0;local lsb=(font._lsbs and (font._lsbs[mg] or font._lsbs[gid])) or 0
        local pp1=(obj.xMin or 0)-lsb
        local ah=font._v_advances and (font._v_advances[mg] or font._v_advances[gid]) or nil
        local tsb=font._v_tsbs and (font._v_tsbs[mg] or font._v_tsbs[gid]) or nil
        local pp3,pp4
        if ah and tsb then
            -- TrueType phantom points n+2/n+3 represent the vertical origin and advance-height
            -- endpoint.
            pp3=(obj.yMax or 0)+tsb;pp4=pp3-ah
        else
            local asc=font.typo_ascent or font.ascent or font.units_per_em or 0
            local desc=font.typo_descent or font.descent or 0
            pp3=asc;pp4=desc
        end
        local vx=aw/2
        return {{x=pp1,y=0,on=true},{x=pp1+aw,y=0,on=true},{x=vx,y=pp3,on=true},{x=vx,y=pp4,on=true}}
    end
    local function apply_simple_gvar(obj,gid,contour_ranges,coords)
        if not gvar_deltas then return obj end
        local n=#(obj.points or {});local dx,dy=gvar_deltas(gid,n+4,obj.points or {},contour_ranges or {},false,coords)
        if not dx and not dy then return obj end
        for i=0,n-1 do local pt=obj.points[i+1];if pt then pt.x=pt.x+(dx and dx[i] or 0);pt.y=pt.y+(dy and dy[i] or 0) end end
        for j=1,4 do local pt=obj.phantoms[j];local idx=n+j-1;if pt then pt.x=pt.x+(dx and dx[idx] or 0);pt.y=pt.y+(dy and dy[idx] or 0) end end
        if n>0 then
            local x1,y1,x2,y2=obj.points[1].x,obj.points[1].y,obj.points[1].x,obj.points[1].y
            for i=2,n do local pt=obj.points[i];x1=math.min(x1,pt.x);y1=math.min(y1,pt.y);x2=math.max(x2,pt.x);y2=math.max(y2,pt.y) end
            obj.xMin,obj.yMin,obj.xMax,obj.yMax=x1,y1,x2,y2
        end
        return obj
    end

    local function transform_point(pt,xx,xy,yx,yy,dx,dy)
        -- TrueType stores xscale, scale01, scale10, yscale.
        return {x=pt.x*xx+pt.y*yx+dx,y=pt.x*xy+pt.y*yy+dy,on=pt.on}
    end
    local function point_at(points,phantoms,index,total_points)
        if index<0 then return nil end
        if index<#points then return points[index+1] end
        if total_points and index>=total_points then return phantoms[index-total_points+1] end
        return nil
    end

    local decode
    decode=function(gid,depth,coords)
        coords=coords or variation.normalized or {};local ck=tostring(gid).."@"..coords_key(coords)
        if raw_cache[ck] then return raw_cache[ck] end
        if decoding[ck] or (depth or 0)>64 then return {contours={},points={},phantoms={},xMin=0,yMin=0,xMax=0,yMax=0,metric_gid=gid} end
        decoding[ck]=true
        local d=glyph_data(gid)
        if not d or #d==0 then local empty={contours={},points={},contour_ranges={},instructions="",is_composite=false,xMin=0,yMin=0,xMax=0,yMax=0,metric_gid=metric_source(gid)};empty.phantoms=metric_phantoms(empty,gid);apply_simple_gvar(empty,gid,{},coords);raw_cache[ck]=empty;decoding[ck]=nil;return empty end
        local nc=s16(d,1) or 0
        local xMin,yMin,xMax,yMax=s16(d,3) or 0,s16(d,5) or 0,s16(d,7) or 0,s16(d,9) or 0
        if nc>=0 then
            local p=11;local ends={};for i=1,nc do ends[i]=u16(d,p) or 0;p=p+2 end
            local count=(ends[nc] or -1)+1
            local ilen=u16(d,p) or 0
            local instructions=(ilen>0 and p+1+ilen<=#d) and sub(d,p+2,ilen) or ""
            p=p+2+ilen
            local flags2={};local i=1
            while i<=count do
                local fl=u8(d,p);if fl==nil then break end;p=p+1;flags2[i]=fl
                if flag(fl,8) then local rep=u8(d,p) or 0;p=p+1;for _=1,rep do i=i+1;if i<=count then flags2[i]=fl end end end
                i=i+1
            end
            local xs={};local x=0;for j=1,count do local fl=flags2[j] or 0;local sh=flag(fl,2);local same=flag(fl,16);local dx;if sh then dx=u8(d,p) or 0;p=p+1;if not same then dx=-dx end elseif same then dx=0 else dx=s16(d,p) or 0;p=p+2 end;x=x+dx;xs[j]=x end
            local ys={};local y=0;for j=1,count do local fl=flags2[j] or 0;local sh=flag(fl,4);local same=flag(fl,32);local dy;if sh then dy=u8(d,p) or 0;p=p+1;if not same then dy=-dy end elseif same then dy=0 else dy=s16(d,p) or 0;p=p+2 end;y=y+dy;ys[j]=y end
            local cs={};local ranges={};local first=1;for ci=1,nc do local last=(ends[ci] or -1)+1;local c={};for j=first,last do c[#c+1]={x=xs[j],y=ys[j],on=flag(flags2[j] or 0,1)} end;cs[#cs+1]=c;ranges[#ranges+1]={first-1,last-1};first=last+1 end
            local obj={contours=cs,points=flat_points(cs),contour_ranges=ranges,instructions=instructions,is_composite=false,xMin=xMin,yMin=yMin,xMax=xMax,yMax=yMax,metric_gid=metric_source(gid)};obj.phantoms=metric_phantoms(obj,gid);apply_simple_gvar(obj,gid,ranges,coords);raw_cache[ck]=obj;decoding[ck]=nil;return obj
        end

        -- Parse component records first.
        local p=11;local records={};local more=true;local have_instructions=false
        while more and p+3<=#d do
            local flags=u16(d,p) or 0;local cg=u16(d,p+2) or 0;p=p+4
            local words=flag(flags,1);local args_xy=flag(flags,2);local a1,a2
            if words then
                if args_xy then a1=s16(d,p) or 0;a2=s16(d,p+2) or 0 else a1=u16(d,p) or 0;a2=u16(d,p+2) or 0 end
                p=p+4
            else
                local q1,q2=u8(d,p) or 0,u8(d,p+1) or 0;p=p+2
                if args_xy then a1=q1>=128 and q1-256 or q1;a2=q2>=128 and q2-256 or q2 else a1,a2=q1,q2 end
            end
            local xx,xy,yx,yy=1,0,0,1
            if flag(flags,8) then local sc=f2dot14(d,p) or 1;p=p+2;xx,yy=sc,sc
            elseif flag(flags,64) then xx=f2dot14(d,p) or 1;yy=f2dot14(d,p+2) or 1;p=p+4
            elseif flag(flags,128) then xx=f2dot14(d,p) or 1;xy=f2dot14(d,p+2) or 0;yx=f2dot14(d,p+4) or 0;yy=f2dot14(d,p+6) or 1;p=p+8 end
            records[#records+1]={flags=flags,gid=cg,args_xy=args_xy,a1=a1,a2=a2,xx=xx,xy=xy,yx=yx,yy=yy}
            if flag(flags,256) then have_instructions=true end
            more=flag(flags,32)
        end
        local instructions=""
        if have_instructions and p+1<=#d then
            local ilen=u16(d,p) or 0
            if ilen>0 and p+1+ilen<=#d then instructions=sub(d,p+2,ilen) end
            p=p+2+ilen
        end

        local total_points=0
        for _,r in ipairs(records) do r.child=decode(r.gid,(depth or 0)+1,coords);total_points=total_points+#(r.child.points or {}) end
        local obj={contours={},points={},contour_ranges={},instructions=instructions,is_composite=true,components=records,xMin=xMin,yMin=yMin,xMax=xMax,yMax=yMax,metric_gid=metric_source(gid)}
        obj.phantoms=metric_phantoms(obj,gid)
        local comp_dx,comp_dy
        if gvar_deltas then comp_dx,comp_dy=gvar_deltas(gid,#records+4,nil,nil,true,coords) end
        for j=1,4 do local idx=#records+j-1;local pt=obj.phantoms[j];if pt then pt.x=pt.x+(comp_dx and comp_dx[idx] or 0);pt.y=pt.y+(comp_dy and comp_dy[idx] or 0) end end
        -- Keep the composite's own variation-adjusted phantom points separate.
        obj.own_phantoms={}
        for j,pt in ipairs(obj.phantoms) do obj.own_phantoms[j]={x=pt.x,y=pt.y,on=true} end

        for ri,r in ipairs(records) do
            local child=r.child;local dx,dy=0,0
            local ci=ri-1
            r.var_dx=(r.args_xy and comp_dx and comp_dx[ci]) or 0
            r.var_dy=(r.args_xy and comp_dy and comp_dy[ci]) or 0
            if r.args_xy then
                dx,dy=r.a1+r.var_dx,r.a2+r.var_dy
                -- Microsoft/Apple and the OpenType recommendation use unscaled offsets when
                -- neither offset flag is present (and for invalid both-set input).
                if flag(r.flags,2048) and not flag(r.flags,4096) then
                    dx,dy=dx*r.xx+dy*r.yx,dx*r.xy+dy*r.yy
                end
                -- ROUND_XY_TO_GRID is a ppem-dependent hinting operation.
            end

            local transformed_contours={}
            for _,cc in ipairs(child.contours or {}) do
                local nc2={};for _,pt in ipairs(cc) do nc2[#nc2+1]=transform_point(pt,r.xx,r.xy,r.yx,r.yy,dx,dy) end;transformed_contours[#transformed_contours+1]=nc2
            end
            local transformed_points=flat_points(transformed_contours)
            local transformed_phantoms={};for _,pt in ipairs(child.phantoms or {}) do transformed_phantoms[#transformed_phantoms+1]=transform_point(pt,r.xx,r.xy,r.yx,r.yy,dx,dy) end

            if not r.args_xy then
                local pa=point_at(obj.points,obj.phantoms,r.a1,total_points)
                local pb=point_at(transformed_points,transformed_phantoms,r.a2,#transformed_points)
                if pa and pb then
                    local adx,ady=pa.x-pb.x,pa.y-pb.y
                    for _,cc in ipairs(transformed_contours) do for _,pt in ipairs(cc) do pt.x=pt.x+adx;pt.y=pt.y+ady end end
                    -- transformed_points aliases the contour point tables above.
                    for _,pt in ipairs(transformed_phantoms) do pt.x=pt.x+adx;pt.y=pt.y+ady end
                end
            end
            if flag(r.flags,512) and #transformed_phantoms>=2 then
                -- In a variable composite, USE_MY_METRICS overrides the composite's own phantom
                -- deltas with the interpolated component phantom positions.
                obj.phantoms=transformed_phantoms
            end
            for _,cc in ipairs(transformed_contours) do obj.contours[#obj.contours+1]=cc end
            -- Re-flatten from the contour copies.
            for _,pt in ipairs(transformed_points) do obj.points[#obj.points+1]=pt end
        end
        raw_cache[ck]=obj;decoding[ck]=nil;return obj
    end

    local function provider_at_coords(gid,coords)
        local raw=decode(gid,0,coords); local out={}
        for _,c in ipairs(raw.contours or {}) do
            local converted={}; for _,p in ipairs(c) do converted[#converted+1]={x=p.x,y=font.ascent-p.y,on=p.on} end
            local flat=quadratic_contour(converted); if #flat>0 then out[#out+1]=flat end
        end
        return out
    end
    local function provider(gid) return provider_at_coords(gid,variation.normalized or {}) end
    local function gvar_advance(gid)
        if not gvar_deltas then return nil end
        local raw=decode(gid,0);local a,b=raw.phantoms and raw.phantoms[1],raw.phantoms and raw.phantoms[2]
        if a and b then return b.x-a.x end
    end
    local function gvar_vertical(gid)
        if not gvar_deltas then return nil end
        local raw=decode(gid,0);local top,bottom=raw.phantoms and raw.phantoms[3],raw.phantoms and raw.phantoms[4]
        if top and bottom then return top.y,top.y-bottom.y end
    end
    local function design_bounds(gid)
        local raw=decode(gid,0);return raw.xMin or 0,raw.yMin or 0,raw.xMax or 0,raw.yMax or 0
    end
    local function hint_source(gid)
        return decode(gid,0)
    end
    return provider,nil,metric_source,gvar_advance,gvar_vertical,design_bounds,hint_source,provider_at_coords
end

-- OpenType variations -------------------------------------------------------
local function parse_fvar_axes(t)
    local data=t["fvar"];if not data then return {} end
    local off=u16(data,5) or 16;local count=u16(data,9) or 0;local size=u16(data,11) or 20
    local out={}
    for i=0,count-1 do
        local p=off+1+i*size;local tag=sub(data,p,4)
        local mn=fixed16_16(data,p+4) or 0;local def=fixed16_16(data,p+8) or 0;local mx=fixed16_16(data,p+12) or 0
        out[#out+1]={tag=tag,min=mn,default=def,max=mx,flags=u16(data,p+16) or 0,name_id=u16(data,p+18) or 0}
    end
    return out
end

local function avar_map_value(v,pairs)
    if not pairs or #pairs==0 then return v end
    if v<=pairs[1][1] then return pairs[1][2]+(v-pairs[1][1]) end
    for i=1,#pairs-1 do
        local a,b=pairs[i],pairs[i+1]
        if v>=a[1] and v<=b[1] then
            if b[1]==a[1] then return a[2] end
            local q=(v-a[1])/(b[1]-a[1]);return a[2]+q*(b[2]-a[2])
        end
    end
    local z=pairs[#pairs];return z[2]+(v-z[1])
end

local parse_item_variation_store,variation_store_delta,parse_delta_set_index_map

local function ot_normalized_round(v)
    -- OpenType normalized coordinates are ultimately F2DOT14.
    local q=floor(max(-1,min(1,v or 0))*16384+0.5)
    return max(-16384,min(16384,q))
end

local function parse_avar(t,axes)
    local data=t["avar"];local info={major=0,maps={}};if not data then return info end
    local major=u16(data,1) or 0;info.major=major
    if major~=1 and major~=2 then return info end
    local count=u16(data,7) or 0;local p=9
    -- avar v2 permits zero segment maps; otherwise the count is the fvar axis count and the
    -- encoding is identical to avar v1.
    for i=1,math.min(count,#axes) do
        local n=u16(data,p) or 0;p=p+2;local a={}
        for _=1,n do a[#a+1]={f2dot14(data,p),f2dot14(data,p+2)};p=p+4 end
        table.sort(a,function(x,y)return x[1]<y[1] end);info.maps[axes[i].tag]=a
    end
    if major==2 then
        if p+7>#data then info.v2_error="truncated avar v2 offsets";return info end
        local map_off=u32(data,p) or 0;local store_off=u32(data,p+4) or 0
        info.axis_index_map=(map_off~=0) and parse_delta_set_index_map(data,map_off+1) or nil
        if store_off~=0 then
            local store,err=parse_item_variation_store(data,store_off+1)
            if store then store._data=data;info.var_store=store else info.v2_error=err end
        end
    end
    return info
end

local function resolve_variations(t,options)
    local axes=parse_fvar_axes(t);local requested=options.variations or options.axes or {};local known={}
    for _,a in ipairs(axes) do known[a.tag]=true end
    for tag in pairs(requested) do if not known[tag] then return nil,"unknown variable-font axis "..tostring(tag) end end
    local avar=parse_avar(t,axes);local design,intermediate={},{}
    for i,a in ipairs(axes) do
        local v=requested[a.tag];if v==nil then v=a.default else v=tonumber(v);if not v then return nil,"invalid value for variable-font axis "..a.tag end end
        v=max(a.min,min(a.max,v));design[a.tag]=v
        local n
        if v==a.default then n=0 elseif v<a.default then local d=a.default-a.min;n=d~=0 and (v-a.default)/d or -1
        else local d=a.max-a.default;n=d~=0 and (v-a.default)/d or 1 end
        n=max(-1,min(1,n));n=avar_map_value(n,avar.maps[a.tag]);n=ot_normalized_round(n)/16384
        intermediate[i]=n;intermediate[a.tag]=n
    end
    local normalized={}
    if avar.major==2 and avar.var_store then
        -- avar2 deltas are stored in F2DOT14 units and are all evaluated from the same
        -- intermediate-coordinate vector.
        for i,a in ipairs(axes) do
            local outer,inner=0,i-1
            local map=avar.axis_index_map
            if map then
                local e=map[i-1] or map[map.count-1]
                if e then outer,inner=e[1],e[2] else outer,inner=0xFFFF,0xFFFF end
            end
            local base=ot_normalized_round(intermediate[i] or 0)
            local delta=variation_store_delta(avar.var_store,outer,inner,intermediate)
            local q=max(-16384,min(16384,base+floor(delta+0.5)))
            normalized[i]=q/16384;normalized[a.tag]=normalized[i]
        end
    else
        for i,a in ipairs(axes) do normalized[i]=intermediate[i];normalized[a.tag]=intermediate[i] end
    end
    return {axes=axes,design=design,normalized=normalized,intermediate_normalized=intermediate,requested=requested,avar_version=avar.major,avar_v2_error=avar.v2_error}
end

local function region_scalar(region,coords)
    local s=1
    for i,a in ipairs(region or {}) do
        local start,peak,finish=a[1],a[2],a[3];local c=coords[i] or 0
        if peak~=0 then
            if start>peak or peak>finish or (start<0 and finish>0) then
                -- Malformed region axis: OpenType says it contributes no restriction rather
                -- than making the whole store unusable.
            elseif c==peak then
                -- factor 1
            elseif c<=start or c>=finish then return 0
            elseif c<peak then
                if peak==start then return 0 end;s=s*(c-start)/(peak-start)
            else
                if finish==peak then return 0 end;s=s*(finish-c)/(finish-peak)
            end
        end
    end
    return s
end

parse_item_variation_store=function(data,base)
    if not base or base<1 or base>#data then return nil,"invalid ItemVariationStore offset" end
    local fmt=u16(data,base) or 0;if fmt~=1 then return nil,"unsupported ItemVariationStore format "..fmt end
    local rlo=u32(data,base+2);local count=u16(data,base+6) or 0;if not rlo then return nil,"truncated ItemVariationStore" end
    local rb=base+rlo;local axis_count=u16(data,rb) or 0;local region_count=u16(data,rb+2) or 0;local p=rb+4;local regions={}
    for r=1,region_count do local aa={};for _=1,axis_count do aa[#aa+1]={f2dot14(data,p),f2dot14(data,p+2),f2dot14(data,p+4)};p=p+6 end;regions[r]=aa end
    local store={regions=regions,var_data={},axis_count=axis_count}
    for i=0,count-1 do
        local off=u32(data,base+8+i*4);if off and off>0 then
            local q=base+off;local items=u16(data,q) or 0;local word_raw=u16(data,q+2) or 0;local region_n=u16(data,q+4) or 0
            local long_words=word_raw>=0x8000;local word_count=word_raw%0x8000;local idx={};local z=q+6
            for j=1,region_n do idx[j]=u16(data,z) or 0;z=z+2 end
            local recsize=word_count*(long_words and 4 or 2)+(region_n-word_count)*(long_words and 2 or 1)
            store.var_data[i+1]={item_count=items,word_count=word_count,long_words=long_words,region_indices=idx,data_pos=z,record_size=recsize}
        end
    end
    return store
end

variation_store_delta=function(store,outer,inner,coords)
    if not store then return 0 end;local vd=store.var_data[(outer or 0)+1];if not vd or inner<0 or inner>=vd.item_count then return 0 end
    local p=vd.data_pos+inner*vd.record_size;local sum=0
    for j,ri in ipairs(vd.region_indices) do
        local d
        if vd.long_words then if j<=vd.word_count then d=s32(store._data or "",p);p=p+4 else d=s16(store._data or "",p);p=p+2 end
        else if j<=vd.word_count then d=s16(store._data or "",p);p=p+2 else d=s8(store._data or "",p);p=p+1 end end
        d=d or 0;local sc=region_scalar(store.regions[ri+1],coords);if sc~=0 then sum=sum+d*sc end
    end
    return sum
end

parse_delta_set_index_map=function(data,base)
    if not base or base<1 or base>#data then return nil end
    local fmt=u8(data,base);local ef=u8(data,base+1);local count,p
    if fmt==0 then count=u16(data,base+2) or 0;p=base+4 elseif fmt==1 then count=u32(data,base+2) or 0;p=base+6 else return nil end
    local entry_size=floor(ef/16)%4+1;local inner_bits=(ef%16)+1;local map={count=count}
    for i=0,count-1 do local v=0;for _=1,entry_size do v=v*256+u8(data,p);p=p+1 end;map[i]={floor(v/2^inner_bits),v%2^inner_bits} end
    return map
end

S._resolve_variations_for_test=resolve_variations

local function parse_hvar(t,variation)
    local data=t["HVAR"];if not data or not variation then return nil end
    local so=u32(data,5);if not so then return nil end;local store=parse_item_variation_store(data,so+1);if not store then return nil end;store._data=data
    local mo=u32(data,9);local map=mo and mo~=0 and parse_delta_set_index_map(data,mo+1) or nil
    return function(gid)
        local outer,inner=0,gid;if map then local e=map[gid] or map[map.count-1];if e then outer,inner=e[1],e[2] end end
        return variation_store_delta(store,outer,inner,variation.normalized)
    end
end

local function parse_vvar(t,variation)
    local data=t["VVAR"];if not data or not variation then return nil end
    local so=u32(data,5);if not so or so==0 then return nil end
    local store=parse_item_variation_store(data,so+1);if not store then return nil end;store._data=data
    local function accessor(offset_pos,implicit)
        local mo=u32(data,offset_pos);local map=mo and mo~=0 and parse_delta_set_index_map(data,mo+1) or nil
        if not map and not implicit then return nil end
        return function(gid)
            local outer,inner=0,gid
            if map then local e=map[gid] or map[map.count-1];if not e then return 0 end;outer,inner=e[1],e[2] end
            return variation_store_delta(store,outer,inner,variation.normalized)
        end
    end
    return {
        advance=accessor(9,true),
        tsb=accessor(13,false),
        bsb=accessor(17,false),
        vorg=accessor(21,false),
    }
end

local function parse_vorg(t)
    local data=t["VORG"];if not data or #data<8 then return nil end
    if (u16(data,1) or 0)~=1 then return nil end
    local default_y=s16(data,5) or 0;local count=u16(data,7) or 0;local entries={}
    for i=0,count-1 do
        local p=9+i*4;local gid=u16(data,p);local y=s16(data,p+2)
        if gid and y then entries[gid]=y end
    end
    return {default_y=default_y,entries=entries,count=count,get=function(self,gid) local v=self.entries[gid];if v==nil then return self.default_y end;return v end}
end

local function parse_mvar(t,variation)
    local data=t["MVAR"];if not data or not variation then return {} end
    local major=u16(data,1) or 0;if major~=1 then return {} end
    local recsize=u16(data,7) or 0;local count=u16(data,9) or 0;local so=u16(data,11) or 0
    if recsize<8 or count==0 or so==0 then return {} end
    local store=parse_item_variation_store(data,so+1);if not store then return {} end;store._data=data
    local out={}
    for i=0,count-1 do
        local p=13+i*recsize;local tg=sub(data,p,4);local outer=u16(data,p+4) or 0;local inner=u16(data,p+6) or 0
        out[tg]=variation_store_delta(store,outer,inner,variation.normalized)
    end
    return out
end

local function parse_gasp(t,mvar)
    local data=t["gasp"];if not data or #data<4 then return nil end
    local version=u16(data,1);local count=u16(data,3) or 0
    if version~=0 and version~=1 then return nil end
    if #data<4+count*4 then return nil end
    local ranges={};local prev=-1
    for i=0,count-1 do
        local p=5+i*4;local maxppem=u16(data,p) or 0;local flags=u16(data,p+2) or 0
        -- OpenType variations may adjust the first ten non-final gasp range thresholds through
        -- MVAR tags gsp0..gsp9.
        if i<count-1 and i<10 and mvar then
            local d=tonumber(mvar["gsp"..i]) or 0
            maxppem=max(0,min(0xFFFF,(d>=0 and floor(maxppem+d+0.5) or ceil(maxppem+d-0.5))))
        end
        if maxppem<prev then maxppem=prev end;prev=maxppem
        ranges[#ranges+1]={max_ppem=maxppem,flags=flags}
    end
    local function behavior(ppem)
        ppem=max(0,tonumber(ppem) or 0)
        local rec
        for _,r in ipairs(ranges) do if ppem<=r.max_ppem then rec=r;break end end
        rec=rec or ranges[#ranges];if not rec then return nil end
        local f=rec.flags or 0
        return {version=version,max_ppem=rec.max_ppem,flags=f,
            gridfit=f%2==1,gray=floor(f/2)%2==1,
            symmetric_gridfit=version>=1 and floor(f/4)%2==1 or false,
            symmetric_smoothing=version>=1 and floor(f/8)%2==1 or false}
    end
    return {version=version,ranges=ranges,behavior=behavior}
end
S._parse_gasp_for_test=parse_gasp

local function sfnt_global_metrics(t,hhea,mvar)
    mvar=mvar or {};local os2=t["OS/2"];local post=t["post"];local vhea=t["vhea"]
    local hhea_ascent=s16(hhea,5) or 0;local hhea_descent=s16(hhea,7) or 0;local hhea_gap=s16(hhea,9) or 0
    local out={ascent=hhea_ascent,descent=hhea_descent,line_gap=hhea_gap,metrics_source="hhea"}
    out.caret_slope_rise=(s16(hhea,19) or 1)+(mvar.hcrs or 0)
    out.caret_slope_run=(s16(hhea,21) or 0)+(mvar.hcrn or 0)
    out.caret_offset=(s16(hhea,23) or 0)+(mvar.hcof or 0)
    if os2 and #os2>=78 then
        local ver=u16(os2,1) or 0
        local fs=u16(os2,63) or 0
        out.use_typo_metrics=ver>=4 and floor(fs/128)%2==1
        out.typo_ascent=(s16(os2,69) or hhea_ascent)+(mvar.hasc or 0)
        out.typo_descent=(s16(os2,71) or hhea_descent)+(mvar.hdsc or 0)
        out.typo_line_gap=(s16(os2,73) or hhea_gap)+(mvar.hlgp or 0)
        out.win_ascent=(u16(os2,75) or 0)+(mvar.hcla or 0)
        out.win_descent=(u16(os2,77) or 0)+(mvar.hcld or 0)
        out.subscript_x_size=(s16(os2,11) or 0)+(mvar.sbxs or 0)
        out.subscript_y_size=(s16(os2,13) or 0)+(mvar.sbys or 0)
        out.subscript_x_offset=(s16(os2,15) or 0)+(mvar.sbxo or 0)
        out.subscript_y_offset=(s16(os2,17) or 0)+(mvar.sbyo or 0)
        out.superscript_x_size=(s16(os2,19) or 0)+(mvar.spxs or 0)
        out.superscript_y_size=(s16(os2,21) or 0)+(mvar.spys or 0)
        out.superscript_x_offset=(s16(os2,23) or 0)+(mvar.spxo or 0)
        out.superscript_y_offset=(s16(os2,25) or 0)+(mvar.spyo or 0)
        out.strikeout_size=(s16(os2,27) or 0)+(mvar.strs or 0)
        out.strikeout_position=(s16(os2,29) or 0)+(mvar.stro or 0)
        if ver>=2 and #os2>=90 then
            out.x_height=(s16(os2,87) or 0)+(mvar.xhgt or 0)
            out.cap_height=(s16(os2,89) or 0)+(mvar.cpht or 0)
        end
        if out.use_typo_metrics then
            out.ascent=out.typo_ascent;out.descent=out.typo_descent;out.line_gap=out.typo_line_gap;out.metrics_source="OS/2 typo"
        end
    end
    if post and #post>=12 then
        out.underline_position=(s16(post,9) or 0)+(mvar.undo or 0)
        out.underline_thickness=(s16(post,11) or 0)+(mvar.unds or 0)
    end
    if vhea and #vhea>=24 then
        out.vertical_ascent=(s16(vhea,5) or 0)+(mvar.vasc or 0)
        out.vertical_descent=(s16(vhea,7) or 0)+(mvar.vdsc or 0)
        out.vertical_line_gap=(s16(vhea,9) or 0)+(mvar.vlgp or 0)
        out.vertical_caret_slope_rise=(s16(vhea,19) or 0)+(mvar.vcrs or 0)
        out.vertical_caret_slope_run=(s16(vhea,21) or 1)+(mvar.vcrn or 0)
        out.vertical_caret_offset=(s16(vhea,23) or 0)+(mvar.vcof or 0)
    end
    out.mvar_deltas=mvar
    return out
end

-- CFF INDEX parsing ----------------------------------------------------------
local function cff_index(data,pos,cff2)
    local count;if cff2 then count=u32(data,pos) or 0;pos=pos+4 else count=u16(data,pos) or 0;pos=pos+2 end
    if count==0 then return {},pos end
    local os=u8(data,pos);pos=pos+1
    local offs={}
    for i=1,count+1 do local v=0;for _=1,os do v=v*256+u8(data,pos);pos=pos+1 end;offs[i]=v end
    local base=pos;local items={}
    for i=1,count do items[i]=sub(data,base+offs[i]-1,offs[i+1]-offs[i]) end
    return items,base+offs[count+1]-1
end

local function cff_number(data,pos)
    local b=u8(data,pos);pos=pos+1
    if b>=32 and b<=246 then return b-139,pos
    elseif b>=247 and b<=250 then local b1=u8(data,pos);return (b-247)*256+b1+108,pos+1
    elseif b>=251 and b<=254 then local b1=u8(data,pos);return -(b-251)*256-b1-108,pos+1
    elseif b==28 then return s16(data,pos),pos+2
    elseif b==29 then return s32(data,pos),pos+4
    elseif b==255 then return (s32(data,pos) or 0)/65536,pos+4
    elseif b==30 then
        local chars={}; local done=false
        while not done do local bb=u8(data,pos);pos=pos+1;for _,n in ipairs({floor(bb/16),bb%16}) do
            if n<=9 then chars[#chars+1]=tostring(n) elseif n==10 then chars[#chars+1]="." elseif n==11 then chars[#chars+1]="E" elseif n==12 then chars[#chars+1]="E-" elseif n==14 then chars[#chars+1]="-" elseif n==15 then done=true;break end
        end end
        return tonumber(table.concat(chars)) or 0,pos
    end
    return nil,pos-1
end

local function cff_dict(data)
    local out={};local stack={};local p=1
    while p<=#data do
        local b=u8(data,p)
        if b>=28 or b>=32 then local n,np=cff_number(data,p);stack[#stack+1]=n;p=np
        else
            p=p+1;local op=tostring(b);if b==12 then op="12."..tostring(u8(data,p));p=p+1 end
            out[op]=stack;stack={}
        end
    end
    return out
end

local function cff_subr_bias(n) if n<1240 then return 107 elseif n<33900 then return 1131 else return 32768 end end

local function parse_cff_source(t,font,cff2,variation)
    local data=cff2 and t["CFF2"] or t["CFF "]; if not data then return nil,cff2 and "no CFF2 table" or "no CFF table" end
    local top,gsubrs,pos
    if cff2 then
        local hdr=u8(data,3) or 5;local top_len=u16(data,4) or 0
        if top_len<=0 or hdr+top_len>#data then return nil,"invalid CFF2 top dict" end
        top=cff_dict(sub(data,hdr+1,top_len));pos=hdr+top_len+1;gsubrs,pos=cff_index(data,pos,true)
    else
        local hdr=u8(data,3) or 4;pos=hdr+1
        local names;names,pos=cff_index(data,pos)
        local tops;tops,pos=cff_index(data,pos)
        local strings;strings,pos=cff_index(data,pos)
        gsubrs,pos=cff_index(data,pos)
        if not tops[1] then return nil,"CFF has no top dict" end
        top=cff_dict(tops[1])
    end
    local csOff=top["17"] and top["17"][1]
    if not csOff then return nil,cff2 and "CFF2 has no CharStrings" or "CFF has no CharStrings" end
    local charstrings=cff_index(data,csOff+1,cff2)

    local varstore
    if cff2 and top["24"] and top["24"][1] then
        local vb=top["24"][1]+1
        -- CFF2 wraps the OpenType ItemVariationStore in a Card16 byte-length.
        local declared=u16(data,vb) or 0
        if declared>0 and vb+1+declared<=#data+1 then
            varstore=parse_item_variation_store(data,vb+2)
            if varstore then varstore._data=data end
        end
    end

    local function private_subrs(dict)
        local pv=dict["18"]; if not pv or #pv<2 then return {},0 end
        local size,off=pv[1],pv[2]; local pd=cff_dict(sub(data,off+1,size)); local so=pd["19"] and pd["19"][1];local vsi=(pd["22"] and pd["22"][1]) or 0
        if not so then return {},vsi end
        local arr=cff_index(data,off+so+1,cff2); return arr,vsi
    end
    local default_subrs,default_vsindex=private_subrs(top)
    local fdarray,fdselect
    if top["12.36"] then
        local fds=cff_index(data,top["12.36"][1]+1,cff2);fdarray={}
        for i,d in ipairs(fds) do local ent={dict=cff_dict(d)};ent.subrs,ent.vsindex=private_subrs(ent.dict);fdarray[i-1]=ent end
        if top["12.37"] then
            local fs=top["12.37"][1]+1;local fmt=u8(data,fs);fs=fs+1;fdselect={format=fmt,pos=fs}
            if fmt==0 then local a={};for gid=0,font._num_glyphs-1 do a[gid]=u8(data,fs+gid) end;fdselect.map=a
            elseif fmt==3 then local nr=u16(data,fs) or 0;fs=fs+2;local ranges={};for _=1,nr do ranges[#ranges+1]={u16(data,fs),u8(data,fs+2)};fs=fs+3 end;local sentinel=u16(data,fs) or font._num_glyphs;fdselect.ranges=ranges;fdselect.sentinel=sentinel
            elseif fmt==4 then local nr=u32(data,fs) or 0;fs=fs+4;local ranges={};for _=1,nr do ranges[#ranges+1]={u32(data,fs),u16(data,fs+4)};fs=fs+6 end;local sentinel=u32(data,fs) or font._num_glyphs;fdselect.ranges=ranges;fdselect.sentinel=sentinel end
        end
    end
    local function local_info_for(gid)
        if fdarray and not fdselect then local ent=fdarray[0];return (ent and ent.subrs) or default_subrs,(ent and ent.vsindex) or default_vsindex end
        if not fdarray or not fdselect then return default_subrs,default_vsindex end
        local fd=0
        if fdselect.format==0 then fd=fdselect.map[gid] or 0 elseif fdselect.format==3 or fdselect.format==4 then for i,r in ipairs(fdselect.ranges or {}) do local nxt=(fdselect.ranges[i+1] and fdselect.ranges[i+1][1]) or fdselect.sentinel;if gid>=r[1] and gid<nxt then fd=r[2];break end end end
        local ent=fdarray[fd];return (ent and ent.subrs) or default_subrs,(ent and ent.vsindex) or default_vsindex
    end

    local cache={}
    F._track_cache(font,cache)
    local function cff_coords_key(coords)
        coords=coords or (variation and variation.normalized) or {};local k={}
        for i=1,#((variation and variation.axes) or {}) do k[#k+1]=string.format("%.8g",coords[i] or 0) end
        return table.concat(k,",")
    end
    local function decode(gid,coords_override)
        local coords=coords_override or (variation and variation.normalized) or {};local ck=tostring(gid).."@"..cff_coords_key(coords)
        if cache[ck] then return cache[ck] end
        local bytes=charstrings[gid+1]; if not bytes then cache[ck]={};return cache[ck] end
        local contours={}; local current=nil; local x,y=0,0; local stack={}; local stems=0; local width_seen=cff2 and true or false
        local lsubrs,vsindex=local_info_for(gid);vsindex=vsindex or 0
        local function begin(dx,dy) x=x+dx;y=y+dy;current={{x=x,y=y}};contours[#contours+1]=current end
        local function line(dx,dy) x=x+dx;y=y+dy;if not current then current={{x=x,y=y}};contours[#contours+1]=current else current[#current+1]={x=x,y=y} end end
        local function curve(dx1,dy1,dx2,dy2,dx3,dy3)
            if not current then current={{x=x,y=y}};contours[#contours+1]=current end
            local x0,y0=x,y;local c1x,c1y=x+dx1,y+dy1;local c2x,c2y=c1x+dx2,c1y+dy2;local nx,ny=c2x+dx3,c2y+dy3
            flatten_cubic(current,x0,font.ascent-y0,c1x,font.ascent-c1y,c2x,font.ascent-c2y,nx,font.ascent-ny)
            -- flatten_cubic above is already in y-down; existing current points need normalization too.
            x,y=nx,ny
        end
        local function normalize_current_start()
            if current and current[1] and current[1]._raw then current[1].y=font.ascent-current[1].y;current[1]._raw=nil end
        end
        local function push_start(dx,dy) x=x+dx;y=y+dy;current={{x=x,y=font.ascent-y}};contours[#contours+1]=current end
        begin=push_start
        line=function(dx,dy) x=x+dx;y=y+dy;if not current then current={{x=x,y=font.ascent-y}};contours[#contours+1]=current else current[#current+1]={x=x,y=font.ascent-y} end end
        curve=function(dx1,dy1,dx2,dy2,dx3,dy3)
            if not current then current={{x=x,y=font.ascent-y}};contours[#contours+1]=current end
            local x0,y0=x,y;local c1x,c1y=x+dx1,y+dy1;local c2x,c2y=c1x+dx2,c1y+dy2;local nx,ny=c2x+dx3,c2y+dy3
            flatten_cubic(current,x0,font.ascent-y0,c1x,font.ascent-c1y,c2x,font.ascent-c2y,nx,font.ascent-ny);x,y=nx,ny
        end
        local function maybe_width(stem_or_move,need)
            if width_seen then return end
            local extra=false
            if stem_or_move=="stem" then extra=(#stack%2)==1 else extra=#stack>need end
            if extra then table.remove(stack,1) end
            width_seen=true
        end
        local function blend_stack()
            local n=floor(tonumber(table.remove(stack)) or 0);if n<=0 then return end
            local vd=varstore and varstore.var_data[vsindex+1];local regions=(vd and vd.region_indices) or {};local nr=#regions
            local total=n*(nr+1);local start=#stack-total+1;if start<1 then stack={};return end
            local vals={};for k=0,n-1 do
                local v=stack[start+k] or 0;local db=start+n+k*nr
                for j=1,nr do local sc=region_scalar(varstore.regions[(regions[j] or 0)+1],coords);v=v+(stack[db+j-1] or 0)*sc end
                vals[#vals+1]=v
            end
            for i=#stack,start,-1 do stack[i]=nil end;for _,v in ipairs(vals) do stack[#stack+1]=v end
        end
        local function exec(code,depth)
            if depth>24 then return end
            local p=1
            while p<=#code do
                local b=u8(code,p)
                if b==28 or b>=32 then local n,np=cff_number(code,p);stack[#stack+1]=n;p=np
                elseif b==12 then
                    local op=u8(code,p+1);p=p+2
                    if op==34 then maybe_width("move",8);local a=stack;curve(a[1],0,a[2],a[3],a[4],0);curve(a[5],0,a[6],a[7],a[8],0);stack={}
                    elseif op==35 then maybe_width("move",13);local a=stack;curve(a[1],a[2],a[3],a[4],a[5],a[6]);curve(a[7],a[8],a[9],a[10],a[11],a[12]);stack={}
                    elseif op==36 then maybe_width("move",9);local a=stack;curve(a[1],a[2],a[3],a[4],a[5],0);curve(a[6],0,a[7],a[8],a[9],-(a[2]+a[4]+a[8]));stack={}
                    elseif op==37 then maybe_width("move",11);local a=stack;local sx,sy=0,0;for i=1,10,2 do sx=sx+a[i];sy=sy+a[i+1] end;local d=a[11];local dx6,dy6;if abs(sx)>abs(sy) then dx6=d;dy6=-sy else dx6=-sx;dy6=d end;curve(a[1],a[2],a[3],a[4],a[5],a[6]);curve(a[7],a[8],a[9],a[10],dx6,dy6);stack={}
                    else stack={} end
                else
                    p=p+1
                    if b==1 or b==3 or b==18 or b==23 then maybe_width("stem",0);stems=stems+floor(#stack/2);stack={}
                    elseif b==4 then maybe_width("move",1);begin(0,stack[#stack] or 0);stack={}
                    elseif b==5 then for i=1,#stack,2 do line(stack[i] or 0,stack[i+1] or 0) end;stack={}
                    elseif b==6 or b==7 then local horiz=b==6;for i=1,#stack do if horiz then line(stack[i],0) else line(0,stack[i]) end;horiz=not horiz end;stack={}
                    elseif b==8 then for i=1,#stack,6 do curve(stack[i] or 0,stack[i+1] or 0,stack[i+2] or 0,stack[i+3] or 0,stack[i+4] or 0,stack[i+5] or 0) end;stack={}
                    elseif b==10 or b==29 then local idx=table.remove(stack) or 0;local arr=b==10 and lsubrs or gsubrs;local si=idx+cff_subr_bias(#arr)+1;if arr[si] then exec(arr[si],depth+1) end
                    elseif b==11 then return
                    elseif cff2 and b==15 then vsindex=floor(tonumber(table.remove(stack)) or 0);if vsindex<0 then vsindex=0 end
                    elseif cff2 and b==16 then blend_stack()
                    elseif b==14 then stack={};return
                    elseif b==19 or b==20 then maybe_width("stem",0);stems=stems+floor(#stack/2);stack={};p=p+ceil(stems/8)
                    elseif b==21 then maybe_width("move",2);begin(stack[#stack-1] or 0,stack[#stack] or 0);stack={}
                    elseif b==22 then maybe_width("move",1);begin(stack[#stack] or 0,0);stack={}
                    elseif b==24 then local n=#stack;local i=1;while i<=n-2 do curve(stack[i],stack[i+1],stack[i+2],stack[i+3],stack[i+4],stack[i+5]);i=i+6 end;line(stack[n-1] or 0,stack[n] or 0);stack={}
                    elseif b==25 then local n=#stack;local i=1;while i<=n-6 do line(stack[i],stack[i+1]);i=i+2 end;curve(stack[n-5] or 0,stack[n-4] or 0,stack[n-3] or 0,stack[n-2] or 0,stack[n-1] or 0,stack[n] or 0);stack={}
                    elseif b==26 or b==27 then local vertical=b==26;local i=1;local extra=(#stack%4)==1 and stack[1] or 0;if extra~=0 then i=2 end;while i<=#stack-3 do if vertical then curve(extra,stack[i],stack[i+1],stack[i+2],0,stack[i+3]) else curve(stack[i],extra,stack[i+1],stack[i+2],stack[i+3],0) end;extra=0;i=i+4 end;stack={}
                    elseif b==30 or b==31 then local horiz=b==31;local i=1;while i<=#stack-3 do local a,c,d,e=stack[i],stack[i+1],stack[i+2],stack[i+3];local rem=#stack-(i+3);local extra=(rem==1) and stack[i+4] or 0;if horiz then curve(a,0,c,d,extra,e) else curve(0,a,c,d,e,extra) end;i=i+4;if rem==1 then i=i+1 end;horiz=not horiz end;stack={}
                    else stack={} end
                end
            end
        end
        exec(bytes,0)
        for _,c in ipairs(contours) do if #c>1 then local f,l=c[1],c[#c];if f.x~=l.x or f.y~=l.y then c[#c+1]={x=f.x,y=f.y} end end end
        cache[ck]=contours;return contours
    end
    local function provider(gid) return decode(gid,(variation and variation.normalized) or {}) end
    return provider,decode
end



-- PNG + CBDT/CBLC ----------------------------------------------------------
local PNG_SIG="\137PNG\r\n\26\n"
local function paeth(a,b,c)
    local p=a+b-c;local pa=abs(p-a);local pb=abs(p-b);local pc=abs(p-c)
    if pa<=pb and pa<=pc then return a elseif pb<=pc then return b end;return c
end
local function decode_png_rgba(data)
    if type(data)~="string" or data:sub(1,8)~=PNG_SIG then return nil,"invalid embedded PNG signature" end
    local width,height,depth,color_type,interlace;local palette;local trns;local idat={};local p=9
    while p+11<=#data do
        local len=u32(data,p);if not len or len>0x7FFFFFFF or p+11+len>#data then return nil,"truncated embedded PNG chunk" end
        local typ=data:sub(p+4,p+7);local body=data:sub(p+8,p+7+len);p=p+12+len
        if typ=="IHDR" then
            if len~=13 then return nil,"invalid embedded PNG IHDR" end
            width=u32(body,1);height=u32(body,5);depth=u8(body,9);color_type=u8(body,10)
            if u8(body,11)~=0 or u8(body,12)~=0 then return nil,"unsupported embedded PNG compression/filter method" end
            interlace=u8(body,13)
        elseif typ=="PLTE" then
            if len%3~=0 then return nil,"invalid embedded PNG palette" end
            palette={};for i=1,len,3 do palette[#palette+1]={body:byte(i,i+2)} end
        elseif typ=="tRNS" then trns=body
        elseif typ=="IDAT" then idat[#idat+1]=body
        elseif typ=="IEND" then break
        end
    end
    if not width or not height or width<1 or height<1 or width*height>16777216 then return nil,"invalid or excessive embedded PNG dimensions" end
    local channels=({[0]=1,[2]=3,[3]=1,[4]=2,[6]=4})[color_type]
    if not channels then return nil,"unsupported embedded PNG color type "..tostring(color_type) end
    local valid=({[0]={[1]=true,[2]=true,[4]=true,[8]=true,[16]=true},[2]={[8]=true,[16]=true},[3]={[1]=true,[2]=true,[4]=true,[8]=true},[4]={[8]=true,[16]=true},[6]={[8]=true,[16]=true}})[color_type]
    if not valid or not valid[depth] then return nil,"unsupported embedded PNG bit depth" end
    if color_type==3 and not palette then return nil,"indexed embedded PNG lacks PLTE" end
    if interlace~=0 and interlace~=1 then return nil,"unsupported embedded PNG interlace method" end
    local compressed=table.concat(idat);if #compressed==0 then return nil,"embedded PNG has no IDAT" end
    local ok,raw=pcall(core.decompress,compressed,"deflate")
    if not ok or type(raw)~="string" then return nil,"unable to inflate embedded PNG" end
    local bitspp=channels*depth;local bpp=max(1,ceil(bitspp/8));local rp=1;local out={}
    local transparent_gray,transparent_rgb
    if trns and color_type==0 and #trns>=2 then transparent_gray=u16(trns,1)
    elseif trns and color_type==2 and #trns>=6 then transparent_rgb={u16(trns,1),u16(trns,3),u16(trns,5)} end
    local function to8(v)
        if depth==8 then return v elseif depth==16 then return floor((v*255+32767)/65535) end
        return floor(v*255/(2^depth-1)+.5)
    end
    local function row_sample(row,x,c)
        if depth==8 then return row[x*channels+c+1] or 0 end
        if depth==16 then local q=(x*channels+c)*2+1;return (row[q] or 0)*256+(row[q+1] or 0) end
        local bit=x*depth;local q=floor(bit/8)+1;local shift=8-depth-(bit%8);return floor((row[q] or 0)/(2^shift))%(2^depth)
    end
    local function pixel(row,x)
        if color_type==0 then
            local v=row_sample(row,x,0);local a=(transparent_gray and v==transparent_gray) and 0 or 255;local g=to8(v);return g,g,g,a
        elseif color_type==2 then
            local rv,gv,bv=row_sample(row,x,0),row_sample(row,x,1),row_sample(row,x,2);local a=255
            if transparent_rgb and rv==transparent_rgb[1] and gv==transparent_rgb[2] and bv==transparent_rgb[3] then a=0 end
            return to8(rv),to8(gv),to8(bv),a
        elseif color_type==3 then
            local idx=row_sample(row,x,0);local c=palette[idx+1] or {0,0,0};local a=trns and (trns:byte(idx+1) or 255) or 255;return c[1],c[2],c[3],a
        elseif color_type==4 then local g=row_sample(row,x,0);return to8(g),to8(g),to8(g),to8(row_sample(row,x,1))
        else return to8(row_sample(row,x,0)),to8(row_sample(row,x,1)),to8(row_sample(row,x,2)),to8(row_sample(row,x,3)) end
    end
    local function pass(x0,y0,dx,dy)
        if width<=x0 or height<=y0 then return true end
        local pw=floor((width-x0+dx-1)/dx);local ph=floor((height-y0+dy-1)/dy);local stride=ceil(pw*bitspp/8);local prev={}
        for py=0,ph-1 do
            local filter=raw:byte(rp);if filter==nil then return nil,"truncated embedded PNG scanline" end;rp=rp+1
            if rp+stride-1>#raw then return nil,"truncated embedded PNG scanline data" end
            local row={};for i=1,stride do
                local v=raw:byte(rp+i-1) or 0;local a=(i>bpp and row[i-bpp] or 0);local b=prev[i] or 0;local c=(i>bpp and (prev[i-bpp] or 0) or 0)
                if filter==1 then v=(v+a)%256 elseif filter==2 then v=(v+b)%256 elseif filter==3 then v=(v+floor((a+b)/2))%256 elseif filter==4 then v=(v+paeth(a,b,c))%256 elseif filter~=0 then return nil,"unsupported embedded PNG row filter" end
                row[i]=v
            end;rp=rp+stride
            local y=y0+py*dy
            for px=0,pw-1 do local x=x0+px*dx;local r,g,b,a=pixel(row,px);out[y*width+x+1]=string.char(r,g,b,a) end
            prev=row
        end
        return true
    end
    if interlace==0 then local ok2,e=pass(0,0,1,1);if not ok2 then return nil,e end
    else
        local passes={{0,0,8,8},{4,0,8,8},{0,4,4,8},{2,0,4,4},{0,2,2,4},{1,0,2,2},{0,1,1,2}}
        for _,q in ipairs(passes) do local ok2,e=pass(q[1],q[2],q[3],q[4]);if not ok2 then return nil,e end end
    end
    for i=1,width*height do if not out[i] then out[i]="\0\0\0\0" end end
    return {width=width,height=height,rgba=table.concat(out),source="png"}
end

S._test_decode_png_rgba=decode_png_rgba
S._decode_png_rgba=decode_png_rgba

-- JPEG --------------------------------------------------------------------
local JPEG_ZIG={
    1,2,9,17,10,3,4,11,
    18,25,33,26,19,12,5,6,
    13,20,27,34,41,49,42,35,
    28,21,14,7,8,15,22,29,
    36,43,50,57,58,51,44,37,
    30,23,16,24,31,38,45,52,
    59,60,53,46,39,32,40,47,
    54,61,62,55,48,56,63,64,
}
local JPEG_BASIS={}
do
    local invsqrt2=1/sqrt(2)
    for x=0,7 do
        local row={}
        for u=0,7 do row[u+1]=(u==0 and invsqrt2 or 1)*math.cos((2*x+1)*u*math.pi/16) end
        JPEG_BASIS[x+1]=row
    end
end

local function jpeg_huffman(counts,symbols)
    local h={};local code=0;local si=1
    for len=1,16 do
        local m={};h[len]=m
        for _=1,(counts[len] or 0) do m[code]=symbols[si];si=si+1;code=code+1 end
        code=code*2
    end
    return h
end

local function jpeg_reader(bytes)
    local p,bit=1,7
    local function one()
        if p>#bytes then return nil end
        local b=bytes:byte(p);local v=floor(b/(2^bit))%2
        bit=bit-1;if bit<0 then bit=7;p=p+1 end
        return v
    end
    local function bits(n)
        local v=0
        for _=1,n do local b=one();if b==nil then return nil end;v=v*2+b end
        return v
    end
    return {one=one,bits=bits}
end

local function jpeg_huff_decode(br,h)
    if not h then return nil end
    local code=0
    for len=1,16 do
        local b=br.one();if b==nil then return nil end;code=code*2+b
        local v=h[len] and h[len][code];if v~=nil then return v end
    end
    return nil
end

local function jpeg_extend(v,n)
    if n==0 then return 0 end
    local pivot=2^(n-1)
    if v<pivot then return v-(2^n-1) end
    return v
end

local function jpeg_entropy_end(data,p)
    local i=p
    while i<=#data do
        if data:byte(i)==0xFF then
            local j=i+1;while data:byte(j)==0xFF do j=j+1 end
            local m=data:byte(j)
            if not m then return #data+1 end
            if m==0x00 or (m>=0xD0 and m<=0xD7) then i=j+1 else return i end
        else i=i+1 end
    end
    return #data+1
end

local function jpeg_entropy_chunks(data,a,b)
    local chunks,out={},{};local p=a
    while p<=b do
        local v=data:byte(p)
        if v==0xFF then
            local n=data:byte(p+1)
            if n==0x00 then out[#out+1]=string.char(0xFF);p=p+2
            elseif n and n>=0xD0 and n<=0xD7 then chunks[#chunks+1]=table.concat(out);out={};p=p+2
            elseif n==0xFF then p=p+1
            else break end
        else out[#out+1]=string.char(v);p=p+1 end
    end
    chunks[#chunks+1]=table.concat(out)
    return chunks
end

local function jpeg_new_block()
    local c={};for i=1,64 do c[i]=0 end;return c
end

local function jpeg_idct(coeff,qt)
    local dc_only=true;for i=2,64 do if coeff[i]~=0 then dc_only=false;break end end
    local out={}
    if dc_only then
        local v=floor((coeff[1]*(qt[1] or 1))/8+128.5);v=max(0,min(255,v))
        for i=1,64 do out[i]=v end;return out
    end
    local temp={}
    for v=0,7 do
        for x=0,7 do
            local s=0
            for u=0,7 do
                local k=v*8+u+1;s=s+(coeff[k] or 0)*(qt[k] or 1)*JPEG_BASIS[x+1][u+1]
            end
            temp[v*8+x+1]=s
        end
    end
    for y=0,7 do
        for x=0,7 do
            local s=0
            for v=0,7 do s=s+temp[v*8+x+1]*JPEG_BASIS[y+1][v+1] end
            local q=floor(s/4+128.5);out[y*8+x+1]=max(0,min(255,q))
        end
    end
    return out
end

local function decode_jpeg_rgba(data)
    if type(data)~="string" or #data<4 or data:byte(1)~=0xFF or data:byte(2)~=0xD8 then return nil,"invalid embedded JPEG signature" end
    local qtables,hdc,hac={},{},{};local frame;local restart=0;local jfif=false;local adobe_transform
    local p=3
    local function segment(marker,body)
        if marker==0xDB then -- DQT
            local i=1
            while i<=#body do
                local info=body:byte(i);if not info then return nil,"truncated JPEG DQT" end;i=i+1
                local prec=floor(info/16);local id=info%16;if prec>1 or id>3 then return nil,"unsupported JPEG quantization table" end
                local qt={};local step=prec==0 and 1 or 2
                if i+64*step-1>#body then return nil,"truncated JPEG DQT values" end
                for k=1,64 do local v=prec==0 and body:byte(i) or u16(body,i);i=i+step;qt[JPEG_ZIG[k]]=v end
                qtables[id]=qt
            end
        elseif marker==0xC4 then -- DHT
            local i=1
            while i<=#body do
                local info=body:byte(i);if not info then return nil,"truncated JPEG DHT" end;i=i+1
                local cls,id=floor(info/16),info%16;if cls>1 or id>3 or i+15>#body then return nil,"invalid JPEG Huffman table" end
                local counts={};local total=0;for k=1,16 do counts[k]=body:byte(i) or 0;total=total+counts[k];i=i+1 end
                if i+total-1>#body then return nil,"truncated JPEG Huffman symbols" end
                local syms={};for k=1,total do syms[k]=body:byte(i);i=i+1 end
                if cls==0 then hdc[id]=jpeg_huffman(counts,syms) else hac[id]=jpeg_huffman(counts,syms) end
            end
        elseif marker==0xDD then restart=u16(body,1) or 0
        elseif marker==0xE0 and body:sub(1,5)=="JFIF\0" then jfif=true
        elseif marker==0xEE and body:sub(1,5)=="Adobe" and #body>=12 then adobe_transform=body:byte(12)
        elseif marker==0xC0 or marker==0xC1 or marker==0xC2 then
            if frame then return nil,"multiple JPEG frames are unsupported" end
            local precision=body:byte(1);local h=u16(body,2);local w=u16(body,4);local n=body:byte(6)
            if precision~=8 or not w or not h or w<1 or h<1 or w*h>16777216 or not n or n<1 or n>4 then return nil,"unsupported or excessive JPEG frame" end
            if 6+n*3>#body then return nil,"truncated JPEG frame components" end
            frame={width=w,height=h,progressive=marker==0xC2,components={},by_id={},max_h=0,max_v=0}
            local i=7
            for ci=1,n do
                local id=body:byte(i);local samp=body:byte(i+1);local tq=body:byte(i+2);i=i+3
                local hh=floor((samp or 0)/16);local vv=(samp or 0)%16
                if not id or hh<1 or hh>4 or vv<1 or vv>4 or tq>3 then return nil,"unsupported JPEG sampling factors" end
                local c={id=id,h=hh,v=vv,tq=tq,blocks={},dc_pred=0};frame.components[ci]=c;frame.by_id[id]=c;frame.max_h=max(frame.max_h,hh);frame.max_v=max(frame.max_v,vv)
            end
            frame.mcu_cols=ceil(w/(8*frame.max_h));frame.mcu_rows=ceil(h/(8*frame.max_v))
            for _,c in ipairs(frame.components) do
                c.block_stride=frame.mcu_cols*c.h;c.block_rows=frame.mcu_rows*c.v
                c.visible_blocks_x=ceil(w*c.h/(8*frame.max_h));c.visible_blocks_y=ceil(h*c.v/(8*frame.max_v))
            end
        end
        return true
    end

    local function block_for(c,bx,by)
        local idx=by*c.block_stride+bx+1;local b=c.blocks[idx]
        if not b then b=jpeg_new_block();c.blocks[idx]=b end
        return b
    end

    local function decode_scan(body,entropy_a,entropy_b)
        if not frame then return nil,"JPEG scan precedes frame header" end
        local ns=body:byte(1);if not ns or ns<1 or ns>#frame.components or 1+ns*2+3>#body then return nil,"invalid JPEG scan header" end
        local scan={};local i=2
        for si=1,ns do
            local id=body:byte(i);local tab=body:byte(i+1);i=i+2;local c=frame.by_id[id]
            if not c then return nil,"JPEG scan references unknown component" end
            scan[si]={c=c,dc=floor(tab/16),ac=tab%16}
        end
        local ss=body:byte(i) or 0;local se=body:byte(i+1) or 63;local ahal=body:byte(i+2) or 0;local ah=floor(ahal/16);local al=ahal%16
        if ss>63 or se>63 or ss>se or ah>13 or al>13 then return nil,"invalid JPEG spectral selection" end
        if not frame.progressive and (ss~=0 or se~=63 or ah~=0 or al~=0) then return nil,"unsupported sequential JPEG scan parameters" end
        if frame.progressive and ss>0 and ns~=1 then return nil,"progressive JPEG AC scans must be non-interleaved" end
        local chunks=jpeg_entropy_chunks(data,entropy_a,entropy_b);local chunk_i=1;local br=jpeg_reader(chunks[1] or "")
        local units_x,units_y
        if ns>1 then units_x,units_y=frame.mcu_cols,frame.mcu_rows
        else units_x,units_y=scan[1].c.visible_blocks_x,scan[1].c.visible_blocks_y end
        local predictors={};for _,s in ipairs(scan) do predictors[s.c.id]=0 end
        local eobrun=0;local unit_index=0
        local function restart_if_needed()
            if restart>0 and unit_index>0 and unit_index%restart==0 then
                chunk_i=chunk_i+1;br=jpeg_reader(chunks[chunk_i] or "");for _,s in ipairs(scan) do predictors[s.c.id]=0 end;eobrun=0
            end
        end
        local function read_value(n)
            if n==0 then return 0 end;local v=br.bits(n);if v==nil then return nil end;return jpeg_extend(v,n)
        end
        local function refine_existing(coeff,nat,p1)
            local v=coeff[nat] or 0;if v==0 then return true end
            local bit=br.one();if bit==nil then return nil end
            if bit==1 and floor(abs(v)/p1)%2==0 then coeff[nat]=v>0 and v+p1 or v-p1 end
            return true
        end
        local function decode_block(s,bx,by)
            local coeff=block_for(s.c,bx,by)
            if not frame.progressive then
                local cat=jpeg_huff_decode(br,hdc[s.dc]);if cat==nil or cat>16 then return nil,"invalid JPEG DC Huffman code" end
                local diff=read_value(cat);if diff==nil then return nil,"truncated JPEG DC coefficient" end
                local pred=(predictors[s.c.id] or 0)+diff;predictors[s.c.id]=pred;coeff[1]=pred
                local k=1
                while k<=63 do
                    local rs=jpeg_huff_decode(br,hac[s.ac]);if rs==nil then return nil,"invalid JPEG AC Huffman code" end
                    local r,sz=floor(rs/16),rs%16
                    if sz==0 then if r==15 then k=k+16 else break end
                    else
                        k=k+r;if k>63 then return nil,"invalid JPEG AC run" end
                        local v=read_value(sz);if v==nil then return nil,"truncated JPEG AC coefficient" end
                        coeff[JPEG_ZIG[k+1]]=v;k=k+1
                    end
                end
                return true
            end
            local p1=2^al
            if ss==0 then
                if ah==0 then
                    local cat=jpeg_huff_decode(br,hdc[s.dc]);if cat==nil or cat>16 then return nil,"invalid progressive JPEG DC Huffman code" end
                    local diff=read_value(cat);if diff==nil then return nil,"truncated progressive JPEG DC coefficient" end
                    local pred=(predictors[s.c.id] or 0)+diff;predictors[s.c.id]=pred;coeff[1]=pred*p1
                else
                    local bit=br.one();if bit==nil then return nil,"truncated progressive JPEG DC refinement" end
                    if bit==1 then coeff[1]=(coeff[1] or 0)>=0 and (coeff[1] or 0)+p1 or (coeff[1] or 0)-p1 end
                end
                return true
            end
            if ah==0 then
                if eobrun>0 then eobrun=eobrun-1;return true end
                local k=ss
                while k<=se do
                    local rs=jpeg_huff_decode(br,hac[s.ac]);if rs==nil then return nil,"invalid progressive JPEG AC Huffman code" end
                    local r,sz=floor(rs/16),rs%16
                    if sz==0 then
                        if r==15 then k=k+16
                        else
                            local extra=r>0 and br.bits(r) or 0;if extra==nil then return nil,"truncated progressive JPEG EOB run" end
                            eobrun=2^r+extra-1;break
                        end
                    else
                        k=k+r;if k>se then return nil,"invalid progressive JPEG AC run" end
                        local v=read_value(sz);if v==nil then return nil,"truncated progressive JPEG AC coefficient" end
                        coeff[JPEG_ZIG[k+1]]=v*p1;k=k+1
                    end
                end
                return true
            end
            if eobrun>0 then
                for k=ss,se do local nat=JPEG_ZIG[k+1];if (coeff[nat] or 0)~=0 and not refine_existing(coeff,nat,p1) then return nil,"truncated progressive JPEG AC refinement" end end
                eobrun=eobrun-1;return true
            end
            local k=ss
            while k<=se do
                local rs=jpeg_huff_decode(br,hac[s.ac]);if rs==nil then return nil,"invalid progressive JPEG AC refinement code" end
                local r,sz=floor(rs/16),rs%16;local newv
                if sz==0 then
                    if r<15 then
                        local extra=r>0 and br.bits(r) or 0;if extra==nil then return nil,"truncated progressive JPEG EOB refinement" end
                        eobrun=2^r+extra
                        for kk=k,se do local nat=JPEG_ZIG[kk+1];if (coeff[nat] or 0)~=0 and not refine_existing(coeff,nat,p1) then return nil,"truncated progressive JPEG AC refinement" end end
                        eobrun=eobrun-1;break
                    end
                    r=16
                elseif sz==1 then
                    local sign=br.one();if sign==nil then return nil,"truncated progressive JPEG new coefficient" end;newv=sign==1 and p1 or -p1
                else return nil,"invalid progressive JPEG refinement magnitude" end
                while k<=se do
                    local nat=JPEG_ZIG[k+1];local cv=coeff[nat] or 0
                    if cv~=0 then if not refine_existing(coeff,nat,p1) then return nil,"truncated progressive JPEG AC refinement" end
                    else
                        if r==0 then break end;r=r-1
                    end
                    k=k+1
                end
                if newv then if k>se then return nil,"progressive JPEG new coefficient beyond band" end;coeff[JPEG_ZIG[k+1]]=newv;k=k+1 end
            end
            return true
        end
        for uy=0,units_y-1 do for ux=0,units_x-1 do
            restart_if_needed()
            if ns>1 then
                for _,s in ipairs(scan) do for vy=0,s.c.v-1 do for hx=0,s.c.h-1 do
                    local ok,err=decode_block(s,ux*s.c.h+hx,uy*s.c.v+vy);if not ok then return nil,err end
                end end end
            else
                local ok,err=decode_block(scan[1],ux,uy);if not ok then return nil,err end
            end
            unit_index=unit_index+1
        end end
        return true
    end

    while p<=#data do
        if data:byte(p)~=0xFF then p=p+1
        else
            while data:byte(p)==0xFF do p=p+1 end
            local marker=data:byte(p);if not marker then break end;p=p+1
            if marker==0xD9 then break
            elseif marker==0xD8 or marker==0x01 or (marker>=0xD0 and marker<=0xD7) then
                -- stand-alone marker
            else
                local len=u16(data,p);if not len or len<2 or p+len-1>#data then return nil,"truncated JPEG marker segment" end
                local body=data:sub(p+2,p+len-1);local payload_end=p+len;p=p+len
                if marker==0xDA then
                    local e=jpeg_entropy_end(data,p);local ok,err=decode_scan(body,p,e-1);if not ok then return nil,err end;p=e
                else
                    local ok,err=segment(marker,body);if not ok then return nil,err end
                end
            end
        end
    end
    if not frame then return nil,"embedded JPEG has no supported frame" end
    local n=#frame.components;if n~=1 and n~=3 then return nil,"embedded JPEG color model is unsupported" end
    for _,c in ipairs(frame.components) do if not qtables[c.tq] then return nil,"embedded JPEG is missing a quantization table" end end
    for _,c in ipairs(frame.components) do
        for idx,b in pairs(c.blocks) do c.blocks[idx]=jpeg_idct(b,qtables[c.tq]) end
    end
    local function sample(c,x,y)
        local sx=floor(x*c.h/frame.max_h);local sy=floor(y*c.v/frame.max_v)
        local bx,by=floor(sx/8),floor(sy/8);local b=c.blocks[by*c.block_stride+bx+1]
        return b and b[(sy%8)*8+(sx%8)+1] or 0
    end
    local direct_rgb=(n==3 and adobe_transform==0 and not jfif)
    local out={};local oi=1
    for y=0,frame.height-1 do for x=0,frame.width-1 do
        local r,g,b
        if n==1 then local v=sample(frame.components[1],x,y);r,g,b=v,v,v
        elseif direct_rgb then r=sample(frame.components[1],x,y);g=sample(frame.components[2],x,y);b=sample(frame.components[3],x,y)
        else
            local yy=sample(frame.components[1],x,y);local cb=sample(frame.components[2],x,y)-128;local cr=sample(frame.components[3],x,y)-128
            r=yy+1.402*cr;g=yy-0.344136*cb-0.714136*cr;b=yy+1.772*cb
        end
        r=max(0,min(255,floor(r+0.5)));g=max(0,min(255,floor(g+0.5)));b=max(0,min(255,floor(b+0.5)))
        out[oi]=string.char(r,g,b,255);oi=oi+1
    end end
    return {width=frame.width,height=frame.height,rgba=table.concat(out),source="jpeg",progressive=frame.progressive}
end

S._test_decode_jpeg_rgba=decode_jpeg_rgba
S._decode_jpeg_rgba=decode_jpeg_rgba

local function small_bitmap_metrics(data,p)
    if p+4>#data then return nil end
    return {height=u8(data,p),width=u8(data,p+1),bearing_x=s8(data,p+2),bearing_y=s8(data,p+3),advance=u8(data,p+4),kind="small"}
end
local function big_bitmap_metrics(data,p)
    if p+7>#data then return nil end
    return {height=u8(data,p),width=u8(data,p+1),bearing_x=s8(data,p+2),bearing_y=s8(data,p+3),advance=u8(data,p+4),vert_bearing_x=s8(data,p+5),vert_bearing_y=s8(data,p+6),vert_advance=u8(data,p+7),kind="big"}
end
local function sbit_line_metrics(data,p)
    if p+11>#data then return nil end
    return {ascender=s8(data,p),descender=s8(data,p+1),width_max=u8(data,p+2),caret_slope_numerator=s8(data,p+3),caret_slope_denominator=s8(data,p+4),caret_offset=s8(data,p+5),min_origin_side_bearing=s8(data,p+6),min_advance_side_bearing=s8(data,p+7),max_before_baseline=s8(data,p+8),min_after_baseline=s8(data,p+9)}
end

local function parse_cbdt_cblc(t)
    local cblc,cbdt=t["CBLC"],t["CBDT"];if not cblc or not cbdt then return nil end
    local cmaj,cmin=u16(cblc,1),u16(cblc,3);local dmaj,dmin=u16(cbdt,1),u16(cbdt,3)
    if not cmaj or not dmaj or cmaj<2 or dmaj<2 then return nil end
    local count=u32(cblc,5) or 0;if count<1 or 8+count*48>#cblc then return nil end
    local strikes={}
    for si=0,count-1 do
        local q=9+si*48;local array_off=u32(cblc,q) or 0;local table_size=u32(cblc,q+4) or 0;local sub_count=u32(cblc,q+8) or 0
        local st={index=si,ppem_x=u8(cblc,q+44),ppem_y=u8(cblc,q+45),bit_depth=u8(cblc,q+46),flags=s8(cblc,q+47),start_gid=u16(cblc,q+40) or 0,end_gid=u16(cblc,q+42) or 0,hori=sbit_line_metrics(cblc,q+16),vert=sbit_line_metrics(cblc,q+28),subtables={}}
        if array_off>0 and sub_count>0 and array_off+sub_count*8<=#cblc and array_off+table_size<=#cblc then
            for ri=0,sub_count-1 do
                local ar=array_off+1+ri*8;local first=u16(cblc,ar) or 0;local last=u16(cblc,ar+2) or 0;local add=u32(cblc,ar+4) or 0;local sp=array_off+add+1
                if sp+7<=#cblc then
                    local idxfmt=u16(cblc,sp) or 0;local imgfmt=u16(cblc,sp+2) or 0;local image_off=u32(cblc,sp+4) or 0
                    local subtab={first=first,last=last,index_format=idxfmt,image_format=imgfmt,image_data_offset=image_off}
                    if idxfmt==1 or idxfmt==3 then
                        local n=max(0,last-first+2);local offs={};local op=sp+8;local step=idxfmt==1 and 4 or 2
                        local valid=true
                        for j=0,n-1 do local v=idxfmt==1 and u32(cblc,op+j*step) or u16(cblc,op+j*step);if not v then valid=false;break end;offs[j+1]=v end
                        if valid then subtab.offsets=offs end
                    elseif idxfmt==2 then
                        subtab.image_size=u32(cblc,sp+8) or 0;subtab.metrics=big_bitmap_metrics(cblc,sp+12)
                    elseif idxfmt==4 then
                        local n=u32(cblc,sp+8) or 0;local pairs={};local pp=sp+12;local valid=n<0x100000
                        if valid then for j=0,n do local gid=u16(cblc,pp+j*4);local off=u16(cblc,pp+j*4+2);if not gid or not off then valid=false;break end;pairs[j+1]={gid=gid,offset=off} end end
                        if valid then subtab.pairs=pairs;subtab.num_glyphs=n end
                    elseif idxfmt==5 then
                        subtab.image_size=u32(cblc,sp+8) or 0;subtab.metrics=big_bitmap_metrics(cblc,sp+12);local n=u32(cblc,sp+20) or 0;local gids={};local gp=sp+24;local valid=n<0x100000
                        if valid then for j=0,n-1 do local gid=u16(cblc,gp+j*2);if not gid then valid=false;break end;gids[j+1]=gid end end
                        if valid then subtab.gids=gids end
                    end
                    st.subtables[#st.subtables+1]=subtab
                end
            end
        end
        strikes[#strikes+1]=st
    end
    if #strikes==0 then return nil end
    local function locate(st,gid)
        for _,s in ipairs(st.subtables) do
            if gid>=s.first and gid<=s.last then
                local rel=gid-s.first
                if (s.index_format==1 or s.index_format==3) and s.offsets then
                    local a,b=s.offsets[rel+1],s.offsets[rel+2];if a and b and b>a then return {offset=s.image_data_offset+a,size=b-a,image_format=s.image_format,metrics=s.metrics} end
                elseif s.index_format==2 and s.image_size and s.image_size>0 then return {offset=s.image_data_offset+rel*s.image_size,size=s.image_size,image_format=s.image_format,metrics=s.metrics}
                elseif s.index_format==4 and s.pairs then
                    for i=1,#s.pairs-1 do local a,b=s.pairs[i],s.pairs[i+1];if a.gid==gid and b.offset>a.offset then return {offset=s.image_data_offset+a.offset,size=b.offset-a.offset,image_format=s.image_format,metrics=s.metrics} end end
                elseif s.index_format==5 and s.gids and s.image_size and s.image_size>0 then
                    for i,g in ipairs(s.gids) do if g==gid then return {offset=s.image_data_offset+(i-1)*s.image_size,size=s.image_size,image_format=s.image_format,metrics=s.metrics} end end
                end
            end
        end
    end
    local cache={}
    local function decode(st,gid,loc)
        local ck=st.index..":"..gid;local old=cache[ck];if old~=nil then return old or nil end
        local p=loc.offset+1;if p<5 or p>#cbdt or p+(loc.size or 0)-1>#cbdt then cache[ck]=false;return nil end
        local fmt=loc.image_format;local metrics=loc.metrics;local png,len
        if fmt==17 then metrics=small_bitmap_metrics(cbdt,p);len=u32(cbdt,p+5) or 0;png=cbdt:sub(p+9,p+8+len)
        elseif fmt==18 then metrics=big_bitmap_metrics(cbdt,p);len=u32(cbdt,p+8) or 0;png=cbdt:sub(p+12,p+11+len)
        elseif fmt==19 then len=u32(cbdt,p) or 0;png=cbdt:sub(p+4,p+3+len)
        else cache[ck]=false;return nil end
        if not metrics or len<=0 or #png~=len then cache[ck]=false;return nil end
        local image=decode_png_rgba(png);if not image then cache[ck]=false;return nil end
        -- Metrics and PNG dimensions are required to agree; reject malformed strikes rather
        -- than silently shifting/scaling corrupt glyph data.
        if metrics.width~=image.width or metrics.height~=image.height then cache[ck]=false;return nil end
        image.metrics=metrics;image.ppem_x=st.ppem_x;image.ppem_y=st.ppem_y;image.bit_depth=st.bit_depth;image.image_format=fmt;image.gid=gid;image.strike_index=st.index
        cache[ck]=image;return image
    end
    local function ordered_strikes(ppem)
        ppem=tonumber(ppem) or 0;local a={};for _,st in ipairs(strikes) do a[#a+1]=st end
        table.sort(a,function(x,y)
            local xp,yp=x.ppem_y or 0,y.ppem_y or 0;local xr=(xp>=ppem) and 0 or 1;local yr=(yp>=ppem) and 0 or 1
            if xr~=yr then return xr<yr end
            if xr==0 then return xp<yp end
            return xp>yp
        end);return a
    end
    local function get(gid,ppem)
        for _,st in ipairs(ordered_strikes(ppem)) do local loc=locate(st,gid);if loc then local im=decode(st,gid,loc);if im then return im end end end
    end
    local pub={}
    for i,st in ipairs(strikes) do pub[i]={ppem_x=st.ppem_x,ppem_y=st.ppem_y,bit_depth=st.bit_depth,flags=st.flags,start_gid=st.start_gid,end_gid=st.end_gid,hori=st.hori,vert=st.vert} end
    return {major=cmaj,minor=cmin,data_major=dmaj,data_minor=dmin,strikes=strikes,public_strikes=pub,get=get,_cache=cache}
end


-- sbix ---------------------------------------------------------------------
local function parse_sbix(t,numGlyphs)
    local data=t["sbix"];if not data or #data<12 or not numGlyphs or numGlyphs<1 then return nil end
    local version=u16(data,1);local flags=u16(data,3) or 0;local count=u32(data,5) or 0
    if version~=1 or count<1 or count>0x10000 or 8+count*4>#data then return nil end
    local strikes={}
    for si=0,count-1 do
        local off=u32(data,9+si*4) or 0
        local next_off=(si+1<count and u32(data,9+(si+1)*4)) or #data
        if off>=8+count*4 and next_off and next_off>off and next_off<=#data then
            local p=off+1;local ppem=u16(data,p) or 0;local ppi=u16(data,p+2) or 0
            local header_size=4+(numGlyphs+1)*4
            if ppem>0 and off+header_size<=next_off then
                local offsets={};local valid=true;local last=-1;local op=p+4
                for gid=0,numGlyphs do
                    local v=u32(data,op+gid*4)
                    if not v or v<header_size or v<last or off+v>next_off then valid=false;break end
                    offsets[gid]=v;last=v
                end
                if valid then strikes[#strikes+1]={index=si,offset=off,end_offset=next_off,ppem=ppem,ppi=ppi,offsets=offsets} end
            end
        end
    end
    if #strikes==0 then return nil end
    local function record(st,gid)
        if gid<0 or gid>=numGlyphs then return nil end
        local a,b=st.offsets[gid],st.offsets[gid+1];if not a or not b or b<=a or b-a<8 then return nil end
        local p=st.offset+a+1;if p+7>#data or st.offset+b>#data then return nil end
        return {origin_offset_x=s16(data,p) or 0,origin_offset_y=s16(data,p+2) or 0,graphic_type=sub(data,p+4,4),payload=data:sub(p+8,st.offset+b)}
    end
    local cache={}
    local function decode(st,gid,depth,seen)
        local ck=st.index..":"..gid;local old=cache[ck];if old~=nil then return old or nil end
        if (depth or 0)>32 then cache[ck]=false;return nil end
        seen=seen or {};if seen[gid] then cache[ck]=false;return nil end;seen[gid]=true
        local rec=record(st,gid);if not rec then cache[ck]=false;seen[gid]=nil;return nil end
        local image
        if rec.graphic_type=="png " then
            image=decode_png_rgba(rec.payload)
            if image then image.resolved_graphic_type="png " end
        elseif rec.graphic_type=="jpg " then
            image=decode_jpeg_rgba(rec.payload)
            if image then image.resolved_graphic_type="jpg " end
        elseif rec.graphic_type=="dupe" and #rec.payload>=2 then
            local ref=u16(rec.payload,1)
            if ref and ref<numGlyphs then
                local target=decode(st,ref,(depth or 0)+1,seen)
                if target then
                    image={width=target.width,height=target.height,rgba=target.rgba,source=target.source,resolved_graphic_type=target.resolved_graphic_type,referenced_gid=ref}
                end
            end
        end
        seen[gid]=nil
        if not image then cache[ck]=false;return nil end
        image.bitmap_format="sbix";image.graphic_type=rec.graphic_type;image.origin_offset_x=rec.origin_offset_x;image.origin_offset_y=rec.origin_offset_y
        image.ppem_x=st.ppem;image.ppem_y=st.ppem;image.ppi=st.ppi;image.gid=gid;image.strike_index=st.index;image.sbix_flags=flags
        cache[ck]=image;return image
    end
    local function ordered_strikes(ppem,ppi)
        ppem=tonumber(ppem) or 0;ppi=tonumber(ppi);local a={};for _,st in ipairs(strikes) do a[#a+1]=st end
        table.sort(a,function(x,y)
            local xp,yp=x.ppem or 0,y.ppem or 0;local xr=(xp>=ppem) and 0 or 1;local yr=(yp>=ppem) and 0 or 1
            if xr~=yr then return xr<yr end
            if xp~=yp then if xr==0 then return xp<yp else return xp>yp end end
            if ppi then local xd,yd=abs((x.ppi or ppi)-ppi),abs((y.ppi or ppi)-ppi);if xd~=yd then return xd<yd end end
            return (x.index or 0)<(y.index or 0)
        end);return a
    end
    local function get(gid,ppem,ppi)
        for _,st in ipairs(ordered_strikes(ppem,ppi)) do local im=decode(st,gid,0,{});if im then return im end end
    end
    local pub={};for i,st in ipairs(strikes) do pub[i]={ppem_x=st.ppem,ppem_y=st.ppem,ppem=st.ppem,ppi=st.ppi,flags=flags,format="sbix"} end
    return {version=version,flags=flags,draw_outlines=floor(flags/2)%2==1,strikes=strikes,public_strikes=pub,get=get,_cache=cache}
end


-- SVG-in-OpenType ----------------------------------------------------------
local function parse_svg_table(t,numGlyphs)
    local data=t["SVG "];if not data or #data<12 then return nil end
    local version=u16(data,1);local list_off=u32(data,3) or 0
    if version~=0 or list_off<=0 then return nil end
    local base=list_off+1;if base+1>#data then return nil end
    local count=u16(data,base) or 0;if count<1 or count>0xFFFF then return nil end
    local ep=base+2;if ep+count*12-1>#data then return nil end
    local records={};local last_end=-1;local glyph_count=0
    for i=0,count-1 do
        local p=ep+i*12;local first=u16(data,p);local last=u16(data,p+2);local off=u32(data,p+4);local len=u32(data,p+8)
        if not first or not last or last<first or first<=last_end or not off or off==0 or not len or len==0 then return nil end
        if numGlyphs and (first>=numGlyphs or last>=numGlyphs) then return nil end
        local dp=base+off
        if dp<1 or dp+len-1>#data then return nil end
        records[#records+1]={first=first,last=last,offset=dp,length=len}
        last_end=last;glyph_count=glyph_count+(last-first+1)
    end
    local cache={}
    local function document(rec)
        local key=rec.offset..":"..rec.length;local old=cache[key]
        if old~=nil then return old or nil end
        local raw=data:sub(rec.offset,rec.offset+rec.length-1)
        if #raw~=rec.length or #raw>16*1024*1024 then cache[key]=false;return nil end
        local doc,err=gunzip(raw);if not doc or #doc>64*1024*1024 then cache[key]=false;return nil end
        -- SVG documents in the table are UTF-8 XML.
        if not doc:find("<svg[%s>]",1) and not doc:find("<svg:",1,true) then cache[key]=false;return nil end
        cache[key]=doc;return doc
    end
    local function get(gid)
        gid=tonumber(gid);if not gid then return nil end
        local lo,hi=1,#records
        while lo<=hi do
            local mid=floor((lo+hi)/2);local r=records[mid]
            if gid<r.first then hi=mid-1 elseif gid>r.last then lo=mid+1 else
                local doc=document(r);if not doc then return nil end
                return {data=doc,gid=gid,start_gid=r.first,end_gid=r.last,compressed=(data:byte(r.offset)==0x1F and data:byte(r.offset+1)==0x8B)}
            end
        end
    end
    return {version=version,records=records,glyph_count=glyph_count,get=get,_cache=cache}
end

S._test_parse_svg_table=function(data,numGlyphs) return parse_svg_table({["SVG "]=data},numGlyphs) end

local function parse_cpal(t)
    local data=t["CPAL"];if not data then return nil end
    local version=u16(data,1) or 0
    if version>1 then return nil end
    local entries=u16(data,3) or 0;local palette_count=u16(data,5) or 0;local record_count=u16(data,7) or 0
    local records_offset=u32(data,9) or 0
    if entries<1 or palette_count<1 or records_offset<=0 then return nil end
    local indices={};local ip=13
    for i=1,palette_count do local n=u16(data,ip+(i-1)*2);if not n then return nil end;indices[i]=n end
    if records_offset+record_count*4>#data then return nil end
    local records={}
    for i=0,record_count-1 do
        local q=records_offset+1+i*4
        local b,g,r,a=data:byte(q,q+3)
        if not a then return nil end
        records[i]={r,g,b,a}
    end
    local palettes={}
    for pi=1,palette_count do
        local first=indices[pi] or 0;local palette={}
        for ei=0,entries-1 do
            local c=records[first+ei]
            if not c then return nil end
            palette[ei+1]={c[1],c[2],c[3],c[4]}
        end
        palettes[pi]=palette
    end
    local out={version=version,num_entries=entries,num_palettes=palette_count,palettes=palettes}
    if version>=1 then
        local extra=13+palette_count*2
        local types_off=u32(data,extra) or 0;local labels_off=u32(data,extra+4) or 0;local entry_labels_off=u32(data,extra+8) or 0
        if types_off>0 and types_off+palette_count*4<=#data then
            out.palette_types={}
            for i=0,palette_count-1 do out.palette_types[i+1]=u32(data,types_off+1+i*4) or 0 end
        end
        if labels_off>0 and labels_off+palette_count*2<=#data then
            out.palette_label_ids={}
            for i=0,palette_count-1 do out.palette_label_ids[i+1]=u16(data,labels_off+1+i*2) or 0xFFFF end
        end
        if entry_labels_off>0 and entry_labels_off+entries*2<=#data then
            out.palette_entry_label_ids={}
            for i=0,entries-1 do out.palette_entry_label_ids[i+1]=u16(data,entry_labels_off+1+i*2) or 0xFFFF end
        end
    end
    return out
end

local function parse_colr_v0(t,cpal)
    local data=t["COLR"];if not data or not cpal then return nil end
    local version=u16(data,1) or 0
    if version>1 then return nil end
    local base_count=u16(data,3) or 0;local base_off=u32(data,5) or 0;local layer_off=u32(data,9) or 0;local layer_count=u16(data,13) or 0
    if base_count==0 or base_off==0 or layer_off==0 then return nil end
    if base_off+base_count*6>#data or layer_off+layer_count*4>#data then return nil end
    local layers={}
    for i=0,layer_count-1 do
        local q=layer_off+1+i*4
        layers[i]={gid=u16(data,q) or 0,palette_index=u16(data,q+2) or 0}
    end
    local glyphs={}
    for i=0,base_count-1 do
        local q=base_off+1+i*6;local gid=u16(data,q);local first=u16(data,q+2);local count=u16(data,q+4)
        if gid and first and count and first+count<=layer_count then
            local list={}
            for j=0,count-1 do local l=layers[first+j];list[#list+1]={gid=l.gid,palette_index=l.palette_index} end
            glyphs[gid]=list
        end
    end
    if next(glyphs)==nil then return nil end
    return {version=version,glyphs=glyphs}
end

local function parse_colr_v1(t,cpal,variation)
    local data=t["COLR"];if not data or not cpal or (u16(data,1) or 0)~=1 then return nil end
    local base_list_off=u32(data,15) or 0;if base_list_off==0 then return nil end
    local layer_list_off=u32(data,19) or 0
    local clip_list_off=u32(data,23) or 0
    local var_map_off=u32(data,27) or 0;local var_store_off=u32(data,31) or 0
    local var_map=var_map_off>0 and parse_delta_set_index_map(data,var_map_off+1) or nil
    local var_store=var_store_off>0 and parse_item_variation_store(data,var_store_off+1) or nil
    if var_store then var_store._data=data end
    local coords=variation and variation.normalized or {}
    local function var_delta(base,seq)
        if not var_store or not base or base==0xFFFFFFFF then return 0 end
        local idx=base+(seq or 0);if idx>0xFFFFFFFF then return 0 end
        local outer,inner
        if var_map then
            if var_map.count<=0 then return 0 end
            local e=var_map[idx] or var_map[var_map.count-1];if not e then return 0 end
            outer,inner=e[1],e[2]
        else outer=floor(idx/65536);inner=idx%65536 end
        if outer==0xFFFF and inner==0xFFFF then return 0 end
        return variation_store_delta(var_store,outer,inner,coords)
    end
    local function vfword(p,base,seq) return (s16(data,p) or 0)+var_delta(base,seq) end
    local function vufword(p,base,seq) return max(0,(u16(data,p) or 0)+var_delta(base,seq)) end
    local function vf2(p,base,seq) return ((s16(data,p) or 0)+var_delta(base,seq))/16384 end
    local function vfixed(p,base,seq) return ((s32(data,p) or 0)+var_delta(base,seq))/65536 end

    -- COLR v1 ClipList.
    local clip_records={}
    if clip_list_off>0 then
        local cb=clip_list_off+1
        if cb<=#data and u8(data,cb)==1 then
            local n=u32(data,cb+1) or 0
            local rp=cb+5
            local last_end=-1
            if n<=0x10000 and rp+n*7-1<=#data then
                for i=0,n-1 do
                    local q=rp+i*7
                    local first=u16(data,q);local last=u16(data,q+2);local off=u24(data,q+4) or 0
                    if first and last and first<=last and first>last_end and off>0 then
                        local bp=cb+off
                        local fmt=u8(data,bp)
                        local box
                        if fmt==1 and bp+8<=#data then
                            box={x_min=s16(data,bp+1) or 0,y_min=s16(data,bp+3) or 0,x_max=s16(data,bp+5) or 0,y_max=s16(data,bp+7) or 0,format=1}
                        elseif fmt==2 and bp+12<=#data then
                            local vb=u32(data,bp+9) or 0xFFFFFFFF
                            local xmin=(s16(data,bp+1) or 0)+var_delta(vb,0)
                            local ymin=(s16(data,bp+3) or 0)+var_delta(vb,1)
                            local xmax=(s16(data,bp+5) or 0)+var_delta(vb,2)
                            local ymax=(s16(data,bp+7) or 0)+var_delta(vb,3)
                            box={x_min=math.floor(xmin),y_min=math.floor(ymin),x_max=math.ceil(xmax),y_max=math.ceil(ymax),format=2,var_index_base=vb}
                        end
                        if box and box.x_min<=box.x_max and box.y_min<=box.y_max then
                            clip_records[#clip_records+1]={first=first,last=last,box=box}
                            last_end=last
                        end
                    end
                end
            end
        end
    end
    local function clip_for_gid(gid)
        local lo,hi=1,#clip_records
        while lo<=hi do
            local mid=floor((lo+hi)/2);local r=clip_records[mid]
            if gid<r.first then hi=mid-1 elseif gid>r.last then lo=mid+1 else return r.box end
        end
        return nil
    end

    local function color_line(pos,is_var)
        if not pos or pos<1 or pos>#data then return {extend=0,stops={}} end
        local extend=u8(data,pos);if extend>2 then extend=0 end
        local count=u16(data,pos+1) or 0;local p=pos+3;local stops={}
        for i=1,count do
            local off,pi,alpha
            if is_var then
                local vb=u32(data,p+6) or 0xFFFFFFFF;off=vf2(p,vb,0);pi=u16(data,p+2) or 0;alpha=vf2(p+4,vb,1);p=p+10
            else off=f2dot14(data,p);pi=u16(data,p+2) or 0;alpha=f2dot14(data,p+4);p=p+6 end
            stops[#stops+1]={offset=off,palette_index=pi,alpha=max(0,min(1,alpha)),order=i}
        end
        table.sort(stops,function(a,b) if a.offset==b.offset then return a.order<b.order end return a.offset<b.offset end)
        return {extend=extend,stops=stops}
    end
    local layer_positions={}
    if layer_list_off>0 then
        local lb=layer_list_off+1;local n=u32(data,lb) or 0
        for i=0,n-1 do local o=u32(data,lb+4+i*4);if o and o>0 then layer_positions[i]=lb+o end end
    end
    local cache,active={},{}
    local parse_paint
    local function mat_scale(sx,sy,cx,cy)
        cx,cy=cx or 0,cy or 0;return {sx,0,0,sy,cx-sx*cx,cy-sy*cy}
    end
    local function mat_rotate(deg,cx,cy)
        local r=deg*math.pi/180;local c,s=math.cos(r),math.sin(r);cx,cy=cx or 0,cy or 0
        return {c,s,-s,c,cx-c*cx+s*cy,cy-s*cx-c*cy}
    end
    local function mat_skew(xdeg,ydeg,cx,cy)
        local xy=-math.tan(xdeg*math.pi/180);local yx=math.tan(ydeg*math.pi/180);cx,cy=cx or 0,cy or 0
        return {1,yx,xy,1,-xy*cy,-yx*cx}
    end
    parse_paint=function(pos)
        if not pos or pos<1 or pos>#data then return nil end
        if cache[pos] then return cache[pos] end;if active[pos] then return nil end;active[pos]=true
        local fmt=u8(data,pos);local node={format=fmt};cache[pos]=node
        local function child(offpos) local o=u24(data,offpos) or 0;return o>0 and parse_paint(pos+o) or nil end
        if fmt==1 then
            node.kind="layers";node.children={};local n=u8(data,pos+1);local first=u32(data,pos+2) or 0
            for i=0,n-1 do local lp=layer_positions[first+i];if lp then node.children[#node.children+1]=parse_paint(lp) end end
        elseif fmt==2 or fmt==3 then
            node.kind="solid";node.palette_index=u16(data,pos+1) or 0
            if fmt==3 then local vb=u32(data,pos+5) or 0xFFFFFFFF;node.alpha=max(0,min(1,vf2(pos+3,vb,0))) else node.alpha=max(0,min(1,f2dot14(data,pos+3))) end
        elseif fmt==4 or fmt==5 then
            node.kind="linear";local off=u24(data,pos+1) or 0;local vb=fmt==5 and (u32(data,pos+16) or 0xFFFFFFFF) or nil
            local rd=fmt==5 and function(p,i)return vfword(p,vb,i)end or function(p)return s16(data,p) or 0 end
            node.x0,node.y0,node.x1,node.y1,node.x2,node.y2=rd(pos+4,0),rd(pos+6,1),rd(pos+8,2),rd(pos+10,3),rd(pos+12,4),rd(pos+14,5)
            node.color_line=color_line(pos+off,fmt==5)
        elseif fmt==6 or fmt==7 then
            node.kind="radial";local off=u24(data,pos+1) or 0;local vb=fmt==7 and (u32(data,pos+16) or 0xFFFFFFFF) or nil
            if fmt==7 then
                node.x0=vfword(pos+4,vb,0);node.y0=vfword(pos+6,vb,1);node.r0=vufword(pos+8,vb,2);node.x1=vfword(pos+10,vb,3);node.y1=vfword(pos+12,vb,4);node.r1=vufword(pos+14,vb,5)
            else node.x0=s16(data,pos+4) or 0;node.y0=s16(data,pos+6) or 0;node.r0=u16(data,pos+8) or 0;node.x1=s16(data,pos+10) or 0;node.y1=s16(data,pos+12) or 0;node.r1=u16(data,pos+14) or 0 end
            node.color_line=color_line(pos+off,fmt==7)
        elseif fmt==8 or fmt==9 then
            node.kind="sweep";local off=u24(data,pos+1) or 0;local vb=fmt==9 and (u32(data,pos+12) or 0xFFFFFFFF) or nil
            if fmt==9 then node.cx=vfword(pos+4,vb,0);node.cy=vfword(pos+6,vb,1);node.start_angle=(vf2(pos+8,vb,2)+1)*180;node.end_angle=(vf2(pos+10,vb,3)+1)*180
            else node.cx=s16(data,pos+4) or 0;node.cy=s16(data,pos+6) or 0;node.start_angle=(f2dot14(data,pos+8)+1)*180;node.end_angle=(f2dot14(data,pos+10)+1)*180 end
            node.color_line=color_line(pos+off,fmt==9)
        elseif fmt==10 then node.kind="glyph";node.child=child(pos+1);node.gid=u16(data,pos+4) or 0
        elseif fmt==11 then node.kind="colr_glyph";node.gid=u16(data,pos+1) or 0
        elseif fmt==12 or fmt==13 then
            node.kind="transform";node.child=child(pos+1);local to=u24(data,pos+4) or 0;local tp=pos+to
            if fmt==13 then local vb=u32(data,tp+24) or 0xFFFFFFFF;node.matrix={vfixed(tp,vb,0),vfixed(tp+4,vb,1),vfixed(tp+8,vb,2),vfixed(tp+12,vb,3),vfixed(tp+16,vb,4),vfixed(tp+20,vb,5)}
            else node.matrix={fixed16_16(data,tp) or 1,fixed16_16(data,tp+4) or 0,fixed16_16(data,tp+8) or 0,fixed16_16(data,tp+12) or 1,fixed16_16(data,tp+16) or 0,fixed16_16(data,tp+20) or 0} end
        elseif fmt==14 or fmt==15 then
            node.kind="transform";node.child=child(pos+1);local dx,dy
            if fmt==15 then local vb=u32(data,pos+8) or 0xFFFFFFFF;dx,dy=vfword(pos+4,vb,0),vfword(pos+6,vb,1) else dx,dy=s16(data,pos+4) or 0,s16(data,pos+6) or 0 end;node.matrix={1,0,0,1,dx,dy}
        elseif fmt==16 or fmt==17 then
            node.kind="transform";node.child=child(pos+1);local sx,sy
            if fmt==17 then local vb=u32(data,pos+8) or 0xFFFFFFFF;sx,sy=vf2(pos+4,vb,0),vf2(pos+6,vb,1) else sx,sy=f2dot14(data,pos+4),f2dot14(data,pos+6) end;node.matrix=mat_scale(sx,sy)
        elseif fmt==18 or fmt==19 then
            node.kind="transform";node.child=child(pos+1);local sx,sy,cx,cy
            if fmt==19 then local vb=u32(data,pos+12) or 0xFFFFFFFF;sx,sy,cx,cy=vf2(pos+4,vb,0),vf2(pos+6,vb,1),vfword(pos+8,vb,2),vfword(pos+10,vb,3) else sx,sy,cx,cy=f2dot14(data,pos+4),f2dot14(data,pos+6),s16(data,pos+8) or 0,s16(data,pos+10) or 0 end;node.matrix=mat_scale(sx,sy,cx,cy)
        elseif fmt==20 or fmt==21 then
            node.kind="transform";node.child=child(pos+1);local sc;if fmt==21 then local vb=u32(data,pos+6) or 0xFFFFFFFF;sc=vf2(pos+4,vb,0) else sc=f2dot14(data,pos+4) end;node.matrix=mat_scale(sc,sc)
        elseif fmt==22 or fmt==23 then
            node.kind="transform";node.child=child(pos+1);local sc,cx,cy
            if fmt==23 then local vb=u32(data,pos+10) or 0xFFFFFFFF;sc,cx,cy=vf2(pos+4,vb,0),vfword(pos+6,vb,1),vfword(pos+8,vb,2) else sc,cx,cy=f2dot14(data,pos+4),s16(data,pos+6) or 0,s16(data,pos+8) or 0 end;node.matrix=mat_scale(sc,sc,cx,cy)
        elseif fmt==24 or fmt==25 then
            node.kind="transform";node.child=child(pos+1);local a;if fmt==25 then local vb=u32(data,pos+6) or 0xFFFFFFFF;a=vf2(pos+4,vb,0)*180 else a=f2dot14(data,pos+4)*180 end;node.matrix=mat_rotate(a)
        elseif fmt==26 or fmt==27 then
            node.kind="transform";node.child=child(pos+1);local a,cx,cy
            if fmt==27 then local vb=u32(data,pos+10) or 0xFFFFFFFF;a,cx,cy=vf2(pos+4,vb,0)*180,vfword(pos+6,vb,1),vfword(pos+8,vb,2) else a,cx,cy=f2dot14(data,pos+4)*180,s16(data,pos+6) or 0,s16(data,pos+8) or 0 end;node.matrix=mat_rotate(a,cx,cy)
        elseif fmt==28 or fmt==29 then
            node.kind="transform";node.child=child(pos+1);local xa,ya
            if fmt==29 then local vb=u32(data,pos+8) or 0xFFFFFFFF;xa,ya=vf2(pos+4,vb,0)*180,vf2(pos+6,vb,1)*180 else xa,ya=f2dot14(data,pos+4)*180,f2dot14(data,pos+6)*180 end;node.matrix=mat_skew(xa,ya)
        elseif fmt==30 or fmt==31 then
            node.kind="transform";node.child=child(pos+1);local xa,ya,cx,cy
            if fmt==31 then local vb=u32(data,pos+12) or 0xFFFFFFFF;xa,ya,cx,cy=vf2(pos+4,vb,0)*180,vf2(pos+6,vb,1)*180,vfword(pos+8,vb,2),vfword(pos+10,vb,3) else xa,ya,cx,cy=f2dot14(data,pos+4)*180,f2dot14(data,pos+6)*180,s16(data,pos+8) or 0,s16(data,pos+10) or 0 end;node.matrix=mat_skew(xa,ya,cx,cy)
        elseif fmt==32 then node.kind="composite";node.source=child(pos+1);node.mode=u8(data,pos+4);local bo=u24(data,pos+5) or 0;node.backdrop=bo>0 and parse_paint(pos+bo) or nil
        else node.kind="unsupported" end
        active[pos]=nil;return node
    end
    local bb=base_list_off+1;local count=u32(data,bb) or 0;local roots={}
    for i=0,count-1 do
        local rp=bb+4+i*6;local gid=u16(data,rp);local off=u32(data,rp+2) or 0
        if gid and off>0 then roots[gid]=parse_paint(bb+off) end
    end
    if next(roots)==nil then return nil end
    return {version=1,roots=roots,var_store=var_store~=nil,var_map=var_map~=nil,clip_for_gid=#clip_records>0 and clip_for_gid or nil,clip_count=#clip_records}
end

local function parse_colr(t,cpal,variation)
    local v0=parse_colr_v0(t,cpal);local v1=parse_colr_v1(t,cpal,variation)
    if not v0 and not v1 then return nil end
    return {version=v1 and 1 or (v0 and v0.version or 0),glyphs=v0 and v0.glyphs or nil,roots=v1 and v1.roots or nil,clip_for_gid=v1 and v1.clip_for_gid or nil,clip_count=v1 and v1.clip_count or 0}
end

local function parse_kern(t)
    local data=t["kern"]; if not data then return {} end
    local out={}; local version=u16(data,1) or 0; local n=u16(data,3) or 0; local p=5
    if version~=0 then return out end
    for _=1,n do
        local len=u16(data,p+2) or 0; local coverage=u16(data,p+4) or 0; local fmt=floor(coverage/256)
        if fmt==0 and len>=14 then local np=u16(data,p+6) or 0; local q=p+14
            for _=1,np do local left=u16(data,q);local right=u16(data,q+2);local val=s16(data,q+4) or 0;if left and right then out[left..":"..right]=val end;q=q+6 end
        end
        if len<6 then break end;p=p+len
    end
    return out
end


local function coverage_index(data, base, gid)
    local fmt=u16(data,base) or 0
    if fmt==1 then
        local count=u16(data,base+2) or 0
        local lo,hi=0,count-1
        while lo<=hi do local mid=floor((lo+hi)/2);local g=u16(data,base+4+mid*2) or -1;if gid<g then hi=mid-1 elseif gid>g then lo=mid+1 else return mid end end
    elseif fmt==2 then
        local count=u16(data,base+2) or 0
        for i=0,count-1 do local p=base+4+i*6;local a=u16(data,p) or 0;local b=u16(data,p+2) or 0;if gid>=a and gid<=b then return (u16(data,p+4) or 0)+(gid-a) end end
    end
    return nil
end


-- Variable Composite (VARC proposal) ----------------------------------------
local function varc_uint32var(data,p,limit)
    limit=limit or #data
    if p>limit then return nil,p,"truncated uint32var" end
    local b0=u8(data,p);p=p+1
    local n,more
    if b0<0x80 then return b0,p
    elseif b0<0xC0 then n=b0-0x80;more=1
    elseif b0<0xE0 then n=b0-0xC0;more=2
    elseif b0<0xF0 then n=b0-0xE0;more=3
    else n=b0-0xF0;more=4 end
    if p+more-1>limit then return nil,p,"truncated uint32var payload" end
    for _=1,more do n=n*256+(u8(data,p) or 0);p=p+1 end
    if n>0xFFFFFFFF then return nil,p,"uint32var exceeds uint32" end
    return n,p
end

local function varc_tuple_values(data,p,count,limit)
    limit=limit or #data;local out={}
    while p<=limit and (not count or #out<count) do
        local control=u8(data,p);p=p+1
        local mode=floor(control/0x40);local run=control%0x40+1
        for _=1,run do
            if count and #out>=count then break end
            local v=0
            if mode==0 then if p>limit then return nil,p,"truncated TupleValues byte run" end;v=s8(data,p);p=p+1
            elseif mode==1 then if p+1>limit then return nil,p,"truncated TupleValues word run" end;v=s16(data,p) or 0;p=p+2
            elseif mode==2 then v=0
            else if p+3>limit then return nil,p,"truncated TupleValues long run" end;v=s32(data,p) or 0;p=p+4 end
            out[#out+1]=v
        end
    end
    if count and #out<count then return nil,p,"TupleValues ended before requested value count" end
    return out,p
end

local function varc_sparse_region_scalar(region,coords)
    local scalar=1
    for _,a in ipairs(region or {}) do
        local c=coords[(a.axis or 0)+1] or 0;local st,pk,en=a.start or 0,a.peak or 0,a.finish or 0
        if st>pk or pk>en or (st<0 and en>0) then
            -- Malformed tents impose no restriction, matching the behavior of the ordinary
            -- OpenType variation-store evaluator above.
        elseif pk==0 then
            -- A peak at zero contributes one for this axis.
        elseif c==pk then
        elseif c<=st or c>=en then return 0
        elseif c<pk then if pk==st then return 0 end;scalar=scalar*(c-st)/(pk-st)
        else if en==pk then return 0 end;scalar=scalar*(en-c)/(en-pk) end
    end
    return scalar
end

local function parse_multi_item_variation_store(data,base)
    if not base or base<1 or base>#data then return nil,"invalid MultiItemVariationStore offset" end
    if (u16(data,base) or 0)~=1 then return nil,"unsupported MultiItemVariationStore format" end
    local region_off=u32(data,base+2);local data_count=u16(data,base+6) or 0
    if not region_off then return nil,"truncated MultiItemVariationStore" end
    local data_offsets={};for i=1,data_count do local o=u32(data,base+8+(i-1)*4);if not o then return nil,"truncated MultiItemVariationStore data offsets" end;data_offsets[i]=o end
    local rbase=base+region_off;local region_count=u16(data,rbase) or 0;local regions={}
    for i=1,region_count do
        local ro=u32(data,rbase+2+(i-1)*4);if not ro then return nil,"truncated sparse region offsets" end
        local p=rbase+ro;local n=u16(data,p) or 0;p=p+2;local axes={}
        for _=1,n do
            local ai=u16(data,p);if ai==nil or p+7>#data then return nil,"truncated sparse variation region" end
            axes[#axes+1]={axis=ai,start=f2dot14(data,p+2),peak=f2dot14(data,p+4),finish=f2dot14(data,p+6)};p=p+8
        end
        regions[i]=axes
    end
    local var_data={}
    for i,o in ipairs(data_offsets) do
        local p=base+o;local fmt=u8(data,p) or -1;if fmt~=1 then return nil,"unsupported MultiItemVariationData format" end;p=p+1
        local nr=u16(data,p) or 0;p=p+2;local ris={}
        for j=1,nr do local ri=u16(data,p);if ri==nil then return nil,"truncated MultiItemVariationData regions" end;ris[j]=ri;p=p+2 end
        local sets,nextp=cff_index(data,p,true);if not sets then return nil,"invalid MultiItemVariationData delta-set index" end
        var_data[i]={region_indices=ris,delta_sets=sets,_end=nextp}
    end
    local store={regions=regions,var_data=var_data}
    function store:delta(varidx,coords)
        varidx=tonumber(varidx) or 0;if varidx==0xFFFFFFFF then return {} end
        local outer=floor(varidx/65536);local inner=varidx%65536;local vd=self.var_data[outer+1];if not vd then return {} end
        local bytes=vd.delta_sets[inner+1];if not bytes then return {} end
        local vals,_,err=varc_tuple_values(bytes,1,nil,#bytes);if not vals then return {},err end
        local nr=#vd.region_indices;if nr==0 then return {} end
        local tuple_len=floor(#vals/nr);if tuple_len<=0 then return {} end
        local out={};for k=1,tuple_len do out[k]=0 end
        for j=1,nr do
            local region=self.regions[(vd.region_indices[j] or 0)+1];local sc=varc_sparse_region_scalar(region,coords or {})
            if sc~=0 then local b=(j-1)*tuple_len;for k=1,tuple_len do out[k]=out[k]+(vals[b+k] or 0)*sc end end
        end
        return out
    end
    return store
end

local function varc_condition_list(data,base)
    if not base or base<=0 or base>#data then return {} end
    local count=u32(data,base) or 0;local out={}
    for i=1,count do local off=u32(data,base+i*4);if off and off>0 and base+off<=#data then out[i]=base+off end end
    return out
end

local function varc_eval_condition(data,p,coords,varstore,depth)
    depth=(depth or 0)+1;if depth>64 or not p or p<1 or p>#data then return false end
    local fmt=u16(data,p) or 0
    if fmt==1 then
        local axis=u16(data,p+2);if axis==nil then return false end
        local lo=f2dot14(data,p+4);local hi=f2dot14(data,p+6);local c=coords[axis+1] or 0
        return c>=lo and c<=hi
    elseif fmt==2 then
        local def=s16(data,p+2) or 0;local idx=u32(data,p+4);if not idx then return false end
        local d=varstore and varstore:delta(idx,coords) or {};return def+(d[1] or 0)>0
    elseif fmt==3 or fmt==4 then
        local count=u8(data,p+2) or 0;local any=(fmt==4)
        if count==0 then return not any end
        for i=1,count do
            local off=u24(data,p+3+(i-1)*3);local v=off and varc_eval_condition(data,p+off,coords,varstore,depth) or false
            if any and v then return true elseif not any and not v then return false end
        end
        return not any
    elseif fmt==5 then
        local off=u24(data,p+2);return not (off and varc_eval_condition(data,p+off,coords,varstore,depth) or false)
    end
    return false
end

local function varc_bit(v,n) return floor((tonumber(v) or 0)/(2^n))%2==1 end
local function varc_coords_key(coords)
    local t={};for i=1,#(coords or {}) do t[i]=string.format("%.7g",coords[i] or 0) end;return table.concat(t,",")
end

local function parse_varc_source(t,font,variation,base_provider,provider_at_coords)
    local data=t["VARC"];if not data then return nil end
    local major,minor=u16(data,1) or 0,u16(data,3) or 0;if major~=1 then return nil,"unsupported VARC version "..major.."."..minor end
    local cov_off=u32(data,5) or 0;local store_off=u32(data,9) or 0;local cond_off=u32(data,13) or 0;local axes_off=u32(data,17) or 0;local glyph_off=u32(data,21) or 0
    if cov_off==0 or glyph_off==0 then return nil,"VARC lacks required coverage/glyph records" end
    local varstore;if store_off~=0 then local e;varstore,e=parse_multi_item_variation_store(data,store_off+1);if not varstore then return nil,e end end
    local conditions=cond_off~=0 and varc_condition_list(data,cond_off+1) or {}
    local axis_items=axes_off~=0 and select(1,cff_index(data,axes_off+1,true)) or {}
    local glyph_records=select(1,cff_index(data,glyph_off+1,true));if not glyph_records then return nil,"invalid VARC glyph record index" end
    local axis_indices={}
    for i,bytes in ipairs(axis_items or {}) do local v=varc_tuple_values(bytes,1,nil,#bytes);axis_indices[i]=v or {} end
    local coverage_base=cov_off+1;local global_coords=(variation and variation.normalized) or {};local cache={};local parsed={}
    F._track_cache(font,cache)

    local function parse_record(record)
        local comps={};local p=1;local limit=#record
        while p<=limit do
            local flags,np,err=varc_uint32var(record,p,limit);if not flags then return nil,err end;p=np
            local gid;if varc_bit(flags,12) then gid=u24(record,p);p=p+3 else gid=u16(record,p);p=p+2 end
            if gid==nil then return nil,"truncated VARC component glyph id" end
            local c={flags=flags,gid=gid}
            if varc_bit(flags,7) then c.condition_index,p,err=varc_uint32var(record,p,limit);if not c.condition_index then return nil,err end end
            if varc_bit(flags,1) then
                c.axis_indices_index,p,err=varc_uint32var(record,p,limit);if c.axis_indices_index==nil then return nil,err end
                c.axis_indices=axis_indices[(c.axis_indices_index or 0)+1] or {}
                local vals;c.axis_values,p,err=varc_tuple_values(record,p,#c.axis_indices,limit);if not c.axis_values then return nil,err end
            else c.axis_indices={};c.axis_values={} end
            if varc_bit(flags,2) then c.axis_var_index,p,err=varc_uint32var(record,p,limit);if c.axis_var_index==nil then return nil,err end end
            if varc_bit(flags,3) then c.transform_var_index,p,err=varc_uint32var(record,p,limit);if c.transform_var_index==nil then return nil,err end end
            local fields={}
            local function field(name,bit,div,default)
                if varc_bit(flags,bit) then local v=s16(record,p);if v==nil then return false end;p=p+2;fields[#fields+1]={name=name,div=div};c[name]=v/div else c[name]=default end
                return true
            end
            if not field("tx",4,1,0) or not field("ty",5,1,0) or not field("rotation",6,4096,0)
                or not field("sx",8,1024,1) then return nil,"truncated VARC transform" end
            if varc_bit(flags,9) then if not field("sy",9,1024,1) then return nil,"truncated VARC transform" end else c.sy=c.sx end
            if not field("skewx",13,4096,0) or not field("skewy",14,4096,0)
                or not field("cx",10,1,0) or not field("cy",11,1,0) then return nil,"truncated VARC transform" end
            c.transform_fields=fields
            for bit=15,31 do if varc_bit(flags,bit) then local _;_,p,err=varc_uint32var(record,p,limit);if err then return nil,err end end end
            comps[#comps+1]=c
        end
        return comps
    end

    local function components_for_gid(gid)
        if parsed[gid]~=nil then return parsed[gid] or nil end
        local ci=coverage_index(data,coverage_base,gid);if ci==nil then parsed[gid]=false;return nil end
        local bytes=glyph_records[ci+1];if not bytes then parsed[gid]=false;return nil end
        local c,e=parse_record(bytes);if not c then parsed[gid]=false;return nil,e end;parsed[gid]=c;return c
    end

    local function leaf(gid,coords)
        local fn=provider_at_coords or base_provider;if not fn then return {} end
        return fn(gid,coords) or {}
    end
    local function transform_contours(contours,c)
        local out={};local rot=(c.rotation or 0)*math.pi;local kx=math.tan(-(c.skewx or 0)*math.pi);local ky=math.tan((c.skewy or 0)*math.pi)
        local cr,sr=math.cos(rot),math.sin(rot);local sx,sy=c.sx or 1,c.sy or c.sx or 1;local cx,cy=c.cx or 0,c.cy or 0;local tx,ty=c.tx or 0,c.ty or 0
        for _,contour in ipairs(contours or {}) do local oc={};for _,pt in ipairs(contour or {}) do
            local x=(pt.x or 0)-cx;local y=(font.ascent-(pt.y or 0))-cy
            local ox=x;x=x+kx*y;y=ky*ox+y;x=x*sx;y=y*sy
            local rx=cr*x-sr*y;local ry=sr*x+cr*y;x=rx+cx+tx;y=ry+cy+ty
            oc[#oc+1]={x=x,y=font.ascent-y,on=pt.on}
        end;if #oc>0 then out[#out+1]=oc end end
        return out
    end
    local function append(dst,src) for _,c in ipairs(src or {}) do dst[#dst+1]=c end end

    local function render(gid,parent_coords,active,depth,current_gid)
        parent_coords=parent_coords or global_coords;active=active or {};depth=depth or 0;if depth>64 then return leaf(gid,parent_coords) end
        local ck=tostring(gid).."@"..varc_coords_key(parent_coords);if not active[gid] and cache[ck] then return cache[ck] end
        local comps=components_for_gid(gid);if not comps or active[gid] then return leaf(gid,parent_coords) end
        active[gid]=true;local out={}
        for _,c0 in ipairs(comps) do
            local coords={};local reset=varc_bit(c0.flags,0);local source=reset and global_coords or parent_coords
            local n=math.max(#source,#global_coords,#(variation and variation.axes or {}));for i=1,n do coords[i]=source[i] or 0 end
            local axis_delta=c0.axis_var_index and varstore and varstore:delta(c0.axis_var_index,parent_coords) or {}
            for i,axis in ipairs(c0.axis_indices or {}) do local ai=floor(axis or -1)+1;if ai>=1 then coords[ai]=((c0.axis_values[i] or 0)+(axis_delta[i] or 0))/16384 end end
            local include=true;if c0.condition_index~=nil then local cp=conditions[c0.condition_index+1];include=cp and varc_eval_condition(data,cp,parent_coords,varstore,0) or false end
            local c={};for k,v in pairs(c0) do c[k]=v end
            if c.transform_var_index and varstore then
                local d=varstore:delta(c.transform_var_index,parent_coords);for i,f in ipairs(c.transform_fields or {}) do c[f.name]=(c[f.name] or 0)+(d[i] or 0)/f.div end
                if not varc_bit(c.flags,9) then c.sy=c.sx end
            end
            local child
            if c.gid==gid then child=leaf(c.gid,coords)
            else child=render(c.gid,coords,active,depth+1,gid) end
            if include then append(out,transform_contours(child,c)) end
        end
        active[gid]=nil;cache[ck]=out;return out
    end

    local api={major=major,minor=minor,var_store=varstore,conditions=conditions,axis_indices=axis_indices}
    function api:has_gid(gid) return coverage_index(data,coverage_base,gid)~=nil end
    function api:components(gid) return components_for_gid(gid) end
    function api:outline(gid,coords) return render(gid,coords or global_coords,{},0,gid) end
    function api:evaluate_condition(index,coords) local p=conditions[(index or 0)+1];return p and varc_eval_condition(data,p,coords or global_coords,varstore,0) or false end
    return api
end

S._parse_varc_for_test=parse_varc_source
S._parse_multi_var_store_for_test=parse_multi_item_variation_store
S._varc_tuple_values_for_test=varc_tuple_values

local function class_value(data,base,gid)
    local fmt=u16(data,base) or 0
    if fmt==1 then local start=u16(data,base+2) or 0;local count=u16(data,base+4) or 0;if gid>=start and gid<start+count then return u16(data,base+6+(gid-start)*2) or 0 end
    elseif fmt==2 then local count=u16(data,base+2) or 0;for i=0,count-1 do local p=base+4+i*6;local a=u16(data,p) or 0;local b=u16(data,p+2) or 0;if gid>=a and gid<=b then return u16(data,p+4) or 0 end end end
    return 0
end

local function value_record(data,p,fmt)
    local xplace,xadvance=0,0
    local bit=1
    for field=1,8 do
        if floor(fmt/bit)%2==1 then local v=s16(data,p) or 0;if field==1 then xplace=v elseif field==3 then xadvance=v end;p=p+2 end
        bit=bit*2
    end
    return xplace,xadvance,p
end

local function parse_pairpos(data,base)
    local fmt=u16(data,base) or 0
    if fmt==1 then
        local cov=base+(u16(data,base+2) or 0);local vf1=u16(data,base+4) or 0;local vf2=u16(data,base+6) or 0;local count=u16(data,base+8) or 0
        local sets={};for i=0,count-1 do sets[i]=base+(u16(data,base+10+i*2) or 0) end
        return function(left,right)
            local idx=coverage_index(data,cov,left);if idx==nil or not sets[idx] then return 0 end
            local p=sets[idx];local n=u16(data,p) or 0;p=p+2
            for _=1,n do local second=u16(data,p) or 0;p=p+2;local xp1,xa1;xp1,xa1,p=value_record(data,p,vf1);local xp2,xa2;xp2,xa2,p=value_record(data,p,vf2);if second==right then return xa1+xp2 end end
            return 0
        end
    elseif fmt==2 then
        local cov=base+(u16(data,base+2) or 0);local vf1=u16(data,base+4) or 0;local vf2=u16(data,base+6) or 0;local cd1=base+(u16(data,base+8) or 0);local cd2=base+(u16(data,base+10) or 0);local c1=u16(data,base+12) or 0;local c2=u16(data,base+14) or 0
        local matrix=base+16;local recsize=0;for bit=1,0x80 do if floor(vf1/bit)%2==1 then recsize=recsize+2 end;if floor(vf2/bit)%2==1 then recsize=recsize+2 end;bit=bit*2;if bit>0x80 then break end end
        return function(left,right)
            if coverage_index(data,cov,left)==nil then return 0 end
            local a=class_value(data,cd1,left);local b=class_value(data,cd2,right);if a>=c1 or b>=c2 then return 0 end
            local p=matrix+(a*c2+b)*recsize;local xp1,xa1;xp1,xa1,p=value_record(data,p,vf1);local xp2,xa2;xp2,xa2,p=value_record(data,p,vf2);return xa1+xp2
        end
    end
    return function() return 0 end
end

local function parse_gpos_kern(t)
    local data=t["GPOS"];if not data then return nil end
    local featureOff=u16(data,7);local lookupOff=u16(data,9);if not featureOff or not lookupOff then return nil end
    local fb=featureOff+1;local lbase=lookupOff+1;local wanted={};local fcount=u16(data,fb) or 0
    for i=0,fcount-1 do local p=fb+2+i*6;local tag=sub(data,p,4);local off=u16(data,p+4);if (tag=="kern" or tag=="dist") and off then local q=fb+off;local n=u16(data,q+2) or 0;for j=0,n-1 do wanted[u16(data,q+4+j*2) or -1]=true end end end
    local functions={};local lcount=u16(data,lbase) or 0
    for li=0,lcount-1 do if wanted[li] then local lo=u16(data,lbase+2+li*2);if lo then local lp=lbase+lo;local ltype=u16(data,lp) or 0;local scount=u16(data,lp+4) or 0
        for si=0,scount-1 do local so=u16(data,lp+6+si*2);if so then local sb=lp+so;local actual_type=ltype;local actual_base=sb
            if ltype==9 then local ef=u16(data,sb) or 0;if ef==1 then actual_type=u16(data,sb+2) or 0;actual_base=sb+(u32(data,sb+4) or 0) end end
            if actual_type==2 then functions[#functions+1]=parse_pairpos(data,actual_base) end
        end end
    end end end
    if #functions==0 then return nil end
    return function(left,right) local v=0;for _,fn in ipairs(functions) do v=v+(fn(left,right) or 0) end;return v end
end

local function load_sfnt(data, options)
    local tables,err,container=choose_sfnt(data,options.face or options.index)
    if not tables then return nil,err end
    local variation,verr=resolve_variations(tables,options);if not variation then return fail(verr) end
    local head=tables["head"];local hhea=tables["hhea"];local maxp=tables["maxp"]
    if not head or not hhea or not maxp then return fail("font lacks required head/hhea/maxp tables") end
    local numGlyphs=u16(maxp,5) or 0;local names=parse_names(tables);local lookup,cerr,variant_lookup,cmap_info=parse_cmap(tables);if not lookup then return nil,cerr end
    local advances,aerr,lsbs=make_metrics(tables,numGlyphs);if not advances then return nil,aerr end
    local vadv,vtsb,verr2=make_vertical_metrics(tables,numGlyphs);if verr2 then return nil,verr2 end
    local mvar=parse_mvar(tables,variation);local gasp=parse_gasp(tables,mvar);local gm=sfnt_global_metrics(tables,hhea,mvar)
    local cpal=parse_cpal(tables);local colr=parse_colr(tables,cpal,variation);local svg=parse_svg_table(tables,numGlyphs);local cbdt=parse_cbdt_cblc(tables);local sbix=parse_sbix(tables,numGlyphs)
    local vorg=parse_vorg(tables);local vvar=parse_vvar(tables,variation)
    local bitmap_strikes={}
    if cbdt then for _,st in ipairs(cbdt.public_strikes or {}) do local q={};for k,v in pairs(st) do q[k]=v end;q.format="CBDT/CBLC";bitmap_strikes[#bitmap_strikes+1]=q end end
    if sbix then for _,st in ipairs(sbix.public_strikes or {}) do bitmap_strikes[#bitmap_strikes+1]=st end end
    local function color_bitmap_for_gid(gid,ppem,ppi)
        local im=cbdt and cbdt.get(gid,ppem,ppi) or nil;if im then im.bitmap_format=im.bitmap_format or "CBDT/CBLC";return im end
        return sbix and sbix.get(gid,ppem,ppi) or nil
    end
    local font={
        family=names.family or "Unnamed Font",style=names.style or "Regular",full_name=names.full_name or names.family or "Unnamed Font",postscript_name=names.postscript_name,
        units_per_em=u16(head,19) or 1000,head_flags=u16(head,17) or 0,force_integer_ppem=floor((u16(head,17) or 0)/8)%2==1,ascent=gm.ascent,descent=gm.descent,line_gap=gm.line_gap,
        default_advance=advances[lookup(32) or 0] or advances[0] or 0,mode="fill",fill_rule="nonzero",glyphs={},aliases={},kern={},
        source_format=container,_num_glyphs=numGlyphs,_lookup_gid=lookup,_lookup_variant_gid=variant_lookup,_cmap_info=cmap_info,_advances=advances,_lsbs=lsbs,_v_advances=vadv,_v_tsbs=vtsb,has_vertical_metrics=vadv~=nil,_kern_glyphs=parse_kern(tables),_gpos_kern=parse_gpos_kern(tables),
        _tables=tables,
        variable=(tables["fvar"] ~= nil or tables["gvar"] ~= nil or tables["CFF2"] ~= nil),
        variation_axes=variation.axes,variations=variation.design,_normalized_variations=variation.normalized,
        metrics_source=gm.metrics_source,use_typo_metrics=gm.use_typo_metrics,typo_ascent=gm.typo_ascent,typo_descent=gm.typo_descent,typo_line_gap=gm.typo_line_gap,
        win_ascent=gm.win_ascent,win_descent=gm.win_descent,x_height=gm.x_height,cap_height=gm.cap_height,
        subscript_x_size=gm.subscript_x_size,subscript_y_size=gm.subscript_y_size,subscript_x_offset=gm.subscript_x_offset,subscript_y_offset=gm.subscript_y_offset,
        superscript_x_size=gm.superscript_x_size,superscript_y_size=gm.superscript_y_size,superscript_x_offset=gm.superscript_x_offset,superscript_y_offset=gm.superscript_y_offset,
        strikeout_size=gm.strikeout_size,strikeout_position=gm.strikeout_position,underline_position=gm.underline_position,underline_thickness=gm.underline_thickness,
        caret_slope_rise=gm.caret_slope_rise,caret_slope_run=gm.caret_slope_run,caret_offset=gm.caret_offset,
        vertical_ascent=gm.vertical_ascent,vertical_descent=gm.vertical_descent,vertical_line_gap=gm.vertical_line_gap,
        vertical_caret_slope_rise=gm.vertical_caret_slope_rise,vertical_caret_slope_run=gm.vertical_caret_slope_run,vertical_caret_offset=gm.vertical_caret_offset,
        _mvar_deltas=mvar,_gasp=gasp,gasp_version=gasp and gasp.version or nil,gasp_ranges=gasp and gasp.ranges or nil,_gasp_behavior=gasp and gasp.behavior or nil,_vorg=vorg,vorg_default_y=vorg and vorg.default_y or nil,vorg_glyph_count=vorg and vorg.count or 0,
        color_palettes=cpal and cpal.palettes or nil,color_palette_count=cpal and cpal.num_palettes or 0,color_palette_entries=cpal and cpal.num_entries or 0,color_palette_version=cpal and cpal.version or nil,
        color_palette_types=cpal and cpal.palette_types or nil,color_palette_label_ids=cpal and cpal.palette_label_ids or nil,color_palette_entry_label_ids=cpal and cpal.palette_entry_label_ids or nil,
        _colr_version=colr and colr.version or nil,_colr_layers=colr and colr.glyphs or nil,_colr_v1=colr and colr.roots or nil,
        _colr_clip_for_gid=colr and colr.clip_for_gid or nil,colr_clip_count=colr and colr.clip_count or 0,
        _svg_for_gid=svg and svg.get or nil,svg_glyph_count=svg and svg.glyph_count or 0,color_svg_format=svg and "SVG" or nil,
        bitmap_strikes=#bitmap_strikes>0 and bitmap_strikes or nil,
        color_bitmap_format=(cbdt and sbix and "CBDT/CBLC+sbix") or (cbdt and "CBDT/CBLC") or (sbix and "sbix") or nil,
        _bitmap_for_gid=(cbdt or sbix) and color_bitmap_for_gid or nil,_sbix_flags=sbix and sbix.flags or nil,_sbix_draw_outlines=sbix and sbix.draw_outlines or false,
    }
    if cbdt and cbdt._cache then F._track_cache(font,cbdt._cache) end
    if sbix and sbix._cache then F._track_cache(font,sbix._cache) end
    if svg and svg._cache then F._track_cache(font,svg._cache) end

    if M.opentype and M.opentype.parse then
        local layout_options={normalized_variations=variation.normalized,units_per_em=font.units_per_em}
        font._gsub=M.opentype.parse(tables["GSUB"],"GSUB",tables["GDEF"],layout_options)
        font._gpos=M.opentype.parse(tables["GPOS"],"GPOS",tables["GDEF"],layout_options)
    end
    local hvar_delta=parse_hvar(tables,variation)
    local function attach_varc(base_provider,provider_at_coords)
        if not tables["VARC"] then font._base_outline_for_gid=base_provider;font._base_outline_at_normalized=provider_at_coords or base_provider;return true end
        local varc,ve=parse_varc_source(tables,font,variation,base_provider,provider_at_coords or base_provider)
        if not varc then return nil,ve end
        font._base_outline_for_gid=base_provider;font._base_outline_at_normalized=provider_at_coords or base_provider;font._varc=varc
        font.varc_available=true;font.varc_version=tostring(varc.major).."."..tostring(varc.minor)
        font._outline_for_gid=function(gid) if varc:has_gid(gid) then return varc:outline(gid,variation.normalized) end;return base_provider(gid) end
        return true
    end
    if tables["glyf"] then
        local provider,perr,metric_source,gvar_advance,gvar_vertical,design_bounds,hint_source,provider_at_coords=parse_glyf_source(tables,font,variation);if not provider then return nil,perr end
        font._outline_for_gid=provider;font._metric_source_for_gid=metric_source;font._gvar_vertical_for_gid=gvar_vertical;font._design_bounds_for_gid=design_bounds;font._tt_hint_source=hint_source;font.outline_format="truetype"
        local vok,ve=attach_varc(provider,provider_at_coords);if not vok then return fail(ve) end
        if font._varc then
            local base_bounds=font._design_bounds_for_gid
            font._design_bounds_for_gid=function(gid)
                if not font._varc:has_gid(gid) then return base_bounds(gid) end
                local contours=font._outline_for_gid(gid) or {};local minx,miny,maxx,maxy
                for _,c in ipairs(contours) do for _,pt in ipairs(c) do local x,y=pt.x or 0,font.ascent-(pt.y or 0);minx=minx and math.min(minx,x) or x;maxx=maxx and math.max(maxx,x) or x;miny=miny and math.min(miny,y) or y;maxy=maxy and math.max(maxy,y) or y end end
                return minx or 0,miny or 0,maxx or 0,maxy or 0
            end
        end
        if M.truetype_vm and M.truetype_vm.new then
            font._tt_vm=M.truetype_vm.new(tables,{units_per_em=font.units_per_em,normalized_variations=variation.normalized,variation_axis_count=#(variation.axes or {})})
            font.truetype_vm_available=true
            local function tt_iround(v)
                if v>=0 then return floor(v+0.5) end
                return ceil(v-0.5)
            end
            local function tt_pix_round(v) return floor(((tonumber(v) or 0)+32)/64)*64 end
            local function tt_flag(v,bit) return floor((tonumber(v) or 0)/bit)%2==1 end
            local function tt_clone_point(pt)
                return {x=tt_iround((pt and pt.x) or 0),y=tt_iround((pt and pt.y) or 0),on=not pt or pt.on~=false,
                    touched_x=pt and pt.touched_x==true or false,touched_y=pt and pt.touched_y==true or false}
            end
            local function tt_scale_point(pt,sx,sy)
                local ux=((pt and pt.x) or 0)*sx;local uy=((pt and pt.y) or 0)*sy
                return {x=tt_iround(ux),y=tt_iround(uy),orus_x=ux,orus_y=uy,on=not pt or pt.on~=false}
            end
            local function tt_transform_device_point(pt,r,sx,sy)
                -- Components are hinted before their composite transform.
                local x,y=(pt and pt.x) or 0,(pt and pt.y) or 0
                local xr=(r.xx or 1)*x+(r.yx or 0)*(sx/sy)*y
                local yr=(r.xy or 0)*(sy/sx)*x+(r.yy or 1)*y
                local out=tt_clone_point(pt);out.x=tt_iround(xr);out.y=tt_iround(yr);return out
            end
            local function tt_translate_points(points,dx,dy)
                for _,pt in ipairs(points or {}) do pt.x=tt_iround((pt.x or 0)+dx);pt.y=tt_iround((pt.y or 0)+dy) end
            end
            local function tt_point_at(points,phantoms,index,total_points)
                index=tonumber(index) or -1
                if index<0 then return nil end
                if index<#(points or {}) then return points[index+1] end
                if total_points and index>=total_points then return phantoms[index-total_points+1] end
                return nil
            end

            function font:_hinted_glyph_for_gid(gid,ppem_x,ppem_y,vm_options)
                gid=tonumber(gid) or 0;vm_options=vm_options or {}
                ppem_x=max(1,tonumber(ppem_x) or tonumber(ppem_y) or self.units_per_em)
                ppem_y=max(1,tonumber(ppem_y) or ppem_x)
                local prepared,prep_err=self._tt_vm:prepare(ppem_x,ppem_y,vm_options)
                if not prepared then return nil,prep_err end
                -- VARC composes raw scalable outlines from potentially mixed glyf/gvar and CFF2
                -- leaves.
                if self._varc and self._varc:has_gid(gid) then
                    return {contours=self._outline_for_gid(gid) or {},advance=(self._advance_for_gid and self:_advance_for_gid(gid)) or self._advances[gid] or self.default_advance,skipped=true,no_instructions=true,is_varc=true,graphics=prepared.graphics,ppem_x=prepared.ppem_x,ppem_y=prepared.ppem_y,rotated=vm_options.rotated==true,stretched=vm_options.stretched==true}
                end
                local raw=self._tt_hint_source and self._tt_hint_source(gid) or nil
                if not raw then return nil,"glyph outline is unavailable" end
                if not raw.is_composite and #(raw.instructions or "")==0 then
                    return {contours=self._outline_for_gid(gid) or {},advance=(self._advance_for_gid and self:_advance_for_gid(gid)) or self._advances[gid] or self.default_advance,skipped=true,no_instructions=true,graphics=prepared.graphics,ppem_x=prepared.ppem_x,ppem_y=prepared.ppem_y,rotated=vm_options.rotated==true,stretched=vm_options.stretched==true}
                end
                local sx=(prepared.ppem_x or ppem_x)*64/self.units_per_em
                local sy=(prepared.ppem_y or ppem_y)*64/self.units_per_em
                local active={}
                local max_depth=(self._tt_vm.maxp and self._tt_vm.maxp.max_component_depth) or 0
                if max_depth<=0 then max_depth=64 end

                local function hint_device(hgid,depth)
                    depth=depth or 0
                    if depth>max_depth then return nil,"composite glyph exceeds maxp component depth" end
                    if active[hgid] then return nil,"cyclic composite glyph" end
                    local hraw=self._tt_hint_source and self._tt_hint_source(hgid) or nil
                    if not hraw then return nil,"component glyph outline is unavailable" end
                    active[hgid]=true
                    local function done(v,e) active[hgid]=nil;return v,e end

                    if not hraw.is_composite then
                        local points={}
                        for _,pt in ipairs(hraw.points or {}) do points[#points+1]=tt_scale_point(pt,sx,sy) end
                        for _,pt in ipairs(hraw.phantoms or {}) do points[#points+1]=tt_scale_point(pt,sx,sy) end
                        local fitted=points;local skipped=false;local run
                        if #(hraw.instructions or "")>0 then
                            local run_err
                            run,run_err=self._tt_vm:run_glyph(prepared,hraw.instructions or "",points,hraw.contour_ranges or {},vm_options)
                            if not run then return done(nil,run_err) end
                            if run.error then self._tt_hint_last_warning=run.error end
                            fitted=run.points or points;skipped=run.skipped==true
                        end
                        return done({points=fitted,contour_ranges=hraw.contour_ranges or {},real_count=#(hraw.points or {}),skipped=skipped,had_instructions=#(hraw.instructions or "")>0,graphics=(run and run.graphics) or prepared.graphics})
                    end

                    local assembled={};local ranges={};local phantoms={}
                    for _,pt in ipairs(hraw.own_phantoms or hraw.phantoms or {}) do phantoms[#phantoms+1]=tt_scale_point(pt,sx,sy) end
                    local total_points=0
                    for _,r in ipairs(hraw.components or {}) do total_points=total_points+#((r.child and r.child.points) or {}) end
                    local had_instructions=false

                    for _,r in ipairs(hraw.components or {}) do
                        local child,child_err=hint_device(r.gid,depth+1)
                        if not child then return done(nil,child_err) end
                        if child.had_instructions then had_instructions=true end
                        local child_real={};local child_phantoms={}
                        for i=1,child.real_count or 0 do
                            local pt=child.points and child.points[i]
                            if pt then child_real[#child_real+1]=tt_transform_device_point(pt,r,sx,sy) end
                        end
                        for j=1,4 do
                            local pt=child.points and child.points[(child.real_count or 0)+j]
                            if pt then child_phantoms[#child_phantoms+1]=tt_transform_device_point(pt,r,sx,sy) end
                        end

                        local dx,dy=0,0
                        if r.args_xy then
                            local ux=(r.a1 or 0)+(r.var_dx or 0);local uy=(r.a2 or 0)+(r.var_dy or 0)
                            if tt_flag(r.flags,2048) and not tt_flag(r.flags,4096) then
                                ux,uy=ux*(r.xx or 1)+uy*(r.yx or 0),ux*(r.xy or 0)+uy*(r.yy or 1)
                            end
                            dx,dy=tt_iround(ux*sx),tt_iround(uy*sy)
                            if tt_flag(r.flags,4) then dx,dy=tt_pix_round(dx),tt_pix_round(dy) end
                        else
                            local pa=tt_point_at(assembled,phantoms,r.a1,total_points)
                            local pb=tt_point_at(child_real,child_phantoms,r.a2,child.real_count or #child_real)
                            if not pa or not pb then return done(nil,"composite point attachment index out of range") end
                            dx,dy=(pa.x or 0)-(pb.x or 0),(pa.y or 0)-(pb.y or 0)
                        end
                        tt_translate_points(child_real,dx,dy);tt_translate_points(child_phantoms,dx,dy)

                        local base=#assembled
                        for _,cr in ipairs(child.contour_ranges or {}) do
                            local first=(cr.first or cr[1] or 0)+base;local last=(cr.last or cr[2] or -1)+base
                            ranges[#ranges+1]={first,last}
                        end
                        for _,pt in ipairs(child_real) do assembled[#assembled+1]=pt end
                        if tt_flag(r.flags,512) and #child_phantoms>=4 then
                            phantoms={}
                            for j=1,4 do phantoms[j]=tt_clone_point(child_phantoms[j]) end
                        end
                    end

                    local points={};for _,pt in ipairs(assembled) do points[#points+1]=pt end
                    for j=1,4 do points[#points+1]=tt_clone_point(phantoms[j] or {}) end
                    local skipped=false;local final_graphics=prepared.graphics
                    if #(hraw.instructions or "")>0 then
                        -- Composite instructions see the already hinted, transformed component
                        -- positions as both the current and original zone-1 coordinates,
                        local input={};for _,pt in ipairs(points) do input[#input+1]=tt_clone_point(pt) end
                        local composite_options={};for k,v in pairs(vm_options) do composite_options[k]=v end;composite_options.is_composite=true
                        local run,run_err=self._tt_vm:run_glyph(prepared,hraw.instructions or "",input,ranges,composite_options)
                        if not run then return done(nil,run_err) end
                        if run.error then self._tt_hint_last_warning=run.error end
                        points=run.points or input;skipped=run.skipped==true;had_instructions=true;final_graphics=run.graphics or final_graphics
                    end
                    return done({points=points,contour_ranges=ranges,real_count=#assembled,skipped=skipped,had_instructions=had_instructions,graphics=final_graphics})
                end

                local fitted,fit_err=hint_device(gid,0)
                if not fitted then return nil,fit_err end
                local fitted_points=fitted.points or {};local real_count=fitted.real_count or max(0,#fitted_points-4)
                local invx=self.units_per_em/((prepared.ppem_x or ppem_x)*64)
                local invy=self.units_per_em/((prepared.ppem_y or ppem_y)*64)
                local contours={}
                for _,r in ipairs(fitted.contour_ranges or {}) do
                    local c={};local first=(r.first or r[1] or 0)+1;local last=(r.last or r[2] or -1)+1
                    for pi=first,last do
                        local fp=fitted_points[pi]
                        if fp then c[#c+1]={x=(fp.x or 0)*invx,y=self.ascent-(fp.y or 0)*invy,on=fp.on~=false} end
                    end
                    local flat=quadratic_contour(c);if #flat>0 then contours[#contours+1]=flat end
                end
                local p1,p2=fitted_points[real_count+1],fitted_points[real_count+2]
                local advance
                if p1 and p2 then advance=((p2.x or 0)-(p1.x or 0))*invx end
                return {contours=contours,advance=advance,points=fitted_points,graphics=fitted.graphics or prepared.graphics,ppem_x=prepared.ppem_x,ppem_y=prepared.ppem_y,rotated=vm_options.rotated==true,stretched=vm_options.stretched==true,skipped=fitted.skipped==true,no_instructions=not fitted.had_instructions,is_composite=raw.is_composite==true}
            end
        end
        font._advance_for_gid=function(self,gid)
            local mg=self._metric_source_for_gid and self._metric_source_for_gid(gid) or gid
            local a=self._advances[mg] or self._advances[gid] or self.default_advance
            if hvar_delta then return a+hvar_delta(gid) end
            local ga=gvar_advance and gvar_advance(gid);return ga or a
        end
        font.default_advance=font:_advance_for_gid(lookup(32) or 0)
    elseif tables["CFF "] then
        local provider,provider_at_coords=parse_cff_source(tables,font,false,variation);if not provider then return nil,provider_at_coords end;font._outline_for_gid=provider;font.outline_format="cff"
        local vok,ve=attach_varc(provider,provider_at_coords);if not vok then return fail(ve) end
        font._advance_for_gid=function(self,gid)local a=self._advances[gid] or self.default_advance;return a+(hvar_delta and hvar_delta(gid) or 0) end
    elseif tables["CFF2"] then
        local provider,provider_at_coords=parse_cff_source(tables,font,true,variation);if not provider then return nil,provider_at_coords end;font._outline_for_gid=provider;font.outline_format="cff2"
        local vok,ve=attach_varc(provider,provider_at_coords);if not vok then return fail(ve) end
        font._advance_for_gid=function(self,gid)local a=self._advances[gid] or self.default_advance;return a+(hvar_delta and hvar_delta(gid) or 0) end
        font.default_advance=font:_advance_for_gid(lookup(32) or 0)
    elseif cbdt or sbix then
        -- Bitmap-only OpenType fonts such as Noto Color Emoji / sbix emoji faces legitimately
        -- have no glyf/CFF outline table.
        font._outline_for_gid=function() return nil end;font.outline_format="bitmap"
        font._advance_for_gid=function(self,gid)local a=self._advances[gid] or self.default_advance;return a+(hvar_delta and hvar_delta(gid) or 0) end
        font.default_advance=font:_advance_for_gid(lookup(32) or 0)
    else return fail("font has no supported outline or color-bitmap glyph data") end

    if font._tt_vm then
        -- Expose the size-dependent VM setup for diagnostics/tests.
        function font:prepare_truetype_vm(ppem_x,ppem_y,vm_options)
            return self._tt_vm:prepare(ppem_x,ppem_y,vm_options)
        end
        function font:truetype_vm_diagnostics()
            local d=self._tt_vm:diagnostics()
            d.last_error=self._tt_hint_last_error
            d.last_recoverable_warning=self._tt_hint_last_warning
            return d
        end
    end

    -- Resolve per-glyph vertical metrics after the outline provider is known.
    local function outline_design_bounds(gid)
        if font._design_bounds_for_gid then return font._design_bounds_for_gid(gid) end
        local contours=font._outline_for_gid and font._outline_for_gid(gid) or nil
        local minx,miny,maxx,maxy
        for _,c in ipairs(contours or {}) do for _,pt in ipairs(c or {}) do
            local x,y=pt.x or 0,pt.y or 0;minx=minx and math.min(minx,x) or x;maxx=maxx and math.max(maxx,x) or x;miny=miny and math.min(miny,y) or y;maxy=maxy and math.max(maxy,y) or y
        end end
        if not miny then return 0,0,0,0 end
        -- Cached scalable outlines use y-down coordinates: recover the font's design-space y-up
        -- bounds.
        return minx,font.ascent-maxy,maxx,font.ascent-miny
    end
    font._vertical_metrics_for_gid=function(self,gid)
        gid=tonumber(gid) or 0
        local mg=self._metric_source_for_gid and self._metric_source_for_gid(gid) or gid
        local _,ymin,_,ymax=outline_design_bounds(gid)
        local ah=self._v_advances and (self._v_advances[mg] or self._v_advances[gid]) or nil
        local tsb=self._v_tsbs and (self._v_tsbs[mg] or self._v_tsbs[gid]) or nil
        local synthesized=false
        if not ah then
            synthesized=true
            ah=(self.vertical_ascent and self.vertical_descent) and (self.vertical_ascent-self.vertical_descent) or self.units_per_em
            if not ah or ah<=0 then ah=self.units_per_em end
            tsb=(self.vertical_ascent or self.ascent or self.units_per_em)-ymax
        end
        local origin;local gv_origin,gv_advance
        if self._gvar_vertical_for_gid then gv_origin,gv_advance=self._gvar_vertical_for_gid(gid) end
        if vvar and vvar.advance then ah=ah+(vvar.advance(gid) or 0) elseif gv_advance then ah=gv_advance end
        if self.outline_format~="truetype" and self._vorg then
            origin=self._vorg:get(gid)+(vvar and vvar.vorg and (vvar.vorg(gid) or 0) or 0)
        elseif gv_origin then
            origin=gv_origin
        else
            tsb=(tsb or 0)+(vvar and vvar.tsb and (vvar.tsb(gid) or 0) or 0)
            origin=ymax+tsb
        end
        -- The vertical origin is authoritative; report the side bearing that corresponds to the
        -- resolved instance/bounds rather than a stale default vmtx value.
        tsb=origin-ymax
        local bsb=ah-(tsb+(ymax-ymin))
        if vvar and vvar.bsb then bsb=bsb+(vvar.bsb(gid) or 0) end
        local ox=((self._advance_for_gid and self:_advance_for_gid(gid)) or self._advances[gid] or self.default_advance)/2
        return {advance=ah,top_side_bearing=tsb or (origin-ymax),bottom_side_bearing=bsb,origin_x=ox,origin_y=origin,synthesized=synthesized}
    end
    font._get_glyph=function(self,cp)
        local gid=self._lookup_gid(cp) or 0; if gid==0 and cp~=0 then return nil end
        return {gid=gid,advance=(self._advance_for_gid and self:_advance_for_gid(gid)) or self._advances[gid] or self.default_advance,contours=self._outline_for_gid(gid)}
    end
    -- SFNT glyph index 0 is the .notdef glyph.
    font._get_missing_glyph=function(self)
        local gid=0
        return {gid=gid,missing=true,advance=(self._advance_for_gid and self:_advance_for_gid(gid)) or self._advances[gid] or self.default_advance,contours=self._outline_for_gid and self._outline_for_gid(gid) or nil}
    end
    return F._normalize(font)
end

local function parse_bdf(data)
    if not data:match("^STARTFONT") then return fail("not BDF") end
    local ascent=0;local descent=0;local family="BDF Font";local default_advance=8;local glyphs={};local lines={}
    for line in (data.."\n"):gmatch("(.-)\r?\n") do lines[#lines+1]=line end
    local i=1
    while i<=#lines do local line=lines[i]
        local v=line:match("^FONT_ASCENT%s+(%-?%d+)");if v then ascent=tonumber(v) end
        v=line:match("^FONT_DESCENT%s+(%-?%d+)");if v then descent=tonumber(v) end
        local fam=line:match('^FAMILY_NAME%s+"(.-)"');if fam then family=fam end
        if line:match("^STARTCHAR") then
            local cp,adv,bw,bh,bx,by;local bitmap={};i=i+1
            while i<=#lines and not lines[i]:match("^ENDCHAR") do local l=lines[i]
                local e=l:match("^ENCODING%s+(%-?%d+)");if e then cp=tonumber(e) end
                local a=l:match("^DWIDTH%s+(%-?%d+)");if a then adv=tonumber(a) end
                local a1,a2,a3,a4=l:match("^BBX%s+(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)");if a1 then bw,bh,bx,by=tonumber(a1),tonumber(a2),tonumber(a3),tonumber(a4) end
                if l=="BITMAP" then i=i+1;while i<=#lines and not lines[i]:match("^ENDCHAR") do bitmap[#bitmap+1]=lines[i];i=i+1 end;break end
                i=i+1
            end
            if cp and cp>=0 and bw and bh then local contours={};local top=ascent-(by+bh)
                for row,hex in ipairs(bitmap) do local run=nil
                    for col=0,bw-1 do
                        local ni=floor(col/4)+1;local nib=tonumber(hex:sub(ni,ni),16) or 0;local bit=3-(col%4);local set=floor(nib/(2^bit))%2==1
                        if set and not run then run=col end
                        if run and (not set or col==bw-1) then local finish=set and col+1 or col;local x1=bx+run;local x2=bx+finish;local y1=top+row-1;local y2=y1+1;contours[#contours+1]={{x=x1,y=y1},{x=x2,y=y1},{x=x2,y=y2},{x=x1,y=y2},{x=x1,y=y1}};run=nil end
                    end
                end
                glyphs[cp]={advance=adv or bw,contours=contours};default_advance=adv or default_advance
            end
        end
        i=i+1
    end
    return F._normalize({family=family,style="Regular",full_name=family,units_per_em=max(1,ascent+descent),ascent=ascent,descent=-descent,line_gap=0,default_advance=default_advance,mode="fill",fill_rule="nonzero",glyphs=glyphs,aliases={},kern={},source_format="bdf"})
end

function S.detect(data,path)
    local sig=sub(data,1,4)
    if sig=="wOFF" then return "woff" elseif sig=="wOF2" then return "woff2" elseif sig=="ttcf" then return "ttc" elseif sig=="OTTO" then return "otf" elseif data:byte(1)==0 and data:byte(2)==1 and data:byte(3)==0 and data:byte(4)==0 then return "ttf" end
    if data:sub(1,4)==string.char(1).."fcp" then return "pcf" end
    if (data:byte(1)==0x36 and data:byte(2)==0x04) or data:sub(1,4)==string.char(0x72,0xB5,0x4A,0x86) then return "psf" end
    if data:match("^STARTFONT") then return "bdf" end
    local ext=path and path:lower():match("%.([a-z0-9]+)$");return ext or "unknown"
end

function S.load_data(data,options,path_hint)
    options=options or {}
    if type(data)~="string" then return fail("font data must be a binary string") end
    local err
    if data:byte(1)==0x1F and data:byte(2)==0x8B then
        data,err=gunzip(data);if not data then return nil,err end
        if path_hint then path_hint=path_hint:gsub("%.gz$",""):gsub("%.svgz$",".svg") end
    end
    local kind=S.detect(data,path_hint or options.filename or options.path_hint)
    if kind=="ttf" or kind=="otf" or kind=="ttc" or kind=="otc" or kind=="woff" or kind=="woff2" then return load_sfnt(data,options)
    elseif kind=="pcf" then
        if not S.parse_pcf then return fail("PCF parser is unavailable") end
        return S.parse_pcf(data)
    elseif kind=="psf" or kind=="psf1" or kind=="psf2" then
        if not S.parse_psf then return fail("PSF parser is unavailable") end
        return S.parse_psf(data)
    elseif kind=="bdf" then return parse_bdf(data)
    end
    return fail("unsupported runtime font format: "..tostring(kind))
end

function S.load(path,options)
    options=options or {};local data,err=read_file(path);if not data then return nil,err end
    return S.load_data(data,options,path)
end

return S
