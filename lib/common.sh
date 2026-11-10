# SPDX-License-Identifier: GPL-3.0-only
# Shared primitives. All persistent records are data, never sourced as shell.
SR_VERSION=0.5.0
SR_SCHEMA=4
SR_ANALYZER=5
export LC_ALL=C
umask 077

sr_die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
sr_progress() {
    SR_PERCENT=$1
    if [[ -n ${SLACKRESOLVE_PROGRESS_FILE:-} ]]; then
        printf '%s\t%s\n' "$1" "$2" > "$SLACKRESOLVE_PROGRESS_FILE.tmp" && mv -- "$SLACKRESOLVE_PROGRESS_FILE.tmp" "$SLACKRESOLVE_PROGRESS_FILE"
    fi
}
sr_log() { printf '%s\n' "$*" >&2; sr_progress "${SR_PERCENT:-0}" "$*"; }
sr_clock() { REPLY=$(date +%s%N); }
sr_seconds_since() { local now; now=$(date +%s%N); awk -v a="$1" -v b="$now" 'BEGIN{printf "%.3f",(b-a)/1000000000}'; }
sr_profile_report() {
    [[ ${SR_PROFILE:-0} == 1 ]] || return 0
    printf '\nPerformance profile\n'
    printf '  Total time:                 %s s\n' "$(sr_seconds_since "$SR_PROFILE_STARTED")"
    printf '  Initialization:             %s s\n' "${SR_PROFILE_INIT_SECONDS:-0.000}"
    printf '  Repository/index loading:   %s s\n' "${SR_PROFILE_REPO_SECONDS:-0.000}"
    printf '  Initial input analysis:     %s s\n' "${SR_PROFILE_INPUT_SECONDS:-0.000}"
    printf '  Dependency solving:         %s s\n' "${SR_PROFILE_SOLVER_SECONDS:-0.000}"
    printf '  Plan serialization:         %s s\n' "${SR_PROFILE_PLAN_SECONDS:-0.000}"
    printf '  Repository index:           %s\n' "$([[ ${SR_REPOSITORY_INDEX_HIT:-0} == 1 ]] && printf cached || printf rebuilt)"
    printf '  Installed-system index:     %s\n' "$([[ ${SR_SYSTEM_INDEX_HIT:-0} == 1 ]] && printf cached || printf rebuilt)"
    printf '  Direct provider lookups:    %s\n' "${SR_PROFILE_LOOKUPS:-0}"
    printf '  slackpkg file-search calls: %s\n' "${SR_PROFILE_FALLBACKS:-0}"
    printf '  Package cache hits:         %s\n' "${SR_PROFILE_PACKAGE_HITS:-0}"
    printf '  Package downloads:          %s\n' "${SR_PROFILE_DOWNLOADS:-0}"
    printf '  Package analyses:           %s\n' "${SR_PROFILE_PACKAGE_ANALYSES:-0}"
    printf '  Package-analysis hits:      %s\n' "${SR_PROFILE_OBJECT_HITS:-0}"
    printf '  ELF analyses:               %s\n' "${SR_PROFILE_ELF_ANALYSES:-0}"
    printf '  ELF cache hits:             %s\n' "${SR_PROFILE_ELF_HITS:-0}"
    printf '  Graph passes:               %s\n' "${SR_PROFILE_GRAPH_PASSES:-0}"
    printf '  Reused graph states:        %s\n' "${SR_PROFILE_GRAPH_HITS:-0}"
    printf '  ELF analysis jobs:          %s\n' "${SR_JOBS:-1}"
}
sr_encode() {
    REPLY=$1
    REPLY=${REPLY//%/%25}; REPLY=${REPLY//$'\t'/%09}
    REPLY=${REPLY//$'\n'/%0A}; REPLY=${REPLY//$'\r'/%0D}
    [[ -n $REPLY ]] || REPLY=%00
}
sr_decode() {
    REPLY=$1
    if [[ $REPLY == %00 ]]; then REPLY=; return; fi
    REPLY=${REPLY//%09/$'\t'}; REPLY=${REPLY//%0A/$'\n'}
    REPLY=${REPLY//%0D/$'\r'}; REPLY=${REPLY//%25/%}
}
sr_record() {
    local field sep=
    for field in "$@"; do
        sr_encode "$field"; printf '%s%s' "$sep" "$REPLY"; sep=$'\t'
    done
    printf '\n'
}
sr_fields() {
    local line=$1 i
    IFS=$'\t' read -r -a F <<< "$line"
    for i in "${!F[@]}"; do sr_decode "${F[$i]}"; F[$i]=$REPLY; done
}
sr_hash() { local v; v=$(sha256sum -- "$1") || return; REPLY=${v:0:64}; }
sr_norm() { REPLY=$(realpath -ms -- "$1") || return; }
sr_control_path() { [[ $1 != *[$'\001'-$'\037'$'\177']* && $1 != *'\'* ]]; }
sr_package_name() {
    local name=${1##*/}
    name=${name%.txz}; name=${name%.tgz}; name=${name%.tlz}; name=${name%.tbz}
    [[ $name =~ ^(.+)-([^-]+)-([^-]+)-([^-]+)$ ]] || return 1
    P_FULL=$name; P_BASE=${BASH_REMATCH[1]}; P_VER=${BASH_REMATCH[2]}
    P_ARCH=${BASH_REMATCH[3]}; P_BUILD=${BASH_REMATCH[4]}
}
sr_arch_valid() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; }
sr_arch_compatible() {
    local package_arch=$1 target=${SR_TARGET_ARCH:-}
    [[ $package_arch == noarch ]] && return 0
    [[ -n $target ]] || return 1
    case $target in
        i?86) [[ $package_arch =~ ^i[3-6]86$ ]];;
        *) [[ $package_arch == "$target" ]];;
    esac
}
sr_target_profile() {
    local detected= arch count best=0 machine
    if [[ -n ${SR_ARCH_OVERRIDE:-} ]]; then
        sr_arch_valid "$SR_ARCH_OVERRIDE" || sr_die "Invalid target architecture: $SR_ARCH_OVERRIDE"
        detected=$SR_ARCH_OVERRIDE
    else
        for arch in "${!SR_ARCH_COUNTS[@]}"; do
            count=${SR_ARCH_COUNTS[$arch]}
            if (( count > best )); then detected=$arch; best=$count; fi
        done
        if [[ -z $detected ]]; then
            machine=$(uname -m 2>/dev/null || printf unknown)
            detected=$machine
        fi
    fi
    sr_arch_valid "$detected" || sr_die 'Could not determine a safe target architecture.'
    SR_TARGET_ARCH=$detected
    if [[ -d ${SR_ROOT%/}/lib64 || -d ${SR_ROOT%/}/usr/lib64 ]]; then
        SR_LIB_TOKEN=lib64
    else
        SR_LIB_TOKEN=lib
    fi
    SR_PLATFORM=$SR_TARGET_ARCH
}
sr_init() {
    [[ ${BASH_VERSINFO[0]} -ge 4 ]] || sr_die 'Bash 4 or later is required.'
    local c
    for c in awk tar readelf sha256sum find sort realpath readlink stat mktemp cp mv grep cmp flock; do
        command -v "$c" >/dev/null || sr_die "Required command not found: $c"
    done
    SR_ROOT=${SR_ROOT:-/}; sr_norm "$SR_ROOT"; SR_ROOT=${REPLY%/}; [[ -n $SR_ROOT ]] || SR_ROOT=/
    [[ -d $SR_ROOT ]] || sr_die "Target root not found: $SR_ROOT"
    SR_CACHE=${SR_CACHE:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/slackresolve}
    mkdir -p -- "$SR_CACHE" || sr_die 'Could not create the cache directory.'
    sr_norm "$SR_CACHE"; SR_CACHE=$REPLY
    SR_WORK=$(mktemp -d "$SR_CACHE/work.XXXXXXXX") || sr_die 'Could not create the work directory.'
    trap '[[ -z ${SR_WORK:-} ]] || rm -rf -- "$SR_WORK"' EXIT
    mkdir -p -- "$SR_CACHE/archives" "$SR_CACHE/objects" "$SR_CACHE/elf/$SR_ANALYZER" \
        "$SR_CACHE/indexes" "$SR_CACHE/searches" "$SR_CACHE/sessions" "$SR_CACHE/system-index"
    SR_PKGDB=
    for c in /var/lib/pkgtools/packages /var/log/packages /var/adm/packages; do
        if [[ -d ${SR_ROOT%/}$c ]]; then SR_PKGDB=${SR_ROOT%/}$c; break; fi
    done
    SR_RELEASE=unknown
    [[ ! -f ${SR_ROOT%/}/etc/slackware-version ]] || IFS= read -r SR_RELEASE < "${SR_ROOT%/}/etc/slackware-version"
    SR_BLACKLIST=${SR_BLACKLIST:-${SR_ROOT%/}/etc/slackpkg/blacklist}
    SR_SLACK_DATA=${SR_SLACK_DATA:-/var/lib/slackpkg}
    SR_SLACK_CACHE=${SR_SLACK_CACHE:-/var/cache/packages}
    : > "$SR_WORK/blacklist"
    if [[ -f $SR_BLACKLIST ]]; then
        awk 'sub(/#.*/, "") { } {gsub(/^[ \t]+|[ \t]+$/, ""); if(length) print}' "$SR_BLACKLIST" > "$SR_WORK/blacklist"
    fi
    sr_system_index_load || sr_die 'Could not build the installed-system index.'
    sr_target_profile
    declare -gA M_LOADED=() M_CLASS=() M_MACHINE=() M_ENDIAN=() M_TYPE=()
    declare -gA M_NEEDED=() M_SONAME=() M_RPATH=() M_RUNPATH=() M_INTERP=()
    declare -gA M_VNEED=() M_SREQ=() M_SDEF=() M_VDEF=() M_FLAGS=() ELF_ID=()
    declare -gA PK_ARCHIVE=() PK_HASH=() PK_DIR=() PK_FULL=() PK_BASE=()
    declare -gA PK_ARCH=() PK_ORIGIN=() PK_ELFS=() PK_SCRIPT=()
    declare -gA PK_ACTION=() PK_PREVIOUS=()
    declare -gA OV_TYPE=() OV_SOURCE=() OV_OWNER=() GUARD_KIND=() GUARD_VALUE=()
    declare -ga SELECTED=() ROOT_PACKAGES=() REPO_IDS=() LD_PATHS=() AUDIT_ROOTS=()
    declare -gA RP_PATH=() RP_RANK=() RP_ORIGIN=() RP_FULL=() RP_BASE=()
    declare -gA RP_MANIFEST=() RP_ARCH=() RP_BY_FULL=() RP_FETCHED_ID=()
    declare -gA RP_CACHE_FILE=() RP_MD5_FILE=()
    declare -gA PROVIDER_RIDS=() SEARCH_RESULT=() SELECTED_SET=()
    declare -gA CANDIDATE_RESULT=()
    declare -gA GRAPH_CONSUMER_EID=()
    SR_SEARCH_COUNT=0; SR_LIMIT_HIT=0; SR_BEST_DEPTH=-1; SR_BEST_SELECTED=
    SR_PROFILE_LOOKUPS=0; SR_PROFILE_FALLBACKS=0; SR_PROFILE_DOWNLOADS=0; SR_PROFILE_PACKAGE_HITS=0
    SR_PROFILE_PACKAGE_ANALYSES=0; SR_PROFILE_OBJECT_HITS=0; SR_PROFILE_ELF_ANALYSES=0; SR_PROFILE_ELF_HITS=0; SR_PROFILE_GRAPH_PASSES=0; SR_PROFILE_GRAPH_HITS=0
    mkdir -p -- "$SR_WORK/graph-cache"
    : > "$SR_WORK/rejections"; : > "$SR_WORK/solutions"
    sr_loader_paths
}
sr_blocked() {
    local value=$1
    [[ -s $SR_WORK/blacklist ]] || return 1
    printf '%s\n' "$value" | grep -Eq -f "$SR_WORK/blacklist"
}
sr_guard() {
    local path=$1 physical=${SR_ROOT%/}$1 kind value
    [[ ${GUARD_KIND[$path]+yes} ]] && return
    if [[ -L $physical ]]; then kind=link; value=$(readlink -- "$physical") || return
    elif [[ -f $physical ]]; then kind=file; sr_hash "$physical" || return; value=$REPLY
    elif [[ -d $physical ]]; then kind=directory; value=$(stat -c '%a' -- "$physical")
    elif [[ -e $physical ]]; then kind=special; value=$(stat -c '%F:%a' -- "$physical")
    else kind=absent; value=; fi
    GUARD_KIND["$path"]=$kind; GUARD_VALUE["$path"]=$value
}
sr_loader_paths() {
    local dir file line
    if [[ $SR_LIB_TOKEN == lib64 ]]; then
        LD_PATHS=(/lib64 /usr/lib64 /lib /usr/lib)
    else
        LD_PATHS=(/lib /usr/lib)
    fi
    : > "$SR_WORK/ldcache"
    if command -v ldconfig >/dev/null && [[ -f ${SR_ROOT%/}/etc/ld.so.cache ]]; then
        ldconfig -p -C "${SR_ROOT%/}/etc/ld.so.cache" 2>/dev/null |
            awk '/=>/ {print $1 "\t" $NF}' > "$SR_WORK/ldcache" || :
        sr_guard /etc/ld.so.cache
    fi
    # These are hints for repository reachability, not a replacement for ld.so.
    file=${SR_ROOT%/}/etc/ld.so.conf
    if [[ -f $file ]]; then
        sr_guard /etc/ld.so.conf
        while IFS= read -r line; do
            line=${line%%#*}; [[ -n $line ]] || continue
            [[ $line == /* ]] && LD_PATHS+=("$line")
        done < "$file"
    fi
    [[ ! -e ${SR_ROOT%/}/etc/slackware-version ]] || sr_guard /etc/slackware-version
}
