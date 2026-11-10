# SPDX-License-Identifier: GPL-3.0-only
# Deliberately restricted shell lexer: no eval, expansion, or script execution.
BEGIN { OFS="\t"; unknown=0 }
function enc(s){gsub(/%/,"%25",s);gsub(/\t/,"%09",s);return length(s)?s:"%00"}
function tokens(s,   i,c,q,word,n,active){
    for(i in t)delete t[i]
    n=0;q="";word="";active=0
    for(i=1;i<=length(s);i++){
        c=substr(s,i,1)
        if(q=="'"){if(c=="'")q="";else word=word c;active=1;continue}
        if(c=="\\"){i++;word=word substr(s,i,1);active=1;continue}
        if(c=="$"||c=="`"||c=="*"||c=="?"||c=="<"||c==">")return -1
        if(q=="\""){if(c=="\"")q="";else word=word c;active=1;continue}
        if(c=="'"||c=="\""){q=c;active=1;continue}
        if(c ~ /[ \t]/){if(active){t[++n]=word;word="";active=0}continue}
        if(c=="("||c==")"||c==";"){if(active){t[++n]=word;word="";active=0}t[++n]=c;continue}
        word=word c;active=1
    }
    if(length(q))return -1
    if(active)t[++n]=word
    return n
}
{
    s=$0;sub(/^[ \t]+/,"",s);sub(/[ \t]+$/,"",s)
    if(!length(s)||s ~ /^#/)next
    if(seen_exit){unknown=1;next}
    n=tokens(s)
    if(n==8&&t[1]=="("&&t[2]=="cd"&&t[4]==";"&&t[5]=="rm"&&t[6]=="-rf"&&t[8]==")"){
        if(t[3] ~ /^\// || t[3] ~ /(^|\/)\.\.(\/|$)/ || t[7] ~ /\// || t[7]==".." || t[7]=="."){unknown=1;next}
        removes["/" t[3] "/" t[7]]=1;next
    }
    if(n==9&&t[1]=="("&&t[2]=="cd"&&t[4]==";"&&t[5]=="ln"&&t[6]=="-sf"&&t[9]==")"){
        if(t[3] ~ /^\// || t[3] ~ /(^|\/)\.\.(\/|$)/ || t[8] ~ /\// || t[8]==".." || t[8]=="."){unknown=1;next}
        links["/" t[3] "/" t[8]]=1
        print "L",enc("/" t[3] "/" t[8]),enc(t[7]),enc("doinst")
        next
    }
    # Harmless exit statements and fixed cache updates are explicit.  These
    # commands are regenerated after an installation group is complete.
    if(s=="exit 0"){seen_exit=1;next}
    if(s=="/sbin/ldconfig"||s=="ldconfig")next
    if(s=="if [ -x sbin/ldconfig ]; then"||s=="if [ -x /sbin/ldconfig ]; then")next
    if(s=="chroot . /sbin/ldconfig")next
    if(s=="if [ -x usr/bin/fc-cache ]; then")next
    if(s=="chroot . /usr/bin/fc-cache -f"||s=="chroot . /usr/bin/fc-cache -r")next
    if(s=="if [ -x usr/bin/update-gdk-pixbuf-loaders ]; then")next
    if(s=="chroot . /usr/bin/update-gdk-pixbuf-loaders")next
    if(s=="if [ -x usr/bin/gdk-pixbuf-query-loaders ]; then")next
    if(s=="chroot . /usr/bin/gdk-pixbuf-query-loaders --update-cache")next
    if(s=="fi")next
    unknown=1
}
END { for(p in removes)if(!(p in links))unknown=1; print "SCRIPT",(unknown?"unconfirmed":"modeled"),"%00","%00" }
