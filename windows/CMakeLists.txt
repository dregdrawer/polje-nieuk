# polje nieuk — JUCE version (Windows; also builds on macOS / Linux for testing).
#   cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release
# On Windows use clang-cl for the Mutable Instruments code:  cmake -B build -T ClangCL
cmake_minimum_required(VERSION 3.22)
project(PoljeNieuk VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if (APPLE)
  set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "Mac architectures")
  set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0" CACHE STRING "")
endif()

include(FetchContent)
FetchContent_Declare(JUCE
  URL https://github.com/juce-framework/JUCE/archive/refs/tags/8.0.4.tar.gz
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(JUCE)

# Emilie Gillet's open-source Eurorack DSP (MIT) + the C bridge — the same code the Mac / iPad app uses
set(MI ${CMAKE_CURRENT_SOURCE_DIR}/../Vendor/mutable)
file(GLOB_RECURSE MI_SRC CONFIGURE_DEPENDS
  ${MI}/clouds/*.cc ${MI}/rings/*.cc ${MI}/plaits/*.cc ${MI}/elements/*.cc ${MI}/warps/*.cc
  ${MI}/tides2/*.cc ${MI}/marbles/*.cc ${MI}/stages/*.cc ${MI}/braids/*.cc ${MI}/beads/*.cc)
add_library(MutableDSP STATIC ${MI_SRC}
  ${MI}/stmlib/dsp/units.cc ${MI}/stmlib/dsp/atan.cc ${MI}/stmlib/utils/random.cc ${MI}/bridge/mi_bridge.cpp)
target_include_directories(MutableDSP PUBLIC ${MI} ${MI}/bridge/include)
target_compile_definitions(MutableDSP PRIVATE TEST)
set_target_properties(MutableDSP PROPERTIES CXX_STANDARD 14 CXX_EXTENSIONS ON)
if (MSVC)
  target_compile_options(MutableDSP PRIVATE /w)
else()
  target_compile_options(MutableDSP PRIVATE -w)
endif()

juce_add_gui_app(PoljeNieuk
  PRODUCT_NAME "polje nieuk"
  COMPANY_NAME "polje nieuk"
  BUNDLE_ID "com.grzegorzdalmata.poljenieuk.juce"
  ICON_BIG ${CMAKE_CURRENT_SOURCE_DIR}/../App/Assets.xcassets/AppIcon.appiconset/icon-ios-1024.png
  MICROPHONE_PERMISSION_ENABLED TRUE
  MICROPHONE_PERMISSION_TEXT "polje nieuk processes audio from your modular through your audio interface.")
juce_generate_juce_header(PoljeNieuk)

target_sources(PoljeNieuk PRIVATE
  Source/Main.cpp Source/Engine.cpp Source/Registry.cpp
  Source/ModulesCore.cpp Source/ModulesFX.cpp Source/ModulesMI.cpp Source/UI.cpp)

target_compile_definitions(PoljeNieuk PRIVATE
  JUCE_WEB_BROWSER=0 JUCE_USE_CURL=0 JUCE_APPLICATION_NAME_STRING="polje nieuk" JUCE_APPLICATION_VERSION_STRING="0.1.0"
  JUCE_DISPLAY_SPLASH_SCREEN=0)

target_link_libraries(PoljeNieuk PRIVATE
  MutableDSP juce::juce_audio_utils juce::juce_audio_devices juce::juce_gui_extra
  PUBLIC juce::juce_recommended_config_flags juce::juce_recommended_lto_flags juce::juce_recommended_warning_flags)
