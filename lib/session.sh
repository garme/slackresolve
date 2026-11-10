# SPDX-License-Identifier: GPL-3.0-only
# Persistent, data-only resolution sessions. Session files are never sourced.
sr_session_id_valid() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$ ]]; }
sr_session_meta_read() {
    local file=$1 line
    declare -gA SESSION_META=()
    [[ -f $file ]] || return 1
    while IFS= read -r line; do
        sr_fields "$line"; [[ ${F[0]} == META && -n ${F[1]} ]] || continue
        SESSION_META["${F[1]}"]=${F[2]}
    done < "$file"
}
sr_system_signature() {
    local value
    value=$({
        printf '%s\n' "$SR_ROOT" "$SR_RELEASE" "$SR_TARGET_ARCH"
        if [[ -n ${SR_PKGDB:-} ]]; then
            find -L "$SR_PKGDB" -maxdepth 1 -type f -printf '%f\t%s\t%T@\n' 2>/dev/null | sort
        fi
        local file
        for file in "${SR_ROOT%/}/etc/slackware-version" "${SR_ROOT%/}/etc/ld.so.conf" "${SR_ROOT%/}/etc/ld.so.cache"; do
            [[ -e $file || -L $file ]] && stat -c '%n\t%s\t%Y' -- "$file"
        done
        :
    } | sha256sum) || return 1
    SR_SYSTEM_SIGNATURE=${value:0:64}
}
sr_session_write_request() {
    local tmp=$SR_SESSION_DIR/request.tsv arg
    : > "$tmp.tmp" || return 1
    for arg in "${SR_ORIGINAL_ARGS[@]}"; do sr_record ARG "$arg" >> "$tmp.tmp"; done
    mv -- "$tmp.tmp" "$tmp"
}
sr_session_write_meta() {
    local status=$1 tmp=$SR_SESSION_DIR/session.meta now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    {
        sr_record META id "$SR_SESSION_ID"
        sr_record META version "$SR_VERSION"
        sr_record META status "$status"
        sr_record META created "${SR_SESSION_CREATED:-$now}"
        sr_record META updated "$now"
        sr_record META command "$SR_COMMAND"
        sr_record META root "$SR_ROOT"
        sr_record META release "$SR_RELEASE"
        sr_record META architecture "$SR_TARGET_ARCH"
        sr_record META repository "$SR_REPO"
        sr_record META repository_signature "$SR_REPO_SIGNATURE"
        sr_record META system_signature "$SR_SYSTEM_SIGNATURE"
        sr_record META output "${SR_OUTPUT:-}"
    } > "$tmp.tmp" || return 1
    mv -- "$tmp.tmp" "$tmp"
}
sr_session_start() {
    sr_system_signature || sr_die 'Could not identify the installed-system state.'
    SR_SESSION_RESUME_VALID=0
    if [[ -n ${SR_RESUME_SESSION:-} ]]; then
        sr_session_id_valid "$SR_RESUME_SESSION" || sr_die 'Invalid resolution session identifier.'
        SR_SESSION_ID=$SR_RESUME_SESSION; SR_SESSION_DIR=$SR_CACHE/sessions/$SR_SESSION_ID
        sr_session_meta_read "$SR_SESSION_DIR/session.meta" || sr_die "Resolution session not found: $SR_SESSION_ID"
        SR_SESSION_CREATED=${SESSION_META[created]:-}
        if [[ ${SESSION_META[repository_signature]:-} == "$SR_REPO_SIGNATURE" &&
              ${SESSION_META[system_signature]:-} == "$SR_SYSTEM_SIGNATURE" &&
              ${SESSION_META[architecture]:-} == "$SR_TARGET_ARCH" ]]; then
            SR_SESSION_RESUME_VALID=1
            printf 'Resuming resolution session: %s\n' "$SR_SESSION_ID"
        else
            printf 'Resolution session state changed; rebuilding the graph while reusing cached packages and ELF data.\n'
        fi
    else
        local label=${SR_COMMAND}
        [[ ${#SR_INPUTS[@]} == 0 ]] || label+=-${SR_INPUTS[0]##*/}
        label=${label//[^A-Za-z0-9._-]/-}; label=${label:0:40}
        SR_SESSION_ID=$(date -u +%Y%m%d-%H%M%S)-$$-$label
        SR_SESSION_DIR=$SR_CACHE/sessions/$SR_SESSION_ID
        mkdir -p -- "$SR_SESSION_DIR" || sr_die 'Could not create the resolution session.'
        sr_session_write_request || sr_die 'Could not save the resolution request.'
        printf 'Resolution session: %s\n' "$SR_SESSION_ID"
    fi
    SR_SESSION_ACTIVE=1
    sr_session_write_meta running || sr_die 'Could not initialize the resolution session.'
    trap 'sr_session_interrupt INT' INT
    trap 'sr_session_interrupt TERM' TERM HUP
}
sr_session_checkpoint() {
    [[ ${SR_SESSION_ACTIVE:-0} == 1 ]] || return 0
    local selection=${1:-${SR_BEST_SELECTED:-$(printf '%s\n' "${SELECTED[@]}")}} id tmp=$SR_SESSION_DIR/checkpoint.tsv
    {
        sr_record CHECKPOINT "$SR_SEARCH_COUNT" "${SR_BEST_DEPTH:--1}"
        while IFS= read -r id; do
            [[ -n $id && ${PK_FULL[$id]+yes} ]] || continue
            sr_record PACKAGE "${PK_FULL[$id]}" "${PK_ARCHIVE[$id]}" "${PK_HASH[$id]}" "${PK_ORIGIN[$id]}"
        done <<< "$selection"
    } > "$tmp.tmp" || return 1
    mv -- "$tmp.tmp" "$tmp" || return 1
    sr_session_write_meta running
}
sr_session_restore() {
    [[ ${SR_SESSION_RESUME_VALID:-0} == 1 && -f $SR_SESSION_DIR/checkpoint.tsv ]] || return 0
    local line full archive hash origin id already actual restored=0
    while IFS= read -r line; do
        sr_fields "$line"; [[ ${F[0]} == PACKAGE ]] || continue
        full=${F[1]}; archive=${F[2]}; hash=${F[3]}; origin=${F[4]}
        [[ -f $archive ]] || continue
        sr_hash "$archive" || continue; actual=$REPLY; [[ $actual == "$hash" ]] || continue
        already=0
        for id in "${SELECTED[@]}"; do [[ ${PK_FULL[$id]} == "$full" ]] && already=1; done
        (( already )) && continue
        sr_archive "$archive" "$origin" || continue
        SELECTED+=("$A_ID"); ((restored+=1))
    done < "$SR_SESSION_DIR/checkpoint.tsv"
    (( restored == 0 )) || printf 'Restored packages from checkpoint: %s\n' "$restored"
}
sr_session_interrupt() {
    local signal=${1:-INT}
    trap - INT TERM HUP
    sr_session_checkpoint "$(printf '%s\n' "${SELECTED[@]}")" || :
    sr_session_write_meta interrupted || :
    printf '\nResolution interrupted safely.\nSession: %s\nContinue with:\n  slackresolve resume %s\n' \
        "$SR_SESSION_ID" "$SR_SESSION_ID" >&2
    [[ $signal == INT ]] && exit 130
    exit 143
}
sr_session_finish() {
    local status=$1
    [[ ${SR_SESSION_ACTIVE:-0} == 1 ]] || return 0
    sr_session_checkpoint "$(printf '%s\n' "${SELECTED[@]}")" || return 1
    sr_session_write_meta "$status"
    trap - INT TERM HUP
}
sr_session_reexec() {
    local id=$1 cache=$2 dir line
    dir=$cache/sessions/$id
    sr_session_id_valid "$id" || sr_die 'Invalid resolution session identifier.'
    [[ -f $dir/request.tsv ]] || sr_die "Resolution session not found: $id"
    local -a args=()
    while IFS= read -r line; do
        sr_fields "$line"; [[ ${F[0]} == ARG ]] || continue; args+=("${F[1]}")
    done < "$dir/request.tsv"
    (( ${#args[@]} )) || sr_die 'The resolution session has no saved request.'
    exec "$SR_CLI_PATH" "${args[@]}" --cache "$cache" --resume-session "$id"
}
sr_sessions_list() {
    local cache=$1 dir file line id status updated command
    printf '%-52s %-12s %-20s %s\n' ID STATUS UPDATED COMMAND
    while IFS= read -r -d '' file; do
        sr_session_meta_read "$file" || continue
        id=${SESSION_META[id]:-${file%/*}}; id=${id##*/}
        status=${SESSION_META[status]:-unknown}; updated=${SESSION_META[updated]:-unknown}; command=${SESSION_META[command]:-unknown}
        printf '%-52s %-12s %-20s %s\n' "$id" "$status" "$updated" "$command"
    done < <(find "$cache/sessions" -mindepth 2 -maxdepth 2 -type f -name session.meta -print0 2>/dev/null | sort -z)
}
