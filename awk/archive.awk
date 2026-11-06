# SPDX-License-Identifier: GPL-3.0-only
# GNU tar --numeric-owner --full-time --quoting-style=escape -tvf.
BEGIN { OFS="\t"; bad=0 }
function enc(s){gsub(/%/,"%25",s);gsub(/\t/,"%09",s);return length(s)?s:"%00"}
function fail(s){print "archive: " s > "/dev/stderr";bad=1}
{
    type=substr($1,1,1); line=$0
    for(i=1;i<=5;i++)sub(/^[^ \t]+[ \t]+/,"",line)
    original=line; target=""
    if(type=="l") {pos=index(line," -> ");if(!pos){fail("invalid symlink");next}target=substr(line,pos+4);line=substr(line,1,pos-1)}
    if(type=="h") {pos=index(line," link to ");if(!pos){fail("invalid hardlink");next}target="/" substr(line,pos+9);line=substr(line,1,pos-1)}
    if(line ~ /\\/ || target ~ /\\/){fail("escaped archive path is not supported: " line);next}
    if(line ~ /^\// || line ~ /(^|\/)\.\.(\/|$)/){fail("archive path escapes its root: " line);next}
    if(type!="-" && type!="d" && type!="l" && type!="h"){fail("unsupported archive entry type: " line);next}
    if(type=="-")print line > regular
    sub(/^\.\//,"",line);sub(/\/$/,"",line)
    if(!length(line)||line==".")next
    if((line in seen) && (type!="d" || seen[line]!="d")){fail("duplicate archive path: " line);next}
    seen[line]=type
    print (type=="-"?"F":(type=="d"?"D":(type=="h"?"H":"L"))),enc("/" line),enc(target),enc($1)
}
END { if(bad)exit 1 }
