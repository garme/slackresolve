# SPDX-License-Identifier: GPL-3.0-only
sr_issue() {
    sr_record ISSUE "$1" "$2" "$3" "$4" >> "$SR_WORK/issues"
    # A conservative overlay issue must not prevent the solver from closing
    # ordinary ELF dependencies.  Keep the first issue for reporting, but let
    # the first missing dependency take precedence as the next search target.
    if [[ -z ${FIRST_CODE:-} || ( $FIRST_CODE != missing && $1 == missing ) ]]; then
        FIRST_CODE=$1; FIRST_PATH=$2; FIRST_NEED=$3; FIRST_REASON=$4
    fi
}
sr_collect_system_roots() {
    AUDIT_ROOTS=()
    local path physical
    while IFS= read -r path; do
        physical=${SR_ROOT%/}$path
        [[ -f $physical ]] || continue
        sr_elf "$physical" || continue
        [[ -n ${M_NEEDED[$E_ID]:-} || -n ${M_INTERP[$E_ID]:-} ]] || continue
        AUDIT_ROOTS+=("$path")
    done < <(printf '%s\n' "${!OWN[@]}" | sort -u)
}
sr_package_actions() {
    local id line kind path owner base previous matched
    for id in "${SELECTED[@]}"; do
        PK_PREVIOUS["$id"]=; PK_ACTION["$id"]=install
        if [[ ${INST_FULL[${PK_FULL[$id]}]+yes} ]]; then
            PK_ACTION["$id"]=keep
            continue
        fi
        base=${PK_BASE[$id]}; previous=; matched=0
        while IFS= read -r line; do
            sr_fields "$line"; kind=${F[0]}; path=${F[1]}
            [[ $kind == F || $kind == L ]] || continue
            owner=${OWN[$path]:-}; [[ -n $owner ]] || continue
            sr_package_name "$owner" || continue
            [[ $P_BASE == "$base" ]] || continue
            if [[ -z $previous ]]; then previous=$owner
            elif [[ $previous != "$owner" ]]; then matched=2; break
            fi
            matched=1
        done < "${PK_DIR[$id]}/files"
        if (( matched == 2 )); then
            sr_issue conflict '' "${PK_FULL[$id]}" 'Several installed versions own paths replaced by this package.'
        elif (( matched == 1 )); then
            PK_ACTION["$id"]=upgrade; PK_PREVIOUS["$id"]=$previous
            SR_AUDIT_SYSTEM=1
        fi
    done
}
sr_overlay() {
    OV_TYPE=(); OV_SOURCE=(); OV_OWNER=(); SELECTED_SET=()
    local id line kind path target mode source physical hash existing same installed
    sr_package_actions
    for id in "${SELECTED[@]}"; do
        SELECTED_SET["$id"]=1
        installed=${INST_BASE[${PK_BASE[$id]}]:-}
        if [[ ${PK_SCRIPT[$id]} == unconfirmed ]]; then
            sr_issue unconfirmed /install/doinst.sh "${PK_FULL[$id]}" 'The installation script contains effects outside the supported declarative subset.'
        fi
        while IFS= read -r line; do
            sr_fields "$line"; kind=${F[0]}; path=${F[1]}; target=${F[2]}; mode=${F[3]}
            [[ $kind == F || $kind == L || $kind == D ]] || continue
            [[ $path != /install && $path != /install/* ]] || continue
            [[ $path == /* && $path != *'/../'* && $path != *'/./'* && $path != *//* ]] || {
                sr_issue unconfirmed "$path" "${PK_FULL[$id]}" 'Archive path is not canonical.'; continue;
            }
            if [[ $kind == F && $mode == *[sS]* ]]; then sr_issue unconfirmed "$path" "${PK_FULL[$id]}" 'Set-ID execution requires a separate loader profile.'; fi
            if [[ $kind == L ]]; then source=$target; else source=${PK_DIR[$id]}/root$path; fi
            if [[ ${OV_TYPE[$path]+yes} ]]; then
                if [[ $kind == D && ${OV_TYPE[$path]} == D ]]; then continue; fi
                same=0
                if [[ $kind == F && ${OV_TYPE[$path]} == F ]]; then cmp -s -- "$source" "${OV_SOURCE[$path]}" && same=1
                elif [[ $kind == L && ${OV_TYPE[$path]} == L && $source == "${OV_SOURCE[$path]}" ]]; then same=1; fi
                if (( ! same )); then sr_issue collision "$path" "${PK_FULL[$id]}" 'Selected packages would overwrite different files or links.'; fi
                continue
            fi
            if sr_lookup "$path" 1; then
                same=0
                if [[ $kind == D && $V_TYPE == D ]]; then same=1
                elif [[ $kind == F && $V_TYPE == F ]] && cmp -s -- "$source" "$V_FILE"; then same=1
                elif [[ $kind == L && -L ${SR_ROOT%/}$path && $(readlink -- "${SR_ROOT%/}$path") == "$target" ]]; then same=1; fi
                if [[ ${PK_ACTION[$id]} == upgrade && $V_OWNER == "${PK_PREVIOUS[$id]}" ]]; then
                    sr_guard "$path"
                elif (( ! same )); then
                    sr_issue preserve "$path" "${PK_FULL[$id]}" "Existing file is preserved (owner: ${OWN[$path]:-unmanaged}); parallel installation is not safe."
                fi
            else
                sr_guard "$path"
                if [[ -n $installed && $installed == "${PK_FULL[$id]}" && $kind != D ]]; then
                    sr_issue stale "$path" "$installed" 'An installed package record exists but its payload is missing or incomplete.'
                fi
                if [[ -e ${SR_ROOT%/}$path || -L ${SR_ROOT%/}$path ]]; then
                    sr_issue collision "$path" "${PK_FULL[$id]}" 'Existing path could not be modeled.'
                fi
            fi
            OV_TYPE["$path"]=$kind; OV_SOURCE["$path"]=$source; OV_OWNER["$path"]=$id
        done < "${PK_DIR[$id]}/files"
    done
    # Do not authorize an archive that writes through one of its own symlinks.
    for path in "${!OV_TYPE[@]}"; do
        local ancestor=${path%/*}
        if [[ ${OV_TYPE[$path]} == L && -n $ancestor && $ancestor != / ]]; then
            if ! sr_lookup "$ancestor" || [[ $V_TYPE != D ]]; then
                sr_issue unconfirmed "$path" '' 'The link installation directory is not present in the modeled filesystem.'
            fi
        fi
        while [[ -n $ancestor && $ancestor != / ]]; do
            if [[ ${OV_TYPE[$ancestor]:-} == L ]]; then sr_issue unconfirmed "$path" '' 'An archive path has a planned symlink ancestor.'; break; fi
            ancestor=${ancestor%/*}
        done
    done
    # A second global provider with the same SONAME may change ldconfig's choice.
    local soname eid prior oldfile oldid dir global
    for id in "${SELECTED[@]}"; do
        while IFS= read -r line; do
            sr_fields "$line"; path=${F[0]}; eid=${F[1]}
            sr_elf "${PK_DIR[$id]}/root$path" || continue
            soname=${M_SONAME[$eid]:-}; [[ -n $soname ]] || continue
            global=0
            for dir in "${LD_PATHS[@]}"; do [[ ${path%/*} == "$dir" ]] && global=1; done
            (( global )) || continue
            for dir in "${LD_PATHS[@]}"; do
                prior=$dir/$soname
                sr_lookup "$prior" 1 || continue
                [[ $V_TYPE == F ]] || continue
                oldfile=$V_FILE
                if [[ ${PK_ACTION[$id]} == upgrade && ${OWN[$prior]:-} == "${PK_PREVIOUS[$id]}" ]]; then
                    : # The full installed-system audit below checks old consumers.
                elif ! cmp -s -- "$oldfile" "${PK_DIR[$id]}/root$path"; then
                    sr_issue preserve "$prior" "$soname" 'An installed global SONAME would be shadowed. Keep it and use a supported private-library context.'
                fi
            done
        done < "${PK_ELFS[$id]}"
    done
}
sr_graph() {
    local graph_value graph_signature graph_dir state_line
    graph_value=$({ printf '%s\n' "${SELECTED[@]}" | sort; printf 'A\t%s\n' "${AUDIT_ROOTS[@]}"; } | sha256sum)
    graph_signature=${graph_value:0:64}; graph_dir=$SR_WORK/graph-cache/$graph_signature
    if [[ -f $graph_dir/complete ]]; then
        ((SR_PROFILE_GRAPH_HITS+=1))
        cp -- "$graph_dir/issues" "$SR_WORK/issues"
        cp -- "$graph_dir/edges" "$SR_WORK/edges"
        FIRST_CODE=; FIRST_PATH=; FIRST_NEED=; FIRST_REASON=; FIRST_EID=
        GRAPH_CONSUMER_EID=(); OV_OWNER=(); SELECTED_SET=()
        for id in "${SELECTED[@]}"; do SELECTED_SET["$id"]=1; done
        while IFS= read -r state_line; do
            sr_fields "$state_line"
            case ${F[0]} in
                FIRST) FIRST_CODE=${F[1]}; FIRST_PATH=${F[2]}; FIRST_NEED=${F[3]}; FIRST_REASON=${F[4]}; FIRST_EID=${F[5]};;
                CONSUMER) GRAPH_CONSUMER_EID["${F[1]}"$'\t'"${F[2]}"]=${F[3]};;
                ACTION) PK_ACTION["${F[1]}"]=${F[2]}; PK_PREVIOUS["${F[1]}"]=${F[3]};;
                OWNER) OV_OWNER["${F[1]}"]=${F[2]};;
            esac
        done < "$graph_dir/state"
        [[ ! -s $SR_WORK/issues ]]
        return
    fi
    ((SR_PROFILE_GRAPH_PASSES+=1))
    : > "$SR_WORK/issues"; : > "$SR_WORK/edges"
    FIRST_CODE=; FIRST_PATH=; FIRST_NEED=; FIRST_REASON=
    GRAPH_CONSUMER_EID=()
    sr_overlay
    if [[ ${SR_AUDIT_SYSTEM:-0} == 1 ]]; then sr_collect_system_roots; fi
    declare -a qpath=() qinherit=()
    declare -A visited=() reached=()
    local id line path eid source index=0 inherit nextinherit needed key count=0 seed=0
    for id in "${SELECTED[@]}"; do
        while IFS= read -r line; do
            sr_fields "$line"; path=${F[0]}
            sr_elf "${PK_DIR[$id]}/root$path" || continue; eid=$E_ID
            if [[ ${M_TYPE[$eid]} == EXEC || -n ${M_INTERP[$eid]:-} ]]; then
                qpath+=("$path"); qinherit+=(""); ((seed+=1))
            fi
        done < "${PK_ELFS[$id]}"
    done
    for path in "${AUDIT_ROOTS[@]}"; do
        qpath+=("$path"); qinherit+=(""); ((seed+=1))
    done
    local phase=0
    while :; do
        while (( index < ${#qpath[@]} )); do
            path=${qpath[$index]}; inherit=${qinherit[$index]}; ((index+=1))
            key=$path$'\t'$inherit
            [[ ${visited[$key]+yes} ]] && continue
            visited["$key"]=1; reached["$path"]=1; ((count+=1))
            if (( count > 10000 )); then sr_issue unconfirmed "$path" '' 'Dependency graph limit reached.'; break; fi
            sr_lookup "$path" || { sr_issue missing "$path" "$path" 'Object or link target not found.'; continue; }
            source=$V_FILE
            sr_elf "$source" || { sr_issue incompatible "$path" '' 'Object is not a readable ELF file.'; continue; }
            eid=$E_ID
            if [[ ${M_FLAGS[$eid]:-} == *UNMODELED* ]]; then sr_issue unconfirmed "$path" '' 'Unsupported dynamic-loader tag.'; fi
            nextinherit=$inherit
            if [[ -z ${M_RUNPATH[$eid]:-} && -n ${M_RPATH[$eid]:-} ]]; then
                if sr_expand_paths "${M_RPATH[$eid]}" "$path"; then nextinherit=$REPLY$inherit
                else sr_issue unconfirmed "$path" '' 'Relative or unsupported RPATH.'; fi
            fi
            local -a needs=()
            [[ -z ${M_INTERP[$eid]:-} ]] || needs+=("${M_INTERP[$eid]}")
            while IFS= read -r needed; do [[ -z $needed ]] || needs+=("$needed"); done <<< "${M_NEEDED[$eid]:-}"
            for needed in "${needs[@]}"; do
                if sr_dependency "$path" "$eid" "$needed" "$inherit"; then
                    sr_record EDGE "$path" "$needed" "$DEP_PATH" "$DEP_OWNER" resolved "$DEP_EID" >> "$SR_WORK/edges"
                    qpath+=("$DEP_PATH"); qinherit+=("$nextinherit")
                else
                    sr_record EDGE "$path" "$needed" '' '' "$DEP_STATUS" "$DEP_REASON" >> "$SR_WORK/edges"
                    sr_issue "$DEP_STATUS" "$path" "$needed" "$DEP_REASON"
                    GRAPH_CONSUMER_EID["$path"$'\t'"$needed"]=$eid
                    if [[ $FIRST_CODE == missing && $FIRST_PATH == "$path" && $FIRST_NEED == "$needed" ]]; then FIRST_EID=$eid; fi
                fi
            done
        done
        (( phase == 0 )) || break
        phase=1
        # Libraries not reached from an executable are still inspected, with an
        # explicit standalone context; unresolved plugin contexts remain pending.
        for id in "${SELECTED[@]}"; do
            while IFS= read -r line; do
                sr_fields "$line"; path=${F[0]}
                [[ ${reached[$path]+yes} ]] && continue
                qpath+=("$path"); qinherit+=(""); ((seed+=1))
            done < "${PK_ELFS[$id]}"
        done
    done
    # A data-only package has no ELF dependency edges. Its package operation
    # remains valid, while non-ELF runtime requirements stay outside coverage.
    local graph_tmp=$SR_WORK/graph-cache/.${graph_signature}.$$
    mkdir -p -- "$graph_tmp"
    cp -- "$SR_WORK/issues" "$graph_tmp/issues"
    cp -- "$SR_WORK/edges" "$graph_tmp/edges"
    {
        sr_record FIRST "${FIRST_CODE:-}" "${FIRST_PATH:-}" "${FIRST_NEED:-}" "${FIRST_REASON:-}" "${FIRST_EID:-}"
        for key in "${!GRAPH_CONSUMER_EID[@]}"; do
            path=${key%%$'\t'*}; needed=${key#*$'\t'}
            sr_record CONSUMER "$path" "$needed" "${GRAPH_CONSUMER_EID[$key]}"
        done
        for id in "${SELECTED[@]}"; do sr_record ACTION "$id" "${PK_ACTION[$id]}" "${PK_PREVIOUS[$id]:-}"; done
        for path in "${!OV_OWNER[@]}"; do sr_record OWNER "$path" "${OV_OWNER[$path]}"; done
    } > "$graph_tmp/state"
    : > "$graph_tmp/complete"
    if [[ ! -e $graph_dir ]]; then mv -- "$graph_tmp" "$graph_dir"; else rm -rf -- "$graph_tmp"; fi
    [[ ! -s $SR_WORK/issues ]]
}
sr_batch_unique_missing() {
    [[ ${SR_OFFLINE:-0} != 2 ]] || return 1
    local line path need key consumer count rank id candidate_id added=0
    declare -A seen=() add=()
    while IFS= read -r line; do
        sr_fields "$line"; [[ ${F[0]} == ISSUE && ${F[1]} == missing ]] || continue
        path=${F[2]}; need=${F[3]}; [[ $need != */* ]] || continue
        key=$path$'\t'$need; [[ ${seen[$key]+yes} ]] && continue; seen["$key"]=1
        consumer=${GRAPH_CONSUMER_EID[$key]:-}; [[ -n $consumer ]] || continue
        sr_candidates "$need" "$consumer"
        count=0; id=; candidate_id=
        while IFS=$'\t' read -r rank id; do
            [[ -n $id ]] || continue; ((count+=1)); candidate_id=$id
        done < "$SR_WORK/candidates"
        (( count == 1 )) || continue
        add["$candidate_id"]=1
    done < "$SR_WORK/issues"
    for id in "${!add[@]}"; do
        [[ $'\n'$(printf '%s\n' "${SELECTED[@]}")$'\n' == *$'\n'$id$'\n'* ]] && continue
        SELECTED+=("$id"); ((added+=1))
    done
    (( added > 0 )) || return 1
    sr_log "Resolved one dependency round with $added unique provider package(s)."
    sr_session_checkpoint "$(printf '%s\n' "${SELECTED[@]}")" || return 1
}
sr_selection_save() { printf '%s\n' "${SELECTED[@]}"; }
sr_selection_restore() {
    SELECTED=(); local value
    while IFS= read -r value; do [[ -z $value ]] || SELECTED+=("$value"); done <<< "$1"
}
sr_solve() {
    local depth=$1 checkpoint candidates rank id tier= tier_before= before after code need consumer
    ((SR_SEARCH_COUNT+=1))
    if (( SR_SEARCH_COUNT > SR_MAX_SEARCH || depth > 64 )); then SR_LIMIT_HIT=1; return; fi
    checkpoint=$(sr_selection_save)
    sr_session_checkpoint "$checkpoint" || return
    if [[ -n ${SLACKRESOLVE_TEST_INTERRUPT_DEPTH:-} && $depth == "$SLACKRESOLVE_TEST_INTERRUPT_DEPTH" ]]; then
        kill -INT $$
    fi
    if sr_graph; then
        local signature
        signature=$(printf '%s\n' "${SELECTED[@]}" | sort | sha256sum); signature=${signature:0:64}
        printf '%s\n' "$checkpoint" > "$SR_WORK/solution.$signature"
        return 0
    fi
    if (( depth > SR_BEST_DEPTH )); then
        SR_BEST_DEPTH=$depth; SR_BEST_SELECTED=$checkpoint
        cp -- "$SR_WORK/issues" "$SR_WORK/best-issues"
    fi
    if sr_batch_unique_missing; then
        sr_solve "$((depth+1))"
        sr_selection_restore "$checkpoint"
        return 0
    fi
    code=$FIRST_CODE; need=$FIRST_NEED; consumer=${FIRST_EID:-}
    if [[ $code != missing || $need == */* || -z $consumer || ${SR_OFFLINE:-0} == 2 ]]; then return 0; fi
    sr_candidates "$need" "$consumer"
    candidates=$(cat "$SR_WORK/candidates")
    before=$(find "$SR_WORK" -maxdepth 1 -name 'solution.*' -type f | wc -l)
    while IFS=$'\t' read -r rank id; do
        [[ -n $id ]] || continue
        if [[ -n $tier && $rank != "$tier" ]]; then
            after=$(find "$SR_WORK" -maxdepth 1 -name 'solution.*' -type f | wc -l)
            (( after > before )) && break
        fi
        tier=$rank
        sr_selection_restore "$checkpoint"
        [[ $'\n'$checkpoint$'\n' == *$'\n'$id$'\n'* ]] && continue
        SELECTED+=("$id")
        sr_solve "$((depth+1))"
        (( SR_LIMIT_HIT == 0 )) || break
    done <<< "$candidates"
    sr_selection_restore "$checkpoint"
    return 0
}
sr_toposort() {
    local line consumer provider from to id path
    : > "$SR_WORK/order-input"
    for id in "${SELECTED[@]}"; do printf 'N\t%s\n' "$id" >> "$SR_WORK/order-input"; done
    while IFS= read -r line; do
        sr_fields "$line"; consumer=${F[1]}; provider=${F[4]}
        [[ -n $provider && ${SELECTED_SET[$provider]+yes} ]] || continue
        from=${OV_OWNER[$consumer]:-}; [[ -n $from && $from != "$provider" ]] || continue
        printf 'E\t%s\t%s\n' "$from" "$provider" >> "$SR_WORK/order-input"
    done < "$SR_WORK/edges"
    : > "$SR_WORK/groups"
    awk -F '\t' -v groups="$SR_WORK/groups" 'BEGIN{OFS="\t"}
        $1=="N" && !seen[$2]++ {node[++count]=$2}
        $1=="E" {edge[$2 SUBSEP $3]=1}
        function sort_members(a,n, i,j,t){for(i=1;i<=n;i++)for(j=i+1;j<=n;j++)if(a[j]<a[i]){t=a[i];a[i]=a[j];a[j]=t}}
        END {
            for(e in edge){split(e,a,SUBSEP);reach[a[1] SUBSEP a[2]]=1}
            for(k=1;k<=count;k++)for(i=1;i<=count;i++)for(j=1;j<=count;j++)
                if(reach[node[i] SUBSEP node[k]]&&reach[node[k] SUBSEP node[j]])reach[node[i] SUBSEP node[j]]=1
            components=0
            for(i=1;i<=count;i++)if(!(node[i] in component)){
                components++; component[node[i]]=components
                for(j=i+1;j<=count;j++)if(!(node[j] in component)&&reach[node[i] SUBSEP node[j]]&&reach[node[j] SUBSEP node[i]])component[node[j]]=components
            }
            for(i=1;i<=count;i++){c=component[node[i]];member_count[c]++;members[c SUBSEP member_count[c]]=node[i]}
            for(e in edge){split(e,a,SUBSEP);x=component[a[1]];y=component[a[2]];if(x!=y)cdep[x SUBSEP y]=1}
            while(done_components<components){
                best=0;bestkey=""
                for(c=1;c<=components;c++)if(!(c in cdone)){
                    blocked=0;for(d in cdep){split(d,a,SUBSEP);if(a[1]==c&&!(a[2] in cdone))blocked=1}
                    key=members[c SUBSEP 1];if(!blocked&&(best==0||key<bestkey)){best=c;bestkey=key}
                }
                if(best==0)exit 2
                delete ordered
                for(i=1;i<=member_count[best];i++)ordered[i]=members[best SUBSEP i]
                sort_members(ordered,member_count[best])
                if(member_count[best]>1)for(i=1;i<=member_count[best];i++)print "GROUP",done_components+1,ordered[i] > groups
                for(i=1;i<=member_count[best];i++)print ordered[i]
                cdone[best]=1;done_components++
            }
        }' "$SR_WORK/order-input" > "$SR_WORK/order"
}
