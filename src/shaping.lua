-- SPDX-License-Identifier: 0BSD
-- Unicode and OpenType shaping.
local M=fontlib
local F=M.font
local U=M.unicode
local P=M.unicode_properties or U
local O=M.opentype
local S={VERSION=1}
M.shaping=S

local SCRIPT_TAGS={
    Arabic={"arab","DFLT"},Hebrew={"hebr","DFLT"},Latin={"latn","DFLT"},Greek={"grek","DFLT"},Cyrillic={"cyrl","DFLT"},
    Devanagari={"dev2","deva","DFLT"},Bengali={"bng2","beng","DFLT"},Gurmukhi={"gur2","guru","DFLT"},Gujarati={"gjr2","gujr","DFLT"},Oriya={"ory2","orya","DFLT"},
    Tamil={"tml2","taml","DFLT"},Telugu={"tel2","telu","DFLT"},Kannada={"knd2","knda","DFLT"},Malayalam={"mlm2","mlym","DFLT"},Sinhala={"sinh","DFLT"},
    Myanmar={"mym2","mymr","DFLT"},Khmer={"khmr","DFLT"},
}
local INDIC_SCRIPTS={Devanagari=true,Bengali=true,Gurmukhi=true,Gujarati=true,Oriya=true,Tamil=true,Telugu=true,Kannada=true,Malayalam=true,Sinhala=true}
function S.script_tags(script) return SCRIPT_TAGS[script] or {"DFLT"} end
function S.script_tag(script) return S.script_tags(script)[1] end

local function ensure_layout(font)
    if font._layout_ready then return end
    font._layout_ready = true
    if font._tables and O and O.parse then
        local opt={normalized_variations=font._normalized_variations or {},units_per_em=font.units_per_em}
        if not font._gsub then font._gsub = O.parse(font._tables.GSUB, "GSUB", font._tables.GDEF,opt) end
        if not font._gpos then font._gpos = O.parse(font._tables.GPOS, "GPOS", font._tables.GDEF,opt) end
    end
end

local function cp_gid(font,cp)
    if font._lookup_gid then return font._lookup_gid(cp) or 0 end
    local g=F.get_glyph(font,cp);return g and g.gid or 0
end
local function is_variation_selector(cp)
    return (cp>=0xFE00 and cp<=0xFE0F) or (cp>=0xE0100 and cp<=0xE01EF)
end

local function add_fallback_spec(out,seen,spec,recurse)
    if spec==nil or spec==false then return end
    if type(spec)=="table" and not F.is_font(spec) then
        for _,ref in ipairs(spec) do add_fallback_spec(out,seen,ref,recurse) end
        return
    end
    local font=F.get(spec)
    if not font or seen[font] then return end
    seen[font]=true;out[#out+1]=font
    if recurse and font.fallback~=nil and font.fallback~=false then
        add_fallback_spec(out,seen,font.fallback,true)
    end
end

local function fallback_chain(primary,options)
    local out={};local seen={}
    seen[primary]=true;out[1]=primary
    local spec=(options and options.fallback~=nil) and options.fallback or primary.fallback
    if spec~=false then add_fallback_spec(out,seen,spec,true) end
    return out
end

local function is_emoji_modifier(cp) return cp>=0x1F3FB and cp<=0x1F3FF end
local function is_regional_indicator(cp) return cp>=0x1F1E6 and cp<=0x1F1FF end
local function is_emoji_tag(cp) return cp>=0xE0020 and cp<=0xE007F end

local function cluster_list(analysis,run)
    local clusters={};local current;local regional_count=0
    local function new_cluster(i)
        current={first=i,last=i,join_next=false,regional_count=0}
        clusters[#clusters+1]=current
    end
    for i=run.first,run.last do
        local it=analysis.items[i]
        if not it.bidi_control then
            local cp=it.cp
            if not current then
                new_cluster(i)
            elseif is_variation_selector(cp) or U.is_combining(cp) or is_emoji_modifier(cp) or is_emoji_tag(cp) then
                current.last=i
            elseif cp==0x200D or cp==0x200C then
                current.last=i;current.join_next=true
            elseif current.join_next then
                current.last=i;current.join_next=false
            elseif is_regional_indicator(cp) and current.regional_count==1 then
                current.last=i;current.regional_count=2
            else
                new_cluster(i)
            end
            if is_regional_indicator(cp) then
                if current.regional_count==0 then current.regional_count=1 end
            elseif cp~=0x200D and cp~=0x200C and not is_variation_selector(cp) and not U.is_combining(cp) and not is_emoji_modifier(cp) and not is_emoji_tag(cp) then
                current.regional_count=0
            end
        end
    end
    return clusters
end

local function cluster_has_selector(analysis,cluster,selector)
    for i=cluster.first,cluster.last do
        local it=analysis.items[i]
        if it and it.cp==selector then return true end
    end
    return false
end

local function cluster_supported(font,analysis,cluster)
    local required=0
    for i=cluster.first,cluster.last do
        local it=analysis.items[i]
        if it and not it.bidi_control and not is_variation_selector(it.cp) then
            required=required+1
            if not F.has_glyph(font,it.cp) then return false end
        end
    end
    return required>0
end

local function font_color_capable(font)
    return font and (font.color_palettes~=nil or font._colr_layers~=nil or font._colr_v1~=nil or font._svg_for_gid~=nil or font._bitmap_for_gid~=nil)
end

local function choose_cluster_font(chain,analysis,cluster)
    -- U+FE0F asks for emoji-style presentation.
    if cluster_has_selector(analysis,cluster,0xFE0F) then
        for _,font in ipairs(chain) do
            if font_color_capable(font) and cluster_supported(font,analysis,cluster) then return font end
        end
    end
    for _,font in ipairs(chain) do
        if cluster_supported(font,analysis,cluster) then return font end
    end
    -- No face covers the whole grapheme/emoji cluster.
    return chain[1]
end

local function fallback_spans(primary,analysis,run,options)
    local chain=fallback_chain(primary,options)
    if #chain==1 then return {{first=run.first,last=run.last,font=primary}} end
    local spans={};local current
    for _,cluster in ipairs(cluster_list(analysis,run)) do
        local font=choose_cluster_font(chain,analysis,cluster)
        if current and current.font==font and current.last+1==cluster.first then
            current.last=cluster.last
        else
            current={first=cluster.first,last=cluster.last,font=font}
            spans[#spans+1]=current
        end
    end
    if #spans==0 then spans[1]={first=run.first,last=run.last,font=primary} end
    return spans
end
local function base_advance(font,item)
    if item.newline then return 0 end
    if font._advance_for_gid and item.gid then return font:_advance_for_gid(item.gid) end
    if font._advances and item.gid then return font._advances[item.gid] or font.default_advance end
    local g=F.get_glyph(font,item.cp);return g and g.advance or font.default_advance
end
local function has_feature_change(font,gid,script_tag,tag)
    ensure_layout(font)
    local gsub = font._gsub
    return gsub and gsub:feature_affects(type(script_tag)=="table" and script_tag or {script_tag,"DFLT"},tag,gid) or false
end

-- Arabic-style joining follows Unicode Joining_Type.
local function joining_type(item)
    local cp=item.cp or 0
    if cp==0x200C then return "U" end -- ZWNJ blocks joining
    if cp==0x200D then return "C" end -- ZWJ causes joining
    return (P.joining_type and P.joining_type(cp)) or (U.is_combining(cp) and "T" or "U")
end
local function can_join_prev(jt) return jt=="D" or jt=="R" or jt=="C" end
local function can_join_next(jt) return jt=="D" or jt=="L" or jt=="C" end

local function assign_arabic_forms(font,glyphs)
    local nodes={}
    for i,g in ipairs(glyphs) do
        local jt=joining_type(g);g._joining_type=jt
        if jt~="T" then nodes[#nodes+1]=i end
    end
    local joins_after={}
    for j=1,#nodes-1 do
        local a,b=glyphs[nodes[j]],glyphs[nodes[j+1]]
        joins_after[j]=can_join_next(a._joining_type) and can_join_prev(b._joining_type)
    end
    for j,ix in ipairs(nodes) do
        local g=glyphs[ix];local jt=g._joining_type
        if jt~="U" then
            local jp=j>1 and joins_after[j-1] or false
            local jn=j<#nodes and joins_after[j] or false
            if jp and jn then g.form="medi"
            elseif jp then g.form="fina"
            elseif jn then g.form="init"
            else g.form="isol" end
        end
    end
end

local function reset_positioning(font,glyphs)
    for _,g in ipairs(glyphs) do
        g.x_advance = base_advance(font,g)
        g.y_advance = 0
        g.x_offset = 0
        g.y_offset = 0
        g.advance = g.x_advance
    end
end

local function make_join_controls_invisible(font,glyphs)
    local space_gid=cp_gid(font,0x20)
    for _,g in ipairs(glyphs) do
        if g.cp==0x200C or g.cp==0x200D then
            g.gid=space_gid;g.x_advance=0;g.y_advance=0;g.x_offset=0;g.y_offset=0;g.advance=0
        end
    end
end

local function normalized_features(options)
    options=options or {}
    local raw=options.features or options.font_features or options.font_feature_settings
    local out={}
    if type(raw)=="table" then
        for k,v in pairs(raw) do
            if type(k)=="number" and type(v)=="string" then out[v]=true else out[tostring(k)]=v end
        end
    elseif type(raw)=="string" then
        for token in raw:gmatch("[^,%s]+") do
            local tag,val=token:match("^([%w%d][%w%d][%w%d][%w%d])=([01])$")
            if tag then out[tag]=val=="1" else out[token]=true end
        end
    end
    if options.kerning==false then out.kern=false;out.vkrn=false elseif options.kerning==true then out.kern=true end
    if options.ligatures==false then out.liga=false;out.clig=false elseif options.ligatures==true then out.liga=true;out.clig=true end
    return out
end

local function feature_enabled(options,tag,default)
    local f=normalized_features(options);local v=f[tag]
    if v==nil then return default~=false end
    return v~=false and v~=0 and v~="0" and v~="off"
end

local function apply_user_features(layout,tags,glyphs,options,lang,ppem,skip)
    if not layout then return end
    local f=normalized_features(options)
    for tag,v in pairs(f) do
        if type(tag)=="string" and #tag==4 and v~=false and v~=0 and v~="0" and not (skip and skip[tag]) then
            layout:apply_feature(tags,tag,glyphs,{language=lang,ppem=ppem})
        end
    end
end

local STANDARD_FEATURES={ccmp=true,locl=true,rlig=true,liga=true,clig=true,calt=true,kern=true,vkrn=true,dist=true,curs=true,mark=true,mkmk=true,
    isol=true,fina=true,fin2=true,fin3=true,medi=true,med2=true,init=true,mset=true,nukt=true,akhn=true,rphf=true,rkrf=true,pref=true,blwf=true,abvf=true,half=true,pstf=true,vatu=true,cjct=true,
    pres=true,abvs=true,blws=true,psts=true,haln=true,abvm=true,blwm=true,cfar=true,vert=true,vrt2=true,rvrn=true}

local function apply_positioning(font,glyphs,script_tags,lang,ppem,options)
    ensure_layout(font)
    reset_positioning(font,glyphs)
    local gpos = font._gpos
    if not gpos then return end
    local tags=type(script_tags)=="table" and script_tags or {script_tags,"DFLT"}
    local standard={kern=true,dist=true,curs=true,mark=true,mkmk=true}
    for _,tag in ipairs({"kern","dist","curs","mark","mkmk"}) do
        if feature_enabled(options,tag,true) then gpos:apply_feature(tags,tag,glyphs,{language=lang,ppem=ppem}) end
    end
    apply_user_features(gpos,tags,glyphs,options,lang,ppem,standard)
    for _,g in ipairs(glyphs) do
        g.advance = g.x_advance or g.advance or font.default_advance
    end
end

local function apply_arabic(font,glyphs,lang,ppem,options)
    ensure_layout(font)
    local gsub=font._gsub
    assign_arabic_forms(font,glyphs)
    if gsub then
        if feature_enabled(options,"ccmp",true) then gsub:apply_feature({"arab","DFLT"},"ccmp",glyphs,{language=lang,ppem=ppem}) end
        if feature_enabled(options,"locl",true) then gsub:apply_feature({"arab","DFLT"},"locl",glyphs,{language=lang,ppem=ppem}) end
        for _,feature in ipairs({"isol","fina","fin2","fin3","medi","med2","init"}) do
            if feature_enabled(options,feature,true) then gsub:apply_feature({"arab","DFLT"},feature,glyphs,{language=lang,ppem=ppem,mask=function(_,i)
                return glyphs[i] and glyphs[i].form==feature
            end}) end
        end
        local standard={ccmp=true,locl=true,isol=true,fina=true,fin2=true,fin3=true,medi=true,med2=true,init=true,rlig=true,calt=true,liga=true,clig=true,mset=true}
        for _,tag in ipairs({"rlig","calt","liga","clig","mset"}) do
            if feature_enabled(options,tag,true) then gsub:apply_feature({"arab","DFLT"},tag,glyphs,{language=lang,ppem=ppem}) end
        end
    end
    make_join_controls_invisible(font,glyphs)
    apply_positioning(font,glyphs,{"arab","DFLT"},lang,ppem,options)
end

local function is_consonant_cat(c)
    return c=="Consonant" or c=="Consonant_Dead" or c=="Consonant_Final" or c=="Consonant_Head_Letter"
        or c=="Consonant_Initial_Postfixed" or c=="Consonant_Medial" or c=="Consonant_Placeholder"
        or c=="Consonant_Prefixed" or c=="Consonant_Subjoined" or c=="Consonant_With_Stacker"
end
local function is_halant_cat(c) return c=="Virama" or c=="Invisible_Stacker" or c=="Pure_Killer" end
local function is_matra_cat(c) return c=="Vowel_Dependent" end
local function is_joiner_cp(cp) return cp==0x200C or cp==0x200D end
local function pos_is_left(pos)
    return pos=="Left" or pos=="Left_And_Right" or pos=="Top_And_Left" or pos=="Top_And_Left_And_Right"
        or pos=="Bottom_And_Left" or pos=="Top_And_Bottom_And_Left" or pos=="Visual_Order_Left"
end

local RA_CODEPOINTS={
    [0x0930]=true,[0x09B0]=true,[0x09F0]=true,[0x0A30]=true,[0x0AB0]=true,[0x0B30]=true,
    [0x0BB0]=true,[0x0C30]=true,[0x0CB0]=true,[0x0D30]=true,[0x0DBB]=true,
}

local function clone_for_cp(font,old,cp)
    return {
        gid=cp_gid(font,cp),cp=cp,cluster=old.cluster,source_index=old.source_index,level=old.level,
        direction=old.direction,script=old.script,
    }
end

local function indic_decompose(font,glyphs)
    local i=1
    while i<=#glyphs do
        local seq=P.indic_decompose and P.indic_decompose(glyphs[i].cp or 0)
        if seq then
            local old=glyphs[i]
            table.remove(glyphs,i)
            for j=#seq,1,-1 do table.insert(glyphs,i,clone_for_cp(font,old,seq[j])) end
            i=i+#seq
        else i=i+1 end
    end
end

local function indic_syllables(glyphs)
    local out={};local i=1
    while i<=#glyphs do
        local c=P.indic_syllabic and P.indic_syllabic(glyphs[i].cp or 0) or "Other"
        if is_consonant_cat(c) or c=="Vowel_Independent" then
            local a=i;i=i+1
            while i<=#glyphs do
                local cur=P.indic_syllabic(glyphs[i].cp or 0)
                local prev=P.indic_syllabic(glyphs[i-1].cp or 0)
                if cur=="Nukta" or cur=="Bindu" or cur=="Visarga" or cur=="Syllable_Modifier" or cur=="Tone_Mark"
                    or is_matra_cat(cur) or is_joiner_cp(glyphs[i].cp) then
                    i=i+1
                elseif is_halant_cat(prev) and (is_consonant_cat(cur) or is_joiner_cp(glyphs[i].cp)) then
                    i=i+1
                elseif i>=3 and is_joiner_cp(glyphs[i-1].cp) and is_halant_cat(P.indic_syllabic(glyphs[i-2].cp or 0)) and is_consonant_cat(cur) then
                    i=i+1
                elseif is_halant_cat(cur) then i=i+1
                else break end
            end
            out[#out+1]={a=a,b=i-1}
        else out[#out+1]={a=i,b=i};i=i+1 end
    end
    return out
end

local function apply_feature_list(layout,tags,glyphs,features,lang,ppem,options)
    if not layout then return end
    for _,feature in ipairs(features) do
        if feature_enabled(options,feature,true) then layout:apply_feature(tags,feature,glyphs,{language=lang,ppem=ppem}) end
    end
end

local IPOS={START=0,REPH=1,PRE_M=2,PRE_C=3,BASE_C=4,AFTER_MAIN=5,ABOVE_C=6,BEFORE_SUB=7,BELOW_C=8,AFTER_SUB=9,BEFORE_POST=10,POST_C=11,AFTER_POST=12,SMVD=13,END_POS=14}
local VIRAMA_CP={Devanagari=0x094D,Bengali=0x09CD,Gurmukhi=0x0A4D,Gujarati=0x0ACD,Oriya=0x0B4D,Tamil=0x0BCD,Telugu=0x0C4D,Kannada=0x0CCD,Malayalam=0x0D4D,Sinhala=0x0DCA}
local BLWF_POST_ONLY={Telugu=true,Kannada=true}

local function feature_pair_substitutes(layout,tags,feature,a,b)
    if not layout or not a or not b or not layout.would_substitute then return false end
    return layout:would_substitute(tags,feature,{a,b}) or layout:would_substitute(tags,feature,{b,a})
end

local function consonant_position(font,tags,virama_gid,gid)
    local gsub=font._gsub
    if feature_pair_substitutes(gsub,tags,"blwf",virama_gid,gid) or feature_pair_substitutes(gsub,tags,"vatu",virama_gid,gid) then return IPOS.BELOW_C end
    if feature_pair_substitutes(gsub,tags,"pstf",virama_gid,gid) or feature_pair_substitutes(gsub,tags,"pref",virama_gid,gid) then return IPOS.POST_C end
    return IPOS.BASE_C
end

local function matra_position(cp)
    local p=P.indic_positional and P.indic_positional(cp or 0) or "NA"
    if p:find("Left",1,true) or p=="Visual_Order_Left" then return IPOS.PRE_M end
    if p:find("Top",1,true) then return IPOS.ABOVE_C end
    if p:find("Bottom",1,true) then return IPOS.BELOW_C end
    if p:find("Right",1,true) then return IPOS.POST_C end
    return IPOS.AFTER_MAIN
end

local function shape_indic_syllable(font,syll,tags,lang,script,ppem,options)
    ensure_layout(font)
    local gsub=font._gsub
    apply_feature_list(gsub,tags,syll,{"locl","ccmp"},lang,ppem,options)

    if script=="Sinhala" then
        -- Sinhala fonts commonly encode the ZWJ conjunct behavior directly in the standard
        -- Indic feature sequence; preserving logical order here lets vatu/abvs form sequences
        for _,feature in ipairs({"nukt","akhn","rphf","rkrf","pref","blwf","abvf","half","pstf","vatu","cjct","init","pres","abvs","blws","psts","haln"}) do
            if gsub and feature_enabled(options,feature,true) then gsub:apply_feature(tags,feature,syll,{language=lang,ppem=ppem}) end
        end
        reset_positioning(font,syll)
        if font._gpos then apply_feature_list(font._gpos,tags,syll,{"dist","kern","abvm","blwm","mark","mkmk"},lang,ppem,options) end
        for _,g in ipairs(syll) do g.advance=g.x_advance or font.default_advance end
        return syll
    end

    local virama_cp=VIRAMA_CP[script]
    local virama_gid=virama_cp and cp_gid(font,virama_cp) or nil
    local reph=false
    if #syll>=2 and RA_CODEPOINTS[syll[1].cp] and is_halant_cat(P.indic_syllabic(syll[2].cp or 0)) then
        -- Telugu only forms reph explicitly with ZWJ; Malayalam normally uses encoded repha
        -- rather than implicit Ra+virama.
        if script=="Telugu" then reph=(syll[3] and syll[3].cp==0x200D) or false
        elseif script~="Malayalam" then reph=true end
    end

    -- Ask the font itself which consonants have below/post forms.
    for i=2,#syll do
        if syll[i].cp==0x200D and is_halant_cat(P.indic_syllabic(syll[i-1].cp or 0)) then
            for j=i-2,1,-1 do
                if is_consonant_cat(P.indic_syllabic(syll[j].cp or 0)) then syll[j]._force_half=true;break end
            end
        end
    end

    local cpos={}
    for i,g in ipairs(syll) do
        if is_consonant_cat(P.indic_syllabic(g.cp or 0)) then cpos[i]=consonant_position(font,tags,virama_gid,g.gid) end
    end

    local limit=reph and math.min(3,#syll+1) or 1
    local base=nil;local seen_below=false
    for i=#syll,limit,-1 do
        local cat=P.indic_syllabic(syll[i].cp or 0)
        if is_consonant_cat(cat) then
            local pos=cpos[i] or IPOS.BASE_C
            base=i
            if pos~=IPOS.BELOW_C and (pos~=IPOS.POST_C or seen_below) then break end
            if pos==IPOS.BELOW_C then seen_below=true end
        elseif syll[i].cp==0x200D and i>1 and is_halant_cat(P.indic_syllabic(syll[i-1].cp or 0)) then
            break
        end
    end
    if not base then
        for i=1,#syll do if is_consonant_cat(P.indic_syllabic(syll[i].cp or 0)) then base=i;break end end
    end
    base=base or 1
    local base_object=syll[base]

    -- Assign initial visual-position classes and stable-sort the cluster before basic GSUB,
    -- following the OpenType Indic model.
    for i,g in ipairs(syll) do
        g._order=i
        local cat=P.indic_syllabic(g.cp or 0)
        if is_consonant_cat(cat) then g._ipos=cpos[i] or IPOS.BASE_C
        elseif is_matra_cat(cat) then g._ipos=matra_position(g.cp)
        elseif cat=="Bindu" or cat=="Visarga" or cat=="Syllable_Modifier" or cat=="Tone_Mark" then g._ipos=IPOS.SMVD
        else g._ipos=IPOS.BASE_C end
    end
    for i=1,base-1 do syll[i]._ipos=math.min(IPOS.PRE_C,syll[i]._ipos or IPOS.BASE_C) end
    base_object._ipos=IPOS.BASE_C
    if reph and syll[1] then syll[1]._ipos=IPOS.REPH end

    -- Halants, nuktas, joiners and similar controls move with the preceding item; post-base
    -- consonants own the halant/control sequence before them.
    local last_pos=IPOS.START
    for i,g in ipairs(syll) do
        local cat=P.indic_syllabic(g.cp or 0)
        if is_halant_cat(cat) or cat=="Nukta" or is_joiner_cp(g.cp) or cat=="Register_Shifter" or cat=="Consonant_Medial" then
            g._ipos=last_pos
        elseif (g._ipos or IPOS.BASE_C)~=IPOS.SMVD then last_pos=g._ipos or IPOS.BASE_C end
    end
    local last=base
    for i=base+1,#syll do
        local cat=P.indic_syllabic(syll[i].cp or 0)
        if is_consonant_cat(cat) then
            for j=last+1,i-1 do if (syll[j]._ipos or 0)<IPOS.SMVD then syll[j]._ipos=syll[i]._ipos end end
            last=i
        elseif is_matra_cat(cat) then last=i end
    end
    table.sort(syll,function(a,b) if a._ipos==b._ipos then return a._order<b._order end return (a._ipos or 0)<(b._ipos or 0) end)
    base=nil;for i,g in ipairs(syll) do if g==base_object then base=i;break end end;base=base or #syll

    local function mask_pre(g) return g._force_half or (((g._ipos or IPOS.BASE_C)<IPOS.BASE_C) and not g._no_half) end
    local function mask_post(g) return (g._ipos or IPOS.BASE_C)>IPOS.BASE_C and (g._ipos or IPOS.BASE_C)<IPOS.SMVD end
    local function mask_blwf(g)
        local p=g._ipos or IPOS.BASE_C
        if BLWF_POST_ONLY[script] then return p>IPOS.BASE_C and p<IPOS.SMVD end
        return p~=IPOS.BASE_C and p<IPOS.SMVD
    end

    for i=base+1,#syll-1 do
        if gsub and gsub:would_substitute(tags,"pref",{syll[i].gid,syll[i+1].gid},{language=lang}) then
            syll[i]._pref_candidate=true;syll[i]._pref_original_gid=syll[i].gid
            syll[i+1]._pref_candidate=true;syll[i+1]._pref_original_gid=syll[i+1].gid
            break
        end
    end

    for _,feature in ipairs({"nukt","akhn","rphf","rkrf","pref","blwf","abvf","half","pstf","vatu","cjct"}) do
        if gsub and feature_enabled(options,feature,true) then
            local featopts={language=lang,ppem=ppem}
            if feature=="rphf" then
                if reph then featopts.mask=function(g) return g._ipos==IPOS.REPH end else featopts=nil end
            elseif feature=="half" then featopts.mask=mask_pre
            elseif feature=="blwf" then featopts.mask=mask_blwf
            elseif feature=="abvf" or feature=="pstf" or feature=="pref" then featopts.mask=mask_post end
            if featopts then gsub:apply_feature(tags,feature,syll,featopts) end
        end
    end

    -- A successful pref substitution is a post-base sequence that must move to pre-base
    -- position after basic shaping.
    local pref_index=nil
    for i,g in ipairs(syll) do
        if g._pref_candidate and (g.ligature or (g._pref_original_gid and g.gid~=g._pref_original_gid)) then pref_index=i;break end
    end
    if pref_index then
        local pg=table.remove(syll,pref_index)
        local bi=nil;for i,g in ipairs(syll) do if g==base_object then bi=i;break end end
        table.insert(syll,bi or 1,pg)
    end

    -- Re-find base after substitutions.
    local base_i=nil
    for i,g in ipairs(syll) do if g==base_object then base_i=i;break end end
    if not base_i then for i,g in ipairs(syll) do if (g._ipos or IPOS.BASE_C)>=IPOS.BASE_C then base_i=i;break end end end
    base_i=base_i or #syll

    -- Pull left matras as close to the base as surviving half/halant forms allow.
    local i=1
    while i<=#syll do local g=syll[i]
        if (g._ipos==IPOS.PRE_M) and i<base_i-1 then
            table.remove(syll,i);base_i=base_i-1;table.insert(syll,base_i,g)
        else i=i+1 end
    end

    -- Move a successfully formed reph out of its logical initial position.
    if reph and #syll>1 then
        local first=syll[1]
        local nominal=first and cp_gid(font,first.cp or 0) or nil
        if first and nominal and first.gid~=nominal then
            table.remove(syll,1);if base_i>1 then base_i=base_i-1 end
            local reph_target=base_i+1
            if script=="Bengali" then
                while reph_target<#syll and (syll[reph_target+1]._ipos or 0)<=IPOS.AFTER_SUB do reph_target=reph_target+1 end
            elseif script=="Tamil" or script=="Telugu" or script=="Kannada" then reph_target=#syll+1 end
            table.insert(syll,math.min(#syll+1,reph_target),first)
        end
    end

    apply_feature_list(gsub,tags,syll,{"init","pres","abvs","blws","psts","haln"},lang,ppem,options)
    reset_positioning(font,syll)
    if font._gpos then apply_feature_list(font._gpos,tags,syll,{"dist","kern","abvm","blwm","mark","mkmk"},lang,ppem,options) end
    for _,g in ipairs(syll) do g.advance=g.x_advance or font.default_advance end
    return syll
end

local function shape_indic_segment(font,segment,tags,lang,script,ppem,options)
    indic_decompose(font,segment)
    local ranges=indic_syllables(segment)
    local out={}
    for _,r in ipairs(ranges) do
        local sub={};for i=r.a,r.b do sub[#sub+1]=segment[i] end
        local shaped=shape_indic_syllable(font,sub,tags,lang,script,ppem,options)
        for _,g in ipairs(shaped) do out[#out+1]=g end
    end
    return out
end

local function make_invisible_joiner(font,g)
    local space_gid=cp_gid(font,0x20)
    g.gid=space_gid
    g.x_advance=0;g.y_advance=0;g.x_offset=0;g.y_offset=0;g.advance=0
    return g
end

local function apply_indic(font,glyphs,tags,lang,script,ppem,options)
    -- ZWNJ is a shaping boundary for Indic consonant formation; ZWJ remains in the syllable so
    -- fonts can use it to request a half/explicit conjunct form.
    local out,segment={},{}
    local function flush()
        if #segment>0 then
            local shaped=shape_indic_segment(font,segment,tags,lang,script,ppem,options)
            for _,g in ipairs(shaped) do out[#out+1]=g end
            segment={}
        end
    end
    for _,g in ipairs(glyphs) do
        if g.cp==0x200C then
            flush();out[#out+1]=make_invisible_joiner(font,g)
        else segment[#segment+1]=g end
    end
    flush()
    for _,g in ipairs(out) do if g.cp==0x200D then make_invisible_joiner(font,g) end end
    for i=#glyphs,1,-1 do glyphs[i]=nil end
    for i,g in ipairs(out) do glyphs[i]=g end
end


-- Myanmar and Khmer both require character reordering before their OpenType feature programs
-- can do the rest.
local function split_syllables(glyphs,is_base,is_stacker)
    local out={};local a=1
    if #glyphs==0 then return out end
    for i=2,#glyphs do
        if is_base(glyphs[i]) and not is_stacker(glyphs[i-1]) then
            out[#out+1]={a=a,b=i-1};a=i
        end
    end
    out[#out+1]={a=a,b=#glyphs}
    return out
end

local function copy_range(glyphs,a,b)
    local t={};for i=a,b do t[#t+1]=glyphs[i] end;return t
end

local function replace_buffer(dst,src)
    for i=#dst,1,-1 do dst[i]=nil end
    for i,g in ipairs(src) do dst[i]=g end
end

local MYANMAR_KINZI_START={[0x1004]=true,[0x101B]=true,[0x105A]=true}
local function myanmar_is_stacker(g) return P.indic_syllabic(g.cp or 0)=="Invisible_Stacker" end
local function myanmar_is_base(g)
    local c=P.indic_syllabic(g.cp or 0)
    -- Myanmar medials are classified as consonant-like by the shared Indic property helper, but
    -- they are never syllable bases.
    return c=="Consonant" or c=="Vowel_Independent" or c=="Number" or c=="Consonant_Placeholder"
end
local function myanmar_kind(g)
    local cp=g.cp or 0
    local c=P.indic_syllabic(cp)
    local pos=P.indic_positional(cp)
    if is_variation_selector(cp) then return "VS" end
    if cp==0x1039 then return "H" end
    if cp==0x103A then return "As" end
    if cp==0x103C then return "MR" end
    if cp==0x103B or cp==0x105E or cp==0x105F then return "MY" end
    if cp==0x103D or cp==0x1082 then return "MW" end
    if cp==0x103E or cp==0x1060 then return "MH" end
    if cp==0x1032 or cp==0x1036 then return "A" end
    if cp==0x1037 then return "DB" end
    if c=="Vowel_Dependent" then
        if pos_is_left(pos) then return "VPre" end
        if pos and pos:find("Bottom",1,true) then return "VBlw" end
        if pos and pos:find("Top",1,true) then return "VAbv" end
        return "VPst"
    end
    if c=="Tone_Mark" or c=="Visarga" then return "SM" end
    if myanmar_is_base(g) then return "C" end
    return "O"
end

local function reorder_myanmar_syllable(syll)
    if #syll==0 then return end
    local has_kinzi=#syll>=3 and MYANMAR_KINZI_START[syll[1].cp or 0]
        and (syll[2].cp==0x103A) and (syll[3].cp==0x1039)
    local limit=has_kinzi and 4 or 1
    local base=limit
    if not has_kinzi then base=1 end
    for i=limit,#syll do if myanmar_is_base(syll[i]) then base=i;break end end

    for i,g in ipairs(syll) do g._order=i;g._ipos=IPOS.AFTER_MAIN end
    if has_kinzi then for i=1,math.min(3,#syll) do syll[i]._ipos=IPOS.AFTER_MAIN end end
    for i=limit,base-1 do syll[i]._ipos=IPOS.PRE_C end
    if syll[base] then syll[base]._ipos=IPOS.BASE_C end

    local pos=IPOS.AFTER_MAIN
    for i=base+1,#syll do
        local k=myanmar_kind(syll[i])
        if k=="MR" then syll[i]._ipos=IPOS.PRE_C
        elseif k=="VPre" then syll[i]._ipos=IPOS.PRE_M
        elseif k=="VS" then syll[i]._ipos=(syll[i-1] and syll[i-1]._ipos) or pos
        elseif pos==IPOS.AFTER_MAIN and k=="VBlw" then pos=IPOS.BELOW_C;syll[i]._ipos=pos
        elseif pos==IPOS.BELOW_C and k=="A" then syll[i]._ipos=IPOS.BEFORE_SUB
        elseif pos==IPOS.BELOW_C and k=="VBlw" then syll[i]._ipos=pos
        elseif pos==IPOS.BELOW_C and k~="A" then pos=IPOS.AFTER_SUB;syll[i]._ipos=pos
        else syll[i]._ipos=pos end
    end
    table.sort(syll,function(a,b)
        if a._ipos==b._ipos then return (a._order or 0)<(b._order or 0) end
        return (a._ipos or 0)<(b._ipos or 0)
    end)

    -- HarfBuzz preserves multiple pre-base-vowel groups in logical group order while reversing
    -- the overall PRE_M span.
    local first,last
    for i,g in ipairs(syll) do if g._ipos==IPOS.PRE_M then first=first or i;last=i end end
    if first and last and first<last then
        local seg={};for i=last,first,-1 do seg[#seg+1]=syll[i] end
        for i=first,last do syll[i]=seg[i-first+1] end
        local i=first
        while i<=last do
            local j=i
            while j<=last and myanmar_kind(syll[j])~="VPre" do j=j+1 end
            if j<=last then
                local a,b=i,j
                while a<b do syll[a],syll[b]=syll[b],syll[a];a=a+1;b=b-1 end
                i=j+1
            else break end
        end
    end
end

local function apply_myanmar(font,glyphs,tags,lang,ppem,options)
    ensure_layout(font)
    local gsub=font._gsub
    local ranges=split_syllables(glyphs,myanmar_is_base,myanmar_is_stacker)
    local out={}
    for _,r in ipairs(ranges) do
        local syll=copy_range(glyphs,r.a,r.b)
        apply_feature_list(gsub,tags,syll,{"locl","ccmp"},lang,ppem,options)
        reorder_myanmar_syllable(syll)
        apply_feature_list(gsub,tags,syll,{"rphf","pref","blwf","pstf","pres","abvs","blws","psts","rlig","liga","clig","calt"},lang,ppem,options)
        for _,g in ipairs(syll) do out[#out+1]=g end
    end
    replace_buffer(glyphs,out)
    for _,g in ipairs(glyphs) do if is_joiner_cp(g.cp) then make_invisible_joiner(font,g) end end
    reset_positioning(font,glyphs)
    -- The Myanmar OpenType model expects GDEF mark advances to be zeroed before GPOS.
    if font._gpos and font._gpos.gdef and font._gpos.gdef.glyph_class then
        for _,g in ipairs(glyphs) do
            if font._gpos.gdef.glyph_class(g.gid or 0)==3 then
                g.x_advance=0; g.advance=0
            end
        end
    end
    if font._gpos then apply_feature_list(font._gpos,tags,glyphs,{"kern","dist","mark","mkmk","abvm","blwm"},lang,ppem,options) end
    for _,g in ipairs(glyphs) do g.advance=g.x_advance or font.default_advance end
end

local KHMER_SPLIT={[0x17BE]=true,[0x17BF]=true,[0x17C0]=true,[0x17C4]=true,[0x17C5]=true}
local function khmer_decompose(font,glyphs)
    local i=1
    while i<=#glyphs do
        if KHMER_SPLIT[glyphs[i].cp or 0] then
            local old=glyphs[i]
            table.insert(glyphs,i,clone_for_cp(font,old,0x17C1))
            i=i+2
        else i=i+1 end
    end
end
local function khmer_is_stacker(g) return (g.cp or 0)==0x17D2 end
local function khmer_is_base(g)
    local c=P.indic_syllabic(g.cp or 0)
    return is_consonant_cat(c) or c=="Vowel_Independent" or c=="Consonant_Placeholder" or c=="Number"
end
local function khmer_is_pre_vowel(g)
    return P.indic_syllabic(g.cp or 0)=="Vowel_Dependent" and pos_is_left(P.indic_positional(g.cp or 0))
end

local function reorder_khmer_syllable(syll)
    if #syll<2 then return end
    -- Khmer places coeng sequences before vowels, so a stable visual class sort gives the same
    -- practical order as the reference shaper's repeated move-to-front operations: left vowel,
    local pref={};local pre={};local rest={};local base=syll[1]
    local skip={}
    local coengs=0
    for i=2,#syll-1 do
        if (syll[i].cp or 0)==0x17D2 and not skip[i] then
            coengs=coengs+1
            if coengs<=2 and (syll[i+1].cp or 0)==0x179A then
                syll[i]._khmer_pref=true;syll[i+1]._khmer_pref=true
                pref[#pref+1]=syll[i];pref[#pref+1]=syll[i+1]
                skip[i]=true;skip[i+1]=true
            end
        end
    end
    for i=2,#syll do
        local g=syll[i]
        if not skip[i] then
            if khmer_is_pre_vowel(g) then pre[#pre+1]=g else rest[#rest+1]=g end
        end
    end
    local out={}
    for _,g in ipairs(pre) do out[#out+1]=g end
    for _,g in ipairs(pref) do out[#out+1]=g end
    out[#out+1]=base
    for _,g in ipairs(rest) do out[#out+1]=g end
    if #pref>0 then
        local seen_base=false
        for _,g in ipairs(out) do
            if g==base then seen_base=true
            elseif seen_base then g._khmer_cfar=true end
        end
    end
    replace_buffer(syll,out)
end

local function apply_khmer(font,glyphs,tags,lang,ppem,options)
    ensure_layout(font)
    khmer_decompose(font,glyphs)
    local gsub=font._gsub
    local ranges=split_syllables(glyphs,khmer_is_base,khmer_is_stacker)
    local out={}
    for _,r in ipairs(ranges) do
        local syll=copy_range(glyphs,r.a,r.b)
        reorder_khmer_syllable(syll)
        apply_feature_list(gsub,tags,syll,{"locl","ccmp","pref","blwf","abvf","pstf"},lang,ppem,options)
        if gsub and feature_enabled(options,"cfar",true) then gsub:apply_feature(tags,"cfar",syll,{language=lang,ppem=ppem,mask=function(g) return g._khmer_cfar end}) end
        apply_feature_list(gsub,tags,syll,{"pres","abvs","blws","psts","rlig","clig","calt"},lang,ppem,options)
        for _,g in ipairs(syll) do out[#out+1]=g end
    end
    replace_buffer(glyphs,out)
    for _,g in ipairs(glyphs) do if is_joiner_cp(g.cp) then make_invisible_joiner(font,g) end end
    reset_positioning(font,glyphs)
    if font._gpos then apply_feature_list(font._gpos,tags,glyphs,{"dist","kern","blwm","abvm","mark","mkmk"},lang,ppem,options) end
    for _,g in ipairs(glyphs) do g.advance=g.x_advance or font.default_advance end
end

local function apply_generic(font,glyphs,script_tags,lang,ppem,options)
    ensure_layout(font)
    local gsub=font._gsub
    if gsub then
        local standard={ccmp=true,locl=true,rlig=true,liga=true,clig=true,calt=true}
        for _,tag in ipairs({"ccmp","locl","rlig","liga","clig","calt"}) do
            if feature_enabled(options,tag,true) then gsub:apply_feature(script_tags,tag,glyphs,{language=lang,ppem=ppem}) end
        end
    end
    apply_positioning(font,glyphs,script_tags,lang,ppem,options)
end

local function make_run_glyphs(font,analysis,run)
    local glyphs={};local cluster
    for i=run.first,run.last do
        local it=analysis.items[i]
        if not it.bidi_control then
            if is_variation_selector(it.cp) then
                -- A Unicode variation selector modifies the immediately preceding scalar; it
                -- never becomes a visible glyph of its own.
                local prev=glyphs[#glyphs]
                if prev and prev.source_index==i-1 and font._lookup_variant_gid then
                    local gid,supported,kind=font._lookup_variant_gid(prev.cp,it.cp)
                    if supported then
                        prev.gid=gid or 0;prev.variation_selector=it.cp;prev.variation_kind=kind
                    end
                end
            else
                if not U.is_combining(it.cp) or not cluster then cluster=i end
                glyphs[#glyphs+1]={gid=cp_gid(font,it.cp),cp=it.cp,cluster=cluster,source_index=i,level=it.level or 0,direction=run.direction,script=run.script,_font=font}
            end
        end
    end
    return glyphs
end

local function rtl_visualize(glyphs)
    local groups={};local current;local pen=0
    for _,g in ipairs(glyphs) do
        if not current or current.cluster~=g.cluster then current={cluster=g.cluster,items={},start=pen};groups[#groups+1]=current end
        g._cluster_abs_x=(pen-current.start)+(g.x_offset or 0)
        g._cluster_abs_y=g.y_offset or 0
        current.items[#current.items+1]=g
        pen=pen+(g.x_advance or g.advance or 0)
    end
    local out={}
    for gi=#groups,1,-1 do
        local gp=0;local items=groups[gi].items;local visual={}
        -- In RTL clusters marks are emitted before the base/ligature while keeping their
        -- logical order, matching OpenType shaping engines.
        for _,g in ipairs(items) do if g.cp and ((P.is_mark and P.is_mark(g.cp)) or U.is_combining(g.cp)) then visual[#visual+1]=g end end
        for j=#items,1,-1 do local g=items[j];if not (g.cp and ((P.is_mark and P.is_mark(g.cp)) or U.is_combining(g.cp))) then visual[#visual+1]=g end end
        for _,g in ipairs(visual) do
            g.x_offset=(g._cluster_abs_x or 0)-gp;g.y_offset=g._cluster_abs_y or 0
            g._cluster_abs_x=nil;g._cluster_abs_y=nil
            out[#out+1]=g;gp=gp+(g.x_advance or g.advance or 0)
        end
    end
    return out
end

local function vertical_writing_mode(options)
    options=options or {}
    local wm=options.writing_mode or options.writing_direction
    if options.vertical==true and not wm then wm="vertical-rl" end
    if options.direction=="ttb" and not wm then wm="vertical-rl" end
    if wm=="vertical" then wm="vertical-rl" end
    if wm=="vertical-rl" or wm=="vertical-lr" then return wm end
    return nil
end

local function apply_vertical_layout(font,glyphs,script_tags,lang,ppem,options)
    ensure_layout(font)
    local gsub=font._gsub
    if gsub then
        local preferred=options and options.vertical_feature
        if preferred=="vert" or preferred=="vrt2" then
            if feature_enabled(options,preferred,true) then gsub:apply_feature(script_tags,preferred,glyphs,{language=lang,ppem=ppem}) end
        else
            -- Fontlib currently relies on the font for pre-rotated sideways forms, so prefer
            -- vrt2.
            local fmap=gsub:script_features(script_tags,lang)
            if fmap and fmap.vrt2 then if feature_enabled(options,"vrt2",true) then gsub:apply_feature(script_tags,"vrt2",glyphs,{language=lang,ppem=ppem}) end
            elseif feature_enabled(options,"vert",true) then gsub:apply_feature(script_tags,"vert",glyphs,{language=lang,ppem=ppem}) end
        end
    end

    local gdef=font._gpos and font._gpos.gdef
    for _,g in ipairs(glyphs) do
        local vm=font._vertical_metrics_for_gid and font:_vertical_metrics_for_gid(g.gid or 0) or nil
        local adv=(vm and vm.advance) or font.units_per_em
        g.x_advance=0;g.y_advance=-adv;g.x_offset=0;g.y_offset=0;g.advance=adv
        g.vertical_advance=adv;g.vertical_origin_x=vm and vm.origin_x or ((font._advance_for_gid and font:_advance_for_gid(g.gid or 0)) or font.default_advance)/2
        g.vertical_origin_y=vm and vm.origin_y or font.ascent;g.vertical_metrics_synthesized=vm and vm.synthesized or true
        if g.cp==0x200C or g.cp==0x200D then g.x_advance=0;g.y_advance=0;g.advance=0;g.vertical_advance=0 end
        if gdef and gdef.glyph_class and gdef.glyph_class(g.gid or 0)==3 then
            -- Nonspacing marks attach to their base and must not consume a full vertical cell
            -- simply because vmtx supplies a default metric.
            g.x_advance=0;g.y_advance=0;g.advance=0;g.vertical_advance=0
        end
    end
    if font._gpos then
        -- vkrn is the vertical counterpart to kern.
        apply_feature_list(font._gpos,script_tags,glyphs,{"vkrn","dist","curs","mark","mkmk"},lang,ppem,options)
    end
    for _,g in ipairs(glyphs) do
        g.vertical_advance=-(g.y_advance or 0)
        g.advance=g.vertical_advance
    end
end

local function rtl_visualize_vertical(glyphs)
    local groups={};local current
    for _,g in ipairs(glyphs) do
        if not current or current.cluster~=g.cluster then current={cluster=g.cluster,items={}};groups[#groups+1]=current end
        current.items[#current.items+1]=g
    end
    local out={}
    for gi=#groups,1,-1 do for _,g in ipairs(groups[gi].items) do out[#out+1]=g end end
    return out
end

local function shape_run(font,analysis,run,options)
    local glyphs=make_run_glyphs(font,analysis,run)
    local script_tags=S.script_tags(run.script);local ppem=tonumber(options.ppem)
    ensure_layout(font)
    if font._gsub and feature_enabled(options,"rvrn",true) then font._gsub:apply_feature(script_tags,"rvrn",glyphs,{language=options.language,ppem=ppem}) end
    if run.script=="Arabic" then apply_arabic(font,glyphs,options.language,ppem,options)
    elseif INDIC_SCRIPTS[run.script] then apply_indic(font,glyphs,script_tags,options.language,run.script,ppem,options)
    elseif run.script=="Myanmar" then apply_myanmar(font,glyphs,script_tags,options.language,ppem,options)
    elseif run.script=="Khmer" then apply_khmer(font,glyphs,script_tags,options.language,ppem,options)
    else apply_generic(font,glyphs,script_tags,options.language,ppem,options) end
    -- Explicit non-default feature tags (ss01, dlig, salt, etc.) are applied after the script's
    -- required shaping sequence.
    apply_user_features(font._gsub,script_tags,glyphs,options,options.language,ppem,STANDARD_FEATURES)
    apply_user_features(font._gpos,script_tags,glyphs,options,options.language,ppem,STANDARD_FEATURES)
    local vertical=vertical_writing_mode(options)
    if vertical then apply_vertical_layout(font,glyphs,script_tags,options.language,ppem,options) end
    if run.direction=="rtl" then glyphs=vertical and rtl_visualize_vertical(glyphs) or rtl_visualize(glyphs) end
    return glyphs
end

local function shape_run_with_fallback(primary,analysis,run,options)
    local spans=fallback_spans(primary,analysis,run,options)
    if #spans==1 and spans[1].font==primary then return shape_run(primary,analysis,run,options) end
    local out={}
    local first,last,step=1,#spans,1
    if run.direction=="rtl" then first,last,step=#spans,1,-1 end
    local i=first
    while (step>0 and i<=last) or (step<0 and i>=last) do
        local span=spans[i]
        local subrun={first=span.first,last=span.last,script=run.script,direction=run.direction}
        local glyphs=shape_run(span.font,analysis,subrun,options)
        for _,g in ipairs(glyphs) do out[#out+1]=g end
        i=i+step
    end
    return out
end

local function visual_rank_map(paragraph)
    local map={};for rank,index in ipairs(paragraph.visual_order or {}) do map[index]=rank end;return map
end

function S.shape(text,font_ref,options)
    options=options or {};local font=assert(F.get(font_ref),"unknown Fontlib font "..tostring(font_ref))
    local writing_mode=vertical_writing_mode(options)
    local bidi_direction=options.base_direction or ((options.direction=="ltr" or options.direction=="rtl" or options.direction=="auto") and options.direction) or "auto"
    local analysis,err=U.analyze(tostring(text or ""),{base_direction=bidi_direction});if not analysis then return nil,err end
    local result={font=font,text=tostring(text or ""),analysis=analysis,glyphs={},paragraphs={},positioned=(font._gpos~=nil or writing_mode~=nil),vertical=writing_mode~=nil,writing_mode=writing_mode}
    for _,para in ipairs(analysis.paragraphs) do
        local rank=visual_rank_map(para);local shaped_runs={}
        for _,run in ipairs(analysis.runs) do
            if run.first>=para.first and run.first<=para.content_last then
                local gs=shape_run_with_fallback(font,analysis,run,options);local r=math.huge
                for i=run.first,run.last do if rank[i] and rank[i]<r then r=rank[i] end end
                shaped_runs[#shaped_runs+1]={rank=r,glyphs=gs,run=run}
            end
        end
        table.sort(shaped_runs,function(a,b)return a.rank<b.rank end)
        local pg={first=#result.glyphs+1,base_direction=para.base_direction,base_level=para.base_level}
        for _,sr in ipairs(shaped_runs) do for _,g in ipairs(sr.glyphs) do result.glyphs[#result.glyphs+1]=g end end
        pg.last=#result.glyphs;result.paragraphs[#result.paragraphs+1]=pg
        if para.last>para.content_last then result.glyphs[#result.glyphs+1]={newline=true,cp=10,advance=0,x_advance=0,y_advance=0,x_offset=0,y_offset=0,cluster=para.last} end
    end
    return result
end

function F.shape(text,font_ref,options) return S.shape(text,font_ref,options) end
function F._methods:shape(text,options) return S.shape(text,self,options) end

return S
