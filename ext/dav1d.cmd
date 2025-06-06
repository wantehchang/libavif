: # If you want to use a local build of dav1d, you must clone the dav1d repo in this directory first, then set CMake's AVIF_CODEC_DAV1D to LOCAL.
: # The git SHA below is known to work, and will occasionally be updated. Feel free to use a more recent commit.

: # The odd choice of comment style in this file is to try to share this script between *nix and win32.

: # meson and ninja must be in your PATH.

: # If you're running this on Windows, be sure you've already run this (from your VC2019 install dir):
: #     "C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\VC\Auxiliary\Build\vcvars64.bat"

: # When updating the dav1d version, make the same change to dav1d_android.sh.
git clone -b 1.5.1 --depth 1 https://code.videolan.org/videolan/dav1d.git

: # macOS might require: -Dc_args=-fno-stack-check
: # Build with asan: -Db_sanitize=address -Db_lundef=false
: # Build with msan: -Db_sanitize=memory -Db_lundef=false -Denable_asm=false
: # Build with ubsan: -Db_sanitize=undefined -Db_lundef=false
meson setup --default-library=static --buildtype release -Denable_tools=false -Denable_tests=false dav1d/build dav1d
meson compile -C dav1d/build
