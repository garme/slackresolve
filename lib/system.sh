# SPDX-License-Identifier: GPL-3.0-only
# Persistent view of Slackware's installed package records.
sr_system_index_load() {
    declare -gA INST_BASE=() INST_BASE_LIST=() INST_FULL=() OWN=() SR_ARCH_COUNTS=()
    [[ -n $SR_PKGDB ]] || return 0
    local signature dir packages owners tmp_packages tmp_owners lock value log owner rel inlist base full arch path
    value=$(find -L "$SR_PKGDB" -maxdepth 1 -type f -printf '%f\t%s\t%T@\n' 2>/dev/null | LC_ALL=C sort | sha256sum) || return 1
    signature=${value:0:64}; dir=$SR_CACHE/system-index/$signature
    packages=$dir/packages.tsv; owners=$dir/owners.tsv
    mkdir -p -- "$dir" || return 1
    exec {lock}> "$dir/build.lock" || return 1; flock "$lock" || return 1
    if [[ ! -f $packages || ! -f $owners ]]; then
        tmp_packages=$(mktemp "$dir/packages.XXXXXXXX") || return 1
        tmp_owners=$(mktemp "$dir/owners.XXXXXXXX") || { rm -f -- "$tmp_packages"; return 1; }
        while IFS= read -r -d '' log; do
            owner=${log##*/}; sr_package_name "$owner" || continue
            printf '%s\t%s\t%s\t%s\n' "$P_BASE" "$P_FULL" "$P_ARCH" "$log" >> "$tmp_packages"
            inlist=0
            while IFS= read -r rel; do
                if [[ $rel == 'FILE LIST:' ]]; then inlist=1; continue; fi
                (( inlist )) || continue; rel=${rel#./}
                [[ -n $rel && $rel != install/* ]] || continue
                printf '/%s\t%s\n' "${rel%/}" "$owner" >> "$tmp_owners"
            done < "$log"
        done < <(find -L "$SR_PKGDB" -maxdepth 1 -type f -print0 | sort -z)
        LC_ALL=C sort -u -o "$tmp_packages" "$tmp_packages"
        LC_ALL=C sort -u -o "$tmp_owners" "$tmp_owners"
        mv -- "$tmp_packages" "$packages"; mv -- "$tmp_owners" "$owners"
        SR_SYSTEM_INDEX_HIT=0
    else SR_SYSTEM_INDEX_HIT=1; fi
    while IFS=$'\t' read -r base full arch path; do
        [[ -n $full ]] || continue
        INST_BASE["$base"]=$full; INST_BASE_LIST["$base"]+="$full"$'\n'; INST_FULL["$full"]=$path
        [[ $arch == noarch ]] || ((SR_ARCH_COUNTS["$arch"]+=1))
    done < "$packages"
    while IFS=$'\t' read -r path owner; do [[ -z $path ]] || OWN["$path"]=$owner; done < "$owners"
    SR_SYSTEM_INDEX=$dir
}
