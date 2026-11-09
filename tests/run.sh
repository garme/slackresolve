#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -o pipefail
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
CLI=$PROJECT/bin/slackresolve
source "$PROJECT/tests/fixtures.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/slackresolve-tests.XXXXXXXX") || exit 1
trap '[[ ${KEEP_TEST_WORK:-0} == 1 ]] || rm -rf -- "$WORK"' EXIT
printf 'Building real ELF fixtures...\n'
fixture_make "$WORK/fixtures" || exit 1
export FIX_REPO FIX_DIR
PASSED=0; FAILED=0
expect() {
    local expected=$1; shift
    "$@" > "$CASE/output" 2>&1
    local status=$?
    if [[ $status != "$expected" ]]; then printf 'Expected exit %s, got %s\n' "$expected" "$status"; cat "$CASE/output"; return 1; fi
}
contains() { grep -Fq -- "$2" "$1" || { printf 'Missing text: %s\n' "$2"; cat "$1"; return 1; }; }
case_setup() {
    CASE=$WORK/case-$1; ROOT=$CASE/root; mkdir -p "$CASE/repo" "$CASE/mock"; fixture_root "$ROOT"
    OPTS=(--root "$ROOT" --cache "$WORK/cache")
}
run_case() {
    local name=$1; shift
    [[ -z ${TEST_FILTER:-} || $name =~ $TEST_FILTER ]] || return 0
    if "$@" > "$WORK/$name.log" 2>&1; then printf 'PASS %s\n' "$name"; ((PASSED+=1))
    else printf 'FAIL %s\n' "$name"; cat "$WORK/$name.log"; ((FAILED+=1)); fi
}
make_mock_pkgtools() {
    cat > "$CASE/mock/installpkg" <<'EOF'
#!/bin/bash
set -e
archive=$1; full=${archive##*/}; full=${full%.txz}
printf 'install %s\n' "$full" >> "$ROOT/operations"
tar -xf "$archive" -C "$ROOT"
[[ ! -f $ROOT/install/doinst.sh ]] || (cd "$ROOT" && bash install/doinst.sh)
{ printf 'PACKAGE NAME: %s\nFILE LIST:\n' "$full"; tar -tf "$archive"; } > "$ROOT/var/lib/pkgtools/packages/$full"
rm -rf "$ROOT/install"
EOF
    cat > "$CASE/mock/upgradepkg" <<'EOF'
#!/bin/bash
set -e
operation=${!#}; old=${operation%%%*}; archive=${operation#*%}; full=${archive##*/}; full=${full%.txz}; base=${full%-*-*-*}
[[ -n $old ]] || exit 3
printf 'upgrade %s -> %s\n' "$old" "$full" >> "$ROOT/operations"
rm -f "$ROOT/var/lib/pkgtools/packages/$old"
tar -xf "$archive" -C "$ROOT"
[[ ! -f $ROOT/install/doinst.sh ]] || (cd "$ROOT" && bash install/doinst.sh)
{ printf 'PACKAGE NAME: %s\nFILE LIST:\n' "$full"; tar -tf "$archive"; } > "$ROOT/var/lib/pkgtools/packages/$full"
rm -rf "$ROOT/install"
EOF
    chmod +x "$CASE/mock/installpkg" "$CASE/mock/upgradepkg"
}
t_program_missing() {
    case_setup program; fixture_install "$ROOT" "$FIX_REPO/srtest-app-1.0-x86_64-1.txz"
    cp "$FIX_REPO/srtest-lib-1.0-x86_64-1.txz" "$CASE/repo/"
    expect 0 "$CLI" check-program "$ROOT/usr/bin/srtest-app" --repo "$CASE/repo" --output "$CASE/program.plan" "${OPTS[@]}" || return
    contains "$CASE/output" 'Status: ready' || return
    contains "$CASE/output" 'install  srtest-lib-1.0-x86_64-1'
}
t_program_healthy() {
    case_setup healthy
    fixture_install "$ROOT" "$FIX_REPO/srtest-lib-1.0-x86_64-1.txz"
    fixture_install "$ROOT" "$FIX_REPO/srtest-app-1.0-x86_64-1.txz"
    expect 0 "$CLI" check-program "$ROOT/usr/bin/srtest-app" --repo "$CASE/repo" --output "$CASE/unused.plan" "${OPTS[@]}" || return
    contains "$CASE/output" 'No package operation is required' || return
    [[ ! -e $CASE/unused.plan ]]
}
t_system() {
    case_setup system; fixture_install "$ROOT" "$FIX_REPO/srtest-app-1.0-x86_64-1.txz"
    cp "$FIX_REPO/srtest-lib-1.0-x86_64-1.txz" "$CASE/repo/"
    expect 0 "$CLI" check-system --repo "$CASE/repo" --output "$CASE/system.plan" "${OPTS[@]}" || return
    contains "$CASE/output" 'Status: ready' || return
    contains "$CASE/output" 'srtest-lib-1.0-x86_64-1'
}
t_recursive_install() {
    case_setup recursive
    cp "$FIX_REPO/srleaf-1.0-x86_64-1.txz" "$FIX_REPO/srchain-1.0-x86_64-1.txz" "$CASE/repo/"
    expect 0 "$CLI" install "$FIX_REPO/srchain-app-1.0-x86_64-1.txz" --repo "$CASE/repo" --output "$CASE/install.plan" "${OPTS[@]}" || return
    contains "$CASE/output" 'install  srleaf-1.0-x86_64-1' || return
    contains "$CASE/output" 'install  srchain-1.0-x86_64-1' || return
    contains "$CASE/output" 'install  srchain-app-1.0-x86_64-1'
}
t_search_file_recursive() {
    case_setup filesearch
    cp "$FIX_REPO/srleaf-1.0-x86_64-1.txz" "$FIX_REPO/srchain-1.0-x86_64-1.txz" "$CASE/repo/"
    expect 0 "$CLI" search-file libsrchain.so.1 --repo "$CASE/repo" --output "$CASE/file.plan" "${OPTS[@]}" || return
    contains "$CASE/output" 'Selected provider: srchain-1.0-x86_64-1' || return
    contains "$CASE/output" 'install  srleaf-1.0-x86_64-1' || return
    contains "$CASE/output" 'Status: ready'
}
t_search_data_file() {
    case_setup datafile
    mkdir -p "$CASE/tree/usr/share/example"
    printf 'fixture data\n' > "$CASE/tree/usr/share/example/data.dat"
    tar -cJf "$CASE/repo/example-data-1.0-noarch-1.txz" -C "$CASE/tree" .
    expect 0 "$CLI" search-file /usr/share/example/data.dat --repo "$CASE/repo" --output "$CASE/data.plan" "${OPTS[@]}" || return
    contains "$CASE/output" 'Selected provider: example-data-1.0-noarch-1' || return
    contains "$CASE/output" 'Status: ready'
}
t_search_file_ambiguity() {
    case_setup fileambiguity
    cp "$FIX_REPO/srtest-lib-1.0-x86_64-1.txz" "$CASE/repo/file-provider-a-1.0-x86_64-1.txz"
    cp "$FIX_REPO/srtest-lib-1.0-x86_64-1.txz" "$CASE/repo/file-provider-b-1.0-x86_64-1.txz"
    expect 1 "$CLI" search-file libsrtest.so.1 --repo "$CASE/repo" --output "$CASE/a.plan" "${OPTS[@]}" || return
    contains "$CASE/output" 'Several equally preferred packages' || return
    expect 0 "$CLI" search-file libsrtest.so.1 --repo "$CASE/repo" --prefer file-provider-b --output "$CASE/b.plan" "${OPTS[@]}" || return
    contains "$CASE/output" 'Selected provider: file-provider-b-1.0-x86_64-1'
}
t_apply() {
    case_setup apply; make_mock_pkgtools
    cp "$FIX_REPO/srleaf-1.0-x86_64-1.txz" "$FIX_REPO/srchain-1.0-x86_64-1.txz" "$CASE/repo/"
    expect 0 "$CLI" install "$FIX_REPO/srchain-app-1.0-x86_64-1.txz" --repo "$CASE/repo" --output "$CASE/apply.plan" "${OPTS[@]}" || return
    expect 0 "$CLI" apply "$CASE/apply.plan" --dry-run --cache "$WORK/cache" || return
    contains "$CASE/output" 'Would install: srleaf' || return
    expect 0 env PATH="$CASE/mock:$PATH" "$CLI" apply "$CASE/apply.plan" --cache "$WORK/cache" || return
    [[ $(wc -l < "$ROOT/operations") == 3 ]] || return 1
    [[ $(head -1 "$ROOT/operations") == 'install srleaf-1.0-x86_64-1' ]] || return 1
    expect 0 env PATH="$CASE/mock:$PATH" "$CLI" verify "$CASE/apply.plan" --cache "$WORK/cache"
}
t_upgrade() {
    case_setup upgrade; make_mock_pkgtools
    cp "$FIX_REPO/srversion-old-1.0-x86_64-1.txz" "$CASE/srversion-1.0-x86_64-1.txz"
    cp "$FIX_REPO/srversion-new-2.0-x86_64-1.txz" "$CASE/srversion-2.0-x86_64-1.txz"
    fixture_install "$ROOT" "$CASE/srversion-1.0-x86_64-1.txz"
    expect 0 "$CLI" install "$CASE/srversion-2.0-x86_64-1.txz" --output "$CASE/upgrade.plan" --repo "$CASE/repo" "${OPTS[@]}" || return
    contains "$CASE/output" 'upgrade  srversion-2.0-x86_64-1' || return
    expect 0 env PATH="$CASE/mock:$PATH" "$CLI" apply "$CASE/upgrade.plan" --cache "$WORK/cache" || return
    contains "$ROOT/operations" 'upgrade srversion-1.0-x86_64-1 -> srversion-2.0-x86_64-1'
}
t_upgrade_breakage() {
    case_setup breakage
    cp "$FIX_REPO/srversion-old-1.0-x86_64-1.txz" "$CASE/srversion-1.0-x86_64-1.txz"
    cp "$FIX_REPO/srversion-new-2.0-x86_64-1.txz" "$CASE/srversion-2.0-x86_64-1.txz"
    fixture_install "$ROOT" "$CASE/srversion-1.0-x86_64-1.txz"
    fixture_install "$ROOT" "$FIX_REPO/srversion-old-client-1.0-x86_64-1.txz"
    expect 1 "$CLI" install "$CASE/srversion-2.0-x86_64-1.txz" --output "$CASE/blocked.plan" --repo "$CASE/repo" "${OPTS[@]}" || return
    contains "$CASE/output" 'missing symbol version: SRTEST_1.0' || return
    contains "$CASE/output" 'Status: incomplete'
}
t_parallel_versions() {
    case_setup parallel
    cp "$FIX_REPO/srtest-lib-1.0-x86_64-1.txz" "$CASE/srparallel-1.0-x86_64-1.txz"
    cp "$FIX_REPO/srtest-compat2-2.0-x86_64-1.txz" "$CASE/srparallel-2.0-x86_64-1.txz"
    fixture_install "$ROOT" "$CASE/srparallel-1.0-x86_64-1.txz"
    expect 0 "$CLI" install "$CASE/srparallel-2.0-x86_64-1.txz" --output "$CASE/parallel.plan" --repo "$CASE/repo" "${OPTS[@]}" || return
    contains "$CASE/output" 'install  srparallel-2.0-x86_64-1'
}
t_ambiguity() {
    case_setup ambiguity
    cp "$FIX_REPO/srtest-lib-1.0-x86_64-1.txz" "$CASE/repo/alternative-a-1.0-x86_64-1.txz"
    cp "$FIX_REPO/srtest-lib-1.0-x86_64-1.txz" "$CASE/repo/alternative-b-1.0-x86_64-1.txz"
    fixture_install "$ROOT" "$FIX_REPO/srtest-app-1.0-x86_64-1.txz"
    expect 1 "$CLI" check-program "$ROOT/usr/bin/srtest-app" --repo "$CASE/repo" --output "$CASE/a.plan" "${OPTS[@]}" || return
    contains "$CASE/output" 'Several complete provider selections' || return
    expect 0 "$CLI" check-program "$ROOT/usr/bin/srtest-app" --repo "$CASE/repo" --prefer alternative-b --output "$CASE/b.plan" "${OPTS[@]}"
}
t_unknown_script() {
    case_setup script; mkdir -p "$CASE/tree/usr/bin" "$CASE/tree/install"
    cp "$FIX_DIR/build/app" "$CASE/tree/usr/bin/app"
    printf 'touch /MUST_NOT_RUN\n' > "$CASE/tree/install/doinst.sh"
    tar -cJf "$CASE/unsafe-1.0-x86_64-1.txz" -C "$CASE/tree" .
    cp "$FIX_REPO/srtest-lib-1.0-x86_64-1.txz" "$CASE/repo/"
    expect 1 "$CLI" install "$CASE/unsafe-1.0-x86_64-1.txz" --output "$CASE/unsafe.plan" --repo "$CASE/repo" "${OPTS[@]}" || return
    contains "$CASE/output" 'installation script contains effects' || return
    contains "$CASE/output" 'install  srtest-lib-1.0-x86_64-1' || return
    [[ ! -e /MUST_NOT_RUN ]]
}
t_modeled_gdk_pixbuf_script() {
    case_setup gdk-script; mkdir -p "$CASE/tree/usr/share/example" "$CASE/tree/install"
    printf 'cache fixture\n' > "$CASE/tree/usr/share/example/cache.dat"
    cat > "$CASE/tree/install/doinst.sh" <<'EOF'
if [ -x usr/bin/update-gdk-pixbuf-loaders ]; then
  chroot . /usr/bin/update-gdk-pixbuf-loaders
fi
EOF
    tar -cJf "$CASE/gdk-cache-1.0-noarch-1.txz" -C "$CASE/tree" .
    expect 0 "$CLI" install "$CASE/gdk-cache-1.0-noarch-1.txz" --output "$CASE/gdk.plan" --repo "$CASE/repo" "${OPTS[@]}" || return
    contains "$CASE/output" 'Status: ready' || return
    ! grep -Fq $'ISSUE\tunconfirmed\t/install/doinst.sh' "$CASE/gdk.plan"
}
t_slackpkg() {
    case_setup slackpkg; mkdir -p "$CASE/data" "$CASE/downloads"
    fixture_install "$ROOT" "$FIX_REPO/srtest-app-1.0-x86_64-1.txz"
    printf 'slackware64 srtest-lib 1.0 x86_64 1 srtest-lib-1.0-x86_64-1 ./slackware64/l txz\n' > "$CASE/data/pkglist"
    local digest; digest=$(md5sum "$FIX_REPO/srtest-lib-1.0-x86_64-1.txz")
    printf '%s  ./slackware64/l/srtest-lib-1.0-x86_64-1.txz\n' "${digest:0:32}" > "$CASE/data/CHECKSUMS.md5"
    cat > "$CASE/mock/slackpkg" <<'EOF'
#!/bin/bash
if [[ $* == *'file-search libsrtest.so.1'* ]]; then
    printf '[uninstalled] - srtest-lib-1.0-x86_64-1\n'
elif [[ $* == *'-checkgpg=on'* && $* == *'-checkmd5=on'* && $* == *'download srtest-lib-1.0-x86_64-1'* ]]; then
    cp "$SR_TEST_FIXTURE" "$SR_TEST_DOWNLOAD/"
    printf signature > "$SR_TEST_DOWNLOAD/${SR_TEST_FIXTURE##*/}.asc"
else exit 9
fi
EOF
    printf '#!/bin/bash\nexit 0\n' > "$CASE/mock/gpg"
    chmod +x "$CASE/mock/slackpkg" "$CASE/mock/gpg"
    expect 0 env PATH="$CASE/mock:$PATH" SR_TEST_FIXTURE="$FIX_REPO/srtest-lib-1.0-x86_64-1.txz" SR_TEST_DOWNLOAD="$CASE/downloads" \
        "$CLI" search-file libsrtest.so.1 --repo slackpkg --slackpkg-data "$CASE/data" --slackpkg-cache "$CASE/downloads" --output "$CASE/official.plan" "${OPTS[@]}" || return
    contains "$CASE/output" 'Status: ready'
}
t_slackpkg_i586() {
    case_setup slackpkg-i586; mkdir -p "$CASE/data" "$CASE/downloads" "$CASE/tree/usr/lib"
    rm -rf "$ROOT/lib64" "$ROOT/usr/lib64"
    rm -f "$ROOT/var/lib/pkgtools/packages/loader-1.0-x86_64-1"
    mkdir -p "$ROOT/lib" "$ROOT/usr/lib"
    printf 'PACKAGE NAME: aaa_base-15.0-i586-4\nFILE LIST:\n' > "$ROOT/var/lib/pkgtools/packages/aaa_base-15.0-i586-4"
    printf 'synthetic exact-name fixture\n' > "$CASE/tree/usr/lib/librsvg-2.so.2"
    tar -cJf "$CASE/librsvg-2.52.5-i586-1.txz" -C "$CASE/tree" .
    printf 'slackware librsvg 2.52.5 i586 1 librsvg-2.52.5-i586-1 ./slackware/l txz\n' > "$CASE/data/pkglist"
    local digest; digest=$(md5sum "$CASE/librsvg-2.52.5-i586-1.txz")
    printf '%s  ./slackware/l/librsvg-2.52.5-i586-1.txz\n' "${digest:0:32}" > "$CASE/data/CHECKSUMS.md5"
    cat > "$CASE/mock/slackpkg" <<'EOF'
#!/bin/bash
if [[ $* == *'file-search librsvg-2.so.2'* ]]; then
    printf '[uninstalled] - librsvg-2.52.5-i586-1\n'
elif [[ $* == *'-checkgpg=on'* && $* == *'-checkmd5=on'* && $* == *'download librsvg-2.52.5-i586-1'* ]]; then
    cp "$SR_TEST_FIXTURE" "$SR_TEST_DOWNLOAD/"
    printf signature > "$SR_TEST_DOWNLOAD/${SR_TEST_FIXTURE##*/}.asc"
else exit 9
fi
EOF
    printf '#!/bin/bash\nexit 0\n' > "$CASE/mock/gpg"
    chmod +x "$CASE/mock/slackpkg" "$CASE/mock/gpg"
    expect 0 env PATH="$CASE/mock:$PATH" SR_TEST_FIXTURE="$CASE/librsvg-2.52.5-i586-1.txz" SR_TEST_DOWNLOAD="$CASE/downloads" \
        "$CLI" search-file librsvg-2.so.2 --repo slackpkg --slackpkg-data "$CASE/data" --slackpkg-cache "$CASE/downloads" --output "$CASE/i586.plan" "${OPTS[@]}" || return
    contains "$CASE/output" 'Selected provider: librsvg-2.52.5-i586-1' || return
    contains "$CASE/output" 'Status: ready' || return
    grep -Fq $'META\tarchitecture\ti586' "$CASE/i586.plan"
}
t_explicit_architecture() {
    case_setup architecture; mkdir -p "$CASE/tree/usr/share/slackresolve"
    printf 'architecture fixture\n' > "$CASE/tree/usr/share/slackresolve/architecture.dat"
    tar -cJf "$CASE/repo/arch-provider-1.0-aarch64-1.txz" -C "$CASE/tree" .
    tar -cJf "$CASE/repo/arch-provider-1.0-x86_64-1.txz" -C "$CASE/tree" .
    expect 0 "$CLI" search-file architecture.dat --arch aarch64 --repo "$CASE/repo" --output "$CASE/aarch64.plan" "${OPTS[@]}" || return
    contains "$CASE/output" 'Selected provider: arch-provider-1.0-aarch64-1' || return
    grep -Fq $'META\tarchitecture\taarch64' "$CASE/aarch64.plan"
}
t_stale() {
    case_setup stale; make_mock_pkgtools
    cp "$FIX_REPO/srtest-lib-1.0-x86_64-1.txz" "$CASE/repo/"
    expect 0 "$CLI" install "$FIX_REPO/srtest-app-1.0-x86_64-1.txz" --repo "$CASE/repo" --output "$CASE/stale.plan" "${OPTS[@]}" || return
    printf 'FILE LIST:\n' > "$ROOT/var/lib/pkgtools/packages/unrelated-1.0-x86_64-1"
    expect 1 env PATH="$CASE/mock:$PATH" "$CLI" apply "$CASE/stale.plan" --cache "$WORK/cache" || return
    contains "$CASE/output" 'package records changed'
}
t_tui() {
    case_setup tui
    cp "$FIX_REPO/srtest-lib-1.0-x86_64-1.txz" "$CASE/repo/"
    cat > "$CASE/mock/dialog" <<'EOF'
#!/bin/bash
args=("$@"); widget=; title=; fd=2
for ((i=0;i<${#args[@]};i++)); do
    case ${args[$i]} in
        --output-fd) fd=${args[$((i+1))]};; --title) title=${args[$((i+1))]};;
        --menu|--fselect|--inputbox|--gauge|--textbox|--msgbox|--yesno|--clear) widget=${args[$i]};;
    esac
done
case $widget in
    --menu)
        if [[ $title == SlackResolve ]]; then
            n=0; [[ ! -f $TUI_STATE ]] || read -r n < "$TUI_STATE"
            choices=(package exit); printf '%s\n' "${choices[$n]}" >&"$fd"; printf '%s\n' "$((n+1))" > "$TUI_STATE"
        else printf 'local\n' >&"$fd"; fi;;
    --fselect) printf '%s\n' "$TUI_PACKAGE" >&"$fd";;
    --inputbox) printf '%s\n' "$TUI_PLAN" >&"$fd";;
    --gauge) cat >/dev/null;;
    --textbox) printf '%s\n' "$title" >> "$TUI_EVENTS";;
    --clear|--msgbox|--yesno) exit 0;;
    *) exit 9;;
esac
EOF
    chmod +x "$CASE/mock/dialog"
    local invocation
    printf -v invocation '%q ' bash "$PROJECT/tests/with-terminal.sh" env TERM=xterm DIALOG="$CASE/mock/dialog" \
        TUI_STATE="$CASE/state" TUI_EVENTS="$CASE/events" TUI_PACKAGE="$FIX_REPO/srtest-app-1.0-x86_64-1.txz" TUI_PLAN="$CASE/tui.plan" \
        "$PROJECT/bin/slackresolve-tui" --root "$ROOT" --repo "$CASE/repo" --cache "$WORK/cache"
    expect 0 script -q -e -c "$invocation" /dev/null || return
    [[ -f $CASE/tui.plan ]] || return 1
    contains "$CASE/events" 'Package dependency plan - completed'
}
t_help() {
    case_setup help
    expect 0 "$CLI" --help || return
    contains "$CASE/output" 'check-program' || return
    contains "$CASE/output" 'search-file' || return
    expect 0 "$PROJECT/bin/slackresolve-tui" --help
}

run_case check-installed-program t_program_missing
run_case healthy-installed-program t_program_healthy
run_case complete-system-audit t_system
run_case recursive-package-plan t_recursive_install
run_case generic-file-search-recursive t_search_file_recursive
run_case generic-data-file-search t_search_data_file
run_case generic-file-provider-preference t_search_file_ambiguity
run_case dry-run-apply-and-verify t_apply
run_case safe-package-upgrade t_upgrade
run_case block-upgrade-breaking-old-program t_upgrade_breakage
run_case parallel-versions-without-collisions t_parallel_versions
run_case alternative-provider-preference t_ambiguity
run_case resolve-dependencies-before-unknown-script t_unknown_script
run_case model-official-gdk-pixbuf-cache-script t_modeled_gdk_pixbuf_script
run_case official-slackpkg-download-contract t_slackpkg
run_case official-slackpkg-i586-file-search t_slackpkg_i586
run_case explicit-non-x86-architecture t_explicit_architecture
run_case reject-stale-system-plan t_stale
run_case dialog-package-workflow t_tui
run_case command-interface t_help
printf '\n%s passed; %s failed.\n' "$PASSED" "$FAILED"
if (( FAILED )); then printf 'Test files: %s (set KEEP_TEST_WORK=1 to keep them).\n' "$WORK"; fi
(( FAILED == 0 ))
