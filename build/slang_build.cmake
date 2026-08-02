# Portable Slang build driver for eggy (cmake -P).
# Follows upstream docs/building.md: recursive source + CMake configure/build,
# and SLANG_GENERATORS_PATH when cross-compiling.
#
# usage:
#   cmake -P slang_build.cmake <src_dir> <tag> <build_dir> <prefix_dir> \
#         <config> <triple> <cross:0|1> <generators_dir> <zig_exe>

if(NOT CMAKE_ARGC EQUAL 12)
  message(FATAL_ERROR
    "usage: cmake -P slang_build.cmake <src> <tag> <build> <prefix> <config> <triple> <cross> <generators> <zig_exe>")
endif()

set(SRC_DIR "${CMAKE_ARGV3}")
set(TAG "${CMAKE_ARGV4}")
set(BUILD_DIR "${CMAKE_ARGV5}")
set(PREFIX_DIR "${CMAKE_ARGV6}")
set(CONFIG "${CMAKE_ARGV7}")
set(TRIPLE "${CMAKE_ARGV8}")
set(CROSS "${CMAKE_ARGV9}")
set(GENERATORS_DIR "${CMAKE_ARGV10}")
set(ZIG_EXE "${CMAKE_ARGV11}")

set(STAMP_FILE "${PREFIX_DIR}/.eggy-slang-stamp")
set(EXPECTED_STAMP "slang-${TAG}-${CONFIG}-${TRIPLE}")
set(MARKER "${SRC_DIR}/external/miniz/CMakeLists.txt")

function(slang_has_runtime out_var)
  if(EXISTS "${PREFIX_DIR}/bin/slang.dll"
     OR EXISTS "${PREFIX_DIR}/bin/libslang.so"
     OR EXISTS "${PREFIX_DIR}/bin/libslang.dylib"
     OR EXISTS "${PREFIX_DIR}/lib/libslang.so"
     OR EXISTS "${PREFIX_DIR}/lib/libslang.dylib"
     OR EXISTS "${PREFIX_DIR}/bin/slang-compiler.dll"
     OR EXISTS "${PREFIX_DIR}/lib/libslang-compiler.so"
     OR EXISTS "${PREFIX_DIR}/lib/libslang-compiler.dylib")
    set(${out_var} TRUE PARENT_SCOPE)
  else()
    set(${out_var} FALSE PARENT_SCOPE)
  endif()
endfunction()

function(slang_has_import_lib out_var)
  if(EXISTS "${PREFIX_DIR}/lib/slang.lib"
     OR EXISTS "${PREFIX_DIR}/lib/libslang.a"
     OR EXISTS "${PREFIX_DIR}/lib/libslang.so"
     OR EXISTS "${PREFIX_DIR}/lib/libslang.dylib"
     OR EXISTS "${PREFIX_DIR}/lib/slang-compiler.lib"
     OR EXISTS "${PREFIX_DIR}/lib/libslang-compiler.a"
     OR EXISTS "${PREFIX_DIR}/lib/libslang-compiler.so")
    set(${out_var} TRUE PARENT_SCOPE)
  else()
    set(${out_var} FALSE PARENT_SCOPE)
  endif()
endfunction()

slang_has_runtime(has_rt)
slang_has_import_lib(has_lib)
if(has_rt AND has_lib AND EXISTS "${STAMP_FILE}")
  file(READ "${STAMP_FILE}" actual_stamp)
  string(STRIP "${actual_stamp}" actual_stamp)
  if(actual_stamp STREQUAL EXPECTED_STAMP)
    message(STATUS "Slang already built (${EXPECTED_STAMP}); skipping")
    return()
  endif()
endif()

# --- source (docs/building.md: clone --recursive) ---------------------------------
if(NOT EXISTS "${MARKER}")
  find_program(GIT_EXECUTABLE git REQUIRED)
  get_filename_component(PARENT "${SRC_DIR}" DIRECTORY)
  file(MAKE_DIRECTORY "${PARENT}")
  if(EXISTS "${SRC_DIR}")
    file(REMOVE_RECURSE "${SRC_DIR}")
  endif()
  message(STATUS "Cloning Slang ${TAG} with submodules into ${SRC_DIR}")
  execute_process(
    COMMAND "${GIT_EXECUTABLE}" clone --recurse-submodules --depth 1 --branch "${TAG}"
            "https://github.com/shader-slang/slang.git" "${SRC_DIR}"
    RESULT_VARIABLE clone_result
  )
  if(NOT clone_result EQUAL 0)
    message(FATAL_ERROR "git clone failed (${clone_result})")
  endif()
  if(NOT EXISTS "${MARKER}")
    execute_process(
      COMMAND "${GIT_EXECUTABLE}" submodule update --init --recursive
      WORKING_DIRECTORY "${SRC_DIR}"
      RESULT_VARIABLE sub_result
    )
    if(NOT sub_result EQUAL 0)
      message(FATAL_ERROR "git submodule update failed (${sub_result})")
    endif()
  endif()
  if(NOT EXISTS "${MARKER}")
    message(FATAL_ERROR "Slang submodules missing; see docs/building.md")
  endif()
else()
  message(STATUS "Slang source ready: ${SRC_DIR}")
endif()

set(COMMON_CACHE
  -DSLANG_ENABLE_TESTS=OFF
  -DSLANG_ENABLE_EXAMPLES=OFF
  -DSLANG_ENABLE_GFX=OFF
  -DSLANG_ENABLE_SLANG_RHI=OFF
  -DSLANG_ENABLE_SLANGD=OFF
  -DSLANG_ENABLE_SLANGI=OFF
  -DSLANG_ENABLE_REPLAYER=OFF
  -DSLANG_SLANG_LLVM_FLAVOR=DISABLE
  -DSLANG_ENABLE_CUDA=OFF
  -DSLANG_ENABLE_OPTIX=OFF
  -DSLANG_ENABLE_NVAPI=OFF
  -DSLANG_ENABLE_AFTERMATH=OFF
  -DSLANG_IGNORE_ABORT_MSG=ON
  -DSLANG_ENABLE_RELEASE_DEBUG_INFO=OFF
)

# --- host generators when cross-compiling (docs/building.md) ---------------------
if(CROSS STREQUAL "1")
  set(GEN_BUILD_DIR "${BUILD_DIR}-generators")
  message(STATUS "Building Slang generators for host -> ${GENERATORS_DIR}")
  execute_process(
    COMMAND "${CMAKE_COMMAND}"
            -S "${SRC_DIR}"
            -B "${GEN_BUILD_DIR}"
            -DCMAKE_BUILD_TYPE=Release
            -DSLANG_ENABLE_SLANGC=OFF
            -DSLANG_ENABLE_SLANGRT=OFF
            ${COMMON_CACHE}
    RESULT_VARIABLE gen_cfg
  )
  if(NOT gen_cfg EQUAL 0)
    message(FATAL_ERROR "generator configure failed (${gen_cfg})")
  endif()
  execute_process(
    COMMAND "${CMAKE_COMMAND}" --build "${GEN_BUILD_DIR}" --config Release --target all-generators --parallel
    RESULT_VARIABLE gen_build
  )
  if(NOT gen_build EQUAL 0)
    message(FATAL_ERROR "generator build failed (${gen_build})")
  endif()
  execute_process(
    COMMAND "${CMAKE_COMMAND}" --install "${GEN_BUILD_DIR}" --prefix "${GENERATORS_DIR}" --component generators --config Release
    RESULT_VARIABLE gen_install
  )
  if(NOT gen_install EQUAL 0)
    message(FATAL_ERROR "generator install failed (${gen_install})")
  endif()
endif()

# --- target configure / build ----------------------------------------------------
set(CONFIGURE_ARGS
  -S "${SRC_DIR}"
  -B "${BUILD_DIR}"
  -DCMAKE_BUILD_TYPE=${CONFIG}
  -DCMAKE_INSTALL_PREFIX=${PREFIX_DIR}
  -DSLANG_ENABLE_SLANGC=ON
  -DSLANG_ENABLE_SLANGRT=ON
  -DSLANG_ENABLE_SLANG_PROXY=ON
  ${COMMON_CACHE}
)
if(CROSS STREQUAL "1")
  list(APPEND CONFIGURE_ARGS
    -DSLANG_GENERATORS_PATH=${GENERATORS_DIR}/bin
    -DCMAKE_C_COMPILER=${ZIG_EXE}
    -DCMAKE_CXX_COMPILER=${ZIG_EXE}
    -DCMAKE_C_COMPILER_ARG1=cc
    -DCMAKE_CXX_COMPILER_ARG1=c++
    -DCMAKE_C_FLAGS=--target=${TRIPLE}
    -DCMAKE_CXX_FLAGS=--target=${TRIPLE}
  )
endif()

message(STATUS "Configuring Slang for ${TRIPLE} (${CONFIG})")
execute_process(COMMAND "${CMAKE_COMMAND}" ${CONFIGURE_ARGS} RESULT_VARIABLE cfg_result)
if(NOT cfg_result EQUAL 0)
  message(FATAL_ERROR "Slang configure failed (${cfg_result})")
endif()

message(STATUS "Building Slang")
execute_process(
  COMMAND "${CMAKE_COMMAND}" --build "${BUILD_DIR}" --config "${CONFIG}"
          --target slang --target slangc --target slang-proxy --target slang-rt --parallel
  RESULT_VARIABLE build_result
)
if(NOT build_result EQUAL 0)
  message(FATAL_ERROR "Slang build failed (${build_result})")
endif()

execute_process(
  COMMAND "${CMAKE_COMMAND}" --install "${BUILD_DIR}" --prefix "${PREFIX_DIR}" --config "${CONFIG}"
  RESULT_VARIABLE install_result
)
# Partial installs are fine; we normalize outputs below.
if(NOT install_result EQUAL 0)
  message(STATUS "cmake --install returned ${install_result}; copying build outputs")
endif()

# --- normalize prefix ------------------------------------------------------------
file(MAKE_DIRECTORY "${PREFIX_DIR}/bin" "${PREFIX_DIR}/lib" "${PREFIX_DIR}/include")

set(BIN_CANDIDATES "${BUILD_DIR}/${CONFIG}/bin" "${BUILD_DIR}/bin" "${BUILD_DIR}/${CONFIG}")
set(LIB_CANDIDATES "${BUILD_DIR}/${CONFIG}/lib" "${BUILD_DIR}/lib" "${BUILD_DIR}/${CONFIG}")

set(BIN_SRC "")
foreach(cand IN LISTS BIN_CANDIDATES)
  if(EXISTS "${cand}/slang.dll" OR EXISTS "${cand}/libslang.so" OR EXISTS "${cand}/libslang.dylib"
     OR EXISTS "${cand}/slang-compiler.dll" OR EXISTS "${cand}/libslang-compiler.so"
     OR EXISTS "${cand}/libslang-compiler.dylib")
    set(BIN_SRC "${cand}")
    break()
  endif()
endforeach()

set(LIB_SRC "")
foreach(cand IN LISTS LIB_CANDIDATES)
  if(EXISTS "${cand}/slang.lib" OR EXISTS "${cand}/libslang.a" OR EXISTS "${cand}/libslang.so"
     OR EXISTS "${cand}/libslang.dylib" OR EXISTS "${cand}/slang-compiler.lib"
     OR EXISTS "${cand}/libslang-compiler.a" OR EXISTS "${cand}/libslang-compiler.so")
    set(LIB_SRC "${cand}")
    break()
  endif()
endforeach()

slang_has_runtime(has_rt)
if(NOT has_rt)
  if(BIN_SRC STREQUAL "")
    message(FATAL_ERROR "Slang runtime libraries not found under ${BUILD_DIR}")
  endif()
  file(GLOB BIN_FILES "${BIN_SRC}/*")
  file(COPY ${BIN_FILES} DESTINATION "${PREFIX_DIR}/bin")
endif()

slang_has_import_lib(has_lib)
if(NOT has_lib)
  if(LIB_SRC STREQUAL "")
    message(FATAL_ERROR "Slang link libraries not found under ${BUILD_DIR}")
  endif()
  file(GLOB LIB_FILES "${LIB_SRC}/*.lib" "${LIB_SRC}/*.a" "${LIB_SRC}/*.so" "${LIB_SRC}/*.dylib")
  file(COPY ${LIB_FILES} DESTINATION "${PREFIX_DIR}/lib")
endif()

if(NOT EXISTS "${PREFIX_DIR}/include/slang.h")
  set(HEADER_SRC "${BUILD_DIR}/${CONFIG}/include")
  if(NOT EXISTS "${HEADER_SRC}/slang.h")
    set(HEADER_SRC "${SRC_DIR}/include")
  endif()
  file(COPY "${HEADER_SRC}/" DESTINATION "${PREFIX_DIR}/include")
endif()

file(WRITE "${STAMP_FILE}" "${EXPECTED_STAMP}")
message(STATUS "Slang prefix ready: ${PREFIX_DIR}")
