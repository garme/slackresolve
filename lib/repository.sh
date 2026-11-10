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
    RP_BASE["$id"]=$P_BASE; RP_ARCH["$id"]=$arch; RP_BY_FULL["$fullname"]=$id
}
sr_repository_signature() {
    local repo=${SR_REPO:-slackpkg} value
    if [[ $repo == slackpkg ]]; then
        value=$({
            printf '%s\n' "$SR_RELEASE" "$SR_TARGET_ARCH"
            find "$SR_SLACK_DATA" -maxdepth 2 -type f \
                \( -name pkglist -o -name filelist -o -name CHECKSUMS.md5 -o -iname '*manifest*' \) \
                -printf '%P\t%s\t%T@\n' 2>/dev/null | sort
        } | sha256sum) || return
    else
        value=$({
            printf '%s\n' "$repo" "$SR_TARGET_ARCH"
            find "$repo" -type f \( -name '*.txz' -o -name '*.tgz' -o -name '*.tlz' -o -name '*.tbz' \) \
                -printf '%P\t%s\t%T@\n' 2>/dev/null | sort
        } | sha256sum) || return
    fi
    SR_REPO_SIGNATURE=${value:0:64}
}
sr_provider_index_load() {
    local index_dir index raw tmp file lock
    index_dir=$SR_CACHE/indexes/$SR_REPO_SIGNATURE; index=$index_dir/files.tsv
    mkdir -p -- "$index_dir" || return 1
    exec {lock}> "$index_dir/build.lock" || return 1
    flock "$lock" || return 1
    [[ ${SR_REBUILD_INDEX:-0} != 1 ]] || rm -f -- "$index"
    if [[ -f $index ]]; then SR_REPOSITORY_INDEX_HIT=1; else SR_REPOSITORY_INDEX_HIT=0; fi
    if [[ ! -f $index ]]; then
        raw=$(mktemp "$index_dir/raw.XXXXXXXX") || return 1
        tmp=$(mktemp "$index_dir/files.XXXXXXXX") || { rm -f -- "$raw"; return 1; }
        if [[ -s $SR_SLACK_DATA/filelist ]]; then
            awk 'BEGIN{OFS="\t"} NF>1 {
                p=$1; sub(/^.*\//,"",p); sub(/\.(txz|tgz|tlz|tbz)$/,"",p)
                for(i=2;i<=NF;i++){f=$i;sub(/^\.\//,"",f);sub(/ -> .*/,"",f)
                    if(length(p)&&length(f)){if(f!~/^\//)f="/" f; print p,f}}
            }' "$SR_SLACK_DATA/filelist" > "$raw" || { rm -f -- "$raw" "$tmp"; return 1; }
        else
            while IFS= read -r -d '' file; do
                if [[ $file == *.bz2 ]]; then bzip2 -dc -- "$file"; else cat -- "$file"; fi
            done < <(find "$SR_SLACK_DATA" -maxdepth 2 -type f -iname '*manifest*' -print0) |
                awk 'BEGIN{OFS="\t"}
                    /Package:/ {for(i=1;i<=NF;i++)if($i=="Package:"){p=$(i+1);sub(/^.*\//,"",p);sub(/\.(txz|tgz|tlz|tbz)$/,"",p)}}
                    /^[l-]/ {s=$0;for(i=1;i<=5;i++)sub(/^[^ \t]+[ \t]+/,"",s);sub(/ -> .*/,"",s);if(s!~/^\//)s="/" s;if(length(p)&&length(s))print p,s}' > "$raw" || {
                        rm -f -- "$raw" "$tmp"; return 1;
                    }
        fi
        awk -F '\t' 'BEGIN{OFS="\t"} NF==2 {path=$2;name=path;sub(/^.*\//,"",name)
            if(length(name))print "B:" name,$1,path; print "P:" path,$1,path}' "$raw" |
            LC_ALL=C sort -u > "$tmp" || { rm -f -- "$raw" "$tmp"; return 1; }
        rm -f -- "$raw"; mv -- "$tmp" "$index" || return 1
    fi
    SR_PROVIDER_INDEX=$index
}
sr_repository_maps() {
    local cached file name expected
    RP_CACHE_FILE=(); RP_MD5_FILE=()
    if [[ -d $SR_SLACK_CACHE ]]; then
        while IFS= read -r -d '' cached; do
            name=${cached##*/}; [[ ${RP_CACHE_FILE[$name]+yes} ]] || RP_CACHE_FILE["$name"]=$cached
        done < <(find "$SR_SLACK_CACHE" -type f \( -name '*.txz' -o -name '*.tgz' -o -name '*.tlz' -o -name '*.tbz' \) -print0 2>/dev/null)
    fi
    if [[ -f $SR_SLACK_DATA/CHECKSUMS.md5 ]]; then
        while read -r expected file; do
            name=${file##*/}; [[ $expected =~ ^[0-9a-fA-F]{32}$ ]] || continue
            if [[ ${RP_MD5_FILE[$name]+yes} && ${RP_MD5_FILE[$name]} != "$expected" ]]; then RP_MD5_FILE["$name"]=conflict
            else RP_MD5_FILE["$name"]=$expected; fi
        done < "$SR_SLACK_DATA/CHECKSUMS.md5"
    fi
}
sr_repo_load() {
    local repo=${SR_REPO:-slackpkg} file rel rank full arch area name version build ext location
    if [[ $repo != slackpkg ]]; then
        [[ -d $repo ]] || sr_die "Repository directory not found: $repo"
        sr_norm "$repo"; SR_REPO=$REPLY
        while IFS= read -r -d '' file; do
            rel=${file#"$SR_REPO"/}; sr_priority "$rel"; rank=$REPLY; (( rank < 90 )) || continue
            sr_package_name "$file" || continue; sr_arch_compatible "$P_ARCH" || continue
            sr_repo_add "$file" "$rank" local "$P_FULL" "$P_ARCH"
        done < <(find "$SR_REPO" -type f \( -name '*.txz' -o -name '*.tgz' -o -name '*.tlz' -o -name '*.tbz' \) -print0 | sort -z)
    elif [[ -f $SR_SLACK_DATA/pkglist ]]; then
        while read -r area name version arch build full location ext; do
            [[ -n $full && -n $ext ]] || continue; sr_arch_compatible "$arch" || continue
            sr_priority "$area"; rank=$REPLY; (( rank < 90 )) || continue
            sr_repo_add "$full.$ext" "$rank" slackpkg "$full" "$arch"
        done < "$SR_SLACK_DATA/pkglist"
    fi
    sr_repository_signature || sr_die 'Could not identify the repository state.'
    if [[ $repo == slackpkg ]]; then
        sr_provider_index_load || sr_die 'Could not build the official file-provider index.'
        sr_repository_maps
    fi
}
sr_hash_string() { local value; value=$(printf '%s' "$1" | sha256sum); REPLY=${value:0:64}; }
sr_fetch() {
    local rid=$1 file full=${RP_FULL[$1]} name=${RP_PATH[$1]##*/} expected actual verifier
    sr_blocked "$full" && { sr_log "Excluded by blacklist: $full"; return 1; }
    if [[ ${RP_FETCHED_ID[$rid]+yes} ]]; then A_ID=${RP_FETCHED_ID[$rid]}; return 0; fi
    if [[ ${RP_ORIGIN[$rid]} == local ]]; then file=${RP_PATH[$rid]}
    else
        command -v slackpkg >/dev/null || { sr_log 'slackpkg is not available.'; return 1; }
        file=${RP_CACHE_FILE[$name]:-}
        if [[ -z $file ]]; then
            sr_log "Downloading $full with slackpkg..."; ((SR_PROFILE_DOWNLOADS+=1))
            slackpkg -batch=on -default_answer=y -dialog=off -checkgpg=on -checkmd5=on download "$full" >> "$SR_WORK/download.log" 2>&1 || {
                sr_log "slackpkg failed for $full. See $SR_WORK/download.log while this command is running."; return 1;
            }
            file=$(find "$SR_SLACK_CACHE" -type f -name "$name" -print -quit 2>/dev/null)
            [[ -z $file ]] || RP_CACHE_FILE["$name"]=$file
        else sr_log "Reusing cached package $full..."; ((SR_PROFILE_PACKAGE_HITS+=1)); fi
        [[ -n $file ]] || { sr_log "Downloaded archive was not found: $name"; return 1; }
        expected=${RP_MD5_FILE[$name]:-}
        [[ $expected =~ ^[0-9a-fA-F]{32}$ ]] || { sr_log "No unique checksum for $name"; return 1; }
        actual=$(md5sum -- "$file"); [[ ${actual:0:32} == "$expected" ]] || return 1
        [[ -f $file.asc ]] || { sr_log "Missing package signature: $name.asc"; return 1; }
        verifier=$(command -v gpg || command -v gpg2) || { sr_log 'GPG is required for repository downloads.'; return 1; }
        "$verifier" --batch --verify "$file.asc" "$file" >> "$SR_WORK/download.log" 2>&1 || {
            sr_log "Package signature verification failed: $name"; return 1;
        }
    fi
    sr_archive "$file" "${RP_ORIGIN[$rid]}" || return 1
    [[ ${PK_FULL[$A_ID]} == "$full" ]] || { sr_log "Unexpected package identity: ${PK_FULL[$A_ID]}"; return 1; }
    RP_FETCHED_ID["$rid"]=$A_ID
}
sr_repo_input() {
    local query=$1 rid min=100 best= count=0 rank
    for rid in "${REPO_IDS[@]}"; do
        [[ ${RP_FULL[$rid]} == "$query" || ${RP_BASE[$rid]} == "$query" || ${RP_PATH[$rid]##*/} == "$query" ]] || continue
        rank=${RP_RANK[$rid]}; if (( rank < min )); then min=$rank; best=$rid; count=1
        elif (( rank == min )); then ((count+=1)); fi
    done
    (( count == 1 )) || { sr_log "Package not found or ambiguous: $query (use an exact archive name)."; return 1; }
    sr_fetch "$best"
}
sr_index_provider_ids() {
    local query=$1 key full path rid cached
    : > "$SR_WORK/slackpkg-provider-ids"
    if [[ $query == */* ]]; then sr_norm "/${query#/}"; key=P:$REPLY; else key=B:$query; fi
    if [[ ${SEARCH_RESULT[$key]+yes} ]]; then
        printf '%s' "${SEARCH_RESULT[$key]}" > "$SR_WORK/slackpkg-provider-ids"
        [[ -s $SR_WORK/slackpkg-provider-ids ]]; return
    fi
    ((SR_PROFILE_LOOKUPS+=1))
    while IFS=$'\t' read -r _ full path; do
        rid=${RP_BY_FULL[$full]:-}; [[ -z $rid ]] || printf '%s\n' "$rid" >> "$SR_WORK/slackpkg-provider-ids"
    done < <(awk -F '\t' -v key="$key" '$1==key' "$SR_PROVIDER_INDEX")
    sort -u -o "$SR_WORK/slackpkg-provider-ids" "$SR_WORK/slackpkg-provider-ids"
    cached=$(cat "$SR_WORK/slackpkg-provider-ids"); SEARCH_RESULT["$key"]=${cached:+$cached$'\n'}
    [[ -s $SR_WORK/slackpkg-provider-ids ]]
}
sr_slackpkg_file_search() {
    local needed=$1 rid output=$SR_WORK/slackpkg-file-search full cache key tmp
    sr_index_provider_ids "$needed" && return 0
    sr_hash_string "$needed"; key=$REPLY; cache=$SR_CACHE/searches/$SR_REPO_SIGNATURE/$key.tsv
    mkdir -p -- "${cache%/*}"
    if [[ ! -f $cache ]]; then
        tmp=$(mktemp "${cache%/*}/search.XXXXXXXX") || return 1
        command -v slackpkg >/dev/null || { sr_log 'slackpkg is not available for file-search.'; return 1; }
        sr_log "Local file index has no entry; asking slackpkg for $needed..."; ((SR_PROFILE_FALLBACKS+=1))
        slackpkg -batch=on -dialog=off file-search "$needed" > "$output" 2>&1 || :
        awk '/^\[(installed|uninstalled|upgrade)[^]]*\][ \t]+-[ \t]+/ {print $NF}' "$output" | sort -u > "$tmp"
        mv -- "$tmp" "$cache" || return 1
    fi
    : > "$SR_WORK/slackpkg-provider-ids"
    while IFS= read -r full; do rid=${RP_BY_FULL[$full]:-}; [[ -z $rid ]] || printf '%s\n' "$rid" >> "$SR_WORK/slackpkg-provider-ids"; done < "$cache"
    [[ -s $SR_WORK/slackpkg-provider-ids ]]
}
sr_package_file_match() {
    local id=$1 query=$2 line kind path wanted result=
    if [[ $query == */* ]]; then wanted=/${query#/}; sr_norm "$wanted"; wanted=$REPLY; else wanted=; fi
    while IFS= read -r line; do
        sr_fields "$line"; kind=${F[0]}; path=${F[1]}; [[ $kind == F || $kind == L ]] || continue
        [[ $path != /install && $path != /install/* ]] || continue
        if [[ -n $wanted ]]; then [[ $path == "$wanted" ]] || continue; else [[ ${path##*/} == "$query" ]] || continue; fi
        result+="$path"$'\n'
    done < "${PK_DIR[$id]}/files"
    REPLY=$result; [[ -n $result ]]
}
sr_file_candidates() {
    local query=$1 rid id rank matches downloads=0 official=0; local -a candidates=()
    : > "$SR_WORK/file-candidates"; declare -gA FILE_MATCHES=()
    for rid in "${REPO_IDS[@]}"; do [[ ${RP_ORIGIN[$rid]} != slackpkg ]] || { official=1; break; }; done
    if (( official )); then sr_slackpkg_file_search "$query" || :; mapfile -t candidates < "$SR_WORK/slackpkg-provider-ids"
    else candidates=("${REPO_IDS[@]}"); fi
    for rid in "${candidates[@]}"; do
        [[ -n $rid && ${RP_FULL[$rid]+yes} ]] || continue; sr_blocked "${RP_FULL[$rid]}" && continue
        (( downloads < SR_MAX_CANDIDATES )) || { SR_LIMIT_HIT=1; break; }; ((downloads+=1))
        sr_fetch "$rid" || continue; id=$A_ID; sr_package_file_match "$id" "$query" || continue; matches=$REPLY
        FILE_MATCHES["$id"]=$matches; rank=${RP_RANK[$rid]}
        if [[ ,${SR_PREFER:-}, == *",${PK_BASE[$id]},"* || ,${SR_PREFER:-}, == *",${PK_FULL[$id]},"* ]]; then rank=$((rank-100)); fi
        printf '%s\t%s\n' "$rank" "$id" >> "$SR_WORK/file-candidates"
    done
    sort -k1,1n -k2,2 -u "$SR_WORK/file-candidates" -o "$SR_WORK/file-candidates"; [[ -s $SR_WORK/file-candidates ]]
}
sr_candidates() {
    local needed=$1 consumer=$2 rid line path eid eligible rank downloads=0 official=0 key cached; local -a candidates=()
    : > "$SR_WORK/candidates"
    key=$needed'|'$consumer
    if [[ ${CANDIDATE_RESULT[$key]+yes} ]]; then
        printf '%s' "${CANDIDATE_RESULT[$key]}" > "$SR_WORK/candidates"; return 0
    fi
    for rid in "${REPO_IDS[@]}"; do [[ ${RP_ORIGIN[$rid]} != slackpkg ]] || { official=1; break; }; done
    if (( official )); then sr_slackpkg_file_search "$needed" || :; mapfile -t candidates < "$SR_WORK/slackpkg-provider-ids"
    else candidates=("${REPO_IDS[@]}"); fi
    for rid in "${candidates[@]}"; do
        [[ -n $rid && ${RP_FULL[$rid]+yes} ]] || continue; sr_blocked "${RP_FULL[$rid]}" && continue
        (( downloads < SR_MAX_CANDIDATES )) || { SR_LIMIT_HIT=1; break; }; ((downloads+=1)); sr_fetch "$rid" || continue
        eligible=0
        while IFS= read -r line; do
            sr_fields "$line"; path=${F[0]}; eid=${F[1]}; sr_elf "${PK_DIR[$A_ID]}/root$path" || continue
            if [[ ${M_SONAME[$eid]:-} == "$needed" || ${path##*/} == "$needed" ]]; then
                if sr_compatible "$consumer" "$needed" "$eid"; then eligible=1
                else sr_record REJECT "${PK_FULL[$A_ID]}" "$needed" "$COMPAT_REASON" >> "$SR_WORK/rejections"; fi
            fi
        done < "${PK_ELFS[$A_ID]}"
        (( eligible )) || continue; rank=${RP_RANK[$rid]}
        if [[ ,${SR_PREFER:-}, == *",${RP_BASE[$rid]},"* || ,${SR_PREFER:-}, == *",${RP_FULL[$rid]},"* ]]; then rank=$((rank-100)); fi
        printf '%s\t%s\n' "$rank" "$A_ID" >> "$SR_WORK/candidates"
    done
    sort -k1,1n -k2,2 -u "$SR_WORK/candidates" -o "$SR_WORK/candidates"
    cached=$(cat "$SR_WORK/candidates"); CANDIDATE_RESULT["$key"]=${cached:+$cached$'\n'}
}
