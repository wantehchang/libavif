# Copyright 2019 Joe Drago. All rights reserved.
# SPDX-License-Identifier: BSD-2-Clause

cmake_minimum_required(VERSION 3.22)

# New in CMake version 3.15. MSVC warning flags are not in CMAKE_<LANG>_FLAGS by default.
if(POLICY CMP0092)
    cmake_policy(SET CMP0092 NEW)
endif()

# New in CMake version 3.19. Support the Xcode "new build system" for ExternalProject_Add().
if(POLICY CMP0114)
    cmake_policy(SET CMP0114 NEW)
endif()

# Prevent warnings in CMake>=3.24 for ExternalProject_Add()
# see https://cmake.org/cmake/help/latest/policy/CMP0135.html
if(POLICY CMP0135)
    cmake_policy(SET CMP0135 NEW) # valid for DOWNLOAD_EXTRACT_TIMESTAMP option in CMake 3.24 and later
endif()

# New in CMake version 3.30. FetchContent_Populate(<name>) is deprecated, call
# FetchContent_MakeAvailable(<name>) instead.
if(POLICY CMP0169)
    cmake_policy(SET CMP0169 OLD)
endif()

project(libavif LANGUAGES C VERSION 1.3.0)

# The root directory of the avif source
set(AVIF_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")

# Specify search path for CMake modules to be loaded by include() and find_package()
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake/Modules")

include(ExternalProject)
include(FetchContent)
include(FindPkgConfig)
include(AvifExternalProjectUtils)
include(GNUInstallDirs)

option(AVIF_ENABLE_NODISCARD "Add [[nodiscard]] to some functions. CMake must be at least 3.21 to force C23." OFF)

# Set C99 as the default
if(AVIF_ENABLE_NODISCARD)
    # [[nodiscard]] requires C23.
    if(CMAKE_VERSION VERSION_LESS 3.21.0)
        message(FATAL_ERROR "CMake must be at least 3.21 to force C23, bailing out")
    endif()
    set(CMAKE_C_STANDARD 23)
    set(CMAKE_C_STANDARD_REQUIRED ON)
else()
    set(CMAKE_C_STANDARD 99)
endif()

# SOVERSION scheme: MAJOR.MINOR.PATCH
#   If there was an incompatible interface change:
#     Increment MAJOR. Set MINOR and PATCH to 0
#   If there was a compatible interface change:
#     Increment MINOR. Set PATCH to 0
#   If the source code was changed, but there were no interface changes:
#     Increment PATCH.
set(LIBRARY_VERSION_MAJOR 16)
set(LIBRARY_VERSION_MINOR 3)
set(LIBRARY_VERSION_PATCH 0)
set(LIBRARY_VERSION "${LIBRARY_VERSION_MAJOR}.${LIBRARY_VERSION_MINOR}.${LIBRARY_VERSION_PATCH}")
set(LIBRARY_SOVERSION ${LIBRARY_VERSION_MAJOR})

option(BUILD_SHARED_LIBS "Build shared avif library" ON)

option(AVIF_ENABLE_WERROR "Treat all compiler warnings as errors" OFF)

option(AVIF_ENABLE_EXPERIMENTAL_MINI "Enable experimental reduced header" OFF)
option(AVIF_ENABLE_EXPERIMENTAL_SAMPLE_TRANSFORM "Enable experimental sample transform code" OFF)
option(AVIF_ENABLE_EXPERIMENTAL_EXTENDED_PIXI "Enable experimental PixelInformationProperty syntax from HEIF 3rd Ed. Amd2" OFF)

set(AVIF_PKG_CONFIG_EXTRA_LIBS_PRIVATE "")
set(AVIF_PKG_CONFIG_EXTRA_REQUIRES_PRIVATE "")

# Creates an option that can take the values 'OFF', 'SYSTEM' or 'LOCAL'.
# The prefix 'AVIF_' is added to the option name automatically.
function(set_local_or_system_option VAR DEFAULT TEXT)
    if(DEFINED AVIF_${VAR})
        set(DEFAULT ${AVIF_${VAR}})
    endif()
    set(AVIF_${VAR} ${DEFAULT} CACHE STRING ${TEXT} FORCE)
    set_property(CACHE AVIF_${VAR} PROPERTY STRINGS OFF LOCAL SYSTEM)
endfunction()
function(set_codec_option CODEC NAME ENCDEC EXTRA)
    if(DEFINED AVIF_CODEC_${CODEC})
        set(DEFAULT ${AVIF_CODEC_${CODEC}})
    else()
        set(DEFAULT "OFF")
    endif()
    set(AVIF_CODEC_${CODEC} ${DEFAULT} CACHE STRING "Use the ${NAME} codec for ${ENCDEC}${EXTRA}" FORCE)
    set_property(CACHE AVIF_CODEC_${CODEC} PROPERTY STRINGS OFF LOCAL SYSTEM)
endfunction()
set_codec_option(AOM "AOM" "encoding/decoding" " (see AVIF_CODEC_AOM_DECODE/AVIF_CODEC_AOM_ENCODE)")
set_codec_option(DAV1D "dav1d" "decoding" "")
set_codec_option(LIBGAV1 "libgav1" "decoding" "")
set_codec_option(RAV1E "rav1e" "encoding" "")
set_codec_option(SVT "SVT-AV1" "encoding" "")
set_codec_option(AVM "AVM (AV2)" "encoding/decoding" " (EXPERIMENTAL)")

# These options allow libavif to only link against / use libaom's encoder or decoder, instead of being forced to use both
include(CMakeDependentOption)
cmake_dependent_option(
    AVIF_CODEC_AOM_DECODE "if AVIF_CODEC_AOM is on, use/offer libaom's decoder" ON "NOT AVIF_CODEC_AOM STREQUAL OFF" OFF
)
cmake_dependent_option(
    AVIF_CODEC_AOM_ENCODE "if AVIF_CODEC_AOM is on, use/offer libaom's encoder" ON "NOT AVIF_CODEC_AOM STREQUAL OFF" OFF
)

set_local_or_system_option(
    "GTEST" OFF
    "Use the GoogleTest framework. Enables avif C++ tests that depend on GoogleTest. Has no effect unless AVIF_BUILD_TESTS is ON."
)

option(AVIF_BUILD_APPS "Build avif apps." OFF)
option(AVIF_BUILD_TESTS "Build avif tests." OFF)
option(
    AVIF_ENABLE_COMPLIANCE_WARDEN
    "Check all avifEncoderFinish() output for AVIF specification compliance. Depends on gpac/ComplianceWarden which can be added with ext/compliance_warden.sh"
    OFF
)
option(
    AVIF_ENABLE_GOLDEN_TESTS
    "Build tests that compare encoding outputs to golden files. Needs AVIF_BUILD_APPS=ON and AVIF_BUILD_TESTS=ON, and depends on MP4box which can be built with ext/mp4box.sh"
    OFF
)
set_local_or_system_option(
    "FUZZTEST" OFF "Build the Google FuzzTest framework. Only OFF and LOCAL are supported. CMake must be at least 3.25."
)

# Whether the libavif library uses c++ indirectly (e.g. through linking to libyuv).
set(AVIF_LIB_USE_CXX OFF)

if(APPLE)
    set(XCRUN xcrun)
else()
    set(XCRUN)
endif()

# This is also needed to get shared libraries (e.g. pixbufloader-avif) to compile against a static libavif.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(BUILD_SHARED_LIBS)
    set(AVIF_LIBRARY_PREFIX "${CMAKE_SHARED_LIBRARY_PREFIX}")
else()
    set(AVIF_LIBRARY_PREFIX "${CMAKE_STATIC_LIBRARY_PREFIX}")
endif()

add_library(avif_obj OBJECT)
add_library(avif)

# Adds <target> to avif_obj's public link libraries for build, and adds
# the <target> library as an install link library for export in case a consumer
# needs to include that library alongside libavif when statically linking.
function(avif_target_link_library target)
    target_link_libraries(avif_obj PUBLIC $<BUILD_INTERFACE:${target}>)
    get_target_property(target_is_local ${target} AVIF_LOCAL)
    if(target_is_local)
        return()
    endif()
    get_target_property(install_target ${target} IMPORTED_SONAME)
    if(NOT install_target)
        set(install_target ${target})
    endif()
    # The transitive dependency needs to be an export link library in a static build.
    if(NOT BUILD_SHARED_LIBS)
        target_link_libraries(avif PUBLIC $<INSTALL_INTERFACE:${install_target}>)
    endif()
endfunction()

#[[
check_avif_option(<option> TARGET <target> PKG_NAME <PackageName>)

If <option> is equal to "SYSTEM", uses <target> if it already exists, otherwise calls find_package(<PackageName>). If <option>
is "LOCAL", includes Local<PackageName>.cmake. Sets <option>_ENABLED to ON if the option is enabled and the target is usable.
]]
macro(check_avif_option _VAR)
    set(_oneValueArgs TARGET PKG_NAME)
    cmake_parse_arguments(_AVIF_OPTION "" "${_oneValueArgs}" "" ${ARGN})
    string(SUBSTRING ${_AVIF_OPTION_PKG_NAME} 0 1 FIRST_LETTER)
    string(TOUPPER ${FIRST_LETTER} FIRST_LETTER)
    string(REGEX REPLACE "^.(.*)" "Local${FIRST_LETTER}\\1" _LOCAL_INCLUDE "${_AVIF_OPTION_PKG_NAME}")
    set(${_VAR}_ENABLED OFF)
    if(${_VAR} STREQUAL "LOCAL" OR ${_VAR} STREQUAL "SYSTEM")
        if(${_VAR} STREQUAL "LOCAL" AND TARGET ${_AVIF_OPTION_TARGET})
            message(ERROR "${_AVIF_OPTION_TARGET} is already defined and ${_VAR} should be set to SYSTEM to use it")
            return()
        endif()
        set(${_VAR}_ENABLED ON)
        if(NOT TARGET ${_AVIF_OPTION_TARGET})
            if(${_VAR} STREQUAL "LOCAL")
                include(${_LOCAL_INCLUDE})
            elseif(${_VAR} STREQUAL "SYSTEM")
                # QUIET instead of REQUIRED in order to use a custom error message below.
                find_package(${_AVIF_OPTION_PKG_NAME} QUIET)
                if(NOT ${_AVIF_OPTION_PKG_NAME}_FOUND)
                    message(
                        FATAL_ERROR
                            "Cannot find ${_AVIF_OPTION_PKG_NAME}. Make sure it's installed on the system, or pass -D${_VAR}=LOCAL (to fetch and build it locally) or -D${_VAR}=OFF (to disable it)"
                    )
                endif()
            endif()
        endif()
    endif()
endmacro()

set_local_or_system_option("ZLIBPNG" "SYSTEM" "Use zlib and libpng.")
if(AVIF_ZLIBPNG STREQUAL "LOCAL")
    include(LocalZlibpng)
endif()

set_local_or_system_option("JPEG" "SYSTEM" "Use jpeg.")
if(AVIF_JPEG STREQUAL "LOCAL")
    include(LocalJpeg)
endif()

set_local_or_system_option("LIBYUV" "SYSTEM" "Use libyuv.")
# check_avif_option libyuv must precede libaom because the latter needs to link against the former
# when building libaom locally
check_avif_option(AVIF_LIBYUV TARGET yuv::yuv PKG_NAME libyuv)
if(AVIF_LIBYUV_ENABLED)
    # libyuv 1755 exposed all of the I*Matrix() functions, which libavif relies on.
    # libyuv 1774 exposed ScalePlane_12 function, which libavif can use for some additional optimizations.
    # libyuv 1813 added the I*ToARGBMatrixFilter() functions, which libavif can use with the bilinear filter.
    if(NOT LIBYUV_VERSION)
        message(STATUS "libavif: libyuv found, but version unknown; libyuv-based fast paths disabled.")
        unset(AVIF_LIBYUV_ENABLED)
    elseif(LIBYUV_VERSION LESS 1755)
        message(STATUS "libavif: libyuv (${LIBYUV_VERSION}) found, but is too old; libyuv-based fast paths disabled.")
        unset(AVIF_LIBYUV_ENABLED)
    else()
        message(STATUS "libavif: libyuv (${LIBYUV_VERSION}) found; libyuv-based fast paths enabled.")
        if(LIBYUV_VERSION LESS 1813)
            message(STATUS "libavif: some libyuv optimizations require at least version 1813 to work.")
        endif()
    endif()
endif()
if(AVIF_LIBYUV_ENABLED)
    target_compile_definitions(avif_obj PRIVATE -DAVIF_LIBYUV_ENABLED=1)
    avif_target_link_library(yuv::yuv)
    set(AVIF_PKG_CONFIG_EXTRA_LIBS_PRIVATE "${AVIF_PKG_CONFIG_EXTRA_LIBS_PRIVATE} -lyuv")
    set(AVIF_LIB_USE_CXX ON)
endif(AVIF_LIBYUV_ENABLED)

set_local_or_system_option("LIBSHARPYUV" "OFF" "Use libsharpyuv.")
check_avif_option(AVIF_LIBSHARPYUV TARGET sharpyuv::sharpyuv PKG_NAME libsharpyuv)
if(AVIF_LIBSHARPYUV_ENABLED)
    message(STATUS "libavif: libsharpyuv found; sharp rgb to yuv conversion enabled.")
    set(AVIF_PKG_CONFIG_EXTRA_REQUIRES_PRIVATE "${AVIF_PKG_CONFIG_EXTRA_REQUIRES_PRIVATE} libsharpyuv")
    target_compile_definitions(avif_obj PRIVATE -DAVIF_LIBSHARPYUV_ENABLED=1)
    avif_target_link_library(sharpyuv::sharpyuv)
endif(AVIF_LIBSHARPYUV_ENABLED)

set_local_or_system_option(
    "LIBXML2" "OFF" "Use libxml2. When enabled, allows converting JPEG files with gain maps to AVIF using avifenc"
)
check_avif_option(AVIF_LIBXML2 TARGET LibXml2::LibXml2 PKG_NAME LibXml2)

# ---------------------------------------------------------------------------------------

# Enable all warnings
include(CheckCCompilerFlag)
# avif_enable_warnings is a CMake interface library. It has no source files.
# Its only purpose is to serve as a carrier of warning-related compiler options
# and macro definitions. We set them by calling target_compile_options() and
# target_compile_definitions() on avif_enable_warnings. We enable compiler
# warnings in a target by linking the target with avif_enable_warnings using
# target_link_libraries().
add_library(avif_enable_warnings INTERFACE)
if(MSVC)
    message(STATUS "libavif: Enabling warnings for MSVC")
    target_compile_options(
        avif_enable_warnings
        INTERFACE /W4 # For clang-cl, /W4 enables -Wall and -Wextra
                  /wd4232 # Disable: address of dllimport 'dllimport' is not static,
                          # identity not guaranteed
                  /wd4324 # Disable: structure was padded due to alignment specifier
    )
    # Disable deprecation warnings about POSIX function names such as setmode (replaced by the ISO C and C++ conformant name _setmode).
    # Disable deprecation warnings about unsafe CRT library functions such as fopen (replaced by fopen_s).
    target_compile_definitions(avif_enable_warnings INTERFACE _CRT_NONSTDC_NO_WARNINGS _CRT_SECURE_NO_WARNINGS)

    # clang-cl documentation says:
    #   /execution-charset:<value>
    #                           Runtime encoding, supports only UTF-8
    #   ...
    #   /source-charset:<value> Source encoding, supports only UTF-8
    # So we don't need to pass /source-charset:utf-8 to clang-cl, and we cannot pass /execution-charset:us-ascii to clang-cl.
    if(CMAKE_C_COMPILER_ID MATCHES "MSVC")
        target_compile_options(
            avif_obj
            PUBLIC $<BUILD_INTERFACE:
                   # This tells MSVC to read source code as UTF-8 and assume console can only use ASCII (minimal safe).
                   # libavif uses ANSI API to print to console, which is not portable between systems using different
                   # languages and results in mojibake unless we only use codes shared by every code page: ASCII.
                   # A C4556 warning will be generated on violation.
                   # Commonly used /utf-8 flag assumes UTF-8 for both source and console, which is usually not the case.
                   # Warnings can be suppressed but there will still be random characters printed to the console.
                   /source-charset:utf-8
                   /execution-charset:us-ascii
                   >
        )
    endif()
elseif(CMAKE_C_COMPILER_ID MATCHES "Clang")
    message(STATUS "libavif: Enabling warnings for Clang")
    target_compile_options(
        avif_enable_warnings INTERFACE -Wall -Wextra -Wgnu-empty-initializer -Wshorten-64-to-32 -Wstrict-prototypes
                                       -Wzero-as-null-pointer-constant
    )
elseif(CMAKE_C_COMPILER_ID MATCHES "GNU")
    message(STATUS "libavif: Enabling warnings for GCC")
    target_compile_options(avif_enable_warnings INTERFACE -Wall -Wextra)
else()
    message(FATAL_ERROR "libavif: Unknown compiler, bailing out")
endif()

if(AVIF_ENABLE_WERROR)
    # Warnings as errors
    if(MSVC)
        target_compile_options(avif_enable_warnings INTERFACE /WX)
    elseif(CMAKE_C_COMPILER_ID MATCHES "Clang" OR CMAKE_C_COMPILER_ID MATCHES "GNU")
        target_compile_options(avif_enable_warnings INTERFACE -Werror)
    else()
        message(FATAL_ERROR "libavif: Unknown compiler, bailing out")
    endif()
endif()

target_link_libraries(avif_obj PRIVATE avif_enable_warnings)

option(
    AVIF_ENABLE_COVERAGE
    "Enable code coverage. Requires LLVM and clang as compiler. Has no effect unless AVIF_BUILD_TESTS is ON. Use the 'avif_coverage' target to generate a coverage report."
    OFF
)
if(AVIF_ENABLE_COVERAGE)
    if(CMAKE_C_COMPILER_ID MATCHES "Clang" OR CMAKE_C_COMPILER_ID MATCHES "GNU")
        message(STATUS "libavif: Enabling coverage for Clang")
        target_compile_options(avif_obj PUBLIC $<BUILD_INTERFACE:-fprofile-instr-generate -fcoverage-mapping -O0>)
        target_compile_options(avif PUBLIC $<BUILD_INTERFACE:-fprofile-instr-generate -fcoverage-mapping -O0>)
        set(CMAKE_EXE_LINKER_FLAGS ${CMAKE_EXE_LINKER_FLAGS} "-fprofile-instr-generate -fcoverage-mapping")
    else()
        # TODO: Add support for other compilers
        message(WARNING "libavif: Ignoring request for coverage (AVIF_ENABLE_COVERAGE); only clang is currently supported.")
        set(AVIF_ENABLE_COVERAGE OFF)
    endif()
endif()

if(AVIF_ENABLE_EXPERIMENTAL_MINI)
    add_compile_definitions(AVIF_ENABLE_EXPERIMENTAL_MINI)
endif()

if(AVIF_ENABLE_EXPERIMENTAL_SAMPLE_TRANSFORM)
    add_compile_definitions(AVIF_ENABLE_EXPERIMENTAL_SAMPLE_TRANSFORM)
endif()

if(AVIF_ENABLE_EXPERIMENTAL_EXTENDED_PIXI)
    add_compile_definitions(AVIF_ENABLE_EXPERIMENTAL_EXTENDED_PIXI)
endif()

set(AVIF_SRCS
    src/alpha.c
    src/avif.c
    src/colr.c
    src/colrconvert.c
    src/diag.c
    src/exif.c
    src/gainmap.c
    src/io.c
    src/mem.c
    src/obu.c
    src/properties.c
    src/rawdata.c
    src/read.c
    src/reformat.c
    src/reformat_libsharpyuv.c
    src/reformat_libyuv.c
    src/scale.c
    src/stream.c
    src/utils.c
    src/write.c
)
if(AVIF_ENABLE_EXPERIMENTAL_SAMPLE_TRANSFORM)
    list(APPEND AVIF_SRCS src/sampletransform.c)
endif()

if(AVIF_ENABLE_COMPLIANCE_WARDEN)
    if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/ext/ComplianceWarden")
        message(FATAL_ERROR "AVIF_ENABLE_COMPLIANCE_WARDEN: ext/ComplianceWarden is missing, bailing out")
    endif()

    set(AVIF_LIB_USE_CXX ON)
    target_compile_definitions(avif_obj PRIVATE AVIF_ENABLE_COMPLIANCE_WARDEN)

    list(
        APPEND
        AVIF_SRCS
        src/compliance.cc
        ext/ComplianceWarden/src/app/cw.cpp
        ext/ComplianceWarden/src/app/options.cpp
        ext/ComplianceWarden/src/app/report_std.cpp
        ext/ComplianceWarden/src/app/report_json.cpp
        ext/ComplianceWarden/src/utils/common_boxes.cpp
        ext/ComplianceWarden/src/utils/tools.cpp
        ext/ComplianceWarden/src/utils/av1_utils.cpp
        ext/ComplianceWarden/src/utils/isobmff_utils.cpp
        ext/ComplianceWarden/src/utils/isobmff_derivations.cpp
        ext/ComplianceWarden/src/utils/spec_utils.cpp
        ext/ComplianceWarden/src/specs/av1_hdr10plus/av1_hdr10plus.cpp
        ext/ComplianceWarden/src/specs/avif/avif.cpp
        ext/ComplianceWarden/src/specs/avif/profiles.cpp
        ext/ComplianceWarden/src/specs/avif/utils.cpp
        ext/ComplianceWarden/src/specs/isobmff/isobmff.cpp
        ext/ComplianceWarden/src/specs/heif/heif.cpp
        ext/ComplianceWarden/src/specs/miaf/miaf.cpp
        ext/ComplianceWarden/src/specs/miaf/audio.cpp
        ext/ComplianceWarden/src/specs/miaf/brands.cpp
        ext/ComplianceWarden/src/specs/miaf/derivations.cpp
        ext/ComplianceWarden/src/specs/miaf/colours.cpp
        ext/ComplianceWarden/src/specs/miaf/num_pixels.cpp
        ext/ComplianceWarden/src/specs/miaf/profiles.cpp
        ext/ComplianceWarden/src/cw_version.cpp
    )
endif()

target_sources(avif_obj PRIVATE ${AVIF_SRCS})

# Only applicable to macOS. In GitHub CI's macos-latest os image, this prevents using the libpng
# and libjpeg headers from /Library/Frameworks/Mono.framework/Headers instead of
# /usr/local/include.
set(CMAKE_FIND_FRAMEWORK LAST)

if(UNIX OR MINGW)
    # Find out if we have threading available
    set(THREADS_PREFER_PTHREAD_FLAG ON)
    find_package(Threads)
    target_link_libraries(avif_obj PRIVATE m Threads::Threads)
endif()

if(NOT AVIF_LIBYUV_ENABLED)
    target_sources(
        avif_obj
        PRIVATE third_party/libyuv/source/scale.c third_party/libyuv/source/scale_common.c third_party/libyuv/source/scale_any.c
                third_party/libyuv/source/row_common.c third_party/libyuv/source/planar_functions.c
    )
    if(DEFINED ANDROID_ABI OR DEFINED APPLE)
        # When building third_party/libyuv/source/scale.c, some functions use
        # some of the parameters only inside an assert statement. This causes
        # unused parameter warnings when building for Android. Suppress the
        # warning in that case.
        target_compile_options(avif_obj PRIVATE -Wno-unused-parameter)
    endif()
endif()

check_avif_option(AVIF_CODEC_DAV1D TARGET dav1d::dav1d PKG_NAME dav1d)
if(AVIF_CODEC_DAV1D_ENABLED)
    target_compile_definitions(avif_obj PRIVATE -DAVIF_CODEC_DAV1D=1)
    target_sources(avif_obj PRIVATE src/codec_dav1d.c)

    if(UNIX AND NOT APPLE)
        target_link_libraries(dav1d::dav1d INTERFACE ${CMAKE_DL_LIBS}) # for dlsym
    endif()

    avif_target_link_library(dav1d::dav1d)

    message(STATUS "libavif: Codec enabled: dav1d (decode)")
    set(AVIF_PKG_CONFIG_EXTRA_REQUIRES_PRIVATE "${AVIF_PKG_CONFIG_EXTRA_REQUIRES_PRIVATE} dav1d")
endif()

check_avif_option(AVIF_CODEC_LIBGAV1 TARGET libgav1::libgav1 PKG_NAME libgav1)
if(AVIF_CODEC_LIBGAV1_ENABLED)
    set(AVIF_LIB_USE_CXX ON)
    target_compile_definitions(avif_obj PRIVATE -DAVIF_CODEC_LIBGAV1=1)
    target_sources(avif_obj PRIVATE src/codec_libgav1.c)
    avif_target_link_library(libgav1::libgav1)

    message(STATUS "libavif: Codec enabled: libgav1 (decode)")
endif()

check_avif_option(AVIF_CODEC_RAV1E TARGET rav1e::rav1e PKG_NAME rav1e)
if(AVIF_CODEC_RAV1E_ENABLED)
    target_compile_definitions(avif_obj PRIVATE -DAVIF_CODEC_RAV1E=1)
    target_sources(avif_obj PRIVATE src/codec_rav1e.c)

    # Unfortunately, rav1e requires a few more libraries
    # first check that RAV1E_LIBRARIES hasn't been populated by the LocalRav1e module
    if(NOT RAV1E_LIBRARIES)
        if(WIN32)
            target_link_libraries(rav1e::rav1e INTERFACE ntdll.lib userenv.lib ws2_32.lib bcrypt.lib)
        elseif(UNIX AND NOT APPLE)
            target_link_libraries(rav1e::rav1e INTERFACE ${CMAKE_DL_LIBS}) # for backtrace
        endif()
    endif()

    avif_target_link_library(rav1e::rav1e)

    message(STATUS "libavif: Codec enabled: rav1e (encode)")
    set(AVIF_PKG_CONFIG_EXTRA_REQUIRES_PRIVATE "${AVIF_PKG_CONFIG_EXTRA_REQUIRES_PRIVATE} rav1e")
endif()

check_avif_option(AVIF_CODEC_SVT TARGET SvtAv1Enc PKG_NAME svt)
if(AVIF_CODEC_SVT_ENABLED)
    target_compile_definitions(avif_obj PRIVATE -DAVIF_CODEC_SVT=1)
    target_sources(avif_obj PRIVATE src/codec_svt.c)
    avif_target_link_library(SvtAv1Enc)

    message(STATUS "libavif: Codec enabled: svt (encode)")
    set(AVIF_PKG_CONFIG_EXTRA_REQUIRES_PRIVATE "${AVIF_PKG_CONFIG_EXTRA_REQUIRES_PRIVATE} SvtAv1Enc")
endif()

check_avif_option(AVIF_CODEC_AOM TARGET aom PKG_NAME aom)
if(AVIF_CODEC_AOM_ENABLED)
    target_compile_definitions(avif_obj PRIVATE -DAVIF_CODEC_AOM=1)
    if(AVIF_CODEC_AOM_ENCODE AND AVIF_CODEC_AOM_DECODE)
        set(AVIF_CODEC_AOM_ENCODE_DECODE_CONFIG "encode/decode")
        target_compile_definitions(avif_obj PRIVATE -DAVIF_CODEC_AOM_ENCODE=1 -DAVIF_CODEC_AOM_DECODE=1)
    elseif(AVIF_CODEC_AOM_ENCODE)
        set(AVIF_CODEC_AOM_ENCODE_DECODE_CONFIG "encode only")
        target_compile_definitions(avif_obj PRIVATE -DAVIF_CODEC_AOM_ENCODE=1)
    elseif(AVIF_CODEC_AOM_DECODE)
        set(AVIF_CODEC_AOM_ENCODE_DECODE_CONFIG "decode only")
        target_compile_definitions(avif_obj PRIVATE -DAVIF_CODEC_AOM_DECODE=1)
    else()
        message(
            FATAL_ERROR
                "libavif: AVIF_CODEC_AOM is on, but both AVIF_CODEC_AOM_ENCODE and AVIF_CODEC_AOM_DECODE are off. Disable AVIF_CODEC_AOM to disable both parts of the codec."
        )
    endif()
    target_sources(avif_obj PRIVATE src/codec_aom.c)

    avif_target_link_library(aom)

    message(STATUS "libavif: Codec enabled: aom (${AVIF_CODEC_AOM_ENCODE_DECODE_CONFIG})")
    set(AVIF_PKG_CONFIG_EXTRA_REQUIRES_PRIVATE "${AVIF_PKG_CONFIG_EXTRA_REQUIRES_PRIVATE} aom")

    get_target_property(AOM_INTERFACE_LINK_LIBRARIES aom INTERFACE_LINK_LIBRARIES)
    if(AOM_INTERFACE_LINK_LIBRARIES MATCHES vmaf)
        set(AVIF_LIB_USE_CXX ON)
    endif()
endif()

check_avif_option(AVIF_CODEC_AVM TARGET aom PKG_NAME avm)
if(AVIF_CODEC_AVM_ENABLED)
    message(WARNING "libavif: AV2 support with avm is experimental. Only use for testing.")

    # The avm repository is a fork of aom and inherited a lot of folders, files and build artifacts named the same way.
    # Having both dependencies at the same time generates conflicts in includes, binary lookups etc.
    if(AVIF_CODEC_AOM_ENABLED)
        message(FATAL_ERROR "libavif: aom conflicts with avm, bailing out")
    endif()

    target_compile_definitions(avif_obj PUBLIC -DAVIF_CODEC_AVM=1)
    target_sources(avif_obj PRIVATE src/codec_avm.c)

    avif_target_link_library(aom)
    # C++ is needed because of tensorflow-lite.
    set(AVIF_LIB_USE_CXX ON)

    message(STATUS "libavif: Codec enabled: avm (encode/decode)")
endif()

if(NOT AVIF_CODEC_AOM_ENABLED
   AND NOT AVIF_CODEC_DAV1D_ENABLED
   AND NOT AVIF_CODEC_LIBGAV1_ENABLED
   AND NOT AVIF_CODEC_AVM_ENABLED
)
    message(WARNING "libavif: No decoding library is enabled.")
endif()

if(AVIF_LIB_USE_CXX OR AVIF_BUILD_APPS OR (AVIF_BUILD_TESTS AND (AVIF_FUZZTEST OR AVIF_GTEST)))
    enable_language(CXX)
    set(CMAKE_CXX_STANDARD 17)
    set(CMAKE_CXX_STANDARD_REQUIRED ON)
endif()

set_target_properties(avif_obj PROPERTIES C_VISIBILITY_PRESET hidden)
target_include_directories(avif_obj PUBLIC $<BUILD_INTERFACE:${libavif_SOURCE_DIR}/include>)
if(NOT AVIF_LIBYUV_ENABLED)
    target_include_directories(avif_obj PRIVATE ${libavif_SOURCE_DIR}/third_party/libyuv/include/)
endif()
if(AVIF_ENABLE_COMPLIANCE_WARDEN)
    target_include_directories(avif_obj PRIVATE ${libavif_SOURCE_DIR}/ext/ComplianceWarden/src/utils/)
endif()
set(AVIF_PKG_CONFIG_EXTRA_CFLAGS "")
if(BUILD_SHARED_LIBS)
    target_compile_definitions(avif_obj PRIVATE AVIF_DLL AVIF_BUILDING_SHARED_LIBS)
    set(AVIF_PKG_CONFIG_EXTRA_CFLAGS " -DAVIF_DLL")
endif()

# Main avif library.
set_target_properties(avif PROPERTIES VERSION ${LIBRARY_VERSION} SOVERSION ${LIBRARY_SOVERSION})
target_link_libraries(avif PRIVATE avif_obj)
target_include_directories(
    avif PUBLIC $<BUILD_INTERFACE:${libavif_SOURCE_DIR}/include> $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
)
if(BUILD_SHARED_LIBS)
    target_compile_definitions(avif INTERFACE AVIF_DLL)
    if(AVIF_LIB_USE_CXX)
        set_target_properties(avif PROPERTIES LINKER_LANGUAGE "CXX")
    endif()
endif()

# Give access to functions defined in internal.h when BUILD_SHARED_LIBS is ON, to tests for example.
# The avif_internal target should not be used by external code.
if(BUILD_SHARED_LIBS)
    add_library(avif_internal STATIC)
    target_link_libraries(avif_internal PRIVATE avif_obj)
    target_include_directories(avif_internal PUBLIC ${libavif_SOURCE_DIR}/include)
    # Define the following to avoid linking against avif and avif_internal at the same time.
    target_compile_definitions(avif_internal PUBLIC AVIF_USING_STATIC_LIBS)
else()
    include(merge_static_libs)
    set_target_properties(avif PROPERTIES AVIF_LOCAL ON)
    merge_static_libs(avif_static avif)
    # Set the avif target's output to "avif_internal" and set the output name of
    # the combined static archive target (avif_static)) to avif, so that libavif.a
    # is the merged archive.
    set_target_properties(avif_static PROPERTIES OUTPUT_NAME avif EXPORT_NAME avif)
    set_target_properties(avif PROPERTIES OUTPUT_NAME avif_internal EXPORT_NAME avif_internal)
    add_library(avif_internal ALIAS avif)
endif()

option(AVIF_BUILD_EXAMPLES "Build avif examples." OFF)
if(AVIF_BUILD_EXAMPLES)
    set(AVIF_EXAMPLES avif_example_decode_memory avif_example_decode_file avif_example_decode_streaming avif_example_encode)

    foreach(EXAMPLE ${AVIF_EXAMPLES})
        add_executable(${EXAMPLE} examples/${EXAMPLE}.c)
        if(AVIF_LIB_USE_CXX)
            set_target_properties(${EXAMPLE} PROPERTIES LINKER_LANGUAGE "CXX")
        endif()
        target_link_libraries(${EXAMPLE} avif avif_enable_warnings)
    endforeach()
endif()

if(CMAKE_SKIP_INSTALL_RULES)
    set(SKIP_INSTALL_ALL TRUE)
endif()

if(AVIF_BUILD_APPS OR (AVIF_BUILD_TESTS AND (AVIF_FUZZTEST OR AVIF_GTEST)))
    if(AVIF_ZLIBPNG STREQUAL "OFF")
        message(FATAL_ERROR "libavif: AVIF_ZLIBPNG cannot be OFF when AVIF_BUILD_APPS or AVIF_BUILD_TESTS is ON")
    elseif(AVIF_ZLIBPNG STREQUAL "SYSTEM")
        find_package(ZLIB REQUIRED)
        find_package(PNG 1.6.32 REQUIRED) # 1.6.32 or above for png_get_eXIf_1()/png_set_eXIf_1() and iTXt (for XMP).
    endif()
    if(AVIF_JPEG STREQUAL "OFF")
        message(FATAL_ERROR "libavif: AVIF_JPEG cannot be OFF when AVIF_BUILD_APPS or AVIF_BUILD_TESTS is ON")
    elseif(AVIF_JPEG STREQUAL "SYSTEM")
        find_package(JPEG REQUIRED)
    endif()

    if(TARGET LibXml2::LibXml2)
        set(AVIF_ENABLE_JPEG_GAIN_MAP_CONVERSION TRUE)
        add_compile_definitions(AVIF_ENABLE_JPEG_GAIN_MAP_CONVERSION)
    else()
        message(STATUS "libavif: libxml2 not found; avifenc will ignore any gain map in JPEG files")
    endif()

    set(AVIF_APPS_SRCS apps/shared/avifexif.c apps/shared/avifjpeg.c apps/shared/avifpng.c apps/shared/avifutil.c
                       apps/shared/iccmaker.c apps/shared/y4m.c third_party/iccjpeg/iccjpeg.c
    )

    macro(add_avif_apps_library suffix)
        add_library(avif_apps${suffix} STATIC ${AVIF_APPS_SRCS})
        target_link_libraries(avif_apps${suffix} PUBLIC avif${suffix} PRIVATE PNG::PNG ZLIB::ZLIB JPEG::JPEG avif_enable_warnings)
        if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
            target_link_libraries(avif_apps${suffix} PRIVATE m)
        endif()
        if(AVIF_ENABLE_JPEG_GAIN_MAP_CONVERSION)
            target_link_libraries(avif_apps${suffix} PRIVATE LibXml2::LibXml2)
        endif()
        target_include_directories(avif_apps${suffix} INTERFACE apps/shared)
        # In GitHub CI's macos-latest os image, /usr/local/include has not only the headers of libpng
        # and libjpeg but also the headers of an older version of libavif. Put the avif include
        # directory before ${PNG_PNG_INCLUDE_DIR} ${JPEG_INCLUDE_DIR} to prevent picking up old libavif
        # headers from /usr/local/include.
        target_include_directories(avif_apps${suffix} PRIVATE third_party/iccjpeg)
        target_include_directories(avif_apps${suffix} SYSTEM PRIVATE ${PNG_PNG_INCLUDE_DIR} ${JPEG_INCLUDE_DIR})
    endmacro()

    # Main avif_apps library.
    add_avif_apps_library("")

    # avif_apps_internal is to use when linking to avif_internal.
    if(BUILD_SHARED_LIBS)
        add_avif_apps_library(_internal)
    else()
        add_library(avif_apps_internal ALIAS avif_apps)
    endif()
endif()

if(AVIF_BUILD_APPS)
    add_executable(avifenc apps/avifenc.c)
    if(WIN32)
        if(MSVC)
            target_sources(avifenc PRIVATE apps/utf8.manifest)
        elseif(MINGW)
            # MinGW doesn't have a manifest tool (mt.exe), so we need to wrap
            # utf8.manifest in a resource-definition script (.rc file).
            target_sources(avifenc PRIVATE apps/utf8.rc)
        endif()
    endif()
    if(AVIF_LIB_USE_CXX)
        set_target_properties(avifenc PROPERTIES LINKER_LANGUAGE "CXX")
    endif()
    target_link_libraries(avifenc avif_apps avif avif_enable_warnings)
    add_executable(avifdec apps/avifdec.c)
    if(WIN32)
        if(MSVC)
            target_sources(avifdec PRIVATE apps/utf8.manifest)
        elseif(MINGW)
            target_sources(avifdec PRIVATE apps/utf8.rc)
        endif()
    endif()
    if(AVIF_LIB_USE_CXX)
        set_target_properties(avifdec PROPERTIES LINKER_LANGUAGE "CXX")
    endif()
    target_link_libraries(avifdec avif_apps avif avif_enable_warnings)

    include(LocalLibargparse)

    set(AVIFGAINMAPUTIL_SRCS
        apps/avifgainmaputil/avifgainmaputil.cc
        apps/avifgainmaputil/convert_command.cc
        apps/avifgainmaputil/combine_command.cc
        apps/avifgainmaputil/extractgainmap_command.cc
        apps/avifgainmaputil/imageio.cc
        apps/avifgainmaputil/printmetadata_command.cc
        apps/avifgainmaputil/tonemap_command.cc
        apps/avifgainmaputil/program_command.cc
        apps/avifgainmaputil/swapbase_command.cc
    )

    add_executable(avifgainmaputil "${AVIFGAINMAPUTIL_SRCS}")
    if(WIN32)
        if(MSVC)
            target_sources(avifgainmaputil PRIVATE apps/utf8.manifest)
        elseif(MINGW)
            target_sources(avifgainmaputil PRIVATE apps/utf8.rc)
        endif()
    endif()
    set_target_properties(avifgainmaputil PROPERTIES LINKER_LANGUAGE "CXX")
    target_link_libraries(avifgainmaputil libargparse avif_apps avif avif_enable_warnings)

    if(NOT SKIP_INSTALL_APPS AND NOT SKIP_INSTALL_ALL)
        install(
            TARGETS avifenc avifdec avifgainmaputil
            RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}"
            ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
            LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}"
        )
    endif()
endif()

if(AVIF_BUILD_TESTS)
    enable_testing() # Allow ctest to be called from top-level directory.
    add_subdirectory(tests)
    # An executable on Windows searches for DLLs it is linked with in the same
    # directory where it resides and in the directories listed in the Path
    # environment variable. For convenience, copy avif.dll to the tests binary
    # directory to allow are_images_equal.exe and the test programs find it.
    if(WIN32 AND BUILD_SHARED_LIBS)
        add_custom_command(
            TARGET avif
            POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy "$<TARGET_FILE:avif>" ${CMAKE_CURRENT_BINARY_DIR}/tests
            COMMENT "Copying avif.dll to the tests binary directory"
        )
    endif()
endif()

option(AVIF_BUILD_MAN_PAGES "Build avif man pages." OFF)
if(AVIF_BUILD_MAN_PAGES)
    if(AVIF_BUILD_APPS)
        find_program(PANDOC_EXE pandoc)
        if(PANDOC_EXE)
            message(STATUS "libavif: Using pandoc: ${PANDOC_EXE}")
        else()
            message(FATAL_ERROR "libavif: Pandoc is missing, bailing out")
        endif()

        set(MAN_PAGES avifenc.1 avifdec.1)

        foreach(MAN_PAGE ${MAN_PAGES})
            add_custom_command(
                OUTPUT ${MAN_PAGE}
                COMMAND ${PANDOC_EXE} -s -V "footer=libavif ${PROJECT_VERSION}" -f markdown -t man -o
                        "${CMAKE_CURRENT_BINARY_DIR}/${MAN_PAGE}" "${CMAKE_CURRENT_SOURCE_DIR}/doc/${MAN_PAGE}.md"
                DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/doc/${MAN_PAGE}.md"
                VERBATIM
            )
        endforeach()
        add_custom_target(man_pages ALL DEPENDS ${MAN_PAGES})

        foreach(MAN_PAGE ${MAN_PAGES})
            install(FILES "${CMAKE_CURRENT_BINARY_DIR}/${MAN_PAGE}" DESTINATION "${CMAKE_INSTALL_MANDIR}/man1")
        endforeach()
    else()
        message(WARNING "libavif: No man pages are built (AVIF_BUILD_MAN_PAGES); AVIF_BUILD_APPS must be on.")
    endif()
endif()

if(NOT SKIP_INSTALL_LIBRARIES AND NOT SKIP_INSTALL_ALL)
    if(BUILD_SHARED_LIBS)
        set(LIBAVIF_INSTALL_TARGET avif)
    else()
        set(LIBAVIF_INSTALL_TARGET avif_static)
    endif()
    install(
        TARGETS ${LIBAVIF_INSTALL_TARGET}
        EXPORT ${PROJECT_NAME}-config
        RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}"
        ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
        LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}"
    )

    # Enable CMake configs in VCPKG mode
    if(BUILD_SHARED_LIBS OR VCPKG_TARGET_TRIPLET)
        install(EXPORT ${PROJECT_NAME}-config DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/${PROJECT_NAME})

        include(CMakePackageConfigHelpers)
        write_basic_package_version_file(
            ${PROJECT_NAME}-config-version.cmake VERSION ${PROJECT_VERSION} COMPATIBILITY SameMajorVersion
        )
        install(FILES ${CMAKE_CURRENT_BINARY_DIR}/${PROJECT_NAME}-config-version.cmake
                DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/${PROJECT_NAME}
        )
    endif()

    # Handle both relative and absolute paths (e.g. NixOS) for a relocatable package
    if(IS_ABSOLUTE "${CMAKE_INSTALL_INCLUDEDIR}")
        set(PC_INCLUDEDIR "${CMAKE_INSTALL_INCLUDEDIR}")
    else()
        set(PC_INCLUDEDIR "\${prefix}/${CMAKE_INSTALL_INCLUDEDIR}")
    endif()
    if(IS_ABSOLUTE "${CMAKE_INSTALL_LIBDIR}")
        set(PC_LIBDIR "${CMAKE_INSTALL_LIBDIR}")
    else()
        set(PC_LIBDIR "\${exec_prefix}/${CMAKE_INSTALL_LIBDIR}")
    endif()
    configure_file(libavif.pc.cmake ${CMAKE_CURRENT_BINARY_DIR}/libavif.pc @ONLY)
    install(FILES ${CMAKE_CURRENT_BINARY_DIR}/libavif.pc DESTINATION ${CMAKE_INSTALL_LIBDIR}/pkgconfig)
endif()
if(NOT SKIP_INSTALL_HEADERS AND NOT SKIP_INSTALL_ALL)
    install(FILES include/avif/avif.h include/avif/avif_cxx.h DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}/avif")
endif()

# ---------------------------------------------------------------------------------------
# Win32 (Visual Studio) fixups

macro(avif_set_folder_safe target folder)
    if(TARGET ${target})
        set_target_properties(${target} PROPERTIES FOLDER ${folder})
    endif()
endmacro()

macro(avif_exclude_safe target)
    if(TARGET ${target})
        set_target_properties(${target} PROPERTIES EXCLUDE_FROM_DEFAULT_BUILD True)
    endif()
endmacro()

if(WIN32)
    set_property(GLOBAL PROPERTY USE_FOLDERS ON)

    avif_set_folder_safe(avif "ext/avif")
    if(AVIF_BUILD_EXAMPLES)
        foreach(EXAMPLE ${AVIF_EXAMPLES})
            avif_set_folder_safe(${EXAMPLE} "ext/avif/examples")
        endforeach()
    endif()
    if(AVIF_ZLIBPNG STREQUAL "LOCAL")
        avif_set_folder_safe(example "ext/zlibpng")
        avif_set_folder_safe(genfiles "ext/zlibpng")
        avif_set_folder_safe(minigzip "ext/zlibpng")
        avif_set_folder_safe(png_static "ext/zlibpng")
        avif_set_folder_safe(zlib "ext/zlibpng")
        avif_set_folder_safe(zlibstatic "ext/zlibpng")

        # Don't bother building these targets
        avif_exclude_safe(example)
        avif_exclude_safe(genfiles)
        avif_exclude_safe(minigzip)
    endif()
    if(AVIF_JPEG STREQUAL "LOCAL")
        avif_set_folder_safe(JPEG::JPEG "ext/libjpeg-turbo")
    endif()
    if(AVIF_LIBXML2 STREQUAL "LOCAL")
        avif_set_folder_safe(xml2 "ext/libxml2")
    endif()
endif()

add_subdirectory(contrib)
