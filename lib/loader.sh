# SPDX-License-Identifier: GPL-3.0-only
sr_lookup() {
    local requested=$1 installed_only=${2:-0} current prefix rest part kind target loops=0 source owner
    sr_norm "$requested"; current=$REPLY
    while (( loops < 64 )); do
        ((loops+=1)); prefix=; rest=${current#/}; target=
        while [[ -n $rest ]]; do
            part=${rest%%/*}; if [[ $rest == */* ]]; then rest=${rest#*/}; else rest=; fi
            prefix+=/$part; kind=; source=; owner=
            if (( ! installed_only )) && [[ ${OV_TYPE[$prefix]+yes} ]]; then
                kind=${OV_TYPE[$prefix]}; source=${OV_SOURCE[$prefix]}; owner=${OV_OWNER[$prefix]}
                [[ $kind != L ]] || target=$source
            else
                sr_guard "$prefix"
                source=${SR_ROOT%/}$prefix
                if [[ -L $source ]]; then kind=L; target=$(readlink -- "$source") || return 1
                elif [[ -f $source ]]; then kind=F
                elif [[ -d $source ]]; then kind=D
                else return 1; fi
                owner=${OWN[$prefix]:-local}
            fi
            if [[ $kind == L ]]; then
                if [[ $target == /* ]]; then current=$target
                else current=${prefix%/*}/$target; fi
                [[ -z $rest ]] || current+=/$rest
                sr_norm "$current"; current=$REPLY
                break
            fi
            if [[ -n $rest && $kind != D ]]; then return 1; fi
            if [[ -z $rest ]]; then
                V_TYPE=$kind; V_FILE=$source; V_PATH=$prefix; V_OWNER=$owner; return 0
            fi
        done
        [[ -n $target ]] || break
    done
    return 1
}
sr_expand_paths() {
    local raw=$1 consumer=$2 part origin=${2%/*} result= token
    while [[ -n $raw ]]; do
        if [[ $raw == *:* ]]; then part=${raw%%:*}; raw=${raw#*:}; else part=$raw; raw=; fi
        [[ -n $part ]] || return 1
        part=${part//\$\{ORIGIN\}/$origin}; part=${part//\$ORIGIN/$origin}
        part=${part//\$\{LIB\}/lib64}; part=${part//\$LIB/lib64}
        part=${part//\$\{PLATFORM\}/x86_64}; part=${part//\$PLATFORM/x86_64}
        [[ $part == /* && $part != *'$'* ]] || return 1
        sr_norm "$part"; result+="$REPLY"$'\n'
    done
    REPLY=$result
}
sr_dependency() {
    local path=$1 consumer=$2 needed=$3 inherited=$4 dir candidate source eid line raw
    local -a paths=()
    DEP_REASON=; DEP_STATUS=missing; DEP_PATH=; DEP_FILE=; DEP_OWNER=; DEP_EID=
    if [[ $needed == */* ]]; then
        [[ $needed == /* ]] || { DEP_STATUS=unconfirmed; DEP_REASON='Relative DT_NEEDED requires an execution directory.'; return 1; }
        paths+=("$needed")
    else
        if [[ -z ${M_RUNPATH[$consumer]:-} ]]; then
            if [[ -n ${M_RPATH[$consumer]:-} ]]; then
                sr_expand_paths "${M_RPATH[$consumer]}" "$path" || { DEP_STATUS=unconfirmed; DEP_REASON='Unsupported RPATH.'; return 1; }
                while IFS= read -r dir; do [[ -z $dir ]] || paths+=("$dir/$needed"); done <<< "$REPLY"
            fi
            while IFS= read -r dir; do [[ -z $dir ]] || paths+=("$dir/$needed"); done <<< "$inherited"
        fi
        if [[ -n ${SR_LIBRARY_PATH:-} ]]; then
            sr_expand_paths "$SR_LIBRARY_PATH" "$path" || { DEP_STATUS=unconfirmed; DEP_REASON='Unsupported library-path profile.'; return 1; }
            while IFS= read -r dir; do [[ -z $dir ]] || paths+=("$dir/$needed"); done <<< "$REPLY"
        fi
        if [[ -n ${M_RUNPATH[$consumer]:-} ]]; then
            sr_expand_paths "${M_RUNPATH[$consumer]}" "$path" || { DEP_STATUS=unconfirmed; DEP_REASON='Unsupported RUNPATH.'; return 1; }
            while IFS= read -r dir; do [[ -z $dir ]] || paths+=("$dir/$needed"); done <<< "$REPLY"
        fi
        while IFS=$'\t' read -r raw candidate; do
            [[ $raw == "$needed" ]] || continue
            if [[ $candidate == */glibc-hwcaps/* ]]; then DEP_STATUS=unconfirmed; DEP_REASON='Hardware-capability selection is not modeled.'; return 1; fi
            if [[ ${M_FLAGS[$consumer]:-} == *NODEFLIB* && ( $candidate == /lib64/* || $candidate == /usr/lib64/* ) ]]; then continue; fi
            paths+=("$candidate")
        done < "$SR_WORK/ldcache"
        # Planned additions to configured cache paths require ldconfig at apply.
        for dir in "${LD_PATHS[@]}"; do
            candidate=$dir/$needed
            [[ ${OV_TYPE[$candidate]+yes} ]] && paths+=("$candidate")
        done
        if [[ ${M_FLAGS[$consumer]:-} != *NODEFLIB* ]]; then paths+=("/lib64/$needed" "/usr/lib64/$needed"); fi
    fi
    for candidate in "${paths[@]}"; do
        sr_lookup "$candidate" || continue
        [[ $V_TYPE == F ]] || continue
        source=$V_FILE
        if ! sr_elf "$source"; then DEP_STATUS=incompatible; DEP_REASON="Not a readable ELF object: $candidate"; return 1; fi
        eid=$E_ID
        if [[ ${M_CLASS[$consumer]} != "${M_CLASS[$eid]}" || ${M_MACHINE[$consumer]} != "${M_MACHINE[$eid]}" || ${M_ENDIAN[$consumer]} != "${M_ENDIAN[$eid]}" ]]; then
            DEP_REASON="Wrong ELF architecture at $candidate"; continue
        fi
        if ! sr_compatible "$consumer" "$needed" "$eid"; then
            DEP_STATUS=incompatible; DEP_REASON="$candidate: $COMPAT_REASON; the installed provider is preserved."; return 1
        fi
        DEP_STATUS=resolved; DEP_PATH=$V_PATH; DEP_FILE=$source; DEP_OWNER=$V_OWNER; DEP_EID=$eid
        return 0
    done
    [[ -n $DEP_REASON ]] || DEP_REASON="No reachable provider for $needed"
    return 1
}
