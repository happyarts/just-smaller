# Builds ect-png from ECT's PNG sources only (no mozjpeg, miniz, gzip, zip).
#     cmake -S Tools/ect-png -B build -DECT_SRC=Vendor/ect/src
cmake_minimum_required(VERSION 3.10)
project(ect-png LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
if(NOT ECT_SRC)
  message(FATAL_ERROR "Set ECT_SRC to ECT's src directory")
endif()

# As in ECT's own build: -O3, NEON and the CRC instructions on arm64.
string(REPLACE "-O2" "-O3" CMAKE_C_FLAGS_RELEASE "${CMAKE_C_FLAGS_RELEASE}")
string(REPLACE "-O2" "-O3" CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -march=armv8-a+crc -w")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -march=armv8-a+crc -w")
add_definitions(-DZLIB_CONST -DADLER32_SIMD_NEON -DINFLATE_CHUNK_SIMD_NEON -DINFLATE_CHUNK_READ_64LE)
set(PNG_ARM_NEON on)

add_subdirectory(${ECT_SRC}/lodepng lodepng EXCLUDE_FROM_ALL)
add_subdirectory(${ECT_SRC}/zlib zlib EXCLUDE_FROM_ALL)
# libpng (through optipng) must use the bundled zlib, never a system copy.
set(ZLIB_LIBRARY ${CMAKE_CURRENT_BINARY_DIR}/zlib/libzlib.a)
set(ZLIB_INCLUDE_DIR ${ECT_SRC}/zlib)
add_subdirectory(${ECT_SRC}/zopfli zopfli EXCLUDE_FROM_ALL)
configure_file(${ECT_SRC}/pngusr.h ${CMAKE_CURRENT_BINARY_DIR}/pngusr/pngusr.h COPYONLY)
include_directories(BEFORE ${CMAKE_CURRENT_BINARY_DIR}/pngusr)
add_subdirectory(${ECT_SRC}/optipng optipng EXCLUDE_FROM_ALL)

add_executable(ect-png main.cpp ${ECT_SRC}/zopflipng.cpp ${ECT_SRC}/support.cpp ${ECT_SRC}/LzFind.c)
target_include_directories(ect-png PRIVATE ${ECT_SRC})
target_link_libraries(ect-png lodepng::lodepng optipng::optipng zopfli::zopfli zlib::zlib)
