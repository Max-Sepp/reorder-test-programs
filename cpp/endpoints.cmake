# Compile-time selection of which HTTP endpoints a server includes.
#
# Each option defaults to ON. Turning one OFF excludes that route's code from
# the build entirely (via a preprocessor macro guard in the server source), so
# the endpoint is not present in the resulting binary at all -- useful for
# isolating individual handlers when measuring startup time.
#
# Every server's CMakeLists includes this file and calls
# configure_endpoints(<target>) after creating its executable. The options are
# shared cache variables, so when building the aggregate project (cpp/) a single
# -DENDPOINT_<NAME>=OFF toggles that endpoint across all implementations.
#
# Example:
#   cmake -S cpp/crow -B build -DENDPOINT_BIGFILE=OFF ...   # build without /bigfile

option(ENDPOINT_ECHO      "Include the POST /echo endpoint"      ON)
option(ENDPOINT_LOG       "Include the GET/POST /log endpoints"  ON)
option(ENDPOINT_SMALLFILE "Include the GET /smallfile endpoint"  ON)
option(ENDPOINT_BIGFILE   "Include the GET /bigfile endpoint"    ON)

# Define ENDPOINT_<NAME> for each enabled endpoint on the given target.
function(configure_endpoints target)
  foreach(ep ECHO LOG SMALLFILE BIGFILE)
    if(ENDPOINT_${ep})
      target_compile_definitions(${target} PRIVATE ENDPOINT_${ep})
    endif()
  endforeach()
endfunction()
