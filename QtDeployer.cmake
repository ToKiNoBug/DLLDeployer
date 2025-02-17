if (DEFINED CMAKE_GENERATOR)
    message(STATUS "Running at configuration time")
    option(QD_configure_time "Whether this script is running at configuration time" ON)
else ()
    # Otherwise we guess that it's running at build or installation time.
    message(STATUS "Running at build/install time")
    option(QD_configure_time "Whether this script is running at configuration time" OFF)
endif ()


if (NOT ${WIN32})
    message(WARNING "This project is designed to deploy dll on windows.")
    return()
endif ()

# Replace backslash \ with slash /
function(QD_replace_backslash in_var out_var)
    set(temp)
    foreach (item ${${in_var}})
        string(REPLACE "\\" "/" item ${item})
        list(APPEND temp ${item})
    endforeach ()
    set(${out_var} ${temp} PARENT_SCOPE)
endfunction()


if (NOT ${QD_configure_time})
    set(QD_deployqt_exe @QD_deployqt_exe@)
    set(CMAKE_C_COMPILER "@CMAKE_C_COMPILER@")                          # C compiler
    set(CMAKE_CXX_COMPILER "@CMAKE_CXX_COMPILER@")                      # C++ compiler
    set(CMAKE_CXX_COMPILER_ID "@CMAKE_CXX_COMPILER_ID@")                # C++ compiler id
    set(CMAKE_PREFIX_PATH "@CMAKE_PREFIX_PATH@")                        # CMAKE_PREFIX_PATH is extremely important for find_file
    set(MSVC @MSVC@)                                                    # If the compiler is MSVC-like
    set(QD_target_executable_filename @QD_target_executable_filename@)  # The windeployqt executable
    set(QD_flags @QD_add_deployqt_FLAGS@)                               # Flags passed to windeployqt
    set(ENV{Path} "@QD_env_path@")                                      # Path

    option(QD_install_mode "Run with install mode" 1)                  # Whether the script is run during installation
    set(QD_this_script_file @QD_configured_script_file@)            # The location of this file(generated by configure_file)
    set(QD_install_prefix @QD_add_deployqt_INSTALL_DESTINATION@)          # The installation prefix of executable
    set(QD_working_dir . CACHE FILEPATH "The working directory of windeployqt")
else ()
    find_package(Qt6 COMPONENTS Tools)
    if (NOT ${Qt6_FOUND})
        message(WARNING "Qt6::Tools not found.")
        return()
    endif ()

    set(QtDeployer_script_file ${CMAKE_CURRENT_LIST_FILE}               # The file location of this script
        CACHE FILEPATH "This cmake script")
    set(QD_env_path $ENV{Path})                                         # Convert backslash in path to slash
    QD_replace_backslash(QD_env_path QD_env_path)
endif ()

function(QD_add_deployqt target_executable)
    if (NOT TARGET ${target_executable})
        message(FATAL_ERROR "\"${target_executable}\" is not a target")
    endif ()
    get_target_property(type ${target_executable} TYPE)
    if (NOT ${type} STREQUAL "EXECUTABLE")
        message(FATAL_ERROR "\"${target_executable}\" is not an executable")
    endif ()

    find_program(QD_deployqt_exe
        NAMES windeployqt
        REQUIRED)

    cmake_parse_arguments(QD_add_deployqt
        "BUILD_MODE;INSTALL_MODE;ALL"
        "INSTALL_DESTINATION"
        "FLAGS"
        ${ARGN})

    get_target_property(target_prop_name ${target_executable} NAME)
    set(QD_target_executable_filename "${target_prop_name}.exe")
    set(QD_configured_script_file "${CMAKE_CURRENT_BINARY_DIR}/QtDeployer_deploy_for_${target_executable}.cmake")

    configure_file(${QtDeployer_script_file}
        ${QD_configured_script_file}
        @ONLY)

    if (${QD_add_deployqt_BUILD_MODE})
        set(custom_target_name "QD_deploy_for_${target_executable}")
        if (${QD_add_deployqt_ALL})
            set(QD_all_tag ALL)
        else ()
            set(QD_all_tag)
        endif ()

        add_custom_target(${custom_target_name}
            ${QD_all_tag}
            COMMAND ${CMAKE_COMMAND} -DQD_install_mode:BOOL=FALSE -DQD_working_dir:FILEPATH=${CMAKE_CURRENT_BINARY_DIR} -P ${QD_configured_script_file}
            DEPENDS ${target_executable}
            COMMENT "Run windeployqt for target ${target_executable}")
        set(DLLD_target_name "DLLD_deploy_for_${target_executable}")
        if (TARGET ${DLLD_target_name})
            # DLLD deploying must run after windeployqt
            add_dependencies(${DLLD_target_name}
                ${custom_target_name})
        endif ()

        if (NOT TARGET QD_deploy_all)
            add_custom_target(QD_deploy_all
                COMMENT "Run windeployqt for all required targets")
        endif ()

        add_dependencies(QD_deploy_all
            ${custom_target_name})
    else ()
        if (QD_add_deploy_ALL)
            message(FATAL_ERROR "\"ALL\" can only be assigned for BUILD_MODE")
        endif ()
    endif ()

    if (${QD_add_deployqt_INSTALL_MODE})
        if (NOT DEFINED QD_add_deployqt_INSTALL_DESTINATION)
            message(FATAL_ERROR "INSTALL_DESTINATION must be assigned for INSTALL_MODE")
        endif ()

        cmake_path(IS_ABSOLUTE QD_add_deployqt_INSTALL_DESTINATION is_destination_abs)
        if (${is_destination_abs})
            message(FATAL_ERROR "Value passed to INSTALL_DESTINATION must be relative path, for example: \"bin\".")
        endif ()

        install(SCRIPT ${QD_configured_script_file}
            DESTINATION ${QD_add_deployqt_INSTALL_DESTINATION})
    endif ()
endfunction()

if (NOT ${QD_configure_time})

    if (QD_install_mode)
        message(STATUS "Running ${QD_this_script_file} indirectly...")
        execute_process(COMMAND ${CMAKE_COMMAND} -DQD_install_mode:BOOL=OFF -DQD_working_dir:FILEPATH=${CMAKE_INSTALL_PREFIX}/${QD_install_prefix} -P ${QD_this_script_file}
            COMMAND_ERROR_IS_FATAL ANY)
        return()
    endif ()

    set(exe_location "${QD_working_dir}/${QD_target_executable_filename}")
    #    if (NOT EXISTS ${exe_location})
    #        message(FATAL_ERROR "\"${exe_location}\" doesn't exist.")
    #    endif ()

    message("Running windeployqt at ${QD_working_dir}")
    execute_process(COMMAND ${QD_deployqt_exe} ${QD_target_executable_filename} ${QD_flags}
        WORKING_DIRECTORY ${QD_working_dir}
        COMMAND_ERROR_IS_FATAL ANY)
endif ()