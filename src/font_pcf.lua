-- SPDX-License-Identifier: 0BSD
-- PCF bitmap font loader.
local M=fontlib
local F=M.font
local S=assert(F.source)
local floor,max,min=math.floor,math.max,math.min

local function le16(d,p)local a,b=d:byte(p,p+1);if not b then return nil end;return a+b*256 end
local function le32(d,p)local a,b,c,e=d:byte(p,p+3);if not e then return nil end;return a+b*256+c*65536+e*16777216 end
local function be16(d,p)local a,b=d:byte(p,p+1);if not b then return nil end;return a*256+b end
local function be32(d,p)local a,b,c,e=d:byte(p,p+3);if not e then return nil end;return ((a*256+b)*256+c)*256+e end
local function signed16(n) return n and (n>=32768 and n-65536 or n) or nil end
local function r16(d,p,fmt) return signed16((floor(fmt/4)%2==1) and be16(d,p) or le16(d,p)) end
local function u16(d,p,fmt) return (floor(fmt/4)%2==1) and be16(d,p) or le16(d,p) end
local function r32(d,p,fmt)
    local n=(floor(fmt/4)%2==1) and be32(d,p) or le32(d,p);if not n then return nil end;return n>=0x80000000 and n-0x100000000 or n
end
local function u32(d,p,fmt) return (floor(fmt/4)%2==1) and be32(d,p) or le32(d,p) end

local PCF_PROPERTIES=1
local PCF_ACCELERATORS=2
local PCF_METRICS=4
local PCF_BITMAPS=8
local PCF_BDF_ENCODINGS=32
local PCF_BDF_ACCELERATORS=256

local function tables(data)
    if data:sub(1,4)~=string.char(1).."fcp" then return nil,"not PCF" end
    local n=le32(data,5) or 0;local out={};local p=9
    if n<1 or p+n*16-1>#data then return nil,"invalid PCF table directory" end
    for _=1,n do
        local typ=le32(data,p);local fmt=le32(data,p+4);local size=le32(data,p+8);local off=le32(data,p+12);p=p+16
        if typ and size and off and off+size<=#data then out[typ]={format=fmt,size=size,offset=off+1,data=data:sub(off+1,off+size)} end
    end
    return out
end

local function cstring(s,p)
    local q=s:find("\0",p,true) or (#s+1);return s:sub(p,q-1)
end
local function properties(tab)
    if not tab then return {} end;local d=tab.data;local fmt=le32(d,1) or tab.format or 0;local p=5;local n=u32(d,p,fmt) or 0;p=p+4
    local rec={};for i=1,n do local no=u32(d,p,fmt);local isstr=d:byte(p+4) or 0;local val=u32(d,p+5,fmt);rec[i]={no,isstr,val};p=p+9 end
    local pad=(4-(n%4))%4;p=p+pad;local ssize=u32(d,p,fmt) or 0;p=p+4;local strings=d:sub(p,p+ssize-1);local out={}
    for _,r in ipairs(rec) do local name=cstring(strings,(r[1] or 0)+1);if r[2]~=0 then out[name]=cstring(strings,(r[3] or 0)+1) else out[name]=r[3] end end
    return out
end

local function metrics(tab)
    if not tab then return nil,"PCF has no metrics table" end;local d=tab.data;local fmt=le32(d,1) or tab.format or 0;local p=5;local compressed=floor(fmt/256)%2==1;local count
    if compressed then count=u16(d,p,fmt) or 0;p=p+2 else count=u32(d,p,fmt) or 0;p=p+4 end
    local out={}
    for i=0,count-1 do
        local l,r,w,a,de
        if compressed then
            l=(d:byte(p) or 128)-128;r=(d:byte(p+1) or 128)-128;w=(d:byte(p+2) or 128)-128;a=(d:byte(p+3) or 128)-128;de=(d:byte(p+4) or 128)-128;p=p+5
        else
            l=r16(d,p,fmt) or 0;r=r16(d,p+2,fmt) or 0;w=r16(d,p+4,fmt) or 0;a=r16(d,p+6,fmt) or 0;de=r16(d,p+8,fmt) or 0;p=p+12
        end
        out[i]={left=l,right=r,width=w,ascent=a,descent=de}
    end
    return out,count
end

local function accelerator(tab)
    if not tab then return nil end;local d=tab.data;local fmt=le32(d,1) or tab.format or 0
    return {ascent=r32(d,13,fmt) or 0,descent=r32(d,17,fmt) or 0}
end

local function encodings(tab)
    if not tab then return nil,"PCF has no encoding table" end;local d=tab.data;local fmt=le32(d,1) or tab.format or 0
    local min2=u16(d,5,fmt) or 0;local max2=u16(d,7,fmt) or 0;local min1=u16(d,9,fmt) or 0;local max1=u16(d,11,fmt) or 0
    local cols=max2-min2+1;local rows=max1-min1+1;if cols<1 or rows<1 then return {},0 end
    local map={};local p=15
    for b1=min1,max1 do for b2=min2,max2 do local gid=u16(d,p,fmt) or 0xFFFF;p=p+2;if gid~=0xFFFF then local cp=b1*256+b2;map[cp]=gid end end end
    return map
end

local function reverse_byte(v)
    local r=0;for _=1,8 do r=r*2+(v%2);v=floor(v/2) end;return r
end
local function normalize_row(row,fmt,scan_unit)
    local bit_msb=floor(fmt/8)%2==1;local byte_msb=floor(fmt/4)%2==1
    local bytes={row:byte(1,#row)}
    if scan_unit>1 and bit_msb~=byte_msb then
        for i=1,#bytes,scan_unit do local j1,j2=i,min(i+scan_unit-1,#bytes);while j1<j2 do bytes[j1],bytes[j2]=bytes[j2],bytes[j1];j1=j1+1;j2=j2-1 end end
    end
    if not bit_msb then for i=1,#bytes do bytes[i]=reverse_byte(bytes[i]) end end
    return bytes
end

local function bitmap_provider(tab, mets, count, font_ascent)
    if not tab then return nil,"PCF has no bitmap table" end;local d=tab.data;local fmt=le32(d,1) or tab.format or 0;local p=5;local n=u32(d,p,fmt) or 0;p=p+4
    if n~=count then count=min(n,count) end
    local offsets={};for i=0,n-1 do offsets[i]=u32(d,p,fmt) or 0;p=p+4 end
    local sizes={};for i=0,3 do sizes[i]=u32(d,p,fmt) or 0;p=p+4 end
    local data_start=p;local pad=2^(fmt%4);local scan=2^(floor(fmt/16)%4);local cache={}
    local function provider(gid)
        if cache[gid] then return cache[gid] end;if gid<0 or gid>=count then return {} end
        local m=mets[gid];if not m then return {} end
        local width=max(0,m.right-m.left);local height=max(0,m.ascent+m.descent);local rowbytes=math.ceil(width/8);local stride=math.ceil(rowbytes/pad)*pad
        local off=offsets[gid] or 0;local contours={};local top=font_ascent-m.ascent
        for y=0,height-1 do
            local row=d:sub(data_start+off+y*stride,data_start+off+y*stride+stride-1);local rb=normalize_row(row,fmt,scan);local run=nil
            for x=0,width-1 do local byte=rb[floor(x/8)+1] or 0;local set=floor(byte/(2^(7-(x%8))))%2==1
                if set and not run then run=x end
                if run and (not set or x==width-1) then local finish=set and x+1 or x;local x1=m.left+run;local x2=m.left+finish;local y1=top+y;contours[#contours+1]={{x=x1,y=y1},{x=x2,y=y1},{x=x2,y=y1+1},{x=x1,y=y1+1},{x=x1,y=y1}};run=nil end
            end
        end
        cache[gid]=contours;return contours
    end
    return provider, cache
end

function S.parse_pcf(data)
    local t,err=tables(data);if not t then return nil,err end
    local props=properties(t[PCF_PROPERTIES]);local mets,count=metrics(t[PCF_METRICS]);if not mets then return nil,count end
    local enc,eerr=encodings(t[PCF_BDF_ENCODINGS]);if not enc then return nil,eerr end
    local acc=accelerator(t[PCF_BDF_ACCELERATORS] or t[PCF_ACCELERATORS]);local ascent=acc and acc.ascent or 0;local descent=acc and acc.descent or 0
    if ascent<=0 then for _,m in pairs(mets) do ascent=max(ascent,m.ascent or 0);descent=max(descent,m.descent or 0) end end
    local outlines,bitmap_cache=bitmap_provider(t[PCF_BITMAPS],mets,count,ascent);if not outlines then return nil,bitmap_cache end
    local family=props.FAMILY_NAME or props.FACE_NAME or "PCF Font";local style=props.WEIGHT_NAME or "Regular";local size=max(1,ascent+descent)
    local font=F._normalize({family=family,style=style,full_name=family,units_per_em=size,ascent=ascent,descent=-descent,line_gap=0,default_advance=size/2,mode="fill",fill_rule="nonzero",glyphs={},aliases={},kern={},source_format="pcf",outline_format="bitmap"})
    if bitmap_cache then F._track_cache(font,bitmap_cache) end
    font._lookup_gid=function(cp) return enc[cp] or 0 end
    font._get_glyph=function(self,cp) local gid=enc[cp];if gid==nil then return nil end;local m=mets[gid];return {gid=gid,advance=m and m.width or self.default_advance,contours=outlines(gid)} end
    local space=enc[32] and mets[enc[32]];if space then font.default_advance=space.width end
    return font
end
return S
