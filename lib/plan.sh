# SPDX-License-Identifier: GPL-3.0-only
sr_db_signature() {
    local log base sum
    {
        if [[ -n $SR_PKGDB ]]; then
            while IFS= read -r -d '' log; do
                base=${log##*/}
                [[ ${DB_IGNORE[$base]+yes} ]] && continue
                sr_hash "$log" || return 1
                sr_record "$base" "$REPLY"
            done < <(find -L "$SR_PKGDB" -maxdepth 1 -type f -print0 | sort -z)
        fi
    } > "$SR_WORK/db-state"
    sr_hash "$SR_WORK/db-state"
}
sr_plan_write() {
    local output=$1 status=$2 id line path kind value mode hash filename rootdir elfline
    sr_norm "$output"; output=$REPLY
    [[ ! -e $output && ! -e $output.d ]] || sr_die "Output already exists: $output (choose another filename)."
    mkdir -p -- "${output%/*}" || return 1
    rootdir=$(mktemp -d "${output%/*}/.slackresolve.XXXXXXXX") || return 1
    mkdir -p -- "$rootdir/data/archives"
    declare -gA DB_IGNORE=()
    for id in "${SELECTED[@]}"; do
        [[ ${INST_FULL[${PK_FULL[$id]}]+yes} ]] || DB_IGNORE["${PK_FULL[$id]}"]=1
        [[ -z ${PK_PREVIOUS[$id]:-} ]] || DB_IGNORE["${PK_PREVIOUS[$id]}"]=1
    done
    sr_db_signature; local signature=$REPLY
    {
        sr_record SLACKRESOLVE_PLAN "$SR_SCHEMA"
        sr_record META version "$SR_VERSION"
        sr_record META root "$SR_ROOT"
        sr_record META release "$SR_RELEASE"
        sr_record META architecture "$SR_TARGET_ARCH"
        sr_record META status "$status"
        sr_record META database "$signature"
        sr_record META library_path "${SR_LIBRARY_PATH:-}"
        sr_record META coverage 'ELF runtime dependencies and versioned symbols; declared loader profile; supported installation scripts only. Language modules, arbitrary dlopen, scripts and full ABI semantics are not inferred.'
        for id in "${SELECTED[@]}"; do
            declare -A plan_elf=()
            while IFS= read -r elfline; do sr_fields "$elfline"; plan_elf["${F[0]}"]=1; done < "${PK_ELFS[$id]}"
            filename=${PK_ARCHIVE[$id]##*/}; mkdir -p -- "$rootdir/data/archives/$id"
            cp --reflink=auto -- "${PK_ARCHIVE[$id]}" "$rootdir/data/archives/$id/$filename" || return 1
            sr_record PACKAGE "$id" "${PK_FULL[$id]}" "${output##*/}.d/archives/$id/$filename" "${PK_HASH[$id]}" "${PK_ORIGIN[$id]}" "${PK_ACTION[$id]}" "${PK_PREVIOUS[$id]:-}"
            while IFS= read -r line; do
                sr_fields "$line"; kind=${F[0]}; path=${F[1]}; value=${F[2]}; mode=${F[3]}
                [[ $kind == L || ( $kind == F && ${plan_elf[$path]+yes} ) ]] || continue
                [[ $path != /install && $path != /install/* ]] || continue
                if [[ $kind == F ]]; then sr_hash "${PK_DIR[$id]}/root$path" || return 1; value=$REPLY; fi
                sr_record FILE "$id" "$path" "$kind" "$value" "$mode"
            done < "${PK_DIR[$id]}/files"
            unset plan_elf
        done
        cat "$SR_WORK/edges" "$SR_WORK/issues"
        [[ ! -f $SR_WORK/rejections ]] || cat "$SR_WORK/rejections"
        [[ ! -f $SR_WORK/groups ]] || cat "$SR_WORK/groups"
        while IFS= read -r id; do [[ -z $id ]] || sr_record ORDER "$id"; done < "$SR_WORK/order"
        if (( ${#GUARD_KIND[@]} )); then
            while IFS= read -r -d '' path; do sr_record GUARD "$path" "${GUARD_KIND[$path]}" "${GUARD_VALUE[$path]}"; done < <(printf '%s\0' "${!GUARD_KIND[@]}" | sort -z)
        fi
    } > "$rootdir/plan" || { rm -rf -- "$rootdir"; return 1; }
    mv -- "$rootdir/data" "$output.d" || return 1
    mv -- "$rootdir/plan" "$output" || return 1
    rmdir -- "$rootdir"
    SR_OUTPUT=$output
    printf 'Plan: %s\nStatus: %s\n' "$output" "$status"
}
sr_plan_read() {
    local plan=$1 line header=0 kind id path action
    [[ -f $plan ]] || sr_die "Plan file not found: $plan"
    sr_control_path "$plan" || sr_die 'Unsupported characters in plan filename.'
    sr_norm "$plan"; PLAN_PATH=$REPLY; PLAN_DIR=${PLAN_PATH%/*}
    declare -gA PLAN_META=() PLAN_FULL=() PLAN_ARCHIVE=() PLAN_HASH=() PLAN_ACTION=() PLAN_PREVIOUS=() PLAN_GK=() PLAN_GV=() PLAN_GROUP_ID=()
    declare -ga PLAN_IDS=() PLAN_ORDER=() PLAN_FILES=() PLAN_EDGES=() PLAN_ISSUES=() PLAN_REJECTIONS=() PLAN_GROUPS=()
    while IFS= read -r line || [[ -n $line ]]; do
        sr_fields "$line"; kind=${F[0]:-}
        if (( ! header )); then
            [[ $kind == SLACKRESOLVE_PLAN && ${F[1]:-} == "$SR_SCHEMA" && ${#F[@]} == 2 ]] || sr_die 'Unsupported plan format.'
            header=1; continue
        fi
        case $kind in
            META) [[ ${#F[@]} == 3 ]] || sr_die 'Invalid META record.'; PLAN_META["${F[1]}"]=${F[2]};;
            PACKAGE)
                [[ ${#F[@]} == 8 ]] || sr_die 'Invalid PACKAGE record.'
                id=${F[1]}; action=${F[6]}
                [[ $id =~ ^[a-f0-9]{64}$ && ${F[4]} =~ ^[a-f0-9]{64}$ && ( $action == install || $action == upgrade || $action == keep ) ]] || sr_die 'Invalid package operation.'
                [[ $action != upgrade || -n ${F[7]} ]] || sr_die 'Upgrade operation has no installed package.'
                sr_package_name "${F[2]}" && [[ $P_FULL == "${F[2]}" ]] || sr_die 'Invalid package name in plan.'
                [[ ! ${PLAN_FULL[$id]+yes} ]] || sr_die 'Duplicate package identity.'
                [[ ${F[3]} != /* && ${F[3]} != *../* && ${F[3]} == "${PLAN_PATH##*/}.d/archives/"* ]] || sr_die 'Archive path escapes the plan data directory.'
                PLAN_IDS+=("$id"); PLAN_FULL["$id"]=${F[2]}; PLAN_ARCHIVE["$id"]=$PLAN_DIR/${F[3]}
                PLAN_HASH["$id"]=${F[4]}; PLAN_ACTION["$id"]=$action; PLAN_PREVIOUS["$id"]=${F[7]};;
            FILE) [[ ${#F[@]} == 6 ]] || sr_die 'Invalid FILE record.'; PLAN_FILES+=("$line");;
            GUARD) [[ ${#F[@]} == 4 ]] || sr_die 'Invalid GUARD record.'; PLAN_GK["${F[1]}"]=${F[2]}; PLAN_GV["${F[1]}"]=${F[3]};;
            ORDER) [[ ${#F[@]} == 2 ]] || sr_die 'Invalid ORDER record.'; PLAN_ORDER+=("${F[1]}");;
            EDGE) [[ ${#F[@]} == 7 ]] || sr_die 'Invalid EDGE record.'; PLAN_EDGES+=("$line");;
            ISSUE) [[ ${#F[@]} == 5 ]] || sr_die 'Invalid ISSUE record.'; PLAN_ISSUES+=("$line");;
            REJECT) PLAN_REJECTIONS+=("$line");;
            GROUP) [[ ${#F[@]} == 3 && ${F[2]} =~ ^[a-f0-9]{64}$ ]] || sr_die 'Invalid GROUP record.'; PLAN_GROUPS+=("$line"); PLAN_GROUP_ID["${F[2]}"]=${F[1]};;
            *) sr_die "Unknown plan record: $kind";;
        esac
    done < "$PLAN_PATH"
    (( header && ${#PLAN_IDS[@]} )) || sr_die 'Empty plan.'
    [[ ${PLAN_META[root]:-} == /* ]] || sr_die 'Invalid target profile.'
    sr_arch_valid "${PLAN_META[architecture]:-}" || sr_die 'Invalid target architecture.'
    for line in "${PLAN_FILES[@]}"; do
        sr_fields "$line"; path=${F[2]}
        [[ ${PLAN_FULL[${F[1]}]+yes} && $path == /* && $path != / && $path != */../* && ( ${F[3]} == F || ${F[3]} == L || ${F[3]} == D ) ]] || sr_die 'Invalid planned file.'
        sr_norm "$path"; [[ $path == "$REPLY" ]] || sr_die 'Noncanonical planned path.'
        sr_control_path "$path" || sr_die 'Unsupported planned filename.'
        [[ ${F[3]} != F || ${F[4]} =~ ^[a-f0-9]{64}$ ]] || sr_die 'Invalid file hash.'
    done
    declare -A ordered=()
    for id in "${PLAN_ORDER[@]}"; do
        [[ ${PLAN_FULL[$id]+yes} && ! ${ordered[$id]+yes} ]] || sr_die 'Invalid operation order.'
        ordered["$id"]=1
    done
    if [[ ${PLAN_META[status]:-} == ready ]]; then
        (( ${#PLAN_ISSUES[@]} == 0 && ${#ordered[@]} == ${#PLAN_IDS[@]} )) || sr_die 'Inconsistent ready plan.'
    fi
}
sr_explain() {
    local id line owner
    printf 'SlackResolve %s\nTarget: %s (%s)\nStatus: %s\n\n' "${PLAN_META[version]}" "${PLAN_META[root]}" "${PLAN_META[release]}" "${PLAN_META[status]}"
    printf 'Packages\n'
    for id in "${PLAN_IDS[@]}"; do printf '  %-8s %s\n' "${PLAN_ACTION[$id]}" "${PLAN_FULL[$id]}"; done
    printf '\nDependency evidence\n'
    for line in "${PLAN_EDGES[@]}"; do
        sr_fields "$line"; owner=${F[4]}; [[ -z $owner ]] || owner=${PLAN_FULL[$owner]:-$owner}
        printf '  %s\n    needs %s -> %s [%s]\n' "${F[1]}" "${F[2]}" "${F[3]:-${F[6]}}" "${owner:-${F[5]}}"
    done
    if (( ${#PLAN_ISSUES[@]} )); then
        printf '\nPending decisions (installation is blocked)\n'
        for line in "${PLAN_ISSUES[@]}"; do sr_fields "$line"; printf '  %s: %s %s\n    %s\n' "${F[1]}" "${F[2]}" "${F[3]}" "${F[4]}"; done
    fi
    if (( ${#PLAN_REJECTIONS[@]} )); then
        printf '\nRejected candidates\n'
        for line in "${PLAN_REJECTIONS[@]}"; do sr_fields "$line"; printf '  %s: %s (%s)\n' "${F[1]}" "${F[2]}" "${F[3]}"; done
    fi
    printf '\nCoverage\n  %s\n' "${PLAN_META[coverage]}"
}
sr_file_matches() {
    local path=$1 kind=$2 value=$3
    if [[ $kind == D ]]; then sr_lookup "$path" 1 && [[ $V_TYPE == D ]]; return; fi
    if [[ $kind == L ]]; then [[ -L ${SR_ROOT%/}$path && $(readlink -- "${SR_ROOT%/}$path") == "$value" ]]; return; fi
    sr_lookup "$path" 1 && [[ $V_TYPE == F ]] || return 1
    sr_hash "$V_FILE" || return 1
    [[ $REPLY == "$value" ]]
}
sr_package_matches() {
    local id=$1 line
    [[ -n $SR_PKGDB && -f $SR_PKGDB/${PLAN_FULL[$id]} ]] || return 1
    for line in "${PLAN_FILES[@]}"; do
        sr_fields "$line"; [[ ${F[1]} == "$id" ]] || continue
        sr_file_matches "${F[2]}" "${F[3]}" "${F[4]}" || return 1
    done
}
sr_guard_check() {
    local path actual kind line id parent
    declare -A completed_paths=()
    for line in "${PLAN_FILES[@]}"; do
        sr_fields "$line"; id=${F[1]}; path=${F[2]}
        [[ ${COMPLETED[$id]+yes} ]] || continue
        completed_paths["$path"]=1
        parent=${path%/*}
        while [[ -n $parent && $parent != / ]]; do completed_paths["$parent"]=1; parent=${parent%/*}; done
    done
    for path in "${!PLAN_GK[@]}"; do
        [[ ${completed_paths[$path]+yes} ]] && continue
        [[ $path != /etc/ld.so.cache || ${#COMPLETED[@]} == 0 ]] || continue
        kind=${PLAN_GK[$path]}; actual=${SR_ROOT%/}$path
        case $kind in
            absent) [[ ! -e $actual && ! -L $actual ]] || { sr_log "Target changed: $path is no longer absent."; return 1; };;
            file) [[ -f $actual && ! -L $actual ]] || return 1; sr_hash "$actual" || return 1; [[ $REPLY == "${PLAN_GV[$path]}" ]] || { sr_log "Target changed: $path"; return 1; };;
            link) [[ -L $actual && $(readlink -- "$actual") == "${PLAN_GV[$path]}" ]] || { sr_log "Link changed: $path"; return 1; };;
            directory) [[ -d $actual && ! -L $actual ]] || return 1;;
            *) sr_log "Unsupported filesystem guard: $path"; return 1;;
        esac
    done
    sr_db_signature || return 1
    [[ $REPLY == "${PLAN_META[database]}" ]] || { sr_log 'Installed package records changed; generate a new plan.'; return 1; }
}
sr_refresh_runtime_caches() {
    if command -v ldconfig >/dev/null; then
        if [[ $SR_ROOT == / ]]; then ldconfig || return 1; else ldconfig -r "$SR_ROOT" || return 1; fi
    fi
    if [[ $SR_ROOT == / ]]; then
        if command -v fc-cache >/dev/null; then fc-cache -f >/dev/null 2>&1 || return 1; fi
        if command -v update-gdk-pixbuf-loaders >/dev/null; then update-gdk-pixbuf-loaders >/dev/null 2>&1 || return 1
        elif command -v gdk-pixbuf-query-loaders >/dev/null; then gdk-pixbuf-query-loaders --update-cache >/dev/null 2>&1 || return 1; fi
    elif command -v chroot >/dev/null; then
        [[ ! -x $SR_ROOT/usr/bin/fc-cache ]] || chroot "$SR_ROOT" /usr/bin/fc-cache -f >/dev/null 2>&1 || return 1
        if [[ -x $SR_ROOT/usr/bin/update-gdk-pixbuf-loaders ]]; then chroot "$SR_ROOT" /usr/bin/update-gdk-pixbuf-loaders >/dev/null 2>&1 || return 1
        elif [[ -x $SR_ROOT/usr/bin/gdk-pixbuf-query-loaders ]]; then chroot "$SR_ROOT" /usr/bin/gdk-pixbuf-query-loaders --update-cache >/dev/null 2>&1 || return 1; fi
    fi
}
sr_apply() {
    local id archive line state journal=$PLAN_PATH.journal hash installer lock action
    [[ ${PLAN_META[status]} == ready && ${#PLAN_ISSUES[@]} == 0 ]] || sr_die 'This plan has pending decisions. Installation is blocked.'
    [[ $SR_RELEASE != unknown ]] || sr_die 'Applying requires a Slackware target.'
    command -v flock >/dev/null || sr_die 'flock is required for applying a plan.'
    if (( SR_DRY_RUN )); then
        exec {lock}> "$SR_CACHE/application-dry-run.lock" || return 1
    else
        [[ $SR_ROOT != / || $EUID == 0 ]] || sr_die 'Applying packages to / requires root.'
        [[ -w $SR_ROOT ]] || sr_die 'The target root is not writable.'
        installer=$(command -v installpkg) || sr_die 'installpkg is not available.'
        mkdir -p -- "${SR_ROOT%/}/var/lock"
        exec {lock}> "${SR_ROOT%/}/var/lock/slackresolve.lock" || return 1
    fi
    flock -n "$lock" || sr_die 'Another SlackResolve application is running.'
    declare -gA DB_IGNORE=() COMPLETED=() STARTED=()
    for id in "${PLAN_IDS[@]}"; do
        archive=${PLAN_ARCHIVE[$id]}
        local resolved
        resolved=$(realpath -e -- "$archive") || sr_die "Archive missing: $archive"
        [[ $resolved == "$PLAN_DIR/${PLAN_PATH##*/}.d/archives/"* ]] || sr_die 'Archive symlink escapes the plan directory.'
        sr_hash "$archive" || return 1; [[ $REPLY == "${PLAN_HASH[$id]}" ]] || sr_die "Archive changed: ${PLAN_FULL[$id]}"
        [[ ${PLAN_ACTION[$id]} == keep ]] || DB_IGNORE["${PLAN_FULL[$id]}"]=1
        [[ -z ${PLAN_PREVIOUS[$id]} ]] || {
            [[ -f $SR_PKGDB/${PLAN_PREVIOUS[$id]} ]] || sr_die "Installed package changed: ${PLAN_PREVIOUS[$id]}"
            DB_IGNORE["${PLAN_PREVIOUS[$id]}"]=1
        }
        sr_blocked "${PLAN_FULL[$id]}" && sr_die "Package is currently blacklisted: ${PLAN_FULL[$id]}"
    done
    sr_hash "$PLAN_PATH"; hash=$REPLY
    if [[ -f $journal ]]; then
        IFS= read -r line < "$journal"; sr_fields "$line"
        [[ ${F[0]} == SLACKRESOLVE_JOURNAL && ${F[1]} == "$hash" ]] || sr_die 'The journal belongs to a different plan.'
        while IFS= read -r line; do
            sr_fields "$line"; state=${F[0]}; id=${F[1]:-}
            [[ $state == START || $state == DONE ]] || continue
            [[ ${PLAN_FULL[$id]+yes} ]] || sr_die 'Invalid package in journal.'
            STARTED["$id"]=1; [[ $state != DONE ]] || COMPLETED["$id"]=1
        done < "$journal"
    fi
    for id in "${PLAN_IDS[@]}"; do
        if [[ ${PLAN_ACTION[$id]} == keep ]]; then sr_package_matches "$id" || sr_die "Installed package no longer matches: ${PLAN_FULL[$id]}"; continue; fi
        if [[ ${STARTED[$id]+yes} ]] && sr_package_matches "$id"; then
            if [[ ! ${COMPLETED[$id]+yes} ]]; then sr_record DONE "$id" >> "$journal"; fi
            COMPLETED["$id"]=1
        elif [[ ${STARTED[$id]+yes} ]]; then
            sr_die "Partial operation needs inspection before retrying: ${PLAN_FULL[$id]}"
        elif [[ -n $SR_PKGDB && -f $SR_PKGDB/${PLAN_FULL[$id]} ]]; then
            sr_die "Package appeared after planning: ${PLAN_FULL[$id]}"
        fi
    done
    sr_guard_check || sr_die 'The target no longer matches the plan.'
    if (( SR_DRY_RUN )); then
        for id in "${PLAN_ORDER[@]}"; do
            case ${PLAN_ACTION[$id]} in
                install) printf 'Would install: %s\n' "${PLAN_FULL[$id]}";;
                upgrade) printf 'Would upgrade: %s -> %s\n' "${PLAN_PREVIOUS[$id]}" "${PLAN_FULL[$id]}";;
            esac
        done
        return 0
    fi
    [[ -f $journal ]] || sr_record SLACKRESOLVE_JOURNAL "$hash" > "$journal"
    for id in "${PLAN_ORDER[@]}"; do
        [[ ${PLAN_ACTION[$id]} != keep && ! ${COMPLETED[$id]+yes} ]] || continue
        sr_guard_check || sr_die 'Target state changed during application.'
        action=${PLAN_ACTION[$id]}
        printf '%s %s\n' "$([[ $action == upgrade ]] && printf 'Upgrading' || printf 'Installing')" "${PLAN_FULL[$id]}"
        sr_record START "$id" >> "$journal"
        if [[ $action == upgrade ]]; then
            command -v upgradepkg >/dev/null || sr_die 'upgradepkg is not available.'
            ROOT="$SR_ROOT" upgradepkg "${PLAN_PREVIOUS[$id]}%${PLAN_ARCHIVE[$id]}" || sr_die "upgradepkg failed: ${PLAN_FULL[$id]}. The journal records the partial state."
        else
            ROOT="$SR_ROOT" "$installer" "${PLAN_ARCHIVE[$id]}" || sr_die "installpkg failed: ${PLAN_FULL[$id]}. The journal records the partial state."
        fi
        sr_package_matches "$id" || sr_die "Installed files do not match the plan: ${PLAN_FULL[$id]}"
        sr_record DONE "$id" >> "$journal"; COMPLETED["$id"]=1
        if command -v ldconfig >/dev/null; then
            if [[ $SR_ROOT == / ]]; then ldconfig || sr_die 'ldconfig failed.'
            else ldconfig -r "$SR_ROOT" || sr_die 'Target ldconfig failed.'; fi
        fi
    done
    sr_refresh_runtime_caches || sr_die 'A runtime cache refresh failed after package installation.'
    printf 'Application completed.\n'
    sr_check
}
sr_check() {
    local id line ok=1
    for id in "${PLAN_IDS[@]}"; do
        if sr_package_matches "$id"; then printf 'OK: %s\n' "${PLAN_FULL[$id]}"
        else printf 'MISMATCH: %s\n' "${PLAN_FULL[$id]}"; ok=0; fi
    done
    # Preserved providers remain protected even after all operations finish.
    for line in "${PLAN_EDGES[@]}"; do
        sr_fields "$line"
        [[ ${F[5]} == resolved ]] || continue
        local provider=${F[3]} expected=${F[6]}
        if ! sr_lookup "$provider" 1 || ! sr_elf "$V_FILE" || [[ $E_ID != "$expected" ]]; then
            printf 'MISMATCH: provider %s\n' "$provider"; ok=0
        fi
    done
    (( ok ))
}
