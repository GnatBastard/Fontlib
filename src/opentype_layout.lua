-- SPDX-License-Identifier: 0BSD
-- OpenType GSUB/GPOS/GDEF support.
local M = fontlib
local U = assert(M.unicode)
local OT = {}
M.opentype = OT

local floor = math.floor
local sub = string.sub

local function u8(s,p) return s:byte(p) or 0 end
local function u16(s,p)
    local a,b=s:byte(p,p+1); if not b then return nil end
    return a*256+b
end
local function s16(s,p)
    local v=u16(s,p); if not v then return nil end
    return v>=32768 and v-65536 or v
end
local function s8(s,p)
    local v=u8(s,p); return v>=128 and v-256 or v
end
local function u32(s,p)
    local a,b,c,d=s:byte(p,p+3); if not d then return nil end
    return ((a*256+b)*256+c)*256+d
end
local function s32(s,p)
    local v=u32(s,p); if not v then return nil end
    return v>=2147483648 and v-4294967296 or v
end
local function f2dot14(s,p) return (s16(s,p) or 0)/16384 end
local function tag(s,p) return sub(s,p,p+3) end

local function coverage(data, base)
    local fmt=u16(data,base) or 0
    local map={}
    if fmt==1 then
        local n=u16(data,base+2) or 0
        for i=0,n-1 do local g=u16(data,base+4+i*2); if g then map[g]=i end end
    elseif fmt==2 then
        local n=u16(data,base+2) or 0
        for i=0,n-1 do
            local p=base+4+i*6; local a=u16(data,p) or 0; local b=u16(data,p+2) or -1; local start=u16(data,p+4) or 0
            for g=a,b do map[g]=start+(g-a) end
        end
    end
    return map
end

local function classdef(data, base)
    if not base or base==0 then return function() return 0 end end
    local fmt=u16(data,base) or 0
    if fmt==1 then
        local start=u16(data,base+2) or 0; local n=u16(data,base+4) or 0; local arr={}
        for i=0,n-1 do arr[i]=u16(data,base+6+i*2) or 0 end
        return function(g) if g>=start and g<start+n then return arr[g-start] or 0 end return 0 end
    elseif fmt==2 then
        local n=u16(data,base+2) or 0; local rows={}
        for i=0,n-1 do local p=base+4+i*6; rows[#rows+1]={u16(data,p) or 0,u16(data,p+2) or 0,u16(data,p+4) or 0} end
        return function(g)
            local lo,hi=1,#rows
            while lo<=hi do local mid=floor((lo+hi)/2); local r=rows[mid]
                if g<r[1] then hi=mid-1 elseif g>r[2] then lo=mid+1 else return r[3] end
            end
            return 0
        end
    end
    return function() return 0 end
end

local function region_scalar(region,coords)
    local scalar=1
    for i,axis in ipairs(region or {}) do
        local startv,peak,endv=axis[1],axis[2],axis[3]
        local c=(coords and coords[i]) or 0
        if peak~=0 then
            if startv>peak or peak>endv or (startv<0 and endv>0) then
                -- A malformed axis record does not constrain this region.
            elseif c==peak then
                -- factor 1
            elseif c<=startv or c>=endv then return 0
            elseif c<peak then
                if peak==startv then return 0 end
                scalar=scalar*(c-startv)/(peak-startv)
            else
                if endv==peak then return 0 end
                scalar=scalar*(endv-c)/(endv-peak)
            end
        end
    end
    return scalar
end

local function parse_item_variation_store(data,base)
    if not base or base<1 or base>#data then return nil end
    if (u16(data,base) or 0)~=1 then return nil end
    local region_off=u32(data,base+2);local data_count=u16(data,base+6) or 0
    if not region_off then return nil end
    local rb=base+region_off;local axis_count=u16(data,rb) or 0;local region_count=u16(data,rb+2) or 0
    local p=rb+4;local regions={}
    for r=1,region_count do
        local axes={}
        for a=1,axis_count do axes[a]={f2dot14(data,p),f2dot14(data,p+2),f2dot14(data,p+4)};p=p+6 end
        regions[r]=axes
    end
    local store={regions=regions,var_data={},axis_count=axis_count,_data=data}
    for i=0,data_count-1 do
        local off=u32(data,base+8+i*4)
        if off and off>0 then
            local q=base+off;local item_count=u16(data,q) or 0;local word_raw=u16(data,q+2) or 0;local region_n=u16(data,q+4) or 0
            local long_words=word_raw>=0x8000;local word_count=word_raw%0x8000;local indices={};local z=q+6
            for j=1,region_n do indices[j]=u16(data,z) or 0;z=z+2 end
            local record_size=word_count*(long_words and 4 or 2)+(region_n-word_count)*(long_words and 2 or 1)
            store.var_data[i+1]={item_count=item_count,word_count=word_count,long_words=long_words,region_indices=indices,data_pos=z,record_size=record_size}
        end
    end
    return store
end

local function variation_store_delta(store,outer,inner,coords)
    if not store then return 0 end
    local vd=store.var_data[(outer or 0)+1]
    if not vd or (inner or 0)<0 or (inner or 0)>=vd.item_count then return 0 end
    local p=vd.data_pos+(inner or 0)*vd.record_size;local sum=0
    for j,ri in ipairs(vd.region_indices) do
        local d
        if vd.long_words then
            if j<=vd.word_count then d=s32(store._data,p);p=p+4 else d=s16(store._data,p);p=p+2 end
        else
            if j<=vd.word_count then d=s16(store._data,p);p=p+2 else d=s8(store._data,p);p=p+1 end
        end
        local sc=region_scalar(store.regions[ri+1],coords or {})
        if sc~=0 then sum=sum+(d or 0)*sc end
    end
    return sum
end

local function parse_adjustment(data,base,gdef,coords)
    if not base or base<1 or base+5>#data then return nil end
    local a=u16(data,base) or 0;local b=u16(data,base+2) or 0;local fmt=u16(data,base+4) or 0
    if fmt==0x8000 then
        return {kind="variation",delta=variation_store_delta(gdef and gdef.var_store,a,b,coords or {})}
    elseif fmt>=1 and fmt<=3 then
        return {kind="device",start_size=a,end_size=b,delta_format=fmt,data=data,data_pos=base+6}
    end
    return nil
end

local function adjustment_delta(adj,ppem,units_per_em)
    if not adj then return 0 end
    if adj.kind=="variation" then return adj.delta or 0 end
    if adj.kind~="device" or not ppem or ppem<=0 then return 0 end
    local size=floor(ppem+0.5)
    if size<adj.start_size or size>adj.end_size then return 0 end
    local bits=(adj.delta_format==1 and 2) or (adj.delta_format==2 and 4) or 8
    local per_word=16/bits;local idx=size-adj.start_size;local word=u16(adj.data,adj.data_pos+floor(idx/per_word)*2) or 0
    local shift=(per_word-1-(idx%per_word))*bits;local mask=2^bits-1
    local v=floor(word/2^shift)%2^bits;local sign=2^(bits-1)
    if v>=sign then v=v-2^bits end
    -- Device deltas are pixels, while the rest of the shaper works in design units.
    return v*((units_per_em or ppem)/ppem)
end

local function parse_anchor(data, base, gdef, coords)
    if not base or base==0 then return nil end
    local fmt=u16(data,base) or 0
    if fmt<1 or fmt>3 then return nil end
    local a={x=s16(data,base+2) or 0,y=s16(data,base+4) or 0}
    if fmt==3 then
        local xo=u16(data,base+6) or 0;local yo=u16(data,base+8) or 0
        if xo>0 then a.x_adjust=parse_adjustment(data,base+xo,gdef,coords) end
        if yo>0 then a.y_adjust=parse_adjustment(data,base+yo,gdef,coords) end
    elseif fmt==2 then
        a.anchor_point=u16(data,base+6) or 0
    end
    return a
end

local function anchor_xy(layout,a,ppem)
    if not a then return nil,nil end
    local upem=layout.units_per_em or 1000
    return (a.x or 0)+adjustment_delta(a.x_adjust,ppem,upem),(a.y or 0)+adjustment_delta(a.y_adjust,ppem,upem)
end

local function value_size(fmt)
    local n=0; local bit=1
    for _=1,8 do if floor(fmt/bit)%2==1 then n=n+2 end; bit=bit*2 end
    return n
end

local function value_record(data,p,fmt,base,gdef,coords)
    local v={x_offset=0,y_offset=0,x_advance=0,y_advance=0}; local bit=1
    for field=1,8 do
        if floor(fmt/bit)%2==1 then
            if field<=4 then
                local x=s16(data,p) or 0
                if field==1 then v.x_offset=x elseif field==2 then v.y_offset=x elseif field==3 then v.x_advance=x elseif field==4 then v.y_advance=x end
            else
                local off=u16(data,p) or 0
                if off>0 then
                    local adj=parse_adjustment(data,base+off,gdef,coords)
                    if field==5 then v.x_offset_adjust=adj elseif field==6 then v.y_offset_adjust=adj elseif field==7 then v.x_advance_adjust=adj else v.y_advance_adjust=adj end
                end
            end
            p=p+2
        end
        bit=bit*2
    end
    return v,p
end

local function parse_gdef(data,coords)
    if not data then return {glyph_class=function()return 0 end,mark_attach=function()return 0 end,mark_sets={},has_glyph_class=false} end
    local glyphOff=u16(data,5) or 0; local markOff=u16(data,11) or 0
    local obj={
        glyph_class=classdef(data,glyphOff>0 and (1+glyphOff) or nil),
        mark_attach=classdef(data,markOff>0 and (1+markOff) or nil),
        mark_sets={},
        has_glyph_class=glyphOff>0,
        var_store=nil,
    }
    local major=u16(data,1) or 1; local minor=u16(data,3) or 0
    if major>1 or (major==1 and minor>=2) then
        local off=u16(data,13) or 0
        if off>0 then
            local b=1+off; local fmt=u16(data,b) or 0
            if fmt==1 then
                local n=u16(data,b+2) or 0
                for i=0,n-1 do local co=u32(data,b+4+i*4) or 0; if co>0 then obj.mark_sets[i]=coverage(data,b+co) end end
            end
        end
    end
    if major>1 or (major==1 and minor>=3) then
        local off=u32(data,15) or 0
        if off>0 then obj.var_store=parse_item_variation_store(data,1+off) end
    end
    obj.coords=coords or {}
    return obj
end

local function parse_script_list(data,base)
    local scripts={}; if not base or base<=0 then return scripts end
    local n=u16(data,base) or 0
    for i=0,n-1 do
        local p=base+2+i*6; local st=tag(data,p); local off=u16(data,p+4) or 0; local sb=base+off
        local s={langs={}}
        local def=u16(data,sb) or 0
        local function parse_lang(lb)
            local req=u16(data,lb+2) or 0xFFFF; local cnt=u16(data,lb+4) or 0; local features={}
            if req~=0xFFFF then features[#features+1]=req end
            for j=0,cnt-1 do features[#features+1]=u16(data,lb+6+j*2) or 0 end
            return features
        end
        if def>0 then s.default=parse_lang(sb+def) end
        local lc=u16(data,sb+2) or 0
        for j=0,lc-1 do local q=sb+4+j*6; local lt=tag(data,q); local lo=u16(data,q+4) or 0; s.langs[lt]=parse_lang(sb+lo) end
        scripts[st]=s
    end
    return scripts
end

local function parse_feature_table(data,base)
    if not base or base<=0 then return {lookups={}} end
    local cnt=u16(data,base+2) or 0;local lookups={}
    for j=0,cnt-1 do lookups[#lookups+1]=u16(data,base+4+j*2) or 0 end
    return {lookups=lookups}
end

local function parse_feature_list(data,base)
    local list={}; if not base or base<=0 then return list end
    local n=u16(data,base) or 0
    for i=0,n-1 do
        local p=base+2+i*6; local ft=tag(data,p); local off=u16(data,p+4) or 0; local f=parse_feature_table(data,base+off)
        f.tag=ft;list[i]=f
    end
    return list
end

local function condition_set_matches(data,base,coords)
    if not base then return true end
    local n=u16(data,base) or 0
    for i=0,n-1 do
        local off=u32(data,base+2+i*4) or 0
        if off==0 then return false end
        local cb=base+off;local fmt=u16(data,cb) or 0
        if fmt~=1 then return false end
        local axis=u16(data,cb+2) or 0;local lo=f2dot14(data,cb+4);local hi=f2dot14(data,cb+6)
        local c=coords[axis+1]
        if c==nil or c<lo or c>hi then return false end
    end
    return true
end

local function parse_feature_substitutions(data,base)
    if not base then return nil end
    local major=u16(data,base) or 0;local minor=u16(data,base+2) or 0
    if major~=1 or minor~=0 then return nil end
    local n=u16(data,base+4) or 0;local out={}
    for i=0,n-1 do
        local p=base+6+i*6;local fi=u16(data,p) or 0;local off=u32(data,p+2) or 0
        if off>0 and out[fi]==nil then out[fi]=parse_feature_table(data,base+off).lookups end
    end
    return out
end

local function parse_feature_variations(data,base,coords)
    if not base or base<=0 then return {} end
    local major=u16(data,base) or 0;local minor=u16(data,base+2) or 0
    if major~=1 or minor~=0 then return {} end
    local n=u32(data,base+4) or 0
    for i=0,n-1 do
        local p=base+8+i*8;local co=u32(data,p) or 0;local so=u32(data,p+4) or 0
        local cb=co>0 and base+co or nil
        if condition_set_matches(data,cb,coords or {}) then
            local subst=parse_feature_substitutions(data,so>0 and base+so or nil)
            if subst then return subst end
            -- Unsupported substitution version: continue to the next record.
        end
    end
    return {}
end

local function parse_lookup_headers(data,base)
    local list={}; if not base or base<=0 then return list end
    local n=u16(data,base) or 0
    for i=0,n-1 do
        local off=u16(data,base+2+i*2) or 0; local lb=base+off; local typ=u16(data,lb) or 0; local flag=u16(data,lb+2) or 0; local cnt=u16(data,lb+4) or 0; local subs={}
        for j=0,cnt-1 do subs[#subs+1]=lb+(u16(data,lb+6+j*2) or 0) end
        local markset=nil; if floor(flag/16)%2==1 then markset=u16(data,lb+6+cnt*2) end
        list[i]={type=typ,flag=flag,subtables=subs,mark_filtering_set=markset}
    end
    return list
end

local Layout={}; Layout.__index=Layout

function OT.parse(data,kind,gdef_data,options)
    if not data then return nil end
    options=options or {}
    local coords=options.normalized_variations or options.coords or {}
    local scriptOff=u16(data,5) or 0; local featureOff=u16(data,7) or 0; local lookupOff=u16(data,9) or 0
    local major=u16(data,1) or 1;local minor=u16(data,3) or 0;local fvo=0
    if major>1 or (major==1 and minor>=1) then fvo=u32(data,11) or 0 end
    local substitutions=parse_feature_variations(data,fvo>0 and 1+fvo or nil,coords)
    return setmetatable({data=data,kind=kind,scripts=parse_script_list(data,1+scriptOff),features=parse_feature_list(data,1+featureOff),lookups=parse_lookup_headers(data,1+lookupOff),gdef=parse_gdef(gdef_data,coords),coords=coords,units_per_em=options.units_per_em or 1000,feature_substitutions=substitutions,_parsed={}},Layout)
end

function Layout:script_features(script_tags,language)
    local s
    for _,st in ipairs(script_tags or {}) do if self.scripts[st] then s=self.scripts[st]; break end end
    if not s then s=self.scripts.DFLT end
    if not s then return {} end
    local idx=s.default or {}
    if language and s.langs[language] then idx=s.langs[language] end
    local out={}
    for _,fi in ipairs(idx) do local f=self.features[fi]; if f then
        local list=out[f.tag]; if not list then list={};out[f.tag]=list end
        local lookups=(self.feature_substitutions and self.feature_substitutions[fi]) or f.lookups
        for _,li in ipairs(lookups or {}) do list[#list+1]=li end
    end end
    return out
end

function Layout:has_feature(script_tags,feature,language)
    return self:script_features(script_tags,language)[feature] ~= nil
end

local function glyph_class(layout,item)
    local c=layout.gdef.glyph_class(item.gid or 0)
    -- A present GDEF GlyphClassDef is authoritative: class 0 explicitly means unclassified.
    if c==0 and not layout.gdef.has_glyph_class and item.cp and U.is_mark(item.cp) then c=3 end
    return c
end

local function ignored(layout,lookup,item)
    local flag=lookup.flag or 0; local c=glyph_class(layout,item)
    if floor(flag/2)%2==1 and c==1 then return true end
    if floor(flag/4)%2==1 and c==2 then return true end
    if floor(flag/8)%2==1 and c==3 then return true end
    local mat=floor(flag/256)%256
    if mat~=0 and c==3 and layout.gdef.mark_attach(item.gid or 0)~=mat then return true end
    if floor(flag/16)%2==1 and c==3 then
        local set=layout.gdef.mark_sets[lookup.mark_filtering_set or -1]
        if set and set[item.gid or 0]==nil then return true end
    end
    return false
end

local function next_visible(layout,lookup,buf,i,step)
    i=i+step
    while i>=1 and i<=#buf and ignored(layout,lookup,buf[i]) do i=i+step end
    if i<1 or i>#buf then return nil end
    return i
end

local function matcher_cov(cov) return function(gid) return cov[gid]~=nil end end
local function matcher_class(fn,value) return function(gid) return fn(gid)==value end end
local function matcher_gid(gid) return function(g) return g==gid end end

local function parse_context(layout,lookup,base,chain)
    local data=layout.data; local fmt=u16(data,base) or 0; local rules={}
    if not chain then
        if fmt==1 then
            local cov=coverage(data,base+(u16(data,base+2) or 0)); local setCount=u16(data,base+4) or 0
            for first,ci in pairs(cov) do if ci<setCount then local so=u16(data,base+6+ci*2) or 0;if so>0 then local sb=base+so;local rc=u16(data,sb) or 0
                for r=0,rc-1 do local ro=u16(data,sb+2+r*2) or 0;local rb=sb+ro;local gc=u16(data,rb) or 0;local sc=u16(data,rb+2) or 0;local input={matcher_gid(first)}
                    for j=1,gc-1 do input[#input+1]=matcher_gid(u16(data,rb+2+j*2) or 0) end
                    local rec={};local rp=rb+2+gc*2;for j=0,sc-1 do rec[#rec+1]={u16(data,rp+j*4) or 0,u16(data,rp+j*4+2) or 0} end
                    rules[#rules+1]={input=input,records=rec}
                end
            end end end
        elseif fmt==2 then
            local cov=coverage(data,base+(u16(data,base+2) or 0)); local cd=classdef(data,base+(u16(data,base+4) or 0));local setCount=u16(data,base+6) or 0
            for cls=0,setCount-1 do local so=u16(data,base+8+cls*2) or 0;if so>0 then local sb=base+so;local rc=u16(data,sb) or 0
                for r=0,rc-1 do local ro=u16(data,sb+2+r*2) or 0;local rb=sb+ro;local gc=u16(data,rb) or 0;local sc=u16(data,rb+2) or 0;local input={function(g)return cov[g]~=nil and cd(g)==cls end}
                    for j=1,gc-1 do input[#input+1]=matcher_class(cd,u16(data,rb+2+j*2) or 0) end
                    local rec={};local rp=rb+2+gc*2;for j=0,sc-1 do rec[#rec+1]={u16(data,rp+j*4) or 0,u16(data,rp+j*4+2) or 0} end
                    rules[#rules+1]={input=input,records=rec}
                end
            end end
        elseif fmt==3 then
            local gc=u16(data,base+2) or 0; local sc=u16(data,base+4) or 0; local input={}
            for j=0,gc-1 do input[#input+1]=matcher_cov(coverage(data,base+(u16(data,base+6+j*2) or 0))) end
            local rec={};local rp=base+6+gc*2;for j=0,sc-1 do rec[#rec+1]={u16(data,rp+j*4) or 0,u16(data,rp+j*4+2) or 0} end
            rules[#rules+1]={input=input,records=rec}
        end
    else
        if fmt==1 then
            local cov=coverage(data,base+(u16(data,base+2) or 0)); local setCount=u16(data,base+4) or 0
            for first,ci in pairs(cov) do if ci<setCount then local so=u16(data,base+6+ci*2) or 0;if so>0 then local sb=base+so;local rc=u16(data,sb) or 0
                for r=0,rc-1 do local ro=u16(data,sb+2+r*2) or 0;local rb=sb+ro;local p=rb;local bc=u16(data,p) or 0;p=p+2;local back={};for j=1,bc do back[j]=matcher_gid(u16(data,p) or 0);p=p+2 end
                    local ic=u16(data,p) or 0;p=p+2;local input={matcher_gid(first)};for j=2,ic do input[j]=matcher_gid(u16(data,p) or 0);p=p+2 end
                    local lc=u16(data,p) or 0;p=p+2;local look={};for j=1,lc do look[j]=matcher_gid(u16(data,p) or 0);p=p+2 end
                    local sc=u16(data,p) or 0;p=p+2;local rec={};for j=1,sc do rec[j]={u16(data,p) or 0,u16(data,p+2) or 0};p=p+4 end
                    rules[#rules+1]={backtrack=back,input=input,lookahead=look,records=rec}
                end
            end end end
        elseif fmt==2 then
            local cov=coverage(data,base+(u16(data,base+2) or 0));local bcd=classdef(data,base+(u16(data,base+4) or 0));local icd=classdef(data,base+(u16(data,base+6) or 0));local lcd=classdef(data,base+(u16(data,base+8) or 0));local setCount=u16(data,base+10) or 0
            for cls=0,setCount-1 do local so=u16(data,base+12+cls*2) or 0;if so>0 then local sb=base+so;local rc=u16(data,sb) or 0
                for r=0,rc-1 do local ro=u16(data,sb+2+r*2) or 0;local rb=sb+ro;local p=rb;local bc=u16(data,p) or 0;p=p+2;local back={};for j=1,bc do back[j]=matcher_class(bcd,u16(data,p) or 0);p=p+2 end
                    local ic=u16(data,p) or 0;p=p+2;local input={function(g)return cov[g]~=nil and icd(g)==cls end};for j=2,ic do input[j]=matcher_class(icd,u16(data,p) or 0);p=p+2 end
                    local lc=u16(data,p) or 0;p=p+2;local look={};for j=1,lc do look[j]=matcher_class(lcd,u16(data,p) or 0);p=p+2 end
                    local sc=u16(data,p) or 0;p=p+2;local rec={};for j=1,sc do rec[j]={u16(data,p) or 0,u16(data,p+2) or 0};p=p+4 end
                    rules[#rules+1]={backtrack=back,input=input,lookahead=look,records=rec}
                end
            end end
        elseif fmt==3 then
            local p=base+2;local bc=u16(data,p) or 0;p=p+2;local back={};for j=1,bc do back[j]=matcher_cov(coverage(data,base+(u16(data,p) or 0)));p=p+2 end
            local ic=u16(data,p) or 0;p=p+2;local input={};for j=1,ic do input[j]=matcher_cov(coverage(data,base+(u16(data,p) or 0)));p=p+2 end
            local lc=u16(data,p) or 0;p=p+2;local look={};for j=1,lc do look[j]=matcher_cov(coverage(data,base+(u16(data,p) or 0)));p=p+2 end
            local sc=u16(data,p) or 0;p=p+2;local rec={};for j=1,sc do rec[j]={u16(data,p) or 0,u16(data,p+2) or 0};p=p+4 end
            rules[#rules+1]={backtrack=back,input=input,lookahead=look,records=rec}
        end
    end
    return {kind=chain and "chain_context" or "context",rules=rules}
end

local function parse_gsub_subtable(layout,typ,base)
    local data=layout.data; local fmt=u16(data,base) or 0
    if typ==1 then
        local cov=coverage(data,base+(u16(data,base+2) or 0));local map={}
        if fmt==1 then local delta=s16(data,base+4) or 0;for g in pairs(cov) do map[g]=(g+delta)%65536 end
        elseif fmt==2 then local n=u16(data,base+4) or 0;for g,i in pairs(cov) do if i<n then map[g]=u16(data,base+6+i*2) or g end end end
        return {kind="single",map=map}
    elseif typ==2 and fmt==1 then
        local cov=coverage(data,base+(u16(data,base+2) or 0));local n=u16(data,base+4) or 0;local map={}
        for g,i in pairs(cov) do if i<n then local sb=base+(u16(data,base+6+i*2) or 0);local c=u16(data,sb) or 0;local arr={};for j=0,c-1 do arr[#arr+1]=u16(data,sb+2+j*2) or 0 end;map[g]=arr end end
        return {kind="multiple",map=map}
    elseif typ==3 and fmt==1 then
        local cov=coverage(data,base+(u16(data,base+2) or 0));local n=u16(data,base+4) or 0;local map={}
        for g,i in pairs(cov) do if i<n then local sb=base+(u16(data,base+6+i*2) or 0);local c=u16(data,sb) or 0;local arr={};for j=0,c-1 do arr[#arr+1]=u16(data,sb+2+j*2) or 0 end;map[g]=arr end end
        return {kind="alternate",map=map}
    elseif typ==4 and fmt==1 then
        local cov=coverage(data,base+(u16(data,base+2) or 0));local n=u16(data,base+4) or 0;local map={}
        for g,i in pairs(cov) do if i<n then local sb=base+(u16(data,base+6+i*2) or 0);local c=u16(data,sb) or 0;local ls={}
            for j=0,c-1 do local lb=sb+(u16(data,sb+2+j*2) or 0);local lig=u16(data,lb) or 0;local cc=u16(data,lb+2) or 1;local comps={};for k=2,cc do comps[#comps+1]=u16(data,lb+2+k*2-2) or 0 end;ls[#ls+1]={lig=lig,components=comps} end
            table.sort(ls,function(a,b)return #a.components>#b.components end);map[g]=ls
        end end
        return {kind="ligature",map=map}
    elseif typ==5 then return parse_context(layout,nil,base,false)
    elseif typ==6 then return parse_context(layout,nil,base,true)
    elseif typ==7 and fmt==1 then
        local extType=u16(data,base+2) or 0;local off=u32(data,base+4) or 0;return parse_gsub_subtable(layout,extType,base+off)
    elseif typ==8 and fmt==1 then
        local cov=coverage(data,base+(u16(data,base+2) or 0));local p=base+4;local bc=u16(data,p) or 0;p=p+2;local back={};for i=1,bc do back[i]=coverage(data,base+(u16(data,p) or 0));p=p+2 end
        local lc=u16(data,p) or 0;p=p+2;local look={};for i=1,lc do look[i]=coverage(data,base+(u16(data,p) or 0));p=p+2 end
        local gc=u16(data,p) or 0;p=p+2;local subs={};for i=0,gc-1 do subs[i]=u16(data,p+i*2) or 0 end
        return {kind="reverse",coverage=cov,backtrack=back,lookahead=look,subs=subs}
    end
    return {kind="unsupported"}
end

local function parse_gpos_subtable(layout,typ,base)
    local data=layout.data;local fmt=u16(data,base) or 0
    if typ==1 then
        local cov=coverage(data,base+(u16(data,base+2) or 0));local vf=u16(data,base+4) or 0;local vals={}
        if fmt==1 then local v=value_record(data,base+6,vf,base,layout.gdef,layout.coords);for g in pairs(cov) do vals[g]=v end
        elseif fmt==2 then local n=u16(data,base+6) or 0;local p=base+8;for g,i in pairs(cov) do if i<n then local q=p+i*value_size(vf);vals[g]=value_record(data,q,vf,base,layout.gdef,layout.coords) end end end
        return {kind="singlepos",values=vals}
    elseif typ==2 then
        local cov=coverage(data,base+(u16(data,base+2) or 0));local vf1=u16(data,base+4) or 0;local vf2=u16(data,base+6) or 0
        if fmt==1 then local n=u16(data,base+8) or 0;local sets={}
            for g,i in pairs(cov) do if i<n then local sb=base+(u16(data,base+10+i*2) or 0);local c=u16(data,sb) or 0;local p=sb+2;local rows={};for _=1,c do local second=u16(data,p) or 0;p=p+2;local v1;v1,p=value_record(data,p,vf1,base,layout.gdef,layout.coords);local v2;v2,p=value_record(data,p,vf2,base,layout.gdef,layout.coords);rows[second]={v1,v2} end;sets[g]=rows end end
            return {kind="pairpos",sets=sets}
        elseif fmt==2 then local cd1=classdef(data,base+(u16(data,base+8) or 0));local cd2=classdef(data,base+(u16(data,base+10) or 0));local c1=u16(data,base+12) or 0;local c2=u16(data,base+14) or 0;local p=base+16;local mat={}
            for a=0,c1-1 do mat[a]={};for b=0,c2-1 do local v1;v1,p=value_record(data,p,vf1,base,layout.gdef,layout.coords);local v2;v2,p=value_record(data,p,vf2,base,layout.gdef,layout.coords);mat[a][b]={v1,v2} end end
            return {kind="pairclass",coverage=cov,class1=cd1,class2=cd2,matrix=mat}
        end
    elseif typ==3 and fmt==1 then
        local cov=coverage(data,base+(u16(data,base+2) or 0));local n=u16(data,base+4) or 0;local records={}
        for g,i in pairs(cov) do if i<n then local p=base+6+i*4;local eo=u16(data,p) or 0;local xo=u16(data,p+2) or 0;records[g]={entry=eo>0 and parse_anchor(data,base+eo,layout.gdef,layout.coords) or nil,exit=xo>0 and parse_anchor(data,base+xo,layout.gdef,layout.coords) or nil} end end
        return {kind="cursive",records=records}
    elseif typ==4 and fmt==1 then
        local mcov=coverage(data,base+(u16(data,base+2) or 0));local bcov=coverage(data,base+(u16(data,base+4) or 0));local classes=u16(data,base+6) or 0;local ma=base+(u16(data,base+8) or 0);local ba=base+(u16(data,base+10) or 0);local marks={};local mcount=u16(data,ma) or 0
        for g,i in pairs(mcov) do if i<mcount then local p=ma+2+i*4;local cls=u16(data,p) or 0;local ao=u16(data,p+2) or 0;marks[g]={class=cls,anchor=ao>0 and parse_anchor(data,ma+ao,layout.gdef,layout.coords) or nil} end end
        local bases={};local bcount=u16(data,ba) or 0
        for g,i in pairs(bcov) do if i<bcount then local row={};local p=ba+2+(i*classes)*2;for c=0,classes-1 do local ao=u16(data,p+c*2) or 0;row[c]=ao>0 and parse_anchor(data,ba+ao,layout.gdef,layout.coords) or nil end;bases[g]=row end end
        return {kind="markbase",marks=marks,bases=bases}
    elseif typ==5 and fmt==1 then
        local mcov=coverage(data,base+(u16(data,base+2) or 0));local lcov=coverage(data,base+(u16(data,base+4) or 0));local classes=u16(data,base+6) or 0;local ma=base+(u16(data,base+8) or 0);local la=base+(u16(data,base+10) or 0);local marks={};local mcount=u16(data,ma) or 0
        for g,i in pairs(mcov) do if i<mcount then local p=ma+2+i*4;local cls=u16(data,p) or 0;local ao=u16(data,p+2) or 0;marks[g]={class=cls,anchor=ao>0 and parse_anchor(data,ma+ao,layout.gdef,layout.coords) or nil} end end
        local ligs={};local lcount=u16(data,la) or 0
        for g,i in pairs(lcov) do if i<lcount then local ao=u16(data,la+2+i*2) or 0;if ao>0 then local ab=la+ao;local compCount=u16(data,ab) or 0;local comps={};for ci=0,compCount-1 do local cb=ab+2+(ci*classes)*2;local row={};for c=0,classes-1 do local x=u16(data,cb+c*2) or 0;row[c]=x>0 and parse_anchor(data,ab+x,layout.gdef,layout.coords) or nil end;comps[ci+1]=row end;ligs[g]=comps end end end
        return {kind="marklig",marks=marks,ligs=ligs}
    elseif typ==6 and fmt==1 then
        local m1cov=coverage(data,base+(u16(data,base+2) or 0));local m2cov=coverage(data,base+(u16(data,base+4) or 0));local classes=u16(data,base+6) or 0;local m1a=base+(u16(data,base+8) or 0);local m2a=base+(u16(data,base+10) or 0);local marks={};local n1=u16(data,m1a) or 0
        for g,i in pairs(m1cov) do if i<n1 then local p=m1a+2+i*4;local cls=u16(data,p) or 0;local ao=u16(data,p+2) or 0;marks[g]={class=cls,anchor=ao>0 and parse_anchor(data,m1a+ao,layout.gdef,layout.coords) or nil} end end
        local bases={};local n2=u16(data,m2a) or 0
        for g,i in pairs(m2cov) do if i<n2 then local row={};local p=m2a+2+i*classes*2;for c=0,classes-1 do local ao=u16(data,p+c*2) or 0;row[c]=ao>0 and parse_anchor(data,m2a+ao,layout.gdef,layout.coords) or nil end;bases[g]=row end end
        return {kind="markmark",marks=marks,bases=bases}
    elseif typ==7 then return parse_context(layout,nil,base,false)
    elseif typ==8 then return parse_context(layout,nil,base,true)
    elseif typ==9 and fmt==1 then local ext=u16(data,base+2) or 0;local off=u32(data,base+4) or 0;return parse_gpos_subtable(layout,ext,base+off) end
    return {kind="unsupported"}
end

function Layout:parsed_lookup(index)
    if self._parsed[index] then return self._parsed[index] end
    local h=self.lookups[index]; if not h then return nil end
    local p={type=h.type,flag=h.flag,mark_filtering_set=h.mark_filtering_set,subtables={}}
    for _,b in ipairs(h.subtables) do p.subtables[#p.subtables+1]=(self.kind=="GSUB" and parse_gsub_subtable(self,h.type,b) or parse_gpos_subtable(self,h.type,b)) end
    self._parsed[index]=p; return p
end

local function match_rule(layout,lookup,buf,pos,rule)
    local indices={}; local i=pos
    for k,m in ipairs(rule.input or {}) do
        if k>1 then i=next_visible(layout,lookup,buf,i,1); if not i then return nil end end
        if not m(buf[i].gid) then return nil end; indices[k]=i
    end
    i=pos
    for k,m in ipairs(rule.backtrack or {}) do i=next_visible(layout,lookup,buf,i,-1);if not i or not m(buf[i].gid) then return nil end end
    i=indices[#indices] or pos
    for _,m in ipairs(rule.lookahead or {}) do i=next_visible(layout,lookup,buf,i,1);if not i or not m(buf[i].gid) then return nil end end
    return indices
end

local apply_lookup_at

local function apply_value(layout,item,v,ppem)
    if not v then return end
    local upem=layout.units_per_em or 1000
    item.x_offset=(item.x_offset or 0)+(v.x_offset or 0)+adjustment_delta(v.x_offset_adjust,ppem,upem)
    item.y_offset=(item.y_offset or 0)+(v.y_offset or 0)+adjustment_delta(v.y_offset_adjust,ppem,upem)
    item.x_advance=(item.x_advance or 0)+(v.x_advance or 0)+adjustment_delta(v.x_advance_adjust,ppem,upem)
    item.y_advance=(item.y_advance or 0)+(v.y_advance or 0)+adjustment_delta(v.y_advance_adjust,ppem,upem)
end

local function advance_between(buf,a,b)
    local x,y=0,0
    for i=a,b-1 do x=x+(buf[i].x_advance or 0);y=y+(buf[i].y_advance or 0) end
    return x,y
end

local function apply_context_records(layout,lookup,buf,indices,records,depth,ppem)
    local changed=false
    -- Records are applied in font order.
    local refs={};for k,i in ipairs(indices) do refs[k]=buf[i] end
    local last_ref=refs[#refs]
    local affected_end=indices[#indices] or indices[1] or 1
    for _,rec in ipairs(records or {}) do
        local seq=rec[1]+1;local ref=refs[seq];local pos
        if ref then for i=1,#buf do if buf[i]==ref then pos=i;break end end end
        if pos then
            local c,advance=apply_lookup_at(layout,rec[2],buf,pos,nil,(depth or 0)+1,ppem)
            if c then
                changed=true
                affected_end=math.max(affected_end,pos+math.max(1,advance or 1)-1)
            end
        end
    end
    -- A contextual lookup consumes the complete matched input sequence.
    if last_ref then
        for i=1,#buf do if buf[i]==last_ref then affected_end=math.max(affected_end,i);break end end
    end
    return changed,affected_end
end

apply_lookup_at = function(layout, index, buf, pos, mask, depth, ppem)
    if (depth or 0) > 16 then return false end
    local lookup = layout:parsed_lookup(index)
    if not lookup or not buf[pos] or ignored(layout, lookup, buf[pos]) then return false end
    if mask and not mask(buf[pos], pos) then return false end

    for _, st in ipairs(lookup.subtables) do
        local kind = st.kind
        local item = buf[pos]
        if layout.kind == "GSUB" then
            if kind == "single" then
                local g = st.map[item.gid]
                if g then item.gid = g; return true,1 end

            elseif kind == "multiple" then
                local arr = st.map[item.gid]
                if arr then
                    if #arr == 0 then table.remove(buf, pos); return true,1 end
                    item.gid = arr[1]
                    for j = 2, #arr do
                        local n = {gid=arr[j], cp=item.cp, cluster=item.cluster,
                            x_advance=item.x_advance, y_advance=0, x_offset=0, y_offset=0}
                        table.insert(buf, pos + j - 1, n)
                    end
                    return true,#arr
                end

            elseif kind == "alternate" then
                local arr = st.map[item.gid]
                if arr and arr[1] then item.gid = arr[1]; return true,1 end

            elseif kind == "ligature" then
                local ligs = st.map[item.gid]
                if ligs then
                    for _, l in ipairs(ligs) do
                        local idx, p, ok = {pos}, pos, true
                        for _, g in ipairs(l.components) do
                            p = next_visible(layout, lookup, buf, p, 1)
                            if not p or buf[p].gid ~= g then ok = false; break end
                            idx[#idx+1] = p
                        end
                        if ok then
                            local cluster = item.cluster
                            local last_component_cluster = buf[idx[#idx]].cluster
                            for _, ii in ipairs(idx) do
                                if (buf[ii].cluster or cluster) < cluster then cluster = buf[ii].cluster end
                            end
                            item.gid = l.lig
                            item.cluster = cluster
                            item.ligature = true
                            item.ligature_components = #idx
                            for comp = 1, #idx - 1 do
                                for j = idx[comp] + 1, idx[comp+1] - 1 do
                                    if glyph_class(layout, buf[j]) == 3 then
                                        buf[j].lig_component = comp
                                        buf[j].cluster = cluster
                                    end
                                end
                            end
                            -- Marks following the final ligature component belong to that
                            -- component's source cluster.
                            local j = idx[#idx] + 1
                            while j <= #buf and glyph_class(layout, buf[j]) == 3 and buf[j].cluster == last_component_cluster do
                                buf[j].lig_component = #idx
                                buf[j].cluster = cluster
                                j = j + 1
                            end
                            for j = #idx, 2, -1 do table.remove(buf, idx[j]) end
                            return true,1
                        end
                    end
                end

            elseif kind == "context" or kind == "chain_context" then
                for _, r in ipairs(st.rules) do
                    local idx = match_rule(layout, lookup, buf, pos, r)
                    if idx then
                        local _,affected_end=apply_context_records(layout, lookup, buf, idx, r.records, depth, ppem)
                        return true,math.max(1,(affected_end or idx[#idx] or pos)-pos+1)
                    end
                end

            elseif kind == "reverse" then
                local ci = st.coverage[item.gid]
                if ci ~= nil then
                    local p, ok = pos, true
                    for _, c in ipairs(st.backtrack) do
                        p = next_visible(layout, lookup, buf, p, -1)
                        if not p or c[buf[p].gid] == nil then ok = false; break end
                    end
                    p = pos
                    if ok then
                        for _, c in ipairs(st.lookahead) do
                            p = next_visible(layout, lookup, buf, p, 1)
                            if not p or c[buf[p].gid] == nil then ok = false; break end
                        end
                    end
                    if ok and st.subs[ci] then item.gid = st.subs[ci]; return true,1 end
                end
            end

        else -- GPOS
            if kind == "singlepos" then
                local v = st.values[item.gid]
                if v then apply_value(layout,item, v, ppem); return true end

            elseif kind == "pairpos" then
                local row = st.sets[item.gid]
                if row then
                    local j = next_visible(layout, lookup, buf, pos, 1)
                    if j and row[buf[j].gid] then
                        apply_value(layout,item, row[buf[j].gid][1], ppem)
                        apply_value(layout,buf[j], row[buf[j].gid][2], ppem)
                        return true
                    end
                end

            elseif kind == "pairclass" then
                if st.coverage[item.gid] ~= nil then
                    local j = next_visible(layout, lookup, buf, pos, 1)
                    if j then
                        local row = st.matrix[st.class1(item.gid)]
                        local pair = row and row[st.class2(buf[j].gid)]
                        if pair then apply_value(layout,item, pair[1], ppem); apply_value(layout,buf[j], pair[2], ppem); return true end
                    end
                end

            elseif kind == "cursive" then
                local rec = st.records[item.gid]
                if rec and rec.exit then
                    local j = next_visible(layout, lookup, buf, pos, 1)
                    local nxt = j and st.records[buf[j].gid]
                    if j and nxt and nxt.entry then
                        local ex,ey=anchor_xy(layout,rec.exit,ppem);local nx,ny=anchor_xy(layout,nxt.entry,ppem)
                        local dx, dy = ex - nx, ey - ny
                        buf[j].x_offset = (buf[j].x_offset or 0) + dx
                        buf[j].y_offset = (buf[j].y_offset or 0) + dy
                        item.x_advance = (item.x_advance or 0) + dx
                        return true
                    end
                end

            elseif kind == "markbase" then
                local mr = st.marks[item.gid]
                if mr and mr.anchor then
                    local j = pos - 1
                    while j >= 1 and glyph_class(layout, buf[j]) == 3 do j = j - 1 end
                    local row = j >= 1 and st.bases[buf[j].gid]
                    local ba = row and row[mr.class]
                    if ba then
                        local dx, dy = advance_between(buf, j, pos)
                        local bx,by=anchor_xy(layout,ba,ppem);local mx,my=anchor_xy(layout,mr.anchor,ppem)
                        local ax = bx - mx - dx + (buf[j].x_offset or 0)
                        local ay = by - my - dy + (buf[j].y_offset or 0)
                        item.x_offset = (item.x_offset or 0) + ax
                        item.y_offset = (item.y_offset or 0) + ay
                        item._mark_attachment_x = (item._mark_attachment_x or 0) + ax
                        item._mark_attachment_y = (item._mark_attachment_y or 0) + ay
                        item.x_advance = 0
                        return true
                    end
                end

            elseif kind == "marklig" then
                local mr = st.marks[item.gid]
                if mr and mr.anchor then
                    local j = pos - 1
                    while j >= 1 and glyph_class(layout, buf[j]) == 3 do j = j - 1 end
                    local comps = j >= 1 and st.ligs[buf[j].gid]
                    if comps then
                        local ci = item.lig_component or #comps
                        local row = comps[ci] or comps[#comps]
                        local ba = row and row[mr.class]
                        if ba then
                            local dx, dy = advance_between(buf, j, pos)
                            local bx,by=anchor_xy(layout,ba,ppem);local mx,my=anchor_xy(layout,mr.anchor,ppem)
                            local ax = bx - mx - dx + (buf[j].x_offset or 0)
                            local ay = by - my - dy + (buf[j].y_offset or 0)
                            item.x_offset = (item.x_offset or 0) + ax
                            item.y_offset = (item.y_offset or 0) + ay
                        item._mark_attachment_x = (item._mark_attachment_x or 0) + ax
                        item._mark_attachment_y = (item._mark_attachment_y or 0) + ay
                            item.x_advance = 0
                            return true
                        end
                    end
                end

            elseif kind == "markmark" then
                local mr = st.marks[item.gid]
                if mr and mr.anchor then
                    -- Mark-to-mark attaches to the immediately preceding eligible Mark2 glyph.
                    local j = next_visible(layout, lookup, buf, pos, -1)
                    local row = j and st.bases[buf[j].gid]
                    local ba = row and row[mr.class]
                    if ba then
                        local dx, dy = advance_between(buf, j, pos)
                        local bx,by=anchor_xy(layout,ba,ppem);local mx,my=anchor_xy(layout,mr.anchor,ppem)
                        local ax = bx - mx - dx + (buf[j].x_offset or 0)
                        local ay = by - my - dy + (buf[j].y_offset or 0)
                        local oldx = item._mark_attachment_x or 0
                        local oldy = item._mark_attachment_y or 0
                        item.x_offset = (item.x_offset or 0) - oldx + ax
                        item.y_offset = (item.y_offset or 0) - oldy + ay
                        item._mark_attachment_x = ax
                        item._mark_attachment_y = ay
                        item.x_advance = 0
                        return true
                    end
                end

            elseif kind == "context" or kind == "chain_context" then
                for _, r in ipairs(st.rules) do
                    local idx = match_rule(layout, lookup, buf, pos, r)
                    if idx then
                        local _,affected_end=apply_context_records(layout, lookup, buf, idx, r.records, depth, ppem)
                        return true,math.max(1,(affected_end or idx[#idx] or pos)-pos+1)
                    end
                end
            end
        end
    end
    return false
end

function Layout:apply_lookup(index,buf,mask,ppem)
    local lookup=self:parsed_lookup(index);if not lookup then return false end
    local changed=false
    if self.kind=="GSUB" and lookup.type==8 then
        local i=#buf;while i>=1 do if (not mask or mask(buf[i],i)) and apply_lookup_at(self,index,buf,i,mask,0,ppem) then changed=true end;i=i-1 end
    else
        local i=1
        while i<=#buf do
            local c,advance=false,1
            if not mask or mask(buf[i],i) then c,advance=apply_lookup_at(self,index,buf,i,mask,0,ppem) end
            if c then changed=true end
            i=i+math.max(1,advance or 1)
        end
    end
    return changed
end

function Layout:apply_feature(script_tags,feature,buf,options)
    options=options or {};local map=self:script_features(script_tags,options.language);local list=map[feature];if not list then return false end
    local changed=false
    for _,li in ipairs(list) do if self:apply_lookup(li,buf,options.mask,options.ppem) then changed=true end end
    return changed
end

function Layout:feature_affects(script_tags,feature,gid)
    local buf={{gid=gid,cluster=0,x_advance=0,x_offset=0,y_offset=0}}
    local before=gid;local changed=self:apply_feature(script_tags,feature,buf)
    return changed and (#buf~=1 or buf[1].gid~=before)
end

function Layout:would_substitute(script_tags,feature,gids,options)
    local buf={}
    for i,gid in ipairs(gids or {}) do buf[i]={gid=gid,cluster=i,x_advance=0,x_offset=0,y_offset=0} end
    local before={}
    for i,g in ipairs(buf) do before[i]=g.gid end
    local changed=self:apply_feature(script_tags,feature,buf,options or {})
    if not changed then return false end
    if #buf~=#before then return true end
    for i,g in ipairs(buf) do if g.gid~=before[i] then return true end end
    return false
end



-- Compatibility wrappers for the earlier procedural API used by tests and older shaping code.
local function compat_tags(script_tag)
    if type(script_tag) == "table" then return script_tag end
    if script_tag and script_tag ~= "DFLT" then return {script_tag, "DFLT"} end
    return {"DFLT"}
end

function OT.apply_feature(layout,glyphs,script_tag,lang_tag,feature_tag)
    if not layout then return false end
    return layout:apply_feature(compat_tags(script_tag),feature_tag,glyphs,{language=lang_tag})
end

function OT.apply_feature_at(layout,glyphs,pos,script_tag,lang_tag,feature_tag)
    if not layout then return false end
    return layout:apply_feature(compat_tags(script_tag),feature_tag,glyphs,{language=lang_tag,mask=function(_,i) return i==pos end})
end

function OT.feature_changes_glyph(layout,gid,script_tag,lang_tag,feature_tag)
    if not layout then return false end
    return layout:feature_affects(compat_tags(script_tag),feature_tag,gid,lang_tag)
end

-- Narrow regression hook for the packed Device-table decoder.
function OT._test_device_delta(data,ppem,units_per_em)
    return adjustment_delta(parse_adjustment(data,1,nil,{}),ppem,units_per_em)
end

return OT
