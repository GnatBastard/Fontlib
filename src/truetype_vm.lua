-- SPDX-License-Identifier: 0BSD
-- TrueType bytecode interpreter.
local M = fontlib
local TT = {}
M.truetype_vm = TT

local floor, ceil, abs, sqrt = math.floor, math.ceil, math.abs, math.sqrt
local min, max = math.min, math.max
local sub = string.sub

local function u8(s,p) return s:byte(p) end
local function u16(s,p)
    local a,b=s:byte(p,p+1);if not b then return nil end;return a*256+b
end
local function s16(s,p)
    local v=u16(s,p);if not v then return nil end;if v>=0x8000 then return v-0x10000 end;return v
end
local function u32(s,p)
    local a,b,c,d=s:byte(p,p+3);if not d then return nil end;return ((a*256+b)*256+c)*256+d
end

local function trunc(v)
    if v<0 then return ceil(v) end
    return floor(v)
end
local function i32(v)
    v=trunc(tonumber(v) or 0)%4294967296
    if v>=2147483648 then return v-4294967296 end
    return v
end
local function u32n(v)
    v=trunc(tonumber(v) or 0)%4294967296
    if v<0 then v=v+4294967296 end
    return v
end
local function copy_array(a)
    local out={};for i=1,#(a or {}) do out[i]=a[i] end;return out
end
local function copy_table(t)
    local out={};for k,v in pairs(t or {}) do out[k]=v end;return out
end
local function bool(v) return v~=0 and 1 or 0 end

local function parse_maxp(data)
    local out={version=u32(data or "",1) or 0,num_glyphs=u16(data or "",5) or 0}
    if out.version==0x00010000 and #(data or "")>=32 then
        out.max_points=u16(data,7) or 0
        out.max_contours=u16(data,9) or 0
        out.max_composite_points=u16(data,11) or 0
        out.max_composite_contours=u16(data,13) or 0
        out.max_zones=u16(data,15) or 1
        out.max_twilight_points=u16(data,17) or 0
        out.max_storage=u16(data,19) or 0
        out.max_function_defs=u16(data,21) or 0
        out.max_instruction_defs=u16(data,23) or 0
        out.max_stack_elements=u16(data,25) or 0
        out.max_size_of_instructions=u16(data,27) or 0
        out.max_component_elements=u16(data,29) or 0
        out.max_component_depth=u16(data,31) or 0
    else
        out.max_zones=1;out.max_twilight_points=0;out.max_storage=0
        out.max_function_defs=0;out.max_instruction_defs=0;out.max_stack_elements=0
        out.max_size_of_instructions=0;out.max_component_elements=0;out.max_component_depth=0
    end
    return out
end
TT.parse_maxp=parse_maxp

local function parse_cvt(data)
    local out={};if not data then return out end
    local n=floor(#data/2)
    for i=0,n-1 do out[i+1]=s16(data,1+i*2) or 0 end
    return out
end

-- cvar uses the tuple-variation store encoding also used by gvar, but the packed "point"
-- numbers are CVT indices and each index has one delta stream.
local function f2dot14(s,p)
    local v=s16(s,p);return v and v/16384 or 0
end

local function cvar_tuple_scalar(peak,start_tuple,end_tuple,coords)
    local scalar=1
    for i=1,#peak do
        local pk=peak[i] or 0
        if pk~=0 then
            local st,fin
            if start_tuple and end_tuple then st=start_tuple[i] or 0;fin=end_tuple[i] or 0
            elseif pk>0 then st,fin=0,1 else st,fin=-1,0 end
            local c=coords[i] or 0
            if st>pk or pk>fin or (st<0 and fin>0) then
                -- Malformed tents impose no restriction on this axis.
            elseif c==pk then
                -- full contribution
            elseif c<=st or c>=fin then return 0
            elseif c<pk then
                if pk==st then return 0 end;scalar=scalar*(c-st)/(pk-st)
            else
                if fin==pk then return 0 end;scalar=scalar*(fin-c)/(fin-pk)
            end
        end
    end
    return scalar
end

local function cvar_unpack_points(data,p,limit)
    if p>limit then return nil,p,false end
    local first=u8(data,p);p=p+1;if first==nil then return nil,p,false end
    if first==0 then return nil,p,true end -- nil means all CVT entries
    local count
    if first>=0x80 then
        if p>limit then return nil,p,false end
        count=(first%0x80)*256+(u8(data,p) or 0);p=p+1
    else count=first end
    local out={};local current=0
    while #out<count do
        if p>limit then return nil,p,false end
        local control=u8(data,p);p=p+1;if control==nil then return nil,p,false end
        local words=control>=0x80;local run=control%0x80+1
        for _=1,run do
            if #out>=count then break end
            local d
            if words then if p+1>limit then return nil,p,false end;d=u16(data,p) or 0;p=p+2
            else if p>limit then return nil,p,false end;d=u8(data,p) or 0;p=p+1 end
            current=current+d;out[#out+1]=current
        end
    end
    return out,p,true
end

local function cvar_unpack_deltas(data,p,count,limit)
    local out={}
    while #out<count do
        if p>limit then return nil,p,false end
        local control=u8(data,p);p=p+1;if control==nil then return nil,p,false end
        local zero=control>=0x80;local words=(control%0x80)>=0x40;local run=control%0x40+1
        for _=1,run do
            if #out>=count then break end
            local v=0
            if not zero then
                if words then if p+1>limit then return nil,p,false end;v=s16(data,p) or 0;p=p+2
                else if p>limit then return nil,p,false end;local b=u8(data,p);if b==nil then return nil,p,false end;v=b>=128 and b-256 or b;p=p+1 end
            end
            out[#out+1]=v
        end
    end
    return out,p,true
end

local function apply_cvar(data,cvt,coords,axis_count)
    local out=copy_array(cvt);if not data or #data<8 or #out==0 or axis_count<=0 then return out,false end
    if (u16(data,1) or 0)~=1 then return out,false,"unsupported cvar version" end
    local count_field=u16(data,5) or 0;local tuple_count=count_field%0x1000
    local shared_flag=count_field>=0x8000;local data_off=u16(data,7) or 0
    if tuple_count==0 or data_off<8 or data_off>=#data then return out,false end
    local hp=9;local headers={}
    for _=1,tuple_count do
        if hp+3>#data then return out,false,"truncated cvar tuple header" end
        local size=u16(data,hp) or 0;local index=u16(data,hp+2) or 0;hp=hp+4
        local embedded=index>=0x8000;local intermediate=(index%0x8000)>=0x4000;local private=(index%0x4000)>=0x2000
        if not embedded then return out,false,"cvar tuple missing embedded peak" end
        local peak={}
        for ai=1,axis_count do if hp+1>#data then return out,false,"truncated cvar peak tuple" end;peak[ai]=f2dot14(data,hp);hp=hp+2 end
        local st,fin
        if intermediate then
            st={};fin={}
            for ai=1,axis_count do if hp+1>#data then return out,false,"truncated cvar intermediate start" end;st[ai]=f2dot14(data,hp);hp=hp+2 end
            for ai=1,axis_count do if hp+1>#data then return out,false,"truncated cvar intermediate end" end;fin[ai]=f2dot14(data,hp);hp=hp+2 end
        end
        headers[#headers+1]={size=size,peak=peak,start_tuple=st,end_tuple=fin,private=private}
    end
    local dp=data_off+1;if dp>#data then return out,false,"invalid cvar data offset" end
    local shared_points
    if shared_flag then local ok;shared_points,dp,ok=cvar_unpack_points(data,dp,#data);if not ok then return out,false,"truncated cvar shared CVT indices" end end
    local applied=false
    for _,h in ipairs(headers) do
        local run_start=dp;local run_end=math.min(#data,run_start+h.size-1);dp=run_start+h.size
        if h.size>0 and run_start<=#data then
            local scalar=cvar_tuple_scalar(h.peak,h.start_tuple,h.end_tuple,coords or {})
            local p=run_start;local points=shared_points;local ok=true
            if h.private then points,p,ok=cvar_unpack_points(data,p,run_end) end
            if ok then
                local n=points and #points or #out;local deltas
                deltas,p,ok=cvar_unpack_deltas(data,p,n,run_end)
                if ok and scalar~=0 then
                    if points then
                        for j,idx in ipairs(points) do
                            if idx>=0 and idx<#out then out[idx+1]=(out[idx+1] or 0)+(deltas[j] or 0)*scalar;applied=true end
                        end
                    else
                        for idx=0,#out-1 do local d=deltas[idx+1] or 0;if d~=0 then out[idx+1]=(out[idx+1] or 0)+d*scalar;applied=true end end
                    end
                end
            end
        end
    end
    return out,applied
end
TT.apply_cvar=apply_cvar

local function graphics_defaults()
    return {
        projection_x=0x4000,projection_y=0,
        freedom_x=0x4000,freedom_y=0,
        dual_projection_x=0x4000,dual_projection_y=0,
        rp0=0,rp1=0,rp2=0,zp0=1,zp1=1,zp2=1,
        loop=1,
        minimum_distance=64,
        control_value_cut_in=68, -- 17/16 px in F26Dot6
        single_width_cut_in=0,
        single_width_value=0,
        auto_flip=true,
        delta_base=9,
        delta_shift=3,
        round_mode="grid",
        round_period=64,round_phase=0,round_threshold=32,
        scan_control=0,scan_type=0,
        instruction_control=0,
        angle_weight=0,
    }
end
TT.graphics_defaults=graphics_defaults

local function clone_graphics(g)
    return copy_table(g or graphics_defaults())
end

-- TrueType vectors are represented as F2Dot14 values.
local function normalise_vector(x,y)
    x=i32(x);y=i32(y);local d=sqrt(x*x+y*y)
    if d==0 then return 0x4000,0 end
    return trunc(x*0x4000/d),trunc(y*0x4000/d)
end

local function make_super_round(state,arg,grid_period)
    arg=u32n(arg)%256
    local pc=floor(arg/64)%4
    local period
    if pc==0 then period=grid_period/2 elseif pc==1 then period=grid_period elseif pc==2 then period=grid_period*2 else period=grid_period end
    local ph=floor(arg/16)%4
    local phase=(ph==0 and 0) or (ph==1 and period/4) or (ph==2 and period/2) or (period*3/4)
    local tc=arg%16;local threshold
    if tc==0 then threshold=period-1 else threshold=(tc-4)*period/8 end
    state.round_mode="super";state.round_period=period;state.round_phase=phase;state.round_threshold=threshold
end

-- Engine compensation is an output-device characteristic, not font data.
local function compensation_value(profile,distance_type)
    profile=profile or {}
    distance_type=trunc(distance_type or 0)
    if distance_type==3 then distance_type=0 end
    local v
    if distance_type==1 then v=profile.black or profile[1]
    elseif distance_type==2 then v=profile.white or profile[2]
    else v=profile.gray or profile.grey or profile[0] end
    return i32(tonumber(v) or 0)
end

local function compensate_distance(v,distance_type,profile)
    v=i32(v);local c=compensation_value(profile,distance_type)
    if c==0 or v==0 then return v end
    local r=v+(v>0 and c or -c)
    -- ROFF/NROUND explicitly require that compensation cannot reverse the sign of a distance.
    if v>0 and r<0 then r=0 elseif v<0 and r>0 then r=0 end
    return i32(r)
end
TT.compensate_distance=compensate_distance

local function round_value(state,v,distance_type,profile)
    -- The TrueType rounders are sign-symmetric, but not the same as applying floor/ceil
    -- directly to a signed number.
    local original=i32(v)
    v=compensate_distance(original,distance_type,profile)
    local mode=state.round_mode or "grid"
    if mode=="off" then return i32(v) end
    local negative=original<0
    local mag=abs(v)
    local r
    if mode=="down" then
        r=floor(mag/64)*64
    elseif mode=="up" then
        r=ceil(mag/64)*64
    elseif mode=="half" then
        r=floor(mag/64)*64+32
        if r<32 then r=32 end
    elseif mode=="double" then
        r=floor((mag+16)/32)*32
        if r<0 then r=0 end
    elseif mode=="super" then
        local period=state.round_period or 64
        local phase=state.round_phase or 0
        local threshold=state.round_threshold or 32
        if period==0 then return i32(v) end
        r=floor((mag+threshold-phase)/period)*period+phase
        if r<0 then r=phase end
    else -- Round_To_Grid
        r=floor((mag+32)/64)*64
        if r<0 then r=0 end
    end
    return i32(negative and -r or r)
end
TT.round_value=round_value

local function instruction_span(program,ip)
    local op=u8(program,ip);if not op then return nil,"truncated instruction" end
    if op==0x40 or op==0x41 then
        local n=u8(program,ip+1);if n==nil then return nil,"truncated NPUSH count" end
        local bytes=(op==0x40) and n or n*2
        if ip+1+bytes>#program then return nil,"truncated NPUSH payload" end
        return ip+2+bytes
    elseif op>=0xB0 and op<=0xB7 then
        local n=op-0xB0+1;if ip+n>#program then return nil,"truncated PUSHB payload" end;return ip+1+n
    elseif op>=0xB8 and op<=0xBF then
        local n=op-0xB8+1;if ip+n*2>#program then return nil,"truncated PUSHW payload" end;return ip+1+n*2
    end
    return ip+1
end
TT.instruction_span=instruction_span

local function scan_if(program,ip,want_else)
    local depth=0
    while ip<=#program do
        local op=u8(program,ip)
        if op==0x58 then depth=depth+1;ip=ip+1
        elseif op==0x59 then
            if depth==0 then return ip+1 end
            depth=depth-1;ip=ip+1
        elseif op==0x1B and depth==0 and want_else then return ip+1
        else
            local n,err=instruction_span(program,ip);if not n then return nil,err end;ip=n
        end
    end
    return nil,"unterminated IF/ELSE block"
end

local function scan_definition(program,ip)
    -- FDEF/IDEF cannot legally nest.
    local start=ip
    while ip<=#program do
        local op=u8(program,ip)
        if op==0x2D then
            if ip-start>65535 then return nil,nil,"FDEF/IDEF body exceeds 64K" end
            return sub(program,start,ip-1),ip+1
        end
        local n,err=instruction_span(program,ip);if not n then return nil,nil,err end;ip=n
    end
    return nil,nil,"unterminated FDEF/IDEF"
end

local Engine={};Engine.__index=Engine
local Run={};Run.__index=Run

local function engine_error(engine,msg)
    engine.last_error=msg;return nil,msg
end

local function max_or_default(v,d)
    v=tonumber(v) or 0;if v<=0 then return d end;return v
end

function TT.new(tables,options)
    tables=tables or {};options=options or {}
    local maxp=parse_maxp(tables["maxp"] or "")
    local head_flags=u16(tables["head"] or "",17) or 0
    local force_integer_ppem=floor(head_flags/8)%2==1
    local units=max(1,tonumber(options.units_per_em) or 1000)
    local normalized=copy_array(options.normalized_variations or {})
    local axis_count=tonumber(options.variation_axis_count) or #(options.normalized_variations or {})
    local base_cvt=parse_cvt(tables["cvt "])
    local varied_cvt,cvar_applied,cvar_error=apply_cvar(tables["cvar"],base_cvt,normalized,axis_count)
    local e=setmetatable({
        tables=tables,units_per_em=units,maxp=maxp,head_flags=head_flags,force_integer_ppem=force_integer_ppem,
        fpgm=tables["fpgm"] or "",prep=tables["prep"] or "",
        cvt_funits=varied_cvt,cvt_default_funits=base_cvt,cvar_applied=cvar_applied,cvar_error=cvar_error,
        functions={},idefs={},font_storage={},
        font_program_ran=false,font_program_error=nil,
        current_prepare_key=nil,current_prepare_state=nil,prepare_runs=0,
        normalized_variations=normalized,
        variation_axis_count=axis_count,
        -- Conservative hard caps protect Luanti from malicious/corrupt fonts whose maxp fields
        -- lie.
        hard_stack_limit=max_or_default(options.hard_stack_limit,65536),
        instruction_budget=max_or_default(options.instruction_budget,1000000),
        call_depth_limit=max_or_default(options.call_depth_limit,64),
        strict=options.strict~=false,
        scaler_version=42,
        supports_variations=options.supports_variations~=false,
        supports_vertical_phantoms=true,
        grayscale=options.grayscale~=false,
        engine_compensation={
            gray=i32(tonumber((options.engine_compensation or {}).gray or (options.engine_compensation or {}).grey or (options.engine_compensation or {})[0]) or 0),
            black=i32(tonumber((options.engine_compensation or {}).black or (options.engine_compensation or {})[1]) or 0),
            white=i32(tonumber((options.engine_compensation or {}).white or (options.engine_compensation or {})[2]) or 0),
        },
    },Engine)
    local storage_n=max(0,maxp.max_storage or 0)
    for i=0,storage_n-1 do e.font_storage[i]=0 end
    return e
end

function Engine:_stack_limit()
    local declared=max(0,tonumber(self.maxp.max_stack_elements) or 0)
    -- Real-world TrueType fonts frequently under-declare maxStackElements.
    local padded=declared+max(floor(declared/2),128)
    return min(self.hard_stack_limit,padded)
end

function Engine:_new_run(kind,program,shared)
    shared=shared or {}
    local r=setmetatable({
        engine=self,kind=kind,program=program or "",ip=1,stack={},
        storage=shared.storage or self.font_storage,
        cvt=shared.cvt or {},
        graphics=shared.graphics or graphics_defaults(),
        functions=shared.functions or self.functions,
        idefs=shared.idefs or self.idefs,
        ppem_x=shared.ppem_x or 0,ppem_y=shared.ppem_y or shared.ppem_x or 0,
        point_size=shared.point_size or shared.ppem_y or shared.ppem_x or 0,
        rotated=shared.rotated or false,stretched=shared.stretched or false,
        grayscale=shared.grayscale==nil and self.grayscale or shared.grayscale,
        budget=shared.budget or {left=self.instruction_budget},
        call_depth=shared.call_depth or 0,
        stack_limit=self:_stack_limit(),
        trace=shared.trace,is_composite=shared.is_composite==true,
        zones=shared.zones,contours=shared.contours,glyph_point_count=shared.glyph_point_count,
    },Run)
    return r
end

function Run:fail(msg)
    return nil,("TrueType VM %s @ byte %d: %s"):format(self.kind or "program",max(1,(self.ip or 1)-1),msg)
end
function Run:pop()
    local n=#self.stack;if n<1 then return nil,"stack underflow" end
    local v=self.stack[n];self.stack[n]=nil;return v
end
function Run:push(v)
    if #self.stack>=self.stack_limit then return nil,"stack overflow" end
    self.stack[#self.stack+1]=i32(v);return true
end
function Run:pop2()
    local a,e=self:pop();if a==nil then return nil,nil,e end
    local b,e2=self:pop();if b==nil then return nil,nil,e2 end
    return a,b
end
function Run:index_check(i,limit,name)
    i=trunc(i or -1);if i<0 or i>=limit then return nil,(name or "index").." out of range" end;return i
end

local function set_axis(state,which,vertical)
    local x,y=vertical and 0 or 0x4000,vertical and 0x4000 or 0
    if which=="p" or which=="both" then state.projection_x,state.projection_y=x,y;state.dual_projection_x,state.dual_projection_y=x,y end
    if which=="f" or which=="both" then state.freedom_x,state.freedom_y=x,y end
end

local function result_getinfo(run,selector)
    selector=u32n(selector);local e=run.engine;local r=0
    if selector%2>=1 then r=r+(e.scaler_version or 42) end
    if floor(selector/2)%2==1 and run.rotated then r=r+0x100 end
    if floor(selector/4)%2==1 and run.stretched then r=r+0x200 end
    if floor(selector/8)%2==1 and e.supports_variations then r=r+0x400 end
    if floor(selector/16)%2==1 and e.supports_vertical_phantoms then r=r+0x800 end
    if floor(selector/32)%2==1 and run.grayscale then r=r+0x1000 end
    return r
end

local function projection_ppem_value(run)
    -- Internal scaling can be fractional when head.flags bit 3 is clear.
    local px=(run.graphics.projection_x or 0x4000)/0x4000
    local py=(run.graphics.projection_y or 0)/0x4000
    local sx=(run.ppem_x or 0)*px
    local sy=(run.ppem_y or 0)*py
    return max(0,sqrt(sx*sx+sy*sy))
end
local function projection_ppem(run) return floor(projection_ppem_value(run)+0.5) end

local function scale_funit(run,v)
    -- FreeType/Microsoft-compatible composite programs operate on component points that have
    -- already been scaled and hinted.
    if run.is_composite then return i32(v) end
    return i32((tonumber(v) or 0)*projection_ppem_value(run)*64/run.engine.units_per_em)
end

local function delta_step(gs,arg,base_offset)
    local rel=floor(u32n(arg)/16)%16
    local target=(gs.delta_base or 9)+base_offset+rel
    local mag=u32n(arg)%16
    local steps;if mag>=8 then steps=mag-7 else steps=mag-8 end
    local shift=2^(gs.delta_shift or 3)
    return target,64*steps/shift
end

local function do_deltac(run,op)
    local count,err=run:pop();if count==nil then return nil,err end
    count=trunc(count);if count<0 or count>run.stack_limit then return nil,"invalid DELTAC count" end
    local base=(op==0x73 and 0) or (op==0x74 and 16) or 32
    for _=1,count do
        local idx,arg,e=run:pop2();if idx==nil then return nil,e end
        local ci,ce=run:index_check(idx,#run.cvt,"CVT index");if not ci then return nil,ce end
        local target,delta=delta_step(run.graphics,arg,base)
        local ppem=projection_ppem(run)
        if ppem==target then run.cvt[ci+1]=i32((run.cvt[ci+1] or 0)+delta) end
    end
    return true
end

-- Point-zone machinery ------------------------------------------------------
local point_op={}
local function mark_point(a,b) for op=a,b do point_op[op]=true end end
for _,r in ipairs({{0x06,0x09},{0x0F,0x0F},{0x27,0x27},{0x29,0x29},{0x2E,0x31},{0x32,0x3C},{0x3E,0x3F},{0x46,0x4A},{0x5D,0x5D},{0x71,0x72},{0x80,0x82},{0x86,0x87},{0xC0,0xFF}}) do mark_point(r[1],r[2]) end

local function iround(v)
    if v>=0 then return floor(v+0.5) end
    return ceil(v-0.5)
end
local function make_point(pt)
    pt=pt or {};local x=i32(pt.x or 0);local y=i32(pt.y or 0)
    local ox=i32(pt.ox==nil and x or pt.ox);local oy=i32(pt.oy==nil and y or pt.oy)
    local orus_x=tonumber(pt.orus_x);if orus_x==nil then orus_x=ox end
    local orus_y=tonumber(pt.orus_y);if orus_y==nil then orus_y=oy end
    return {x=x,y=y,ox=ox,oy=oy,orus_x=orus_x,orus_y=orus_y,
        on=pt.on~=false,touched_x=pt.touched_x==true,touched_y=pt.touched_y==true}
end
local function copy_points(points)
    local out={};for i=1,#(points or {}) do out[i]=make_point(points[i]) end;return out
end
local function make_twilight(n)
    local out={};for i=1,max(0,trunc(n or 0)) do out[i]=make_point() end;return out
end
local function project_xy(x,y,vx,vy) return i32(iround((x*vx+y*vy)/0x4000)) end
local function project_point(run,pt,original,dual)
    local gs=run.graphics;local vx,vy
    if original and dual then vx,vy=gs.dual_projection_x or gs.projection_x,gs.dual_projection_y or gs.projection_y
    else vx,vy=gs.projection_x,gs.projection_y end
    return project_xy(original and pt.ox or pt.x,original and pt.oy or pt.y,vx,vy)
end
local function point_distance(run,a,b,original)
    local gs=run.graphics;local vx,vy
    if original then vx,vy=gs.dual_projection_x or gs.projection_x,gs.dual_projection_y or gs.projection_y
    else vx,vy=gs.projection_x,gs.projection_y end
    local ax,ay=original and a.ox or a.x,original and a.oy or a.y
    local bx,by=original and b.ox or b.x,original and b.oy or b.y
    return project_xy(ax-bx,ay-by,vx,vy)
end
local function orus_distance(run,a,b)
    local gs=run.graphics;local vx=gs.dual_projection_x or gs.projection_x;local vy=gs.dual_projection_y or gs.projection_y
    local ax=tonumber(a.orus_x) or a.ox or a.x or 0;local ay=tonumber(a.orus_y) or a.oy or a.y or 0
    local bx=tonumber(b.orus_x) or b.ox or b.x or 0;local by=tonumber(b.orus_y) or b.oy or b.y or 0
    -- Keep this value fractional.
    return ((ax-bx)*vx+(ay-by)*vy)/0x4000
end
local function original_distance(run,a,az,b,bz)
    -- Any twilight-zone participation switches the interpreter back to the rounded `org`
    -- coordinates because twilight `orus` is undefined/zero.
    if az==0 or bz==0 then return point_distance(run,a,b,true) end
    return i32(iround(orus_distance(run,a,b)))
end
function Run:get_point(zone,index)
    if not self.zones then return nil,"point instruction requires glyph zones" end
    zone=trunc(zone or -1);if zone~=0 and zone~=1 then return nil,"zone must be 0 or 1" end
    index=trunc(index or -1);local z=self.zones[zone]
    if not z or index<0 or index>=#z then return nil,(zone==0 and "twilight" or "glyph").." point out of range" end
    return z[index+1]
end
local function touch_point(run,pt)
    if (run.graphics.freedom_x or 0)~=0 then pt.touched_x=true end
    if (run.graphics.freedom_y or 0)~=0 then pt.touched_y=true end
end
local function shift_freedom(run,pt,amount,touch)
    local fx,fy=run.graphics.freedom_x or 0,run.graphics.freedom_y or 0
    pt.x=i32(pt.x+iround(amount*fx/0x4000));pt.y=i32(pt.y+iround(amount*fy/0x4000))
    if touch~=false then touch_point(run,pt) end
    return true
end
local function movement_dot(run)
    local gs=run.graphics;local px,py=gs.projection_x or 0x4000,gs.projection_y or 0
    local fx,fy=gs.freedom_x or 0x4000,gs.freedom_y or 0
    -- Match the Microsoft-compatible scaler convention used by FreeType: quantize the
    -- projection/freedom dot product to F2.14, and prohibit movement when the vectors are too
    return floor((px*fx+py*fy+0x2000)/0x4000)
end
local function move_projection(run,pt,target,touch)
    local gs=run.graphics;local px,py=gs.projection_x or 0x4000,gs.projection_y or 0
    local fx,fy=gs.freedom_x or 0x4000,gs.freedom_y or 0
    local f_dot_p=movement_dot(run)
    if f_dot_p>-0x1555 and f_dot_p<0x1555 then return true end
    local cur=project_xy(pt.x,pt.y,px,py);local amount=(target-cur)*0x4000/f_dot_p
    pt.x=i32(pt.x+iround(amount*fx/0x4000));pt.y=i32(pt.y+iround(amount*fy/0x4000))
    if touch~=false then touch_point(run,pt) end
    return true
end
local function vector_from_points(run,p1,z1,p2,z2,original,perp)
    local a,e=run:get_point(z1,p1);if not a then return nil,nil,e end
    local b,e2=run:get_point(z2,p2);if not b then return nil,nil,e2 end
    local ax,ay=original and a.ox or a.x,original and a.oy or a.y
    local bx,by=original and b.ox or b.x,original and b.oy or b.y
    local x,y=bx-ax,by-ay;if perp then x,y=-y,x end
    return normalise_vector(x,y)
end
local function loop_count(run)
    -- SLOOP may legally set zero.
    local n=max(0,trunc(run.graphics.loop or 1));run.graphics.loop=1;return n
end
local function reference_shift(run,use_rp1)
    local gs=run.graphics;local zone=use_rp1 and gs.zp0 or gs.zp1;local idx=use_rp1 and gs.rp1 or gs.rp2
    local pt,e=run:get_point(zone,idx);if not pt then return nil,nil,nil,e end
    -- SHP/SHC/SHZ use the ordinary projection vector for both current and original positions.
    local current=project_point(run,pt,false,false);local original=project_point(run,pt,true,false)
    return current-original,zone,idx
end

local function set_twilight_relative(run,pt,ref,distance)
    local fx,fy=run.graphics.freedom_x or 0x4000,run.graphics.freedom_y or 0
    local rx,ry=0,0
    if ref then rx,ry=ref.ox or 0,ref.oy or 0 end
    pt.ox=i32(rx+iround(distance*fx/0x4000));pt.oy=i32(ry+iround(distance*fy/0x4000))
    pt.x,pt.y=pt.ox,pt.oy
end
local function set_twilight_projected_relative(run,pt,ref,distance)
    local gs=run.graphics;local fx,fy=gs.freedom_x or 0x4000,gs.freedom_y or 0
    local rx,ry=ref.ox or 0,ref.oy or 0;pt.ox,pt.oy=i32(rx),i32(ry)
    local f_dot_p=movement_dot(run)
    if not (f_dot_p>-0x1555 and f_dot_p<0x1555) then
        local amount=distance*0x4000/f_dot_p
        pt.ox=i32(pt.ox+iround(amount*fx/0x4000));pt.oy=i32(pt.oy+iround(amount*fy/0x4000))
    end
    pt.x,pt.y=pt.ox,pt.oy;return true
end
local function contour_range(run,c)
    local z=run.graphics.zp2 or 1;c=trunc(c or -1)
    if z==0 then
        -- Microsoft rasterizers expose the twilight zone to SHC as one virtual contour numbered
        -- zero, containing every twilight point.
        if c~=0 then return nil,nil,"twilight contour out of range" end
        return 0,#(run.zones[0] or {})-1
    end
    if z~=1 then return nil,nil,"contour operation requires zone 0 or 1" end
    local r=run.contours and run.contours[c+1];if not r then return nil,nil,"contour out of range" end
    local first=r.first or r[1] or 0;local last=r.last or r[2] or first
    first=trunc(first);last=trunc(last);if first<0 or last<first or last>=#(run.zones[1] or {}) then return nil,nil,"invalid contour range" end
    return first,last
end
local function iup_axis(run,use_x)
    if (run.graphics.zp2 or 1)~=1 then return nil,"IUP requires glyph zone 1" end
    local zone=run.zones and run.zones[1];if not zone then return nil,"IUP requires glyph points" end
    local touched_key=use_x and "touched_x" or "touched_y";local cur_key=use_x and "x" or "y";local org_key=use_x and "ox" or "oy";local orus_key=use_x and "orus_x" or "orus_y"
    for ci=1,#(run.contours or {}) do
        local first,last,e=contour_range(run,ci-1);if not first then return nil,e end
        local touched={}
        for idx=first,last do if zone[idx+1][touched_key] then touched[#touched+1]=idx end end
        if #touched==1 then
            local t=zone[touched[1]+1];local delta=t[cur_key]-t[org_key]
            for idx=first,last do local p=zone[idx+1];if not p[touched_key] then p[cur_key]=i32(p[org_key]+delta) end end
        elseif #touched>1 then
            for ti=1,#touched do
                local aidx=touched[ti];local bidx=touched[ti%#touched+1];local a,b=zone[aidx+1],zone[bidx+1]
                -- FreeType orders the reference pair in unrounded-original space but applies
                -- endpoint deltas to the rounded originals.
                local ra,rb=a,b;local orus1=tonumber(a[orus_key]) or a[org_key];local orus2=tonumber(b[orus_key]) or b[org_key]
                if orus1>orus2 then ra,rb=rb,ra;orus1,orus2=orus2,orus1 end
                local org1,org2=ra[org_key],rb[org_key];local cur1,cur2=ra[cur_key],rb[cur_key]
                local delta1,delta2=cur1-org1,cur2-org2
                local idx=aidx
                while true do
                    idx=idx+1;if idx>last then idx=first end;if idx==bidx then break end
                    local q=zone[idx+1]
                    if not q[touched_key] then
                        local qo=q[org_key];local x
                        if qo<=org1 then x=qo+delta1
                        elseif qo>=org2 then x=qo+delta2
                        elseif cur1==cur2 or orus1==orus2 then x=cur1
                        else
                            local qor=tonumber(q[orus_key]) or qo
                            x=cur1+(qor-orus1)*(cur2-cur1)/(orus2-orus1)
                        end
                        q[cur_key]=i32(iround(x))
                    end
                end
            end
        end
    end
    return true
end
local function enforce_single_width(gs,d)
    local sw=gs.single_width_value or 0;local cut=abs(gs.single_width_cut_in or 0)
    if cut>0 and abs(abs(d)-abs(sw))<cut then return d<0 and -abs(sw) or abs(sw) end
    return d
end
local function enforce_minimum(gs,d,sign_source)
    local md=abs(gs.minimum_distance or 0)
    -- MDRP/MIRP choose the minimum-distance direction from the *original* distance, not from
    -- the rounded result.
    local sign=(sign_source==nil) and d or sign_source
    if sign>=0 then
        if d<md then return md end
    else
        if d>-md then return -md end
    end
    return d
end
local function do_deltap(run,op)
    local count,err=run:pop();if count==nil then return nil,err end
    count=trunc(count);if count<0 or count>run.stack_limit then return nil,"invalid DELTAP count" end
    local base=(op==0x5D and 0) or (op==0x71 and 16) or 32
    for _=1,count do
        local pidx,arg,e=run:pop2();if pidx==nil then return nil,e end
        local pt,pe=run:get_point(run.graphics.zp0,pidx);if not pt then return nil,pe end
        local target,delta=delta_step(run.graphics,arg,base)
        if projection_ppem(run)==target then shift_freedom(run,pt,delta,true) end
    end
    return true
end
local function execute_point(run,op)
    local gs=run.graphics
    if not run.zones then return nil,"point instruction requires glyph zones" end
    if op>=0x06 and op<=0x09 then
        local p1,p2,e=run:pop2();if p1==nil then return nil,e end
        local is_proj=op<=0x07;local x,y,ve=vector_from_points(run,p1,gs.zp2,p2,gs.zp1,false,op%2==1);if not x then return nil,ve end
        if is_proj then gs.projection_x,gs.projection_y=x,y;gs.dual_projection_x,gs.dual_projection_y=x,y else gs.freedom_x,gs.freedom_y=x,y end
        return true
    elseif op==0x86 or op==0x87 then
        local p1,p2,e=run:pop2();if p1==nil then return nil,e end
        local cx,cy,ce=vector_from_points(run,p1,gs.zp2,p2,gs.zp1,false,op==0x87);if not cx then return nil,ce end
        local ox,oy,oe=vector_from_points(run,p1,gs.zp2,p2,gs.zp1,true,op==0x87);if not ox then return nil,oe end
        gs.projection_x,gs.projection_y=cx,cy;gs.dual_projection_x,gs.dual_projection_y=ox,oy;return true
    elseif op==0x0F then
        local b1,e=run:pop();if b1==nil then return nil,e end;local b0,e2=run:pop();if b0==nil then return nil,e2 end
        local a1,e3=run:pop();if a1==nil then return nil,e3 end;local a0,e4=run:pop();if a0==nil then return nil,e4 end;local pidx,e5=run:pop();if pidx==nil then return nil,e5 end
        local A0,ae=run:get_point(gs.zp1,a0);if not A0 then return nil,ae end;local A1,ae2=run:get_point(gs.zp1,a1);if not A1 then return nil,ae2 end
        local B0,be=run:get_point(gs.zp0,b0);if not B0 then return nil,be end;local B1,be2=run:get_point(gs.zp0,b1);if not B1 then return nil,be2 end
        local P,pe=run:get_point(gs.zp2,pidx);if not P then return nil,pe end
        local adx,ady=A1.x-A0.x,A1.y-A0.y;local bdx,bdy=B1.x-B0.x,B1.y-B0.y;local den=adx*bdy-ady*bdx
        if abs(den)<1e-9 then P.x=i32(iround((A0.x+A1.x+B0.x+B1.x)/4));P.y=i32(iround((A0.y+A1.y+B0.y+B1.y)/4))
        else local t=((B0.x-A0.x)*bdy-(B0.y-A0.y)*bdx)/den;P.x=i32(iround(A0.x+t*adx));P.y=i32(iround(A0.y+t*ady)) end
        P.touched_x=true;P.touched_y=true;return true
    elseif op==0x27 then
        local p1,p2,e=run:pop2();if p1==nil then return nil,e end;local a,ae=run:get_point(gs.zp1,p1);if not a then return nil,ae end;local b,be=run:get_point(gs.zp0,p2);if not b then return nil,be end
        local target=iround((project_point(run,a,false,false)+project_point(run,b,false,false))/2);local ok,me=move_projection(run,a,target,true);if not ok then return nil,me end;return move_projection(run,b,target,true)
    elseif op==0x29 then
        local p,e=run:pop();if p==nil then return nil,e end;local pt,pe=run:get_point(gs.zp0,p);if not pt then return nil,pe end
        if (gs.freedom_x or 0)~=0 then pt.touched_x=false end;if (gs.freedom_y or 0)~=0 then pt.touched_y=false end;return true
    elseif op==0x2E or op==0x2F then
        local p,e=run:pop();if p==nil then return nil,e end;local pt,pe=run:get_point(gs.zp0,p);if not pt then return nil,pe end
        if op==0x2F then local target=round_value(gs,project_point(run,pt,false,false));local ok,me=move_projection(run,pt,target,true);if not ok then return nil,me end else touch_point(run,pt) end
        gs.rp0=u32n(p);gs.rp1=u32n(p);return true
    elseif op==0x30 or op==0x31 then return iup_axis(run,op==0x31)
    elseif op==0x32 or op==0x33 then
        local shift,_,_,se=reference_shift(run,op==0x33);if shift==nil then return nil,se end;local n=loop_count(run)
        for _=1,n do local p,e=run:pop();if p==nil then return nil,e end;local pt,pe=run:get_point(gs.zp2,p);if not pt then return nil,pe end;local target=project_point(run,pt,false,false)+shift;local ok,me=move_projection(run,pt,target,true);if not ok then return nil,me end end;return true
    elseif op==0x34 or op==0x35 then
        local shift,rz,ri,se=reference_shift(run,op==0x35);if shift==nil then return nil,se end;local c,e=run:pop();if c==nil then return nil,e end;local first,last,ce=contour_range(run,c);if first==nil then return nil,ce end
        local z=gs.zp2 or 1;local zone=run.zones[z] or {}
        for idx=first,last do if not (rz==z and ri==idx) then local pt=zone[idx+1];local target=project_point(run,pt,false,false)+shift;local ok,me=move_projection(run,pt,target,true);if not ok then return nil,me end end end;return true
    elseif op==0x36 or op==0x37 then
        local shift,rz,ri,se=reference_shift(run,op==0x37);if shift==nil then return nil,se end;local z,e=run:pop();if z==nil then return nil,e end;z=trunc(z);if z~=0 and z~=1 then return nil,"SHZ zone must be 0 or 1" end;local zone=run.zones[z] or {}
        -- SHZ follows Microsoft rasterizer behavior: it does not touch moved points, and when
        -- shifting zone 1 it stops before the four phantom points rather than perturbing
        local limit=#zone;if z==1 then limit=min(limit,run.glyph_point_count or limit) end
        for idx=0,limit-1 do if not (rz==z and ri==idx) then local pt=zone[idx+1];local target=project_point(run,pt,false,false)+shift;local ok,me=move_projection(run,pt,target,false);if not ok then return nil,me end end end;return true
    elseif op==0x38 then
        local amount,e=run:pop();if amount==nil then return nil,e end;local n=loop_count(run);for _=1,n do local p,pe=run:pop();if p==nil then return nil,pe end;local pt,qe=run:get_point(gs.zp2,p);if not pt then return nil,qe end;shift_freedom(run,pt,amount,true) end;return true
    elseif op==0x39 then
        local r1,re=run:get_point(gs.zp0,gs.rp1);if not r1 then return nil,re end;local r2,re2=run:get_point(gs.zp1,gs.rp2);if not r2 then return nil,re2 end
        local c1,c2=project_point(run,r1,false,false),project_point(run,r2,false,false);local cur_range=c2-c1
        local use_orus=gs.zp0~=0 and gs.zp1~=0 and gs.zp2~=0
        local old_range=use_orus and orus_distance(run,r2,r1) or point_distance(run,r2,r1,true);local n=loop_count(run)
        for _=1,n do
            local p,e=run:pop();if p==nil then return nil,e end;local pt,pe=run:get_point(gs.zp2,p);if not pt then return nil,pe end
            local org_dist=use_orus and orus_distance(run,pt,r1) or point_distance(run,pt,r1,true);local new_dist
            -- When the two original reference points coincide, preserve the point's original
            -- projected distance.
            if org_dist==0 then new_dist=0 elseif old_range==0 then new_dist=org_dist else new_dist=org_dist*cur_range/old_range end
            local ok,me=move_projection(run,pt,iround(c1+new_dist),true);if not ok then return nil,me end
        end;return true
    elseif op==0x3A or op==0x3B then
        local d,p,e=run:pop2();if d==nil then return nil,e end;local pt,pe=run:get_point(gs.zp1,p);if not pt then return nil,pe end;local ref,re=run:get_point(gs.zp0,gs.rp0);if not ref then return nil,re end
        -- Microsoft-compatible twilight behavior: a fresh MSIRP reference recreates both its
        -- original and current position relative to rp0 before the ordinary projected move is
        if gs.zp1==0 then local tok,te=set_twilight_projected_relative(run,pt,ref,d);if not tok then return nil,te end end
        local target=project_point(run,ref,false,false)+d;local ok,me=move_projection(run,pt,target,true);if not ok then return nil,me end
        local old=gs.rp0;gs.rp1=old;gs.rp2=u32n(p);if op==0x3B then gs.rp0=u32n(p) end;return true
    elseif op==0x3C then
        local ref,re=run:get_point(gs.zp0,gs.rp0);if not ref then return nil,re end;local target=project_point(run,ref,false,false);local n=loop_count(run)
        for _=1,n do local p,e=run:pop();if p==nil then return nil,e end;local pt,pe=run:get_point(gs.zp1,p);if not pt then return nil,pe end;local ok,me=move_projection(run,pt,target,true);if not ok then return nil,me end end;return true
    elseif op==0x3E or op==0x3F then
        local ci,p,e=run:pop2();if ci==nil then return nil,e end;local idx,ie=run:index_check(ci,#run.cvt,"CVT index");if not idx then return nil,ie end;local pt,pe=run:get_point(gs.zp0,p);if not pt then return nil,pe end
        local cv=run.cvt[idx+1] or 0;local target
        if gs.zp0==0 then
            -- Real-world Microsoft fonts rely on this undocumented-but-established behavior:
            -- twilight MIAP first creates an unrounded original point from the CVT and does not
            set_twilight_relative(run,pt,nil,cv);target=cv
        else
            local orig=project_point(run,pt,true,false)
            target=(op==0x3F and abs(cv-orig)>abs(gs.control_value_cut_in or 0)) and orig or cv
        end
        if op==0x3F then target=round_value(gs,target) end;local ok,me=move_projection(run,pt,target,true);if not ok then return nil,me end
        gs.rp0=u32n(p);gs.rp1=u32n(p);return true
    elseif op==0x46 or op==0x47 then
        local p,e=run:pop();if p==nil then return nil,e end;local pt,pe=run:get_point(gs.zp2,p);if not pt then return nil,pe end;local ok,qe=run:push(project_point(run,pt,op==0x47,op==0x47));if not ok then return nil,qe end;return true
    elseif op==0x48 then
        local value,p,e=run:pop2();if value==nil then return nil,e end;local pt,pe=run:get_point(gs.zp2,p);if not pt then return nil,pe end;return move_projection(run,pt,value,true)
    elseif op==0x49 or op==0x4A then
        local p1,p2,e=run:pop2();if p1==nil then return nil,e end;local a,ae=run:get_point(gs.zp1,p1);if not a then return nil,ae end;local b,be=run:get_point(gs.zp0,p2);if not b then return nil,be end
        -- MD measures zp0[p2] - zp1[p1].
        local d=op==0x4A and original_distance(run,b,gs.zp0,a,gs.zp1) or point_distance(run,b,a,false)
        local ok,qe=run:push(d);if not ok then return nil,qe end;return true
    elseif op==0x5D or op==0x71 or op==0x72 then return do_deltap(run,op)
    elseif op==0x80 then
        local n=loop_count(run);for _=1,n do local p,e=run:pop();if p==nil then return nil,e end;local pt,pe=run:get_point(gs.zp0,p);if not pt then return nil,pe end;pt.on=not pt.on end;return true
    elseif op==0x81 or op==0x82 then
        local high,low,e=run:pop2();if high==nil then return nil,e end;high=trunc(high);low=trunc(low);if low<0 or high<low then return nil,"invalid FLIPRG range" end
        for idx=low,high do local pt,pe=run:get_point(gs.zp0,idx);if not pt then return nil,pe end;pt.on=(op==0x81) end;return true
    elseif op>=0xC0 and op<=0xFF then
        local indirect=op>=0xE0;local bits=op-(indirect and 0xE0 or 0xC0);local set_rp0=floor(bits/16)%2==1;local keep_min=floor(bits/8)%2==1;local do_round=floor(bits/4)%2==1;local distance_type=bits%4
        local p,ci,e
        if indirect then ci,p,e=run:pop2();if ci==nil then return nil,e end else p,e=run:pop();if p==nil then return nil,e end end
        local pt,pe=run:get_point(gs.zp1,p);if not pt then return nil,pe end;local ref,re=run:get_point(gs.zp0,gs.rp0);if not ref then return nil,re end
        -- MDRP measures its ideal distance from unscaled originals (`orus`) for normal glyph
        -- zones.
        local original=indirect and point_distance(run,pt,ref,true)
            or original_distance(run,pt,gs.zp1,ref,gs.zp0)
        local dist
        if indirect then
            local idx,ie=run:index_check(ci,#run.cvt,"CVT index");if not idx then return nil,ie end;local cv=run.cvt[idx+1] or 0
            cv=enforce_single_width(gs,cv)
            -- A MIRP that targets zone 0 creates a new ideal/original point from rp0 plus the
            -- (single-width-adjusted) CVT distance before the dual-projection/autoflip/cut-in
            if gs.zp1==0 then set_twilight_relative(run,pt,ref,cv);original=point_distance(run,pt,ref,true) end
            if gs.auto_flip and original~=0 and cv~=0 and ((original<0)~=(cv<0)) then cv=-cv end
            dist=cv
            -- Microsoft/FreeType compatibility: MIRP's CVT cut-in is only applied when the
            -- reference and moved point are in the same zone.
            if do_round and gs.zp0==gs.zp1 and abs(cv-original)>abs(gs.control_value_cut_in or 0) then dist=original end
            if do_round then dist=round_value(gs,dist,distance_type,run.engine.engine_compensation) else dist=compensate_distance(dist,distance_type,run.engine.engine_compensation) end
        else
            dist=enforce_single_width(gs,original)
            if do_round then dist=round_value(gs,dist,distance_type,run.engine.engine_compensation) else dist=compensate_distance(dist,distance_type,run.engine.engine_compensation) end
        end
        if keep_min then dist=enforce_minimum(gs,dist,original) end
        local target=project_point(run,ref,false,false)+dist;local ok,me=move_projection(run,pt,target,true);if not ok then return nil,me end
        local old=gs.rp0;gs.rp1=old;gs.rp2=u32n(p);if set_rp0 then gs.rp0=u32n(p) end;return true
    end
    return nil,("unimplemented point opcode 0x%02X"):format(op)
end

local native_opcode={
    [0x00]=true,[0x01]=true,[0x02]=true,[0x03]=true,[0x04]=true,[0x05]=true,[0x0A]=true,[0x0B]=true,[0x0C]=true,[0x0D]=true,[0x0E]=true,
    [0x10]=true,[0x11]=true,[0x12]=true,[0x13]=true,[0x14]=true,[0x15]=true,[0x16]=true,[0x17]=true,[0x18]=true,[0x19]=true,[0x1A]=true,[0x1B]=true,[0x1C]=true,[0x1D]=true,[0x1E]=true,[0x1F]=true,
    [0x20]=true,[0x21]=true,[0x22]=true,[0x23]=true,[0x24]=true,[0x25]=true,[0x26]=true,[0x2A]=true,[0x2B]=true,[0x2C]=true,[0x2D]=true,
    [0x3D]=true,[0x42]=true,[0x43]=true,[0x44]=true,[0x45]=true,[0x4B]=true,[0x4C]=true,[0x4D]=true,[0x4E]=true,[0x4F]=true,
    [0x50]=true,[0x51]=true,[0x52]=true,[0x53]=true,[0x54]=true,[0x55]=true,[0x56]=true,[0x57]=true,[0x58]=true,[0x59]=true,[0x5A]=true,[0x5B]=true,[0x5C]=true,[0x5E]=true,[0x5F]=true,
    [0x60]=true,[0x61]=true,[0x62]=true,[0x63]=true,[0x64]=true,[0x65]=true,[0x66]=true,[0x67]=true,[0x68]=true,[0x69]=true,[0x6A]=true,[0x6B]=true,[0x6C]=true,[0x6D]=true,[0x6E]=true,[0x6F]=true,[0x70]=true,
    [0x73]=true,[0x74]=true,[0x75]=true,[0x76]=true,[0x77]=true,[0x78]=true,[0x79]=true,[0x7A]=true,[0x7C]=true,[0x7D]=true,[0x7E]=true,[0x7F]=true,
    [0x85]=true,[0x88]=true,[0x89]=true,[0x8A]=true,[0x8B]=true,[0x8C]=true,[0x8D]=true,[0x8E]=true,[0x91]=true,
}
for op=0x40,0x41 do native_opcode[op]=true end
for op=0xB0,0xBF do native_opcode[op]=true end
for op in pairs(point_op) do native_opcode[op]=true end
local function is_native(op) return native_opcode[op] == true end

function Run:call_body(body,label)
    if self.call_depth>=self.engine.call_depth_limit then return nil,"call depth exceeded" end
    local child=self.engine:_new_run(label or "function",body,{
        storage=self.storage,cvt=self.cvt,graphics=self.graphics,functions=self.functions,idefs=self.idefs,
        ppem_x=self.ppem_x,ppem_y=self.ppem_y,point_size=self.point_size,rotated=self.rotated,stretched=self.stretched,grayscale=self.grayscale,
        budget=self.budget,call_depth=self.call_depth+1,trace=self.trace,
        zones=self.zones,contours=self.contours,glyph_point_count=self.glyph_point_count,
    })
    child.stack=self.stack -- function calls share the same interpreter stack
    local ok,err=child:execute();self.stack=child.stack
    return ok,err
end

function Run:execute()
    while self.ip<=#self.program do
        if self.budget.left<=0 then return self:fail("instruction budget exceeded") end
        self.budget.left=self.budget.left-1
        local op_pos=self.ip;local op=u8(self.program,self.ip);self.ip=self.ip+1
        if self.trace then self.trace[#self.trace+1]={kind=self.kind,ip=op_pos,opcode=op,depth=#self.stack} end

        -- Push families ------------------------------------------------------
        if op==0x40 or op==0x41 then
            local n=u8(self.program,self.ip);if n==nil then return self:fail("truncated NPUSH count") end;self.ip=self.ip+1
            for _=1,n do
                local v;if op==0x40 then v=u8(self.program,self.ip);self.ip=self.ip+1 else v=s16(self.program,self.ip);self.ip=self.ip+2 end
                if v==nil then return self:fail("truncated NPUSH payload") end
                local ok,e=self:push(v);if not ok then return self:fail(e) end
            end
        elseif op>=0xB0 and op<=0xB7 then
            local n=op-0xB0+1
            for _=1,n do local v=u8(self.program,self.ip);self.ip=self.ip+1;if v==nil then return self:fail("truncated PUSHB payload") end;local ok,e=self:push(v);if not ok then return self:fail(e) end end
        elseif op>=0xB8 and op<=0xBF then
            local n=op-0xB8+1
            for _=1,n do local v=s16(self.program,self.ip);self.ip=self.ip+2;if v==nil then return self:fail("truncated PUSHW payload") end;local ok,e=self:push(v);if not ok then return self:fail(e) end end

        -- IDEF gets first chance only for opcodes not natively known by this scaler.
        elseif not is_native(op) and self.idefs[op] then
            local ok,e=self:call_body(self.idefs[op],("IDEF 0x%02X"):format(op));if not ok then return self:fail(e) end

        -- Vector/graphics-state instructions which do not inspect glyph points.
        elseif op==0x00 or op==0x01 then set_axis(self.graphics,"both",op==0x00)
        elseif op==0x02 or op==0x03 then set_axis(self.graphics,"p",op==0x02)
        elseif op==0x04 or op==0x05 then set_axis(self.graphics,"f",op==0x04)
        elseif op==0x0A or op==0x0B then
            local y,x,e=self:pop2();if y==nil then return self:fail(e) end;x,y=normalise_vector(x,y)
            if op==0x0A then self.graphics.projection_x,self.graphics.projection_y=x,y;self.graphics.dual_projection_x,self.graphics.dual_projection_y=x,y else self.graphics.freedom_x,self.graphics.freedom_y=x,y end
        elseif op==0x0C then local ok,e=self:push(self.graphics.projection_x);if not ok then return self:fail(e) end;ok,e=self:push(self.graphics.projection_y);if not ok then return self:fail(e) end
        elseif op==0x0D then local ok,e=self:push(self.graphics.freedom_x);if not ok then return self:fail(e) end;ok,e=self:push(self.graphics.freedom_y);if not ok then return self:fail(e) end
        elseif op==0x0E then self.graphics.freedom_x,self.graphics.freedom_y=self.graphics.projection_x,self.graphics.projection_y
        elseif op>=0x10 and op<=0x12 then local v,e=self:pop();if v==nil then return self:fail(e) end;self.graphics[({"rp0","rp1","rp2"})[op-0x0F]]=u32n(v)
        elseif op>=0x13 and op<=0x15 then local v,e=self:pop();if v==nil then return self:fail(e) end;v=trunc(v);if v~=0 and v~=1 then return self:fail("zone pointer must be 0 or 1") end;self.graphics[({"zp0","zp1","zp2"})[op-0x12]]=v
        elseif op==0x16 then local v,e=self:pop();if v==nil then return self:fail(e) end;v=trunc(v);if v~=0 and v~=1 then return self:fail("zone pointer must be 0 or 1") end;self.graphics.zp0,self.graphics.zp1,self.graphics.zp2=v,v,v
        elseif op==0x17 then local v,e=self:pop();if v==nil then return self:fail(e) end;v=trunc(v);if v<0 then return self:fail("SLOOP requires a non-negative count") end;self.graphics.loop=min(v,0xFFFF)
        elseif op==0x18 then self.graphics.round_mode="grid";self.graphics.round_period,self.graphics.round_phase,self.graphics.round_threshold=64,0,32
        elseif op==0x19 then self.graphics.round_mode="half";self.graphics.round_period,self.graphics.round_phase,self.graphics.round_threshold=64,32,32
        elseif op==0x1A then local v,e=self:pop();if v==nil then return self:fail(e) end;self.graphics.minimum_distance=i32(v)
        elseif op==0x1D then local v,e=self:pop();if v==nil then return self:fail(e) end;self.graphics.control_value_cut_in=i32(v)
        elseif op==0x1E then local v,e=self:pop();if v==nil then return self:fail(e) end;self.graphics.single_width_cut_in=i32(v)
        elseif op==0x1F then local v,e=self:pop();if v==nil then return self:fail(e) end;self.graphics.single_width_value=scale_funit(self,v)
        elseif op==0x3D then self.graphics.round_mode="double";self.graphics.round_period,self.graphics.round_phase,self.graphics.round_threshold=32,0,16
        elseif op==0x4D then self.graphics.auto_flip=true
        elseif op==0x4E then self.graphics.auto_flip=false
        elseif op==0x5E then local v,e=self:pop();if v==nil then return self:fail(e) end;self.graphics.delta_base=i32(v)
        elseif op==0x5F then local v,e=self:pop();if v==nil then return self:fail(e) end;v=trunc(v);if v<0 or v>6 then return self:fail("SDS delta_shift must be in 0..6") end;self.graphics.delta_shift=v
        elseif op==0x76 or op==0x77 then local v,e=self:pop();if v==nil then return self:fail(e) end;make_super_round(self.graphics,v,op==0x76 and 64 or (64*sqrt(2)/2))
        elseif op==0x7A then self.graphics.round_mode="off"
        elseif op==0x7C then self.graphics.round_mode="up"
        elseif op==0x7D then self.graphics.round_mode="down"
        elseif op==0x7E then local v,e=self:pop();if v==nil then return self:fail(e) end;self.graphics.angle_weight=i32(v)
        elseif op==0x85 then local v,e=self:pop();if v==nil then return self:fail(e) end;self.graphics.scan_control=u32n(v)%65536
        elseif op==0x8D then local v,e=self:pop();if v==nil then return self:fail(e) end;self.graphics.scan_type=i32(v)
        elseif op==0x8E then
            local selector,value,e=self:pop2();if selector==nil then return self:fail(e) end;selector=i32(selector);value=u32n(value)
            if selector==1 then if value>1 then return self:fail("INSTCTRL selector 1 value must be 0/1") end;local b=1;if value==1 then self.graphics.instruction_control=self.graphics.instruction_control+b else self.graphics.instruction_control=self.graphics.instruction_control-self.graphics.instruction_control%2 end
            elseif selector==2 then if value>2 or value%2~=0 then return self:fail("INSTCTRL selector 2 value must be 0/2") end;local set=value==2;local has=floor(self.graphics.instruction_control/2)%2==1;if set and not has then self.graphics.instruction_control=self.graphics.instruction_control+2 elseif not set and has then self.graphics.instruction_control=self.graphics.instruction_control-2 end
            elseif selector==3 then if value~=0 and value~=4 then return self:fail("INSTCTRL selector 3 value must be 0/4") end;local set=value==4;local has=floor(self.graphics.instruction_control/4)%2==1;if set and not has then self.graphics.instruction_control=self.graphics.instruction_control+4 elseif not set and has then self.graphics.instruction_control=self.graphics.instruction_control-4 end
            end

        -- Stack --------------------------------------------------------------
        elseif op==0x20 then local v,e=self:pop();if v==nil then return self:fail(e) end;local ok,pe=self:push(v);if not ok then return self:fail(pe) end;ok,pe=self:push(v);if not ok then return self:fail(pe) end
        elseif op==0x21 then local _,e=self:pop();if e then return self:fail(e) end
        elseif op==0x22 then self.stack={}
        elseif op==0x23 then local a,b,e=self:pop2();if a==nil then return self:fail(e) end;local ok,pe=self:push(a);if not ok then return self:fail(pe) end;ok,pe=self:push(b);if not ok then return self:fail(pe) end
        elseif op==0x24 then local ok,e=self:push(#self.stack);if not ok then return self:fail(e) end
        elseif op==0x25 then
            local k,e=self:pop();if k==nil then return self:fail(e) end;k=trunc(k);if k<1 or k>#self.stack then return self:fail("CINDEX out of range") end;local ok,pe=self:push(self.stack[#self.stack-k+1]);if not ok then return self:fail(pe) end
        elseif op==0x26 then
            local k,e=self:pop();if k==nil then return self:fail(e) end;k=trunc(k);if k<1 or k>#self.stack then return self:fail("MINDEX out of range") end;local pos=#self.stack-k+1;local v=table.remove(self.stack,pos);local ok,pe=self:push(v);if not ok then return self:fail(pe) end
        elseif op==0x8A then
            if #self.stack<3 then return self:fail("ROLL stack underflow") end
            local n=#self.stack;local c=self.stack[n-2];self.stack[n-2]=self.stack[n-1];self.stack[n-1]=self.stack[n];self.stack[n]=c

        -- Storage / CVT ------------------------------------------------------
        elseif op==0x42 then
            local value,loc,e=self:pop2();if value==nil then return self:fail(e) end;local idx,ie=self:index_check(loc,self.engine.maxp.max_storage or 0,"storage index");if not idx then return self:fail(ie) end;self.storage[idx]=i32(value)
        elseif op==0x43 then
            local loc,e=self:pop();if loc==nil then return self:fail(e) end;local idx,ie=self:index_check(loc,self.engine.maxp.max_storage or 0,"storage index");if not idx then return self:fail(ie) end;local ok,pe=self:push(self.storage[idx] or 0);if not ok then return self:fail(pe) end
        elseif op==0x44 or op==0x70 then
            local value,loc,e=self:pop2();if value==nil then return self:fail(e) end;local idx,ie=self:index_check(loc,#self.cvt,"CVT index");if not idx then return self:fail(ie) end
            if op==0x70 then value=scale_funit(self,value) end;self.cvt[idx+1]=i32(value)
        elseif op==0x45 then
            local loc,e=self:pop();if loc==nil then return self:fail(e) end;local idx,ie=self:index_check(loc,#self.cvt,"CVT index");if not idx then return self:fail(ie) end;local ok,pe=self:push(self.cvt[idx+1] or 0);if not ok then return self:fail(pe) end
        elseif op==0x73 or op==0x74 or op==0x75 then local ok,e=do_deltac(self,op);if not ok then return self:fail(e) end

        -- Flow / functions --------------------------------------------------
        elseif op==0x58 then
            local cond,e=self:pop();if cond==nil then return self:fail(e) end;if cond==0 then local np,se=scan_if(self.program,self.ip,true);if not np then return self:fail(se) end;self.ip=np end
        elseif op==0x1B then local np,e=scan_if(self.program,self.ip,false);if not np then return self:fail(e) end;self.ip=np
        elseif op==0x59 then -- EIF
        elseif op==0x1C then local off,e=self:pop();if off==nil then return self:fail(e) end;local np=op_pos+i32(off);if np<1 or np>#self.program+1 then return self:fail("JMPR target out of range") end;self.ip=np
        elseif op==0x78 or op==0x79 then
            local cond,off,e=self:pop2();if cond==nil then return self:fail(e) end;local take=(op==0x78 and cond~=0) or (op==0x79 and cond==0)
            if take then local np=op_pos+i32(off);if np<1 or np>#self.program+1 then return self:fail("conditional jump target out of range") end;self.ip=np end
        elseif op==0x2C or op==0x89 then
            if self.kind=="glyph" then return self:fail(op==0x2C and "FDEF not allowed in glyph program" or "IDEF not allowed in glyph program") end
            local id,e=self:pop();if id==nil then return self:fail(e) end;id=u32n(id)
            local body,np,se=scan_definition(self.program,self.ip);if not body then return self:fail(se) end;self.ip=np
            if op==0x2C then
                local lim=self.engine.maxp.max_function_defs or 0;if lim>0 and id>=lim then return self:fail("FDEF id exceeds maxFunctionDefs") end;self.functions[id]=body
            else
                if id>255 then return self:fail("IDEF opcode out of range") end
                local lim=self.engine.maxp.max_instruction_defs or 0
                if lim>0 then local count=0;for _ in pairs(self.idefs) do count=count+1 end;if not self.idefs[id] and count>=lim then return self:fail("IDEF count exceeds maxInstructionDefs") end end
                if not is_native(id) then self.idefs[id]=body end
            end
        elseif op==0x2D then return self:fail("ENDF outside FDEF/IDEF")
        elseif op==0x2B then
            local f,e=self:pop();if f==nil then return self:fail(e) end;f=u32n(f);local body=self.functions[f];if not body then return self:fail("CALL to undefined function "..f) end;local ok,ce=self:call_body(body,"FDEF "..f);if not ok then return self:fail(ce) end
        elseif op==0x2A then
            local f,count,e=self:pop2();if f==nil then return self:fail(e) end;f=u32n(f);count=i32(count);if count<0 then return self:fail("negative LOOPCALL count") end;local body=self.functions[f];if not body then return self:fail("LOOPCALL to undefined function "..f) end
            if count>self.budget.left then return self:fail("LOOPCALL exceeds instruction budget") end
            for _=1,count do local ok,ce=self:call_body(body,"FDEF "..f);if not ok then return self:fail(ce) end end

        -- Logic -------------------------------------------------------------
        elseif op>=0x50 and op<=0x55 then
            local e2,e1,e=self:pop2();if e2==nil then return self:fail(e) end;local r
            if op==0x50 then r=e1<e2 elseif op==0x51 then r=e1<=e2 elseif op==0x52 then r=e1>e2 elseif op==0x53 then r=e1>=e2 elseif op==0x54 then r=e1==e2 else r=e1~=e2 end
            local ok,pe=self:push(r and 1 or 0);if not ok then return self:fail(pe) end
        elseif op==0x56 or op==0x57 then
            local v,e=self:pop();if v==nil then return self:fail(e) end;local iv=trunc(round_value(self.graphics,v)/64);local odd=abs(iv)%2==1;local ok,pe=self:push(((op==0x56 and odd) or (op==0x57 and not odd)) and 1 or 0);if not ok then return self:fail(pe) end
        elseif op==0x5A or op==0x5B then local a,b,e=self:pop2();if a==nil then return self:fail(e) end;local r=op==0x5A and (a~=0 and b~=0) or (a~=0 or b~=0);local ok,pe=self:push(r and 1 or 0);if not ok then return self:fail(pe) end
        elseif op==0x5C then local a,e=self:pop();if a==nil then return self:fail(e) end;local ok,pe=self:push(a==0 and 1 or 0);if not ok then return self:fail(pe) end

        -- Arithmetic --------------------------------------------------------
        elseif op>=0x60 and op<=0x63 then
            local a,b,e=self:pop2();if a==nil then return self:fail(e) end;local r
            if op==0x60 then r=b+a elseif op==0x61 then r=b-a elseif op==0x62 then if a==0 then return self:fail("division by zero") end;r=trunc(b*64/a) else r=trunc(b*a/64) end
            local ok,pe=self:push(r);if not ok then return self:fail(pe) end
        elseif op==0x64 or op==0x65 or op==0x66 or op==0x67 then
            local a,e=self:pop();if a==nil then return self:fail(e) end;local r;if op==0x64 then r=abs(a) elseif op==0x65 then r=-a elseif op==0x66 then r=floor(a/64)*64 else r=ceil(a/64)*64 end;local ok,pe=self:push(r);if not ok then return self:fail(pe) end
        elseif op>=0x68 and op<=0x6B then local a,e=self:pop();if a==nil then return self:fail(e) end;local dtype=op-0x68;local ok,pe=self:push(round_value(self.graphics,a,dtype,self.engine.engine_compensation));if not ok then return self:fail(pe) end
        elseif op>=0x6C and op<=0x6F then local a,e=self:pop();if a==nil then return self:fail(e) end;local dtype=op-0x6C;local ok,pe=self:push(compensate_distance(a,dtype,self.engine.engine_compensation));if not ok then return self:fail(pe) end
        elseif op==0x8B or op==0x8C then local a,b,e=self:pop2();if a==nil then return self:fail(e) end;local ok,pe=self:push(op==0x8B and max(a,b) or min(a,b));if not ok then return self:fail(pe) end

        -- Size/scaler information ------------------------------------------
        elseif op==0x4B then local ok,e=self:push(projection_ppem(self));if not ok then return self:fail(e) end
        elseif op==0x4C then local ok,e=self:push(self.point_size or projection_ppem(self)*64);if not ok then return self:fail(e) end
        elseif op==0x88 then local selector,e=self:pop();if selector==nil then return self:fail(e) end;local ok,pe=self:push(result_getinfo(self,selector));if not ok then return self:fail(pe) end
        elseif op==0x91 then
            for i=1,self.engine.variation_axis_count do local c=self.engine.normalized_variations[i] or 0;local ok,e=self:push(trunc(max(-1,min(1,c))*16384));if not ok then return self:fail(e) end end
        elseif op==0x4F then local _,e=self:pop();if e then return self:fail(e) end -- DEBUG is a no-op
        elseif op==0x7F then local _,e=self:pop();if e then return self:fail(e) end -- obsolete AA: consume argument, no effect

        elseif point_op[op] then
            local ok,e=execute_point(self,op);if not ok then return self:fail(e) end
        else
            return self:fail(("unsupported opcode 0x%02X"):format(op))
        end
    end
    return true
end

local function scale_cvt(engine,ppem)
    local out={};local scale=(ppem or 0)*64/engine.units_per_em
    for i=1,#engine.cvt_funits do out[i]=i32(engine.cvt_funits[i]*scale) end
    return out
end

function Engine:_run_font_program()
    if self.font_program_ran then return self.font_program_error==nil,self.font_program_error end
    self.font_program_ran=true
    if #self.fpgm>0 then
        local run=self:_new_run("fpgm",self.fpgm,{storage=self.font_storage,cvt={},graphics=graphics_defaults(),ppem_x=0,ppem_y=0,point_size=0})
        local ok,err=run:execute();if not ok then self.font_program_error=err;return nil,err end
    end
    return true
end

function Engine:prepare(ppem_x,ppem_y,options)
    options=options or {}
    local requested_x=max(1,tonumber(ppem_x) or 1);local requested_y=max(1,tonumber(ppem_y) or requested_x)
    local point_size=i32(tonumber(options.point_size) or (requested_y*64))
    if self.force_integer_ppem then
        -- head.flags bit 3 requests ROUND-to-nearest integer ppem for scaler math.
        ppem_x=max(1,floor(requested_x+0.5));ppem_y=max(1,floor(requested_y+0.5))
    else ppem_x,ppem_y=requested_x,requested_y end
    local grayscale=options.grayscale==nil and self.grayscale or options.grayscale~=false
    local key=table.concat({ppem_x,ppem_y,point_size,options.rotated and 1 or 0,options.stretched and 1 or 0,grayscale and 1 or 0},":")
    -- The CV program runs whenever scaler-observable state changes, not as an independent
    -- memoized function of ppem.
    if self.current_prepare_key==key and self.current_prepare_state then return self.current_prepare_state end
    local ok,err=self:_run_font_program();if not ok then return nil,err end
    local cvt=scale_cvt(self,max(ppem_x,ppem_y));local storage=self.font_storage;local gs=graphics_defaults()
    local run=self:_new_run("prep",self.prep,{storage=storage,cvt=cvt,graphics=gs,functions=self.functions,idefs=self.idefs,ppem_x=ppem_x,ppem_y=ppem_y,point_size=point_size,rotated=options.rotated,stretched=options.stretched,grayscale=grayscale})
    if #self.prep>0 then local pok,perr=run:execute();if not pok then return nil,perr end end
    -- Only a defined subset of the graphics state survives the CVT/prep program into glyph
    -- execution.
    local saved_gs=graphics_defaults()
    for _,k in ipairs({
        "minimum_distance","control_value_cut_in","single_width_cut_in",
        "single_width_value","delta_base","delta_shift","auto_flip",
        "instruction_control","scan_control","scan_type"
    }) do saved_gs[k]=gs[k] end
    local state={ppem_x=ppem_x,ppem_y=ppem_y,requested_ppem_x=requested_x,requested_ppem_y=requested_y,force_integer_ppem=self.force_integer_ppem==true,point_size=run.point_size,cvt=cvt,storage=storage,graphics=saved_gs,functions=self.functions,idefs=self.idefs,grayscale=grayscale,twilight=make_twilight(self.maxp.max_twilight_points or 0)}
    self.prepare_runs=self.prepare_runs+1;self.current_prepare_key=key;self.current_prepare_state=state
    return state
end


-- Execute one glyph instruction stream against already-scaled F26.6 points.
function Engine:run_glyph(prepared,program,points,contours,options)
    options=options or {};if not prepared then return nil,"prepared TrueType VM state is required" end
    points=points or {};contours=contours or {}
    local declared_points=max(self.maxp.max_points or 0,self.maxp.max_composite_points or 0)
    local declared_contours=max(self.maxp.max_contours or 0,self.maxp.max_composite_contours or 0)
    -- maxp point counts exclude the four phantom points supplied by the scaler.
    local real_points=max(0,#points-4)
    if declared_points>0 and real_points>declared_points then return nil,"glyph point count exceeds maxp" end
    if declared_contours>0 and #contours>declared_contours then return nil,"glyph contour count exceeds maxp" end
    local ic=prepared.graphics and prepared.graphics.instruction_control or 0
    local glyph_points=copy_points(points)
    if ic%2==1 then return {points=glyph_points,twilight=prepared.twilight,graphics=clone_graphics(prepared.graphics),skipped=true} end
    local gs
    if floor(ic/2)%2==1 then gs=graphics_defaults();gs.instruction_control=ic else gs=clone_graphics(prepared.graphics) end
    local zones={[0]=prepared.twilight or make_twilight(self.maxp.max_twilight_points or 0),[1]=glyph_points}
    prepared.twilight=zones[0]
    local run=self:_new_run("glyph",program or "",{storage=prepared.storage,cvt=prepared.cvt,graphics=gs,functions=prepared.functions or self.functions,idefs=prepared.idefs or self.idefs,ppem_x=prepared.ppem_x,ppem_y=prepared.ppem_y,point_size=prepared.point_size,grayscale=prepared.grayscale,is_composite=options.is_composite==true,zones=zones,contours=contours,glyph_point_count=real_points})
    local ok,err=run:execute()
    if not ok and options.pedantic==true then return nil,err end
    -- Microsoft-compatible rasterizers (and FreeType by default) are non-pedantic for glyph
    -- programs: if bytecode fails after moving some points, retain those movements and continue
    return {points=glyph_points,twilight=zones[0],graphics=gs,stack=run.stack,skipped=false,error=err,partial=not ok}
end

function Engine:diagnostics()
    local f=0;for _ in pairs(self.functions) do f=f+1 end;local i=0;for _ in pairs(self.idefs) do i=i+1 end
    return {maxp=copy_table(self.maxp),head_flags=self.head_flags or 0,force_integer_ppem=self.force_integer_ppem==true,cvt_entries=#self.cvt_funits,cvar_present=self.tables and self.tables["cvar"]~=nil or false,cvar_applied=self.cvar_applied==true,cvar_error=self.cvar_error,engine_compensation=copy_table(self.engine_compensation or {}),fpgm_bytes=#self.fpgm,prep_bytes=#self.prep,function_defs=f,instruction_defs=i,prepare_runs=self.prepare_runs or 0,font_program_ran=self.font_program_ran,font_program_error=self.font_program_error}
end

-- Raw VM entry point.
function TT._test_run(program,options)
    options=options or {}
    local maxp=options.maxp or {max_storage=options.max_storage or 32,max_function_defs=options.max_function_defs or 64,max_instruction_defs=options.max_instruction_defs or 64,max_stack_elements=options.max_stack_elements or 256}
    local e=setmetatable({units_per_em=options.units_per_em or 1000,maxp=maxp,functions={},idefs={},font_storage={},font_program_ran=true,current_prepare_key=nil,current_prepare_state=nil,prepare_runs=0,normalized_variations=options.normalized_variations or {},variation_axis_count=options.variation_axis_count or #(options.normalized_variations or {}),hard_stack_limit=65536,instruction_budget=options.instruction_budget or 100000,call_depth_limit=64,strict=true,scaler_version=42,supports_variations=true,supports_vertical_phantoms=true,grayscale=true,engine_compensation={gray=tonumber((options.engine_compensation or {}).gray or 0) or 0,black=tonumber((options.engine_compensation or {}).black or 0) or 0,white=tonumber((options.engine_compensation or {}).white or 0) or 0}},Engine)
    for i=0,(maxp.max_storage or 0)-1 do e.font_storage[i]=0 end
    local cvt=copy_array(options.cvt or {});local storage=copy_table(options.storage or e.font_storage);local gs=clone_graphics(options.graphics or graphics_defaults())
    local px=options.ppem_x or 16;local py=options.ppem_y or px
    local zones
    if options.points or options.twilight then zones={[0]=copy_points(options.twilight or make_twilight(maxp.max_twilight_points or 0)),[1]=copy_points(options.points or {})} end
    local r=e:_new_run(options.kind or "test",program,{storage=storage,cvt=cvt,graphics=gs,ppem_x=px,ppem_y=py,point_size=options.point_size or py*64,grayscale=options.grayscale,is_composite=options.is_composite==true,zones=zones,contours=options.contours or {},glyph_point_count=zones and (options.glyph_point_count or #zones[1]) or nil})
    local ok,err=r:execute();return ok,err,{stack=r.stack,storage=storage,cvt=cvt,graphics=gs,functions=e.functions,idefs=e.idefs,engine=e,points=zones and zones[1] or nil,twilight=zones and zones[0] or nil}
end

return TT
