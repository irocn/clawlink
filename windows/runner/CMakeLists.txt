cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# === libfakeip (DLL only)
# Source crate: sibling itunnel/crates/libfakeip  (e.g. E:/github/itunnel/crates/libfakeip)
# Build there:
#   cd itunnel/crates/libfakeip
#   cargo build --release
#   → target/release/libfakeip.dll
# Then sync: scripts/sync-libfakeip.ps1
# Or set CLAWLINK_BUILD_LIBFAKEIP=ON to cargo-build during Flutter/CMake.
option(CLAWLINK_BUILD_LIBFAKEIP "Run cargo build --release for libfakeip during CMake" OFF)
set(_clawlink_windows_lib "${CMAKE_SOURCE_DIR}/../lib")
set(_bundled_fakeip "${_clawlink_windows_lib}/libfakeip.dll")
if(DEFINED ENV{CLAWLINK_LIBFAKEIP_ROOT} AND NOT "$ENV{CLAWLINK_LIBFAKEIP_ROOT}" STREQUAL "")
  file(TO_CMAKE_PATH "$ENV{CLAWLINK_LIBFAKEIP_ROOT}" _lf_root)
else()
  # windows/runner → ../../itunnel/crates/libfakeip
  set(_lf_root "${CMAKE_SOURCE_DIR}/../../itunnel/crates/libfakeip")
endif()
set(_lf_dll "${_lf_root}/target/release/libfakeip.dll")
set(_bundle_fakeip_dll FALSE)

if(WIN32)
  if(CLAWLINK_BUILD_LIBFAKEIP)
    find_program(CARGO_EXECUTABLE cargo)
    if(NOT CARGO_EXECUTABLE)
      message(FATAL_ERROR "CLAWLINK_BUILD_LIBFAKEIP=ON but cargo not found")
    endif()
    if(NOT EXISTS "${_lf_root}/Cargo.toml")
      message(FATAL_ERROR "libfakeip crate not found at:\n  ${_lf_root}\nExpected sibling itunnel/crates/libfakeip (or set CLAWLINK_LIBFAKEIP_ROOT).")
    endif()
    add_custom_target(libfakeip_dll
      COMMAND ${CARGO_EXECUTABLE} build --release
      COMMAND ${CMAKE_COMMAND} -E make_directory "${_clawlink_windows_lib}"
      COMMAND ${CMAKE_COMMAND} -E copy_if_different "${_lf_dll}" "${_bundled_fakeip}"
      COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_SOURCE_DIR}/../../libs"
      COMMAND ${CMAKE_COMMAND} -E copy_if_different "${_lf_dll}" "${CMAKE_SOURCE_DIR}/../../libs/libfakeip.dll"
      WORKING_DIRECTORY "${_lf_root}"
      COMMENT "libfakeip: cargo build --release → copy libfakeip.dll"
      VERBATIM
    )
    add_dependencies(${BINARY_NAME} libfakeip_dll)
    set(_bundle_fakeip_dll TRUE)
  elseif(EXISTS "${_bundled_fakeip}")
    set(_bundle_fakeip_dll TRUE)
  elseif(EXISTS "${_lf_dll}")
    # Prefer already-built DLL from itunnel/crates/libfakeip/target/release/
    add_custom_target(libfakeip_dll
      COMMAND ${CMAKE_COMMAND} -E make_directory "${_clawlink_windows_lib}"
      COMMAND ${CMAKE_COMMAND} -E copy_if_different "${_lf_dll}" "${_bundled_fakeip}"
      COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_SOURCE_DIR}/../../libs"
      COMMAND ${CMAKE_COMMAND} -E copy_if_different "${_lf_dll}" "${CMAKE_SOURCE_DIR}/../../libs/libfakeip.dll"
      COMMENT "libfakeip: copy existing ${_lf_dll}"
      VERBATIM
    )
    add_dependencies(${BINARY_NAME} libfakeip_dll)
    set(_bundle_fakeip_dll TRUE)
  else()
    message(WARNING "libfakeip.dll missing. Build it first:\n  cd ${_lf_root}\n  cargo build --release\nThen: powershell -File scripts/sync-libfakeip.ps1")
  endif()
endif()

# Bundle libfakeip.dll next to the EXE / data / libs for Dart FFI lookup.
if(_bundle_fakeip_dll)
  add_custom_command(
    TARGET ${BINARY_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${_bundled_fakeip}"
      "$<TARGET_FILE_DIR:${BINARY_NAME}>/libfakeip.dll"
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:${BINARY_NAME}>/data"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${_bundled_fakeip}"
      "$<TARGET_FILE_DIR:${BINARY_NAME}>/data/libfakeip.dll"
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:${BINARY_NAME}>/libs"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${_bundled_fakeip}"
      "$<TARGET_FILE_DIR:${BINARY_NAME}>/libs/libfakeip.dll"
    VERBATIM
  )
endif()

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Elevate GUI (local proxy needs Admin). Prefer linker UAC over embedding
# requireAdministrator in runner.exe.manifest — avoids LNK1327 / mt.exe merge failures.
set_target_properties(${BINARY_NAME} PROPERTIES
  LINK_FLAGS "/MANIFESTUAC:\"level='requireAdministrator' uiAccess='false'\""
)
