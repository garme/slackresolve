# SPDX-License-Identifier: GPL-3.0-only
sr_archive() {
    local input=$1 origin=${2:-local} id dir tmp line type path target mode physical found=0 content
    [[ -f $input ]] || { sr_log "Package not found: $input"; return 1; }
    sr_control_path "$input" || { sr_log 'Unsupported characters in archive filename.'; return 1; }
    sr_package_name "$input" || { sr_log "Invalid Slackware package name: ${input##*/}"; return 1; }
    local full=$P_FULL base=$P_BASE arch=$P_ARCH
    sr_arch_compatible "$arch" || {
        sr_log "Package architecture $arch is incompatible with target $SR_TARGET_ARCH"; return 1;
    }
    sr_hash "$input" || return; content=$REPLY
    sr_hash_string "$content|$full"; id=$REPLY; A_ID=$id
    [[ ${PK_DIR[$id]+yes} ]] && return 0
    dir=$SR_CACHE/objects/$id
    if [[ ! -f $dir/complete ]]; then
        tmp=$(mktemp -d "$SR_WORK/archive.XXXXXXXX") || return 1
        mkdir -p -- "$tmp/root"; : > "$tmp/regular"
        tar -tvf "$input" --numeric-owner --full-time --quoting-style=escape > "$tmp/list" 2> "$tmp/tar.err" || return 1
        awk -v regular="$tmp/regular" -f "$SR_LIBDIR/../awk/archive.awk" "$tmp/list" > "$tmp/files" || return 1
        if [[ -s $tmp/regular ]]; then
            tar -xf "$input" -C "$tmp/root" --no-same-owner --no-same-permissions --no-recursion \
                --verbatim-files-from -T "$tmp/regular" 2>> "$tmp/tar.err" || return 1
        fi
        # Materialize archive hardlinks as ordinary analysis files. Native tar
        # still installs the original hardlinks from the pinned archive.
        local hardpath hardtarget pass remaining
        for ((pass=0;pass<64;pass++)); do
            remaining=0
            while IFS= read -r line; do
                sr_fields "$line"; [[ ${F[0]} == H ]] || continue
                hardpath=${F[1]}; hardtarget=${F[2]}
                sr_norm "$hardtarget"; hardtarget=$REPLY
                [[ ! -f $tmp/root$hardpath ]] || continue
                if [[ -f $tmp/root$hardtarget ]]; then
                    mkdir -p -- "$tmp/root${hardpath%/*}"
                    cp -- "$tmp/root$hardtarget" "$tmp/root$hardpath" || return 1
                else ((remaining+=1)); fi
            done < "$tmp/files"
            (( remaining )) || break
        done
        (( remaining == 0 )) || { sr_log 'Unresolved archive hardlink.'; return 1; }
        awk -F '\t' 'BEGIN{OFS="\t"} $1=="H"{$1="F";$3="%00"}{print}' "$tmp/files" > "$tmp/files.normalized"
        mv -- "$tmp/files.normalized" "$tmp/files"
        printf 'SCRIPT\tabsent\t%%00\t%%00\n' > "$tmp/script"
        if [[ -f $tmp/root/install/doinst.sh ]]; then
            awk -f "$SR_LIBDIR/../awk/doinst.awk" "$tmp/root/install/doinst.sh" > "$tmp/script" || return 1
        fi
        cat "$tmp/script" >> "$tmp/files"
        : > "$tmp/elfs"
        while IFS= read -r line; do
            sr_fields "$line"; type=${F[0]}; path=${F[1]}
            [[ $type == F && $path != /install/* ]] || continue
            physical=$tmp/root$path
            if sr_elf "$physical"; then
                sr_record "$path" "$E_ID" >> "$tmp/elfs"; found=1
            fi
        done < "$tmp/files"
        cp -- "$input" "$tmp/$full.${input##*.}" || return 1
        printf '%s\n' "$full" > "$tmp/name"; : > "$tmp/complete"
        if [[ -e $dir ]]; then rm -rf -- "$dir"; fi
        mv -- "$tmp" "$dir" || return 1
    fi
    PK_DIR["$id"]=$dir; PK_FULL["$id"]=$full; PK_BASE["$id"]=$base; PK_ARCH["$id"]=$arch
    PK_ARCHIVE["$id"]=$dir/$full.${input##*.}; PK_HASH["$id"]=$content; PK_ORIGIN["$id"]=$origin
    PK_ELFS["$id"]=$dir/elfs; PK_SCRIPT["$id"]=absent
    while IFS= read -r line; do
        sr_fields "$line"; [[ ${F[0]} != SCRIPT ]] || PK_SCRIPT["$id"]=${F[1]}
    done < "$dir/files"
    A_ID=$id
}
