# SPDX-License-Identifier: GPL-3.0-only
# Parse one readelf -W -h -l -d --version-info --dyn-syms invocation.
BEGIN { OFS="\t"; mode="" }
function enc(s) { gsub(/%/,"%25",s); gsub(/\t/,"%09",s); gsub(/\r/,"%0D",s); return length(s)?s:"%00" }
function emit(k,a,b,c) { print k,enc(a),enc(b),enc(c) }
function after(s,key) { sub("^.*" key "[ \t]*", "",s); sub(/[ \t]+$/, "",s); return s }
function bracket(s) { sub(/^[^[]*\[/,"",s); sub(/\].*$/,"",s); return s }
/^[ \t]*Class:/ { emit("CLASS",after($0,"Class:")); next }
/^[ \t]*Data:/ { emit("ENDIAN",after($0,"Data:")); next }
/^[ \t]*Machine:/ { emit("MACHINE",after($0,"Machine:")); next }
/^[ \t]*Type:/ { emit("TYPE",$2); next }
/Requesting program interpreter:/ { s=$0; sub(/^.*interpreter: /,"",s); sub(/\].*$/,"",s); emit("INTERP",s); next }
/\(NEEDED\)/ { emit("NEEDED",bracket($0)); next }
/\(SONAME\)/ { emit("SONAME",bracket($0)); next }
/\(RPATH\)/ { emit("RPATH",bracket($0)); next }
/\(RUNPATH\)/ { emit("RUNPATH",bracket($0)); next }
/\(FLAGS_1\)/ { if ($0 ~ /NODEFLIB/) emit("FLAG","NODEFLIB"); if ($0 ~ /ORIGIN/) emit("FLAG","ORIGIN"); next }
/\((AUDIT|DEPAUDIT|FILTER|AUXILIARY)\)/ { emit("FLAG","UNMODELED_DYNAMIC_TAG"); next }
/^Symbol table .*\.dynsym/ { mode="symbols"; next }
/^Version needs section/ { mode="needs"; next }
/^Version definition section/ { mode="definitions"; next }
/^Version symbols section/ { mode="other"; next }
mode=="symbols" && $1 ~ /^[0-9]+:$/ && NF>=8 {
    name=$8
    if ($7=="UND") {
        if ($5!="WEAK" && index(name,"@")) {
            idx=$NF; gsub(/[()]/,"",idx)
            req[++nreq]=name; reqidx[nreq]=idx
        }
    } else if (($5=="GLOBAL" || $5=="WEAK" || $5=="UNIQUE") && ($6=="DEFAULT" || $6=="PROTECTED")) {
        defaultversion=index(name,"@@")
        gsub(/@@/,"@",name); emit("SDEF",name)
        if(defaultversion) {sub(/@.*/,"",name);emit("SDEF",name)}
    }
    next
}
mode=="needs" && /File:/ { for(i=1;i<=NF;i++) if($i=="File:") neededfile=$(i+1) }
mode=="needs" && /Name:/ {
    ver="";idx="";weak=0
    for(i=1;i<=NF;i++) {
        if($i=="Name:")ver=$(i+1)
        if($i=="Version:")idx=$(i+1)
        if($i=="Flags:" && $(i+1) ~ /WEAK/)weak=1
    }
    if(length(ver)&&length(neededfile)) {
        vfile[idx]=neededfile
        if(!weak)emit("VNEED",neededfile,ver)
    }
}
mode=="definitions" && /Name:/ { for(i=1;i<=NF;i++)if($i=="Name:")emit("VDEF",$(i+1)) }
END { for(i=1;i<=nreq;i++) if(reqidx[i] in vfile)emit("SREQ",vfile[reqidx[i]],req[i]) }
