#!/usr/bin/env bash

cd "$(dirname "$0")"

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# complain about unset env variables
set -u

if [ -z "$AUTOBUILD" ] ; then
    exit 1
fi

if [[ "$OSTYPE" == "cygwin" || "$OSTYPE" == "msys" ]] ; then
    # need igncr so cygwin bash will trim both '\r\n' from $(command)
    set -o igncr
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
    # dummy to avoid tedious conditionals everywhere
    function cygpath {
        # pathname comes last after switches
        local last
        eval last=\$$#
        echo "$last"
    }
fi

top="$(pwd)"
stage="$top/stage"
CURL_SOURCE_DIR="$top/curl"
CURL_BUILD_DIR="$top/build"

# load autobuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

# remove_cxxstd
source "$(dirname "$AUTOBUILD_VARIABLES_FILE")/functions"

# Use msbuild.exe instead of devenv.com
build_sln() {
    local solution=$1
    local config=$2
    local proj="${3:-}"
    local toolset="${AUTOBUILD_WIN_VSTOOLSET:-v143}"

    # e.g. config = "Release|$AUTOBUILD_WIN_VSPLATFORM" per devenv.com convention
    local -a confparts
    IFS="|" read -ra confparts <<< "$config"

    msbuild.exe \
        "$(cygpath -w "$solution")" \
        ${proj:+-t:"$proj"} \
        -p:Configuration="${confparts[0]}" \
        -p:Platform="${confparts[1]}" \
        -p:PlatformToolset=$toolset
}

ZLIB_INCLUDE="${stage}"/packages/include/zlib-ng
OPENSSL_INCLUDE="${stage}"/packages/include/openssl

[ -f "$ZLIB_INCLUDE"/zlib.h ] || fail "You haven't installed the zlib package yet."
[ -f "$OPENSSL_INCLUDE"/ssl.h ] || fail "You haven't installed the openssl package yet."

LIBCURL_HEADER_DIR="${CURL_SOURCE_DIR}"/include
LIBCURL_VERSION_HEADER_DIR="$LIBCURL_HEADER_DIR/curl"
version="$(sed -nE 's/#define LIBCURL_VERSION "([^"]+)".*$/\1/p' \
           "$(cygpath -m "${LIBCURL_VERSION_HEADER_DIR}/curlver.h")")"
build=${AUTOBUILD_BUILD_ID:=0}
echo "${version}-${build}" > "${stage}/VERSION.txt"

# Restore all .sos
restore_sos ()
{
    for solib in "${stage}"/packages/lib/release/lib*.so*.disable; do
        if [ -f "$solib" ]; then
            mv -f "$solib" "${solib%.disable}"
        fi
    done
}


# Restore all .dylibs
restore_dylibs ()
{
    for dylib in "$stage/packages/lib"/release/*.dylib.disable; do
        if [ -f "$dylib" ]; then
            mv "$dylib" "${dylib%.disable}"
        fi
    done
}

# See if there's anything wrong with the checked out or
# generated files.  Main test is to confirm that c-ares
# is defeated and we're using a threaded resolver.
check_damage ()
{
    case "$1" in
        windows*)
            #echo "Verifying Ares is disabled"
            #grep 'USE_ARES\s*1' lib/curl_config.h | grep '^/\*'
        ;;

        darwin*|linux*)
            echo "Verifying Ares is disabled"
            egrep 'USE_THREADS_POSIX[[:space:]]+1' lib/curl_config.h
        ;;
    esac
}

# Read the version of a particular installable package from autobuild.xml.
# Optional $2 specifies number of version-number parts to report.
get_installable_version ()
{
    set +x
    # This command dumps the autobuild.xml data for the specified installable
    # in Python literal syntax.
    pydata="$("$autobuild" installables print "$1")"
    # Now harvest the version key.
    # It's important to use ''' syntax because of newlines in output. Specify
    # raw literal syntax too in case of backslashes.
    # Use ast.literal_eval(), safer than plain builtin eval.
    # Once we have the Python dict, extract "version" key.
    # Split version number on '.'.
    # Keep up to $2 version-number parts.
    # Rejoin them on '.' again and print.
    # On Windows, use sys.stdout.buffer.write() to avoid appending '\r\n': the
    # '\r' is NOT removed by bash, so it becomes part of the string contents,
    # which confuses both scripted comparisons and human readers.
    python -c "from ast import literal_eval
import sys
sys.stdout.buffer.write('.'.join(literal_eval(r'''$pydata''')['version'].split('.')[:${2:-}]).encode('utf-8'))"
    set -x
}

# Given an (e.g. version) string possibly containing periods, escape those
# periods with backslashes.
escape_dots ()
{
    echo "${1//./\\.}"
}

mkdir -p "$CURL_BUILD_DIR"

pushd "$CURL_BUILD_DIR"
    case "$AUTOBUILD_PLATFORM" in
        windows*)
            opts="$(replace_switch /Zi /Z7 $LL_BUILD_RELEASE) -DNGHTTP2_STATICLIB=1"
            plainopts="$(remove_switch /GR $(remove_cxxstd $opts))"

            packages="$(cygpath -m "$stage/packages")"
            load_vsvars

            cmake "$(cygpath -m "${CURL_SOURCE_DIR}")" \
                -G"$AUTOBUILD_WIN_CMAKE_GEN" -A"$AUTOBUILD_WIN_VSPLATFORM" \
                -DCMAKE_C_FLAGS:STRING="$plainopts" \
                -DCMAKE_CXX_FLAGS:STRING="$opts" \
                -DENABLE_THREADED_RESOLVER:BOOL=ON \
                -DCMAKE_USE_OPENSSL:BOOL=TRUE \
                -DUSE_NGHTTP2:BOOL=TRUE \
                -DNGHTTP2_INCLUDE_DIR:FILEPATH="$packages/include" \
                -DNGHTTP2_LIBRARY:FILEPATH="$packages/lib/release/nghttp2.lib" \
                -DCMAKE_INSTALL_PREFIX="$(cygpath -m "$stage")"

            check_damage "$AUTOBUILD_PLATFORM"

            cmake --build . --config Release -j$AUTOBUILD_CPU_COUNT
            cmake --install . --config Release
            
            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                pushd tests
                # Nothin' to do yet
                popd
            fi

            # Stage archives
            mkdir -p "${stage}/lib/release"
            mv "${stage}/lib/libcurl.lib" "${stage}"/lib/release/

            # Run 'curl' as a sanity check. Capture just the first line, which
            # should have versions of stuff.
            curlout="$("${stage}/bin/curl.exe" --version | head -n 1)"
            # With -e in effect, any nonzero rc blows up the script --
            # so plain 'expr str : pattern' asserts that str contains pattern.
            # curl version - should be start of line
            expr "$curlout" : "curl $(escape_dots "$version")" #> /dev/null
            # libcurl/version
            expr "$curlout" : ".* libcurl/$(escape_dots "$version")" > /dev/null
            # OpenSSL/version
            expr "$curlout" : ".* OpenSSL/$(escape_dots "$(get_installable_version openssl 3)")" > /dev/null
            # zlib/version
            expr "$curlout" : ".* zlib/" > /dev/null
        ;;

        darwin*)
            export MACOSX_DEPLOYMENT_TARGET="$LL_BUILD_DARWIN_DEPLOY_TARGET"

            opts="${TARGET_OPTS:--arch $AUTOBUILD_CONFIGURE_ARCH $LL_BUILD_RELEASE}"
            opts="$(set_target $opts)"
            plainopts="$(remove_cxxstd $opts)"

            mkdir -p "$stage/lib/release"
            rm -rf Resources/ ../Resources tests/Resources/

            # Force libz and openssl static linkage by moving .dylibs out of the way
            trap restore_dylibs EXIT
            for dylib in "$stage"/packages/lib/release/lib{z,crypto,ssl}*.dylib; do
                if [ -f "$dylib" ]; then
                    mv "$dylib" "$dylib".disable
                fi
            done

            # Release configure and build

            # Make .dylib's usable during configure as well as unit tests
            # (Used when building with dylib libz or OpenSSL.)
            # mkdir -p Resources/
            # ln -sf "${stage}"/packages/lib/release/*.dylib Resources/
            # mkdir -p ../Resources/
            # ln -sf "${stage}"/packages/lib/release/*.dylib ../Resources/
            # mkdir -p tests/Resources/
            # ln -sf "${stage}"/packages/lib/release/*.dylib tests/Resources/
            # LDFLAGS="-L../Resources/ -L\"$stage\"/packages/lib/release" \

            # -T buildsystem=1 is to work around an error in the upstream
            # CMakeLists.txt that doesn't work with the Xcode "new build
            # system." Possibly a newer version of curl will fix.
            # https://stackoverflow.com/a/65474688
            cmake "${CURL_SOURCE_DIR}" -G Ninja -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_C_FLAGS:STRING="$plainopts" \
                -DCMAKE_CXX_FLAGS:STRING="$opts" \
                -DBUILD_SHARED_LIBS:BOOL=OFF \
                -DENABLE_THREADED_RESOLVER:BOOL=ON \
                -DCMAKE_USE_OPENSSL:BOOL=TRUE \
                -DUSE_NGHTTP2:BOOL=TRUE \
                -DNGHTTP2_INCLUDE_DIR:FILEPATH="$stage/packages/include" \
                -DNGHTTP2_LIBRARY:FILEPATH="$stage/packages/lib/release/libnghttp2.a" \
                -DCMAKE_INSTALL_PREFIX=$stage \
                -DCMAKE_OSX_ARCHITECTURES="x86_64" \
                -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET}

            check_damage "$AUTOBUILD_PLATFORM"

            cmake --build . --config Release -j$AUTOBUILD_CPU_COUNT
            cmake --install . --config Release

            mkdir -p "$stage/lib/release"
            mv "$stage/lib/libcurl.a" "$stage/lib/release/libcurl.a"

            # conditionally run unit tests
            # Disabled here and below by default on Mac because they
            # trigger the Mac firewall dialog and that may make
            # automated builds unreliable.  During development,
            # explicitly inhibit the disable and run the tests.  They
            # matter.
#            if [ "${DISABLE_UNIT_TESTS:-1}" = "0" ]; then
#                pushd tests
#                    # We hijack the 'quiet-test' target and redefine it as
#                    # a no-valgrind test.  Also exclude test 906.  It fails in the
#                    # 7.33 distribution with our configuration options.  530 fails
#                    # in TeamCity.  (Expect problems with the unit tests, they're
#                    # very sensitive to environment.)
#                    make quiet-test TEST_Q='-n !906 !530 !564 !584 !706 !1316'
#                popd
#            fi
            
#            make distclean
            # Again, for dylib dependencies
            # rm -rf Resources/ ../Resources tests/Resources/

            # Run 'curl' as a sanity check. Capture just the first line, which
            # should have versions of stuff.
            curlout="$("${stage}"/bin/curl --version | tr -d '\r' | head -n 1)"
            # With -e in effect, any nonzero rc blows up the script --
            # so plain 'expr str : pattern' asserts that str contains pattern.
            # curl version - should be start of line
            expr "$curlout" : "curl $(escape_dots "$version")" > /dev/null
            # libcurl/version
            expr "$curlout" : ".* libcurl/$(escape_dots "$version")" > /dev/null
            # OpenSSL/version
            expr "$curlout" : ".* OpenSSL/$(escape_dots "$(get_installable_version openssl 3)")" > /dev/null
            # zlib/version
            expr "$curlout" : ".* zlib/" > /dev/null
            # nghttp2/versionx
            expr "$curlout" : ".* nghttp2/$(escape_dots "$(get_installable_version nghttp2 3)")" > /dev/null
        ;;

        linux*)
            # Default target per --address-size
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE}"
            plainopts="$(remove_cxxstd $opts)"

            # Handle any deliberate platform targeting
            if [ -z "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="$TARGET_CPPFLAGS"
            fi

            # Force static linkage to libz and openssl by moving .sos out of the way
            trap restore_sos EXIT
            for solib in "${stage}"/packages/lib/release/lib{z,ssl,crypto}.so*; do
                if [ -f "$solib" ]; then
                    mv -f "$solib" "$solib".disable
                fi
            done

            mkdir -p "$stage/lib/release"

            # Autoconf's configure will do some odd things to flags.  '-I' options
            # will get transferred to '-isystem' and there's a problem with quoting.
            # Linking and running also require LD_LIBRARY_PATH to locate the OpenSSL
            # .so's.  The '--with-ssl' option could do this if we had a more normal
            # package layout.
            #
            # configure-time compilation looks like:
            # ac_compile='$CC -c $CFLAGS $CPPFLAGS conftest.$ac_ext >&5'
            # ac_link='$CC -o conftest$ac_exeext $CFLAGS $CPPFLAGS $LDFLAGS conftest.$ac_ext $LIBS >&5'
            saved_path="${LD_LIBRARY_PATH:-}"

            # Release configure and build
            export LD_LIBRARY_PATH="${stage}"/packages/lib/release:"$saved_path"

            cmake "${CURL_SOURCE_DIR}" -G"Ninja" -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_C_FLAGS:STRING="$plainopts" \
                -DCMAKE_CXX_FLAGS:STRING="$opts" \
                -DENABLE_THREADED_RESOLVER:BOOL=ON \
                -DCMAKE_USE_OPENSSL:BOOL=TRUE \
                -DUSE_NGHTTP2:BOOL=TRUE \
                -DNGHTTP2_INCLUDE_DIR:FILEPATH="$stage/packages/include" \
                -DNGHTTP2_LIBRARY:FILEPATH="$stage/packages/lib/release/libnghttp2.a" \
                -DBUILD_SHARED_LIBS:BOOL=FALSE \
                -DCMAKE_INSTALL_PREFIX=$stage
            
            check_damage "$AUTOBUILD_PLATFORM"

            cmake --build . --config Release -j$AUTOBUILD_CPU_COUNT
            cmake --install . --config Release

            mkdir -p "$stage/lib/release"
            mv "$stage/lib/libcurl.a" "$stage/lib/release/libcurl.a"

#           # conditionally run unit tests
#           if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
#                pushd tests
#                    # We hijack the 'quiet-test' target and redefine it as
#                    # a no-valgrind test.  Also exclude test 906.  It fails in the
#                    # 7.33 distribution with our configuration options.  530 fails
#                    # in TeamCity.  815 hangs in 7.36.0 fixed in 7.37.0.
#                    #
#                    # Expect problems with the unit tests, they're very sensitive
#                    # to environment.
#                    make quiet-test TEST_Q='-n !906 !530 !564 !584 !1026'
#                popd
#            fi

            # Run 'curl' as a sanity check. Capture just the first line, which
            # should have versions of stuff.
            curlout="$("${stage}"/bin/curl --version | tr -d '\r' | head -n 1)"
            # With -e in effect, any nonzero rc blows up the script --
            # so plain 'expr str : pattern' asserts that str contains pattern.
            # curl version - should be start of line
            expr "$curlout" : "curl $(escape_dots "$version")" > /dev/null
            # libcurl/version
            expr "$curlout" : ".* libcurl/$(escape_dots "$version")" > /dev/null
            # OpenSSL/version
            expr "$curlout" : ".* OpenSSL/$(escape_dots "$(get_installable_version openssl 3)")" > /dev/null
            # zlib/version
            expr "$curlout" : ".* zlib/" > /dev/null
            # nghttp2/versionx
            expr "$curlout" : ".* nghttp2/$(escape_dots "$(get_installable_version nghttp2 3)")" > /dev/null

            export LD_LIBRARY_PATH="$saved_path"
        ;;
    esac
    mkdir -p "$stage/LICENSES"
    cp "${CURL_SOURCE_DIR}"/COPYING "$stage/LICENSES/curl.txt"
popd
rm -rf "$CURL_BUILD_DIR"

mkdir -p "$stage"/docs/curl/
cp -a "$top"/README.Linden "$stage"/docs/curl/
