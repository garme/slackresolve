# SPDX-License-Identifier: GPL-3.0-only
# Small, real ELF objects; no Python or external test framework.
fixture_package() {
    local tree=$1 name=$2
    mkdir -p "$tree/install"
    printf '%s: synthetic integration fixture\n' "${name%%-*}" > "$tree/install/slack-desc"
    tar -cJf "$FIX_REPO/$name.txz" -C "$tree" . || return 1
}
fixture_record() {
    local root=$1 archive=$2 full=${2##*/}
    full=${full%.txz}; mkdir -p "$root/var/lib/pkgtools/packages"
    { printf 'PACKAGE NAME: %s\nFILE LIST:\n' "$full"; tar -tf "$archive"; } > "$root/var/lib/pkgtools/packages/$full"
}
fixture_root() {
    local root=$1 loader
    mkdir -p "$root"/{etc,lib64,usr/lib64,usr/bin,var/lib/pkgtools/packages,var/lock,var/cache/ldconfig}
    printf 'Slackware 15.0\n' > "$root/etc/slackware-version"
    : > "$root/etc/ld.so.conf"
    loader=$(readlink -f /lib64/ld-linux-x86-64.so.2)
    cp "$loader" "$root/lib64/ld-linux-x86-64.so.2"
    printf 'PACKAGE NAME: loader-1.0-x86_64-1\nFILE LIST:\nlib64/ld-linux-x86-64.so.2\n' > "$root/var/lib/pkgtools/packages/loader-1.0-x86_64-1"
}
fixture_install() {
    local root=$1 archive=$2
    tar -xf "$archive" -C "$root"
    if [[ -f $root/install/doinst.sh ]]; then (cd "$root" && bash install/doinst.sh); fi
    fixture_record "$root" "$archive"
    rm -rf "$root/install"
}
fixture_make() {
    FIX_DIR=$1; FIX_REPO=$FIX_DIR/repo
    mkdir -p "$FIX_REPO" "$FIX_DIR/build" "$FIX_DIR/src"
    local b=$FIX_DIR/build s=$FIX_DIR/src tree
    cat > "$s/start.c" <<'EOF'
extern int answer(void);
void _start(void) {
    long result=answer();
    __asm__ volatile("syscall" : : "a"(60L), "D"(result) : "rcx", "r11", "memory");
    __builtin_unreachable();
}
EOF
    printf 'int answer(void){return 42;}\n' > "$s/simple.c"
    gcc -fPIC -shared -nostdlib -Wl,-soname,libsrtest.so.1 "$s/simple.c" -o "$b/libsrtest.so.1" || return 1
    gcc -nostdlib -fno-stack-protector "$s/start.c" -L"$b" -Wl,--no-as-needed -l:libsrtest.so.1 -o "$b/app" || return 1
    tree=$FIX_DIR/tree-simple; mkdir -p "$tree/usr/lib64"; cp "$b/libsrtest.so.1" "$tree/usr/lib64/"
    fixture_package "$tree" 'srtest-lib-1.0-x86_64-1'
    tree=$FIX_DIR/tree-app; mkdir -p "$tree/usr/bin"; cp "$b/app" "$tree/usr/bin/srtest-app"
    fixture_package "$tree" 'srtest-app-1.0-x86_64-1'

    printf 'int leaf(void){return 21;}\n' > "$s/leaf.c"
    printf 'extern int leaf(void);int answer(void){return leaf()*2;}\n' > "$s/mid.c"
    gcc -fPIC -shared -nostdlib -Wl,-soname,libsrleaf.so.1 "$s/leaf.c" -o "$b/libsrleaf.so.1" || return 1
    gcc -fPIC -shared -nostdlib -Wl,-soname,libsrchain.so.1 "$s/mid.c" -L"$b" -Wl,--no-as-needed -l:libsrleaf.so.1 -o "$b/libsrchain.so.1" || return 1
    gcc -nostdlib -fno-stack-protector "$s/start.c" -L"$b" -Wl,--no-as-needed -l:libsrchain.so.1 -Wl,-rpath-link,"$b" -o "$b/chain-app" || return 1
    tree=$FIX_DIR/tree-leaf; mkdir -p "$tree/usr/lib64"; cp "$b/libsrleaf.so.1" "$tree/usr/lib64/"
    fixture_package "$tree" 'srleaf-1.0-x86_64-1'
    tree=$FIX_DIR/tree-chain; mkdir -p "$tree/usr/lib64"; cp "$b/libsrchain.so.1" "$tree/usr/lib64/"
    fixture_package "$tree" 'srchain-1.0-x86_64-1'
    tree=$FIX_DIR/tree-chainapp; mkdir -p "$tree/usr/bin"; cp "$b/chain-app" "$tree/usr/bin/srchain-app"
    fixture_package "$tree" 'srchain-app-1.0-x86_64-1'

    printf 'SRTEST_1.0 {global: answer; local: *;};\n' > "$s/old.map"
    printf 'SRTEST_2.0 {global: answer; local: *;};\n' > "$s/new.map"
    gcc -fPIC -shared -nostdlib -Wl,-soname,libsrversion.so.1 -Wl,--version-script,"$s/old.map" "$s/simple.c" -o "$b/old.so" || return 1
    gcc -fPIC -shared -nostdlib -Wl,-soname,libsrversion.so.1 -Wl,--version-script,"$s/new.map" "$s/simple.c" -o "$b/libsrversion.so.1" || return 1
    gcc -nostdlib -fno-stack-protector "$s/start.c" -L"$b" -Wl,--no-as-needed -l:libsrversion.so.1 -o "$b/version-app" || return 1
    tree=$FIX_DIR/tree-old; mkdir -p "$tree/usr/lib64"; cp "$b/old.so" "$tree/usr/lib64/libsrversion.so.1"
    fixture_package "$tree" 'srversion-old-1.0-x86_64-1'
    tree=$FIX_DIR/tree-new; mkdir -p "$tree/usr/lib64"; cp "$b/libsrversion.so.1" "$tree/usr/lib64/"
    fixture_package "$tree" 'srversion-new-2.0-x86_64-1'
    tree=$FIX_DIR/tree-versionapp; mkdir -p "$tree/usr/bin"; cp "$b/version-app" "$tree/usr/bin/srversion-app"
    fixture_package "$tree" 'srversion-app-1.0-x86_64-1'

    tree=$FIX_DIR/tree-private; mkdir -p "$tree/opt/srprivate/"{bin,lib}
    cp "$b/libsrversion.so.1" "$tree/opt/srprivate/lib/"
    gcc -nostdlib -fno-stack-protector "$s/start.c" -L"$b" -Wl,--no-as-needed -l:libsrversion.so.1 -Wl,-rpath,'$ORIGIN/../lib' -o "$tree/opt/srprivate/bin/app" || return 1
    fixture_package "$tree" 'srprivate-1.0-x86_64-1'

    tree=$FIX_DIR/tree-links; mkdir -p "$tree/usr/lib64" "$tree/install"
    cp "$b/libsrtest.so.1" "$tree/usr/lib64/libsrtest.so.1.0"
    cat > "$tree/install/doinst.sh" <<'EOF'
( cd usr/lib64 ; rm -rf libsrtest.so.1 )
( cd usr/lib64 ; ln -sf libsrtest.so.1.0 libsrtest.so.1 )
EOF
    fixture_package "$tree" 'srlinks-1.0-x86_64-1'

    tree=$FIX_DIR/tree-compat; mkdir -p "$tree/usr/lib64"
    gcc -fPIC -shared -nostdlib -Wl,-soname,libsrtest.so.2 "$s/simple.c" -o "$b/libsrtest.so.2" || return 1
    cp "$b/libsrtest.so.2" "$tree/usr/lib64/"; fixture_package "$tree" 'srtest-compat2-2.0-x86_64-1'
    tree=$FIX_DIR/tree-app2; mkdir -p "$tree/usr/bin"
    gcc -nostdlib -fno-stack-protector "$s/start.c" -L"$b" -Wl,--no-as-needed -l:libsrtest.so.2 -o "$tree/usr/bin/srtest-app2" || return 1
    fixture_package "$tree" 'srtest-app2-1.0-x86_64-1'

    mkdir -p "$b/old-version"
    cp "$b/old.so" "$b/old-version/libsrversion.so.1"
    gcc -nostdlib -fno-stack-protector "$s/start.c" -L"$b/old-version" -Wl,--no-as-needed -l:libsrversion.so.1 -o "$b/old-version/old-app" || return 1
    tree=$FIX_DIR/tree-old-client; mkdir -p "$tree/usr/bin"
    cp "$b/old-version/old-app" "$tree/usr/bin/srversion-old-client"
    fixture_package "$tree" 'srversion-old-client-1.0-x86_64-1'
    gcc -m32 -fPIC -shared -nostdlib -Wl,-soname,libsrtest.so.1 "$s/simple.c" -o "$b/wrong32.so" || return 1

    local dt
    for dt in rpath runpath; do
        tree=$FIX_DIR/tree-$dt; mkdir -p "$tree/opt/sr-$dt/"{bin,lib}
        cp "$b/libsrleaf.so.1" "$b/libsrchain.so.1" "$tree/opt/sr-$dt/lib/"
        local -a flags=(); [[ $dt != rpath ]] || flags=(-Wl,--disable-new-dtags)
        gcc -nostdlib -fno-stack-protector "$s/start.c" -L"$b" -Wl,--no-as-needed -l:libsrchain.so.1 -Wl,-rpath-link,"$b" "${flags[@]}" -Wl,-rpath,'$ORIGIN/../lib' -o "$tree/opt/sr-$dt/bin/app" || return 1
        fixture_package "$tree" "sr-$dt-1.0-x86_64-1"
    done

    printf 'int answer(void){return 42;}\n' > "$s/cycle-a.c"
    printf 'extern int answer(void);int b(void){return answer();}\n' > "$s/cycle-b.c"
    gcc -fPIC -shared -nostdlib -Wl,-soname,libsrcyclea.so.1 "$s/cycle-a.c" -o "$b/libsrcyclea.so.1" || return 1
    gcc -fPIC -shared -nostdlib -Wl,-soname,libsrcycleb.so.1 "$s/cycle-b.c" -L"$b" -Wl,--no-as-needed -l:libsrcyclea.so.1 -o "$b/libsrcycleb.so.1" || return 1
    printf 'extern int b(void);int answer(void){return b();}\n' > "$s/cycle-a.c"
    gcc -fPIC -shared -nostdlib -Wl,-soname,libsrcyclea.so.1 "$s/cycle-a.c" -L"$b" -Wl,--no-as-needed -l:libsrcycleb.so.1 -o "$b/newcycle.so" || return 1
    mv "$b/newcycle.so" "$b/libsrcyclea.so.1"
    tree=$FIX_DIR/tree-cycle; mkdir -p "$tree/usr/bin"
    gcc -nostdlib -fno-stack-protector "$s/start.c" -L"$b" -Wl,--no-as-needed -l:libsrcyclea.so.1 -Wl,-rpath-link,"$b" -o "$tree/usr/bin/cycle-app" || return 1
    fixture_package "$tree" 'srcycle-app-1.0-x86_64-1'
    for dt in a b; do
        tree=$FIX_DIR/tree-cycle-$dt; mkdir -p "$tree/usr/lib64"; cp "$b/libsrcycle$dt.so.1" "$tree/usr/lib64/"
        fixture_package "$tree" "srcycle-$dt-1.0-x86_64-1"
    done
}
