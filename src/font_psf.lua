-- SPDX-License-Identifier: 0BSD
-- PSF bitmap font loader.
local M=fontlib
local F=M.font
local S=assert(F.source)
local floor, max = math.floor, math.max

local function le16(d,p)
    local a,b=d:byte(p,p+1); if not b then return nil end; return a+b*256
end
local function le32(d,p)
    local a,b,c,e=d:byte(p,p+3); if not e then return nil end; return a+b*256+c*65536+e*16777216
end
local function utf8_codes(s)
    local out={};local p=1
    while p<=#s do
        local a=s:byte(p);local cp,n
        if a<0x80 then cp,n=a,1
        elseif a<0xE0 then local b=s:byte(p+1) or 0;cp,n=(a-0xC0)*64+(b-0x80),2
        elseif a<0xF0 then local b,c=s:byte(p+1,p+2);b=b or 0;c=c or 0;cp,n=(a-0xE0)*4096+(b-0x80)*64+(c-0x80),3
        else local b,c,d=s:byte(p+1,p+3);b=b or 0;c=c or 0;d=d or 0;cp,n=(a-0xF0)*262144+(b-0x80)*4096+(c-0x80)*64+(d-0x80),4 end
        if cp>=0 and cp<=0x10FFFF then out[#out+1]=cp end;p=p+n
    end
    return out
end
local function bitmap_contours(bytes,width,height)
    local contours={};local rowbytes=math.ceil(width/8)
    for y=0,height-1 do
        local run=nil
        for x=0,width-1 do
            local b=bytes:byte(y*rowbytes+floor(x/8)+1) or 0
            local set=floor(b/(2^(7-(x%8))))%2==1
            if set and not run then run=x end
            if run and (not set or x==width-1) then
                local finish=set and x+1 or x
                contours[#contours+1]={{x=run,y=y},{x=finish,y=y},{x=finish,y=y+1},{x=run,y=y+1},{x=run,y=y}}
                run=nil
            end
        end
    end
    return contours
end

local function psf1(data)
    if data:byte(1)~=0x36 or data:byte(2)~=0x04 then return nil,"not PSF1" end
    local mode=data:byte(3) or 0;local charsize=data:byte(4) or 0
    local count=(mode%2==1) and 512 or 256;local start=5;local need=start+count*charsize-1
    if charsize<1 or need>#data then return nil,"truncated PSF1 glyph data" end
    local cp_to_gid={}
    if floor(mode/2)%2==1 or floor(mode/4)%2==1 then
        local p=need+1;local gid=0
        while gid<count and p+1<=#data do
            local v=le16(data,p);p=p+2
            if v==0xFFFF then gid=gid+1
            elseif v~=0xFFFE and v and not cp_to_gid[v] then cp_to_gid[v]=gid end
        end
    else
        for cp=0,math.min(255,count-1) do cp_to_gid[cp]=cp end
    end
    local cache={}
    local font=F._normalize({family="PSF Console Font",style="Regular",full_name="PSF Console Font",units_per_em=charsize,ascent=charsize,descent=0,line_gap=0,default_advance=8,mode="fill",fill_rule="nonzero",glyphs={},aliases={},kern={},source_format="psf1",outline_format="bitmap"})
    F._track_cache(font,cache)
    font._lookup_gid=function(cp) return cp_to_gid[cp] or 0 end
    font._get_glyph=function(self,cp)
        local gid=cp_to_gid[cp];if gid==nil then return nil end
        if cache[gid] then return cache[gid] end
        local bytes=data:sub(start+gid*charsize,start+(gid+1)*charsize-1)
        local g={gid=gid,advance=8,contours=bitmap_contours(bytes,8,charsize)};cache[gid]=g;return g
    end
    return font
end

local function psf2(data)
    if data:sub(1,4)~=string.char(0x72,0xB5,0x4A,0x86) then return nil,"not PSF2" end
    local headersize=le32(data,9) or 0;local flags=le32(data,13) or 0;local count=le32(data,17) or 0
    local charsize=le32(data,21) or 0;local height=le32(data,25) or 0;local width=le32(data,29) or 0
    if headersize<32 or count<1 or charsize<1 or height<1 or width<1 then return nil,"invalid PSF2 header" end
    local start=headersize+1;local need=start+count*charsize-1;if need>#data then return nil,"truncated PSF2 glyph data" end
    local cp_to_gid={}
    if flags%2==1 then
        local p=need+1;local gid=0;local buf={}
        local function flush()
            if #buf>0 then local cps=utf8_codes(table.concat(buf));if cps[1] and not cp_to_gid[cps[1]] then cp_to_gid[cps[1]]=gid end end;buf={}
        end
        while gid<count and p<=#data do
            local b=data:byte(p);p=p+1
            if b==0xFF then flush();gid=gid+1
            elseif b==0xFE then flush() -- following bytes are a sequence; first codepoint still useful only as fallback
            else buf[#buf+1]=string.char(b) end
        end
    else
        for cp=0,math.min(255,count-1) do cp_to_gid[cp]=cp end
    end
    local cache={};local upem=max(height,width)
    local font=F._normalize({family="PSF Console Font",style="Regular",full_name="PSF Console Font",units_per_em=upem,ascent=height,descent=0,line_gap=0,default_advance=width,mode="fill",fill_rule="nonzero",glyphs={},aliases={},kern={},source_format="psf2",outline_format="bitmap"})
    F._track_cache(font,cache)
    font._lookup_gid=function(cp) return cp_to_gid[cp] or 0 end
    font._get_glyph=function(self,cp)
        local gid=cp_to_gid[cp];if gid==nil then return nil end
        if cache[gid] then return cache[gid] end
        local bytes=data:sub(start+gid*charsize,start+(gid+1)*charsize-1)
        local g={gid=gid,advance=width,contours=bitmap_contours(bytes,width,height)};cache[gid]=g;return g
    end
    return font
end

function S.parse_psf(data)
    if data:byte(1)==0x36 and data:byte(2)==0x04 then return psf1(data) end
    if data:sub(1,4)==string.char(0x72,0xB5,0x4A,0x86) then return psf2(data) end
    return nil,"not a PSF font"
end
return S
