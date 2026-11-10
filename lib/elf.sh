# SPDX-License-Identifier: GPL-3.0-only
sr_elf() {
    local physical=$1 id dest tmp line key magic
    [[ -f $physical ]] || return 1
    if [[ ${ELF_ID[$physical]+yes} ]]; then
        id=${ELF_ID[$physical]}; E_ID=$id
        [[ ${M_TYPE[$id]:-} == EXEC || ${M_TYPE[$id]:-} == DYN ]]
        return
    fi
    IFS= read -r -N 4 magic < "$physical" || :
    [[ $magic == $'\177ELF' ]] || return 1
    sr_hash "$physical" || return; id=$REPLY; ELF_ID["$physical"]=$id
    E_ID=$id
    if [[ ${M_LOADED[$id]+yes} ]]; then [[ ${M_TYPE[$id]:-} == EXEC || ${M_TYPE[$id]:-} == DYN ]]; return; fi
    dest=$SR_CACHE/elf/$SR_ANALYZER/$id.tsv
    if [[ ! -s $dest ]]; then
        tmp=$(mktemp "$SR_WORK/elf.XXXXXXXX") || return 1
        if ! readelf -W -h -l -d --version-info --dyn-syms -- "$physical" > "$tmp.raw" 2> "$tmp.err"; then
            sr_log "Could not read ELF object: $physical"; return 1
        fi
        awk -f "$SR_LIBDIR/../awk/elf.awk" "$tmp.raw" > "$tmp" || return 1
        [[ -s $tmp ]] || return 1
        mv -- "$tmp" "$dest" || return 1
    fi
    while IFS= read -r line; do
        sr_fields "$line"
        case ${F[0]} in
            CLASS) M_CLASS["$id"]=${F[1]};; MACHINE) M_MACHINE["$id"]=${F[1]};;
            ENDIAN) M_ENDIAN["$id"]=${F[1]};; TYPE) M_TYPE["$id"]=${F[1]};;
            INTERP) M_INTERP["$id"]=${F[1]};; SONAME) M_SONAME["$id"]=${F[1]};;
            NEEDED) M_NEEDED["$id"]+="${F[1]}"$'\n';;
            RPATH) M_RPATH["$id"]=${F[1]};; RUNPATH) M_RUNPATH["$id"]=${F[1]};;
            VNEED) key=$id'|'${F[1]}; M_VNEED["$key"]+="${F[2]}"$'\n';;
            SREQ) key=$id'|'${F[1]}; M_SREQ["$key"]+="${F[2]}"$'\n';;
            SDEF) M_SDEF["$id|${F[1]}"]=1;; VDEF) M_VDEF["$id|${F[1]}"]=1;;
            FLAG) M_FLAGS["$id"]+="${F[1]} ";;
        esac
    done < "$dest"
    M_LOADED["$id"]=1
    [[ ${M_TYPE[$id]:-} == EXEC || ${M_TYPE[$id]:-} == DYN ]]
}
sr_compatible() {
    local consumer=$1 needed=$2 provider=$3 value
    COMPAT_REASON=
    [[ ${M_CLASS[$consumer]} == "${M_CLASS[$provider]}" &&
       ${M_MACHINE[$consumer]} == "${M_MACHINE[$provider]}" &&
       ${M_ENDIAN[$consumer]} == "${M_ENDIAN[$provider]}" ]] || {
        COMPAT_REASON='incompatible ELF class, machine or endianness'; return 1;
    }
    while IFS= read -r value; do
        [[ -n $value ]] || continue
        [[ ${M_VDEF[$provider'|'$value]+yes} ]] || {
            COMPAT_REASON="missing symbol version: $value"; return 1;
        }
    done <<< "${M_VNEED[$consumer'|'$needed]:-}"
    while IFS= read -r value; do
        [[ -n $value ]] || continue
        [[ ${M_SDEF[$provider'|'$value]+yes} ]] || {
            COMPAT_REASON="missing versioned symbol: $value"; return 1;
        }
    done <<< "${M_SREQ[$consumer'|'$needed]:-}"
}
