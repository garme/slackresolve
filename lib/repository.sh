# SPDX-License-Identifier: GPL-3.0-only
sr_priority() {
    case $1 in *patches*) REPLY=0;; *extra*) REPLY=20;; *testing*|*pasture*) REPLY=90;; *) REPLY=10;; esac
}
sr_repo_add() {
    local path=$1 rank=$2 origin=$3 fullname=$4 arch=$5 id
    sr_hash_string "$origin|$fullname|$path"; id=$REPLY
    [[ ${RP_PATH[$id]+yes} ]] && return
    sr_package_name "$fullname" || return
    REPO_IDS+=("$id"); RP_PATH["$id"]=$path; RP_RANK["$id"]=$rank
    RP_ORIGIN["$id"]=$origin; RP_FULL["$id"]=$fullname
    RP_BASE["$id"]=$P_BASE; RP_ARCH["$id"]=$arch
}
sr_repo_load() {
    local repo=${SR_REPO:-slackpkg} file rel rank line full arch area name version build ext location
    if [[ $repo != slackpkg ]]; then
        [[ -d $repo ]] || sr_die "Repository directory not found: $repo"
        sr_norm "$repo"; SR_REPO=$REPLY
        while IFS= read -r -d '' file; do
            rel=${file#"$SR_REPO"/}; sr_priority "$rel"; rank=$REPLY
            (( rank < 90 )) || continue
            sr_package_name "$file" || continue
            sr_arch_compatible "$P_ARCH" || continue
            sr_repo_add "$file" "$rank" local "$P_FULL" "$P_ARCH"
        done < <(find "$SR_REPO" -type f \( -name '*.txz' -o -name '*.tgz' -o -name '*.tlz' -o -name '*.tbz' \) -print0 | sort -z)
    elif [[ -f $SR_SLACK_DATA/pkglist ]]; then
        while read -r area name version arch build full location ext; do
            [[ -n $full && -n $ext ]] || continue
            sr_arch_compatible "$arch" || continue
            sr_priority "$area"; rank=$REPLY; (( rank < 90 )) || continue
            sr_repo_add "$full.$ext" "$rank" slackpkg "$full" "$arch"
        done < "$SR_SLACK_DATA/pkglist"
        # MANIFEST is only a provider hint. The archive is always inspected.
        while IFS= read -r -d '' file; do
            if [[ $file == *.bz2 ]]; then bzip2 -dc -- "$file"; else cat -- "$file"; fi
        done < <(find "$SR_SLACK_DATA" -maxdepth 2 -type f -iname '*manifest*' -print0) |
            awk 'BEGIN{OFS="\t"} /Package:/ {for(i=1;i<=NF;i++)if($i=="Package:"){p=$(i+1);sub(/^.*\//,"",p);sub(/\.(t[gxbl]z|tbz)$/,"",p)}} /^[l-]/ && /\.so/ {s=$0;for(i=1;i<=5;i++)sub(/^[^ \t]+[ \t]+/,"",s);sub(/ -> .*/,"",s);sub(/^.*\//,"",s);if(length(p)&&length(s))print p,s}' > "$SR_WORK/manifest"
        while IFS=$'\t' read -r full name; do
            for file in "${REPO_IDS[@]}"; do
                [[ ${RP_FULL[$file]} != "$full" ]] || RP_MANIFEST["$file"]+="$name"$'\n'
            done
        done < "$SR_WORK/manifest"
    fi
}
sr_hash_string() { local value; value=$(printf '%s' "$1" | sha256sum); REPLY=${value:0:64}; }
sr_fetch() {
    local rid=$1 file cached full=${RP_FULL[$1]} name=${RP_PATH[$1]##*/}
    sr_blocked "$full" && { sr_log "Excluded by blacklist: $full"; return 1; }
    if [[ ${RP_ORIGIN[$rid]} == local ]]; then
        file=${RP_PATH[$rid]}
    else
        command -v slackpkg >/dev/null || { sr_log 'slackpkg is not available.'; return 1; }
        sr_log "Downloading $full with slackpkg..."
        if ! slackpkg -batch=on -default_answer=y -dialog=off -checkgpg=on -checkmd5=on download "$full" >> "$SR_WORK/download.log" 2>&1; then
            sr_log "slackpkg failed for $full. See $SR_WORK/download.log while this command is running."
            return 1
        fi
        file=
        while IFS= read -r -d '' cached; do
            [[ ${cached##*/} == "$name" ]] || continue
            if [[ -n $file ]] && ! cmp -s -- "$file" "$cached"; then
                sr_log "Conflicting cached archives for $name"; return 1
            fi
            file=$cached
        done < <(find "$SR_SLACK_CACHE" -type f -name "$name" -print0)
        [[ -n $file ]] || { sr_log "Downloaded archive was not found: $name"; return 1; }
        # Independently check the exact bytes against slackpkg's signed list.
        local expected actual
        expected=$(awk -v name="$name" '{p=$2;sub(/^.*\//,"",p);if(p==name)print $1}' "$SR_SLACK_DATA/CHECKSUMS.md5" 2>/dev/null | sort -u)
        [[ $expected =~ ^[0-9a-fA-F]{32}$ ]] || { sr_log "No unique checksum for $name"; return 1; }
        actual=$(md5sum -- "$file"); [[ ${actual:0:32} == "$expected" ]] || return 1
        [[ -f $file.asc ]] || { sr_log "Missing package signature: $name.asc"; return 1; }
        local verifier
        verifier=$(command -v gpg || command -v gpg2) || { sr_log 'GPG is required for repository downloads.'; return 1; }
        "$verifier" --batch --verify "$file.asc" "$file" >> "$SR_WORK/download.log" 2>&1 || {
            sr_log "Package signature verification failed: $name"; return 1;
        }
    fi
    sr_archive "$file" "${RP_ORIGIN[$rid]}" || return 1
    [[ ${PK_FULL[$A_ID]} == "$full" ]] || { sr_log "Unexpected package identity: ${PK_FULL[$A_ID]}"; return 1; }
}
sr_repo_input() {
    local query=$1 rid min=100 best= count=0 rank
    for rid in "${REPO_IDS[@]}"; do
        [[ ${RP_FULL[$rid]} == "$query" || ${RP_BASE[$rid]} == "$query" || ${RP_PATH[$rid]##*/} == "$query" ]] || continue
        rank=${RP_RANK[$rid]}
        if (( rank < min )); then min=$rank; best=$rid; count=1
        elif (( rank == min )); then ((count+=1)); fi
    done
    (( count == 1 )) || { sr_log "Package not found or ambiguous: $query (use an exact archive name)."; return 1; }
    sr_fetch "$best"
}
sr_slackpkg_file_search() {
    local needed=$1 rid output=$SR_WORK/slackpkg-file-search
    : > "$SR_WORK/slackpkg-provider-ids"
    command -v slackpkg >/dev/null || { sr_log 'slackpkg is not available for file-search.'; return 1; }
    sr_log "Searching official Slackware packages for $needed..."
    slackpkg -batch=on -dialog=off file-search "$needed" > "$output" 2>&1 || :
    for rid in "${REPO_IDS[@]}"; do
        [[ ${RP_ORIGIN[$rid]} == slackpkg ]] || continue
        if awk -v full="${RP_FULL[$rid]}" '$NF==full {found=1} END{exit !found}' "$output"; then
            printf '%s\n' "$rid" >> "$SR_WORK/slackpkg-provider-ids"
        fi
    done
    [[ -s $SR_WORK/slackpkg-provider-ids ]]
}
sr_package_file_match() {
    local id=$1 query=$2 line kind path wanted result=
    if [[ $query == */* ]]; then
        wanted=/${query#/}; sr_norm "$wanted"; wanted=$REPLY
    else wanted=; fi
    while IFS= read -r line; do
        sr_fields "$line"; kind=${F[0]}; path=${F[1]}
        [[ $kind == F || $kind == L ]] || continue
        [[ $path != /install && $path != /install/* ]] || continue
        if [[ -n $wanted ]]; then
            [[ $path == "$wanted" ]] || continue
        else
            [[ ${path##*/} == "$query" ]] || continue
        fi
        result+="$path"$'\n'
    done < "${PK_DIR[$id]}/files"
    REPLY=$result
    [[ -n $result ]]
}
sr_file_candidates() {
    local query=$1 rid id rank matches downloads=0 official=0
    : > "$SR_WORK/file-candidates"
    declare -gA FILE_MATCHES=()
    for rid in "${REPO_IDS[@]}"; do
        if [[ ${RP_ORIGIN[$rid]} == slackpkg ]]; then official=1; break; fi
    done
    (( ! official )) || sr_slackpkg_file_search "$query" || :
    for rid in "${REPO_IDS[@]}"; do
        sr_blocked "${RP_FULL[$rid]}" && continue
        if [[ ${RP_ORIGIN[$rid]} == slackpkg ]]; then
            grep -Fxq -- "$rid" "$SR_WORK/slackpkg-provider-ids" || continue
        fi
        (( downloads < SR_MAX_CANDIDATES )) || { SR_LIMIT_HIT=1; break; }
        ((downloads+=1)); sr_fetch "$rid" || continue; id=$A_ID
        sr_package_file_match "$id" "$query" || continue; matches=$REPLY
        FILE_MATCHES["$id"]=$matches; rank=${RP_RANK[$rid]}
        if [[ ,${SR_PREFER:-}, == *",${PK_BASE[$id]},"* || ,${SR_PREFER:-}, == *",${PK_FULL[$id]},"* ]]; then rank=$((rank-100)); fi
        printf '%s\t%s\n' "$rank" "$id" >> "$SR_WORK/file-candidates"
    done
    sort -k1,1n -k2,2 -u "$SR_WORK/file-candidates" -o "$SR_WORK/file-candidates"
    [[ -s $SR_WORK/file-candidates ]]
}
sr_candidates() {
    local needed=$1 consumer=$2 rid line path eid eligible rank hint matched downloads=0 official=0
    : > "$SR_WORK/candidates"
    for rid in "${REPO_IDS[@]}"; do
        if [[ ${RP_ORIGIN[$rid]} == slackpkg ]]; then official=1; break; fi
    done
    (( ! official )) || sr_slackpkg_file_search "$needed" || :
    for rid in "${REPO_IDS[@]}"; do
        sr_blocked "${RP_FULL[$rid]}" && continue
        hint=${RP_MANIFEST[$rid]:-}; matched=0
        if [[ -n $hint ]]; then
            while IFS= read -r line; do
                [[ $line == "$needed" || $line == "$needed".* ]] && matched=1
            done <<< "$hint"
            (( matched )) || continue
        elif [[ ${RP_ORIGIN[$rid]} == slackpkg ]]; then
            grep -Fxq -- "$rid" "$SR_WORK/slackpkg-provider-ids" || continue
        fi
        (( downloads < SR_MAX_CANDIDATES )) || { SR_LIMIT_HIT=1; break; }
        ((downloads+=1))
        sr_fetch "$rid" || continue
        eligible=0
        while IFS= read -r line; do
            sr_fields "$line"; path=${F[0]}; eid=${F[1]}
            sr_elf "${PK_DIR[$A_ID]}/root$path" || continue
            if [[ ${M_SONAME[$eid]:-} == "$needed" || ${path##*/} == "$needed" ]]; then
                if sr_compatible "$consumer" "$needed" "$eid"; then eligible=1
                else sr_record REJECT "${PK_FULL[$A_ID]}" "$needed" "$COMPAT_REASON" >> "$SR_WORK/rejections"; fi
            fi
        done < "${PK_ELFS[$A_ID]}"
        (( eligible )) || continue
        rank=${RP_RANK[$rid]}
        if [[ ,${SR_PREFER:-}, == *",${RP_BASE[$rid]},"* || ,${SR_PREFER:-}, == *",${RP_FULL[$rid]},"* ]]; then rank=$((rank-100)); fi
        printf '%s\t%s\n' "$rank" "$A_ID" >> "$SR_WORK/candidates"
    done
    sort -k1,1n -k2,2 -u "$SR_WORK/candidates" -o "$SR_WORK/candidates"
}
