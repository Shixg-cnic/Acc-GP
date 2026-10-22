cmake_minimum_required(VERSION 3.24)

if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
    set(CMAKE_CUDA_ARCHITECTURES native CACHE STRING "CUDA architectures")
endif()
project(gpart LANGUAGES CXX CUDA)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)
find_package(CUDAToolkit REQUIRED)
set(METIS_ROOT "" CACHE PATH "METIS installation prefix (matching header and library)")
find_path(METIS_INCLUDE_DIR metis.h HINTS "${METIS_ROOT}" PATH_SUFFIXES include include/metis REQUIRED)
find_library(METIS_LIBRARY NAMES metis HINTS "${METIS_ROOT}" PATH_SUFFIXES lib lib64 REQUIRED)
# Current standalone METIS builds require GKlib; packaged shared builds may
# contain those symbols themselves, so a separate GKlib library is optional.
find_library(GKLIB_LIBRARY NAMES GKlib gklib HINTS "${METIS_ROOT}" PATH_SUFFIXES lib lib64)
add_library(gpart_metis UNKNOWN IMPORTED)
set_target_properties(gpart_metis PROPERTIES
    IMPORTED_LOCATION "${METIS_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${METIS_INCLUDE_DIR}")
if(GKLIB_LIBRARY)
    set_property(TARGET gpart_metis APPEND PROPERTY INTERFACE_LINK_LIBRARIES "${GKLIB_LIBRARY}")
endif()
if(UNIX)
    find_package(Threads REQUIRED)
    set_property(TARGET gpart_metis APPEND PROPERTY INTERFACE_LINK_LIBRARIES m Threads::Threads)
endif()
message(STATUS "METIS initialization: ${METIS_LIBRARY} (${METIS_INCLUDE_DIR})")
find_package(OpenMP QUIET COMPONENTS CXX)
add_executable(gpart_verify_csr tools/verify_csr.cpp)
target_compile_options(gpart_verify_csr PRIVATE -O3)
if(OpenMP_CXX_FOUND)
    target_link_libraries(gpart_verify_csr PRIVATE OpenMP::OpenMP_CXX)
endif()

add_library(gpart_options INTERFACE)
target_include_directories(gpart_options INTERFACE ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_compile_options(gpart_options INTERFACE
    $<$<COMPILE_LANGUAGE:CXX>:-O3;-march=native>
    $<$<COMPILE_LANGUAGE:CUDA>:-O3;-Xcompiler=-march=native>)
target_link_libraries(gpart_options INTERFACE CUDA::cudart_static)
set_source_files_properties(src/graph.cpp PROPERTIES LANGUAGE CUDA)

# One graph representation and one production partitioning executable.
add_library(gpart_graph_standard STATIC src/graph.cpp)
target_link_libraries(gpart_graph_standard PUBLIC gpart_options)
add_library(gpart_coarsening_standard STATIC src/coarsen.cu)
target_link_libraries(gpart_coarsening_standard PUBLIC gpart_graph_standard)
add_library(gpart_initial_metis_standard STATIC src/initial_partition_metis.cu)
target_link_libraries(gpart_initial_metis_standard PUBLIC gpart_graph_standard PRIVATE gpart_metis)
add_library(gpart_refinement_standard STATIC src/refine.cu src/uncoarsen.cu)
target_link_libraries(gpart_refinement_standard PUBLIC gpart_graph_standard)
add_executable(gpart_partition_standard app/partition_main.cu)
target_link_libraries(gpart_partition_standard PRIVATE
    gpart_coarsening_standard gpart_initial_metis_standard gpart_refinement_standard)
