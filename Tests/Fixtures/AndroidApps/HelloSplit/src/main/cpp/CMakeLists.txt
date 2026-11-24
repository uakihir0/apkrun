cmake_minimum_required(VERSION 3.22.1)
project(hellosplit)

add_library(hellosplit SHARED native-lib.cpp)

# check-fixtures.sh byte-compares the built .apks; drop the linker's
# nondeterministic build-id so rebuilds are reproducible.
target_link_options(hellosplit PRIVATE "-Wl,--build-id=none")
