#!/bin/bash

#********************************************************************************
# Copyright 2014 IBM
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#********************************************************************************

# load helper functions
source $(dirname "$0")/deploy_utilities.sh

insert_inventory(){
    update_inventory $1 $2 "insert"
}
delete_inventory(){
    update_inventory $1 $2 "delete"
}

# function to wait for a container to start
# takes a container name as the only parameter
wait_for (){
    local WAITING_FOR=$1
    if [ -z ${WAITING_FOR} ]; then
        log_and_echo "$ERROR" "Expected container name to be passed into wait_for"
        return 1
    fi
    local COUNTER=0
    local STATE="unknown"
    while [[ ( $COUNTER -lt 180 ) && ("${STATE}" != "Running") && ("${STATE}" != "Crashed") ]]; do
        let COUNTER=COUNTER+1
        STATE=$($IC_COMMAND inspect $WAITING_FOR 2> /dev/null | grep "Status" | awk '{print $2}' | sed 's/"//g')
        if [ -z "${STATE}" ]; then
            STATE="being placed"
        fi
        log_and_echo "${WAITING_FOR} is ${STATE}"
        sleep 3
    done
    if [ "$STATE" == "Crashed" ]; then
        return 2
    fi
    if [ "$STATE" != "Running" ]; then
        log_and_echo "$ERROR" "Failed to start instance "
        return 1
    fi
    return 0
}

# function to wait for a container to start
# takes a container name as the only parameter
wait_for_stopped (){
    local WAITING_FOR=$1
    if [ -z ${WAITING_FOR} ]; then
        log_and_echo "$ERROR" "Expected container name to be passed into wait_for"
        return 1
    fi
    local COUNTER=0
    local FOUND=0
    while [[ ( $COUNTER -lt 60 ) && ("${STATE}" != "Shutdown")  ]]; do
        let COUNTER=COUNTER+1
        STATE=$($IC_COMMAND inspect $WAITING_FOR 2> /dev/null | grep "Status" | awk '{print $2}' | sed 's/"//g')
        if [ -z "${STATE}" ]; then
            STATE="being deleted"
        fi
        sleep 2
    done
    if [ "$STATE" != "Shutdown" ]; then
        log_and_echo "$ERROR" "Failed to stop instance $WAITING_FOR "
        return 1
    else
        log_and_echo "Successfully stopped $WAITING_FOR"
    fi
    return 0
}

deploy_container() {
    local MY_CONTAINER_NAME=$1
    log_and_echo "deploying container ${MY_CONTAINER_NAME}"

    if [ -z MY_CONTAINER_NAME ];then
        log_and_echo "$ERROR" "No container name was provided"
        return 1
    fi

    # check to see if that container name is already in use
    $IC_COMMAND inspect ${MY_CONTAINER_NAME} > /dev/null
    local FOUND=$?
    if [ ${FOUND} -eq 0 ]; then
        log_and_echo "$ERROR" "${MY_CONTAINER_NAME} already exists.  Please remove these containers or change the Name of the container or group being deployed"
    fi

    # check to see if container image is exisit
    check_image "$FULL_IMAGE_NAME"
    local RESULT=$?
    if [ $RESULT -ne 0 ]; then
        log_and_echo "$ERROR" "Image '${FULL_IMAGE_NAME}' does not exist."
        $IC_COMMAND images
        return 1
    fi

    local BIND_PARMS=""
    # validate the bind_to parameter if one was passed
    if [ ! -z "${BIND_TO}" ]; then
        log_and_echo "Binding to ${BIND_TO}"
        local APP=$(cf env ${BIND_TO})
        local APP_FOUND=$?
        if [ $APP_FOUND -ne 0 ]; then
            log_and_echo "$ERROR" "${BIND_TO} application not found in space.  Please confirm that you wish to bind the container to the application, and that the application exists"
        fi
        local VCAP_SERVICES=$(echo "${APP}" | grep "VCAP_SERVICES")
        local SERVICES_BOUND=$?
        if [ $SERVICES_BOUND -ne 0 ]; then
            log_and_echo "$WARN" "No services appear to be bound to ${BIND_TO}.  Please confirm that you have bound the intended services to the application."
        fi
        if [ "$USE_ICE_CLI" = "1" ]; then
            BIND_PARMS="--bind ${BIND_TO}"
        else
            BIND_PARMS="-e CCS_BIND_APP=${BIND_TO}"
        fi
    fi
    # run the container and check the results
    log_and_echo "run the container: $IC_COMMAND run --name ${MY_CONTAINER_NAME} ${PUBLISH_PORT} ${MEMORY} ${OPTIONAL_ARGS} ${BIND_PARMS} ${FULL_IMAGE_NAME} "
    ice_retry run --name ${MY_CONTAINER_NAME} --env-file ${ENV_FILE} ${PUBLISH_PORT} ${MEMORY} ${OPTIONAL_ARGS} ${BIND_PARMS} ${FULL_IMAGE_NAME}  2> /dev/null
    RESULT=$?
    if [ $RESULT -ne 0 ]; then
        log_and_echo "$ERROR" "Failed to deploy ${MY_CONTAINER_NAME} using ${FULL_IMAGE_NAME}"
        dump_info
        return 1
    fi

    # wait for container to start
    wait_for ${MY_CONTAINER_NAME}
    RESULT=$?
    if [ $RESULT -eq 0 ]; then
        insert_inventory "ibm_containers" ${MY_CONTAINER_NAME}
    elif [ $RESULT -eq 2 ]; then
        log_and_echo "$ERROR" "Container instance crashed."
        log_and_echo "$WARN" "The container was removed successfully."
        ice_retry rm ${MY_CONTAINER_NAME} 2> /dev/null
        if [ $? -ne 0 ]; then
            log_and_echo "$WARN" "'$IC_COMMAND rm ${MY_CONTAINER_NAME}' command failed with return code ${RESULT}"
            log_and_echo "$WARN" "Removing Container instance ${MY_CONTAINER_NAME} is not completed"
        fi
        print_fail_msg "ibm_containers"
    fi
    return ${RESULT}
}

deploy_ha () {
    local MY_CONTAINER_NAME_BASE="${CONTAINER_NAME}_${BUILD_NUMBER}"

    if [ -z "$NUMBER_OF_INSTANCES" ]; then
        NUMBER_OF_INSTANCES=3
    else
        NUMBER_OF_INSTANCES=${NUMBER_OF_INSTANCES}
    fi

    local COUNTER=0
    while [[ ( $COUNTER -lt NUMBER_OF_INSTANCES ) ]]; do
        let COUNTER=COUNTER+1
        local MY_CONTAINER_NAME="${MY_CONTAINER_NAME_BASE}_$COUNTER"
        log_and_echo "RUNNING $MY_CONTAINER_NAME"

        deploy_container ${MY_CONTAINER_NAME}
        local RESULT=$?

        if [ $RESULT -ne 0 ]; then
            log_and_echo "$ERROR" "Error encountered with simple build strategy for ${MY_CONTAINER_NAME}"
            ${EXT_DIR}/utilities/sendMessage.sh -l bad -m "Failed deployment of ${MY_CONTAINER_NAME}. $(get_error_info)"
            exit $RESULT
        fi
    done
}

deploy_simple () {
    local MY_CONTAINER_NAME="${CONTAINER_NAME}_${BUILD_NUMBER}"
    deploy_container ${MY_CONTAINER_NAME}
    local RESULT=$?
    if [ $RESULT -ne 0 ]; then
        log_and_echo "$ERROR" "Error encountered with simple build strategy for ${CONTAINER_NAME}_${BUILD_NUMBER}"
        ${EXT_DIR}/utilities/sendMessage.sh -l bad -m "Failed deployment of ${MY_CONTAINER_NAME}. $(get_error_info)"
        exit $RESULT
    fi
}

clean () {
    log_and_echo "Removing old $NAME containers."
    ice_retry stop $(ice_retry ps -a -q --filter env=NAME=${NAME})
    ice_retry rm $(ice_retry ps -a -q --filter env=NAME=${NAME})
}

clean_and_deploy () {
    clean
    deploy_ha
}

##################
# Initialization #
##################
# Check to see what deployment type:
#   simple: simply deploy a container and set the inventory
#   red_black: deploy new container, assign floating IP address, keep original container
if [ -z "$URL_PROTOCOL" ]; then
 export URL_PROTOCOL="http://"
fi

if [ -z "$VERSION_NUMBER" ]; then
    FULL_IMAGE_NAME="${IMAGE_NAME}:latest"
else
    FULL_IMAGE_NAME="${IMAGE_NAME}:${VERSION_NUMBER}"
fi


# set the port numbers with --publish
if [ "${PORT}" == "-P" ]; then
    export PUBLISH_PORT="-P"
else
    export PUBLISH_PORT=$(get_port_numbers "${PORT}")
fi

if [ ! -z ${DEPLOY_PROPERTY_FILE} ]; then
    echo "export SINGLE_CONTAINER_NAME="${CONTAINER_NAME}_${BUILD_NUMBER}"" >> "${DEPLOY_PROPERTY_FILE}"
fi

# set the memory size
if [ -z "$CONTAINER_SIZE" ];then
    export MEMORY=""
else
    RET_MEMORY=$(get_memory_size $CONTAINER_SIZE)
    if [ $RET_MEMORY == -1 ]; then
        ${EXT_DIR}/utilities/sendMessage.sh -l bad -m "Failed with container size ${CONTAINER_SIZE}. $(get_error_info)"
        exit 1;
    else
        export MEMORY="--memory $RET_MEMORY"
    fi
fi

# set current version
if [ -z "$CONCURRENT_VERSIONS" ];then
    export CONCURRENT_VERSIONS=1
fi

log_and_echo "$LABEL" "Deploying using ${DEPLOY_TYPE} strategy, for ${CONTAINER_NAME}, deploy number ${BUILD_NUMBER}"
${EXT_DIR}/utilities/sendMessage.sh -l info -m "New ${DEPLOY_TYPE} container deployment for ${CONTAINER_NAME} requested"

if [ "${DEPLOY_TYPE}" == "red_black" ]; then
    deploy_red_black
elif [ "${DEPLOY_TYPE}" == "clean_and_deploy" ]; then
    clean_and_deploy
elif [ "${DEPLOY_TYPE}" == "ha" ]; then
    deploy_ha
elif [ "${DEPLOY_TYPE}" == "simple" ]; then
    deploy_simple
elif [ "${DEPLOY_TYPE}" == "clean" ]; then
    clean
else
    log_and_echo "$WARN" "Currently only supporting red_black deployment strategy"
    log_and_echo "$WARN" "If you would like another strategy please fork https://github.com/Osthanes/deployscripts.git and submit a pull request"
    log_and_echo "$WARN" "Defaulting to red_black deploy"
    deploy_red_black
fi
dump_info
${EXT_DIR}/utilities/sendMessage.sh -l good -m "Sucessful deployment of ${CONTAINER_NAME}"
exit 0
