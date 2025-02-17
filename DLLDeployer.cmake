cmake_minimum_required(VERSION 3.20)

# If CMAKE_GENERATOR is defined, we guess that this script is running at configuration time
if (DEFINED CMAKE_GENERATOR)
    message(STATUS "Running at configuration time")
    option(DLLD_configure_time "Whether this script is running at configuration time" ON)
else ()
    # Otherwise we guess that it's running at build or installation time.
    message(STATUS "Running at build/install time")
    option(DLLD_configure_time "Whether this script is running at configuration time" OFF)
endif ()

if (NOT ${WIN32})
    message(FATAL_ERROR "This project is designed to deploy dll on windows.")
    return()
endif ()


# Replace backslash \ with slash /
function(DLLD_replace_backslash in_var out_var)
    set(temp)
    foreach (item ${${in_var}})
        string(REPLACE "\\" "/" item ${item})
        list(APPEND temp ${item})
    endforeach ()
    set(${out_var} ${temp} PARENT_SCOPE)
endfunction()

if (NOT ${DLLD_configure_time})
    # These variables are necessary when the script running at build or installation time. They are kept by configure_file
    set(DLLD_msvc_utils @DLLD_msvc_utils@)                              # Whether to use binary utils provided by msvc toolchain
    set(DLLD_msvc_dumpbin_exe "@DLLD_msvc_dumpbin_exe@")                # dumpbin.exe
    set(DLLD_gnu_objdump_exe "@DLLD_gnu_objdump_exe@")                  # objdump.exe
    set(CMAKE_C_COMPILER "@CMAKE_C_COMPILER@")                          # C compiler
    set(CMAKE_CXX_COMPILER "@CMAKE_CXX_COMPILER@")                      # C++ compiler
    set(CMAKE_CXX_COMPILER_ID "@CMAKE_CXX_COMPILER_ID@")                # C++ compiler id
    set(CMAKE_PREFIX_PATH "@CMAKE_PREFIX_PATH@")                        # CMAKE_PREFIX_PATH is extremely important for find_file
    set(MSVC @MSVC@)                                                    # If the compiler is MSVC-like
    set(DLLD_filename @DLLD_filename@)                                  # The executable file to be deployed
    set(DLLD_this_script_file @DLLD_configured_script_file@)            # The location of this file(generated by configure_file)
    set(ENV{Path} "@DLLD_env_path@")                                    # Path

    option(DLLD_install_mode "Run with install mode" ON)                # Whether the script is run during installation
    set(DLLD_install_prefix @DLLD_add_deploy_INSTALL_DESTINATION@)      # The installation prefix of executable
    #message(WARNING "CMAKE_CXX_COMPILER_ID = ${CMAKE_CXX_COMPILER_ID}")
else ()
    # These variables are necessary in the configuration time
    set(DLLDeployer_script_file ${CMAKE_CURRENT_LIST_FILE}              # The file location of this script
        CACHE FILEPATH "This cmake script")
    set(DLLD_env_path $ENV{Path})                                       # Convert backslash in path to slash
    DLLD_replace_backslash(DLLD_env_path DLLD_env_path)
endif ()


# Basic functions
function(DLLD_is_dll library_file out_var_name)
    cmake_path(GET library_file EXTENSION extension)
    string(TOLOWER ${extension} extension)
    if (extension MATCHES .dll)
        set(${out_var_name} ON PARENT_SCOPE)
        return()
    endif ()

    set(${out_var_name} OFF PARENT_SCOPE)
    #message(WARNING "extension = ${extension}")
endfunction()


# Tells if the given file is a system library
function(DLLD_is_system_dll lib_file out_var_name)
    DLLD_is_dll(${lib_file} is_dll)
    if (NOT ${is_dll})
        message(WARNING "The given file \"${lib_file}\" is not an dynamic library.")
        set(${out_var_name} OFF PARENT_SCOPE)
        return()
    endif ()


    set(${out_var_name} OFF PARENT_SCOPE)
    cmake_path(GET lib_file FILENAME lib_file)

    set(DLLD_system_prefixes
        C:/Windows/system32/
        C:/Windows/
        C:/Windows/System32/Wbem/
        C:/Windows/System32/WindowsPowerShell/v1.0/
        C:/Windows/System32/OpenSSH/)

    foreach (system_prefix ${DLLD_system_prefixes})
        string(CONCAT temp ${system_prefix} ${lib_file})
        if (EXISTS ${temp})
            set(${out_var_name} ON PARENT_SCOPE)
            return()
        endif ()
    endforeach ()

    if (${lib_file} MATCHES "api-ms-win-*")
        set(${out_var_name} ON PARENT_SCOPE)
        return()
    endif ()
endfunction(DLLD_is_system_dll)

# Guess the abi of c++ compiler, and then
if (${DLLD_configure_time})
    if (${MSVC})
        # if the compiler is msvc-like use msvc utils
        set(DLLD_msvc_utils_default_val ON)
    else ()
        if (${CMAKE_CXX_COMPILER_ID} STREQUAL "GNU")
            # gcc
            set(DLLD_msvc_utils_default_val OFF)
        endif ()

        if (${CMAKE_CXX_COMPILER_ID} STREQUAL "Clang")
            cmake_path(GET CMAKE_CXX_COMPILER PARENT_PATH compiler_prefix)
            cmake_path(GET compiler_prefix PARENT_PATH compiler_prefix)

            if (EXISTS ${compiler_prefix}/bin/c++.exe)
                # Clang with mingw abi(libstdc++ or libc++)
                set(DLLD_msvc_utils_default_val OFF)
            else ()
                # clang with msvc abi and gnu-like command line
                set(DLLD_msvc_utils_default_val ON)
            endif ()
        endif ()

        if (${CMAKE_CXX_COMPILER_ID} STREQUAL "MSVC")
            # MSVC
            set(DLLD_msvc_utils_default_val ON)
        endif ()
    endif ()

endif ()

option(DLLD_msvc_utils "Use msvc utils" ${DLLD_msvc_utils_default_val})


if (${DLLD_msvc_utils})
    #find_program(DLLD_msvc_lib_exe NAMES lib REQUIRED)
    unset(DLLD_msvc_dumpbin_exe)
    find_program(DLLD_msvc_dumpbin_exe NAMES dumpbin REQUIRED)
    # Get dll dependents of a dll. This function runs directly without recursion
    function(DLLD_get_dll_dependents_norecurse dll_file result_var_name)
        DLLD_is_dll(${dll_file} is_dll)
        #        if (NOT ${is_dll})
        #            message(WARNING "${dll_file} is not a dll file, but it was passed to function DLLD_get_dll_dependents_norecurse. Nothing will be done to it.")
        #            return()
        #        endif ()

        if (NOT DLLD_msvc_dumpbin_exe)
            message(FATAL_ERROR "dumpbin.exe is not found on this computer, but you are using a msvc-like compiler, please install msvc and make sure the environment variables are initialized for msvc.")
        endif ()
        # dumpbin /dependents xxx.dll
        execute_process(COMMAND ${DLLD_msvc_dumpbin_exe} /dependents ${dll_file}
            OUTPUT_VARIABLE lib_output
            #OUTPUT_QUIET
            COMMAND_ERROR_IS_FATAL ANY)
        # parse the output of dumpbin
        string(REPLACE "\n" ";" lib_output ${lib_output})
        set(result)
        foreach (output ${lib_output})
            string(STRIP ${output} output)
            if (output MATCHES "Dump of file")
                continue()
            endif ()

            if (NOT output MATCHES .dll)
                #message("\"${output}\" doesn't refer to a filename, skip it.")
                continue()
            endif ()
            list(APPEND result ${output})
        endforeach ()

        #message("result = ${result}")
        set(${result_var_name} ${result} PARENT_SCOPE)
    endfunction(DLLD_get_dll_dependents_norecurse)

else ()

    cmake_path(GET CMAKE_CXX_COMPILER PARENT_PATH compiler_bin_dir)
    unset(DLLD_gnu_objdump_exe)
    find_program(DLLD_gnu_objdump_exe
        NAMES objdump
        HINTS ${compiler_bin_dir}
        REQUIRED)
    # Get dll dependents of a dll
    function(DLLD_get_dll_dependents_norecurse dll_file result_var_name)
        unset(${result_var_name} PARENT_SCOPE)
        if (NOT DLLD_gnu_objdump_exe)
            message(FATAL_ERROR "You are using a non-msvc compiler, but objdump is not found")
        endif ()
        # objdump xxx.dll -x --section=.idata | findstr "DLL Name:"
        execute_process(COMMAND ${DLLD_gnu_objdump_exe} ${dll_file} -x --section=.idata
            COMMAND findstr "DLL Name:"
            OUTPUT_VARIABLE outputs
            COMMAND_ERROR_IS_FATAL ANY)
        # Parse the output of objdump
        string(REPLACE "\n" ";" outputs ${outputs})

        set(result)
        foreach (output ${outputs})
            string(STRIP ${output} output)
            if (NOT ${output} MATCHES "DLL Name:")
                #message("\"${output}\" doesn't contains dll information.")
                continue()
            endif ()

            string(REPLACE "DLL Name: " "" output ${output})
            list(APPEND result ${output})
            #message("output = ${output}")
        endforeach ()
        set(${result_var_name} ${result} PARENT_SCOPE)

    endfunction(DLLD_get_dll_dependents_norecurse)
endif ()

# Get dll deps recursively
function(DLLD_get_dll_dependents dll_location out_var_name)
    unset(${out_var_name} PARENT_SCOPE)

    cmake_parse_arguments(DLLD_get_dll_dependents
        "RECURSE;SKIP_SYSTEM_DLL" "" "" ${ARGN})
    #message("DLLD_get_dll_dependents_RECURSE = ${DLLD_get_dll_dependents_RECURSE}")
    cmake_path(GET dll_location PARENT_PATH dll_parent_path)

    set(dep_list)
    DLLD_get_dll_dependents_norecurse(${dll_location} temp)
    #message("Direct deps of ${dll_location} are: ${temp}")
    foreach (dep ${temp})
        DLLD_is_system_dll(${dep} is_system)

        if (${DLLD_get_dll_dependents_SKIP_SYSTEM_DLL} AND ${is_system})
            continue()
        endif ()


        if (EXISTS "${dll_parent_path}/${dep}")
            set(dep_location "${dll_parent_path}/${dep}")
        else ()
            unset(dep_location)
            find_file(dep_location
                NAMES ${dep}
                PATH_SUFFIXES bin
                NO_CACHE)

            if (NOT dep_location)
                if (NOT ${is_system})
                    message(WARNING "${dep} is not found, it will be skipped.")
                endif ()
                continue()
            endif ()
        endif ()


        list(APPEND dep_list ${dep_location})

        if (${is_system})
            continue()
        endif ()

        if (${DLLD_get_dll_dependents_RECURSE})
            DLLD_get_dll_dependents(${dep_location} temp_var RECURSE)
            list(APPEND dep_list ${temp_var})
        endif ()
    endforeach ()
    #list(APPEND dep_list ${temp})

    #    if(${DLLD_get_dll_dependents_RECURSE})
    #        foreach (dep ${temp})
    #            DLLD_get_dll_dependents(${dep} temp_var RECURSE)
    #            list(APPEND dep_list ${temp_var})
    #        endforeach ()
    #    endif ()
    list(REMOVE_DUPLICATES dep_list)
    set(${out_var_name} ${dep_list} PARENT_SCOPE)
endfunction()

function(DLLD_get_exe_dependents exe_file result_var_name)
    DLLD_get_dll_dependents(${exe_file} temp RECURSE)
    set(${result_var_name} ${temp} PARENT_SCOPE)
endfunction()

function(DLLD_deploy_runtime file_location)
    cmake_path(GET file_location EXTENSION extension)
    #message("extension = ${extension}")
    set(valid_extensions .exe .dll)
    if (NOT (${extension} IN_LIST valid_extensions))
        message(FATAL_ERROR "${file_location} is not a exe or dll.")
    endif ()

    cmake_parse_arguments(DLLD_deploy_runtime
        "COPY;INSTALL" "DESTINATION" "" ${ARGN})

    DLLD_get_exe_dependents(${file_location} dependent_list)

    #message(WARNING "dependent_list = ${dependent_list}")

    foreach (dep ${dependent_list})
        cmake_path(GET dep FILENAME dep_filename)
        #message(WARNING "Processing ${dep_filename}")
        DLLD_is_system_dll(${dep} is_system)
        if (${is_system})
            continue()
        endif ()


        if (${DLLD_deploy_runtime_COPY})
            if (EXISTS "${DLLD_deploy_runtime_DESTINATION}/${dep_filename}")
                message(STATUS "\"${DLLD_deploy_runtime_DESTINATION}/${dep_filename}\" already exists.")
                continue()
            endif ()
            file(COPY ${dep}
                DESTINATION ${DLLD_deploy_runtime_DESTINATION})
            message(STATUS "Copy ${dep} to ${DLLD_deploy_runtime_DESTINATION}")
        endif ()
        if (${DLLD_deploy_runtime_INSTALL})
            install(FILES ${dep}
                DESTINATION ${DLLD_deploy_runtime_DESTINATION})
            message(STATUS "Install ${dep} to ${DLLD_deploy_runtime_DESTINATION}")
        endif ()
    endforeach ()
endfunction()


# Main API
function(DLLD_add_deploy target_name)
    cmake_parse_arguments(DLLD_add_deploy
        "BUILD_MODE;INSTALL_MODE;ALL" "INSTALL_DESTINATION" "" ${ARGN})

    #get_target_property(target_prefix ${target_name} PREFIX)
    get_target_property(target_prop_name ${target_name} NAME)
    #get_target_property(target_suffix ${target_name} PREFIX)

    set(filename "${target_prop_name}.exe")
    #message("The filename is \"${filename}\"")

    set(custom_target_name "DLLD_deploy_for_${target_name}")
    set(DLLD_configured_script_file "${CMAKE_CURRENT_BINARY_DIR}/DLLDeployer_deploy_for_${target_name}.cmake")
    set(DLLD_filename ${filename})
    configure_file(${DLLDeployer_script_file}
        ${DLLD_configured_script_file}
        @ONLY)

    # Build mode
    if (${DLLD_add_deploy_BUILD_MODE})
        if (${DLLD_add_deploy_ALL})
            set(DLLD_all_tag ALL)
        else ()
            set(DLLD_all_tag)
        endif ()

        add_custom_target(${custom_target_name}
            ${DLLD_all_tag}
            COMMAND ${CMAKE_COMMAND} -DDLLD_install_mode:BOOL=false -P ${DLLD_configured_script_file}
            WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
            DEPENDS ${target_name}
            COMMENT "Deploy dlls for target ${target_name}"
            )

        set(QD_custom_target_name "QD_deploy_for_${target_name}")
        if (TARGET ${QD_custom_target_name})
            # DLLD deploying must run after windeployqt
            add_dependencies(${custom_target_name} ${QD_custom_target_name})
        endif ()

        if (NOT TARGET DLLD_deploy_all)
            add_custom_target(DLLD_deploy_all
                COMMENT "Deploy dlls for all targets")
        endif ()
        add_dependencies(DLLD_deploy_all
            ${custom_target_name})
    else ()
        if (DLLD_add_deploy_ALL)
            message(FATAL_ERROR "\"ALL\" can only be assigned for BUILD_MODE")
        endif ()
    endif ()
    # Install mode
    if (${DLLD_add_deploy_INSTALL_MODE})
        #message("DLLD_add_deploy_INSTALL_DESTINATION = ${DLLD_add_deploy_INSTALL_DESTINATION}")
        if (NOT DEFINED DLLD_add_deploy_INSTALL_DESTINATION)
            message(FATAL_ERROR "INSTALL_DESTINATION must be assigned for INSTALL_MODE")
        endif ()

        cmake_path(IS_ABSOLUTE DLLD_add_deploy_INSTALL_DESTINATION is_destination_abs)
        if (${is_destination_abs})
            message(FATAL_ERROR "Value passed to INSTALL_DESTINATION must be relative path, for example: \"bin\".")
        endif ()

        install(SCRIPT ${DLLD_configured_script_file}
            DESTINATION ${DLLD_add_deploy_INSTALL_DESTINATION})
    endif ()
endfunction()

# This code will execute only during build or installation
if (NOT ${DLLD_configure_time})
    #cmake_path(GET DLLD_this_script_file PARENT_PATH parent_path)

    #    if(NOT parent_path STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    #        message(FATAL_ERROR "This code is expected to run at ${parent_path}, but current running at ${CMAKE_CURRENT_SOURCE_DIR}")
    #    endif ()

    if (NOT ${DLLD_install_mode})
        # Deploy dlls directly in current dir
        message(STATUS "Deploying dlls for ${DLLD_filename}")
        #message(STATUS "CMAKE_CURRENT_SOURCE_DIR = ${CMAKE_CURRENT_SOURCE_DIR}")
        #message(WARNING "DLLD_filename = ${DLLD_filename}")
        DLLD_deploy_runtime(${DLLD_filename}
            COPY
            SKIP_SYSTEM_DLL
            DESTINATION .)
        return()
    else ()
        # Run this script in another location(installation prefix)
        # This is necessary because although the script is installed by install(SCRIPT ... DESTINATION...), the execution directory is still the same dir of the configured script.
        message(STATUS "Running ${DLLD_this_script_file} indirectly...")
        execute_process(COMMAND ${CMAKE_COMMAND} -DDLLD_install_mode:BOOL=false -P ${DLLD_this_script_file}
            WORKING_DIRECTORY "${CMAKE_INSTALL_PREFIX}/${DLLD_install_prefix}"
            COMMAND_ERROR_IS_FATAL ANY)
    endif ()

endif ()