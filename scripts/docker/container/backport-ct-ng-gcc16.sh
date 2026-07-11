#!/bin/sh
# Register GCC 16.1.0 with crosstool-NG 1.28 before and after installation.
set -eu

BACKPORT=/tmp/gcc16-backport

usage() {
    echo "usage: $0 prepare [--aarch64] | install <ct-ng-prefix> [--aarch64]" >&2
    exit 2
}

action=${1:-}
shift || true

case "$action" in
    prepare)
        aarch64=false
        if [ "${1:-}" = "--aarch64" ]; then
            aarch64=true
            shift
        fi
        [ "$#" -eq 0 ] || usage

        cp -r "$BACKPORT/packages/gcc/16.1.0" packages/gcc/
        # This workaround is only needed by the CentOS 6 glibc 2.12 build.
        rm -f packages/gcc/16.1.0/0002-libgcc-generic-morestack-guard-NR-mmap2.patch
        if "$aarch64"; then
            cp "$BACKPORT/packages/glibc/2.17/0001-aarch64-use-hidden-dl-argv-alias.patch" \
                packages/glibc/2.17/
        fi

        sed -i "s|^milestones='4.9 5 6 7 8 9 10 11 12 13 14 15'|milestones='4.9 5 6 7 8 9 10 11 12 13 14 15 16'|" \
            packages/gcc/package.desc
        grep -q "milestones='4.9 5 6 7 8 9 10 11 12 13 14 15 16'" packages/gcc/package.desc
        awk '
            /^config GCC_V_15$/ && !done {
                print "config GCC_V_16"
                print "    bool \"16.1.0\""
                print "    select GCC_later_than_15"
                print "    select GCC_15_or_later"
                print "    select GCC_later_than_14"
                print "    select GCC_14_or_later"
                print "    select GCC_later_than_13"
                print "    select GCC_13_or_later"
                print "    select GCC_later_than_12"
                print "    select GCC_12_or_later"
                print "    select GCC_later_than_11"
                print "    select GCC_11_or_later"
                print "    select GCC_later_than_10"
                print "    select GCC_10_or_later"
                print "    select GCC_later_than_9"
                print "    select GCC_9_or_later"
                print "    select GCC_later_than_8"
                print "    select GCC_8_or_later"
                print "    select GCC_later_than_7"
                print "    select GCC_7_or_later"
                print "    select GCC_later_than_6"
                print "    select GCC_6_or_later"
                print "    select GCC_later_than_5"
                print "    select GCC_5_or_later"
                print "    select GCC_later_than_4_9"
                print "    select GCC_4_9_or_later"
                print ""
                done=1
            }
            /^    default n if GCC_V_15$/ { print "    default n if GCC_V_16" }
            /^    default "15\.2\.0" if GCC_V_15$/ { print "    default \"16.1.0\" if GCC_V_16" }
            { print }
        ' config/versions/gcc.in > config/versions/gcc.in.new
        mv config/versions/gcc.in.new config/versions/gcc.in
        grep -q '^config GCC_V_16$' config/versions/gcc.in
        grep -q '^    default "16.1.0" if GCC_V_16$' config/versions/gcc.in

        awk '
            !done && /"\$\{extra_config\[@\]\}"/ {
                print
                print "        --disable-libatomic                            " sprintf("%c", 92)
                done=1
                next
            }
            { print }
        ' scripts/build/cc/gcc.sh > scripts/build/cc/gcc.sh.new
        mv scripts/build/cc/gcc.sh.new scripts/build/cc/gcc.sh
        grep -q -- '--disable-libatomic' scripts/build/cc/gcc.sh
        ;;
    install)
        prefix=${1:-}
        [ -n "$prefix" ] || usage
        shift
        aarch64=false
        if [ "${1:-}" = "--aarch64" ]; then
            aarch64=true
            shift
        fi
        [ "$#" -eq 0 ] || usage

        installed="$prefix/share/crosstool-ng/packages"
        cp -r "$BACKPORT/packages/gcc/16.1.0" "$installed/gcc/"
        rm -f "$installed/gcc/16.1.0/0002-libgcc-generic-morestack-guard-NR-mmap2.patch"
        test -f "$installed/gcc/16.1.0/chksum"
        if "$aarch64"; then
            cp "$BACKPORT/packages/glibc/2.17/0001-aarch64-use-hidden-dl-argv-alias.patch" \
                "$installed/glibc/2.17/"
            test -f "$installed/glibc/2.17/0001-aarch64-use-hidden-dl-argv-alias.patch"
        fi
        ;;
    *) usage ;;
esac
