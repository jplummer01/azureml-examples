#!/bin/bash 

if [ "${BASH_SOURCE[0]}" == "$0" ];  then
    echo "This script is to be sourced, not executing directly, will bail out" >&2
    exit 1
fi

####################
# SET VARIABLES FOR CURRENT FILE & DIR
####################

# The filename of this script for help messages
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$( cd "$( dirname "${SCRIPT_PATH}" )" && pwd )"
ROOT_DIR=$(cd "${SCRIPT_DIR}/../" && pwd)

EPOCH_START="$( date -u +%s )"  # e.g. 1661361223

declare -A SKIP_AUTO_DELETE_TILL=$(date -d "+30 days" +'%y-%m-%d')
declare -a DELETE_AFTER=("30.00:00:00")
echo SKIP_AUTO_DELETE_TILL $SKIP_AUTO_DELETE_TILL
COMMON_TAGS=(
  "cleanup:DeleteAfter=${DELETE_AFTER}" 
  "cleanup:Policy=DeleteAfter" 
  "creationTime=${EPOCH_START}" 
  "SkipAutoDeleteTill=${SKIP_AUTO_DELETE_TILL}" 
)

####################
# SETUP LOGGING
####################
LOG_FILE="/tmp/$(basename "$0").log"
readonly LOG_FILE
DATE_FORMAT=${DATE_FORMAT:-'%Y-%m-%dT%H:%M:%S.%2N'}
readonly DATE_FORMAT
LOG_FORMAT='%s :  %s :  %s\n'
readonly LOG_FORMAT
echo_info()     { printf "$LOG_FORMAT"  [INFO]  "$(date +"$DATE_FORMAT")"  "$@" | tee -a "$LOG_FILE" >&2 ; }
echo_warning()  { printf "$LOG_FORMAT"  [WARNING]  "$(date +"$DATE_FORMAT")"  "$@" | tee -a "$LOG_FILE" >&2 ; }
echo_error()    { printf "$LOG_FORMAT"  [ERROR]  "$(date +"$DATE_FORMAT")"  "$@" | tee -a "$LOG_FILE" >&2 ; }
echo_fatal()    { printf "$LOG_FORMAT"  [FATAL]  "$(date +"$DATE_FORMAT")"  "$@" | tee -a "$LOG_FILE" >&2 ; exit 1 ; }

####################
# CUSTOM ECHO FUNCTIONS TO PRINT TEXT TO THE SCREEN
####################

echo_title() {
  echo
  echo "### ${1} ###"
}

echo_subtitle() {
  echo "# ${1} #"
}

####################
# DEBUGGING CONFIGURATION
####################

CONTINUE_ON_ERR=${CONTINUE_ON_ERR:-0}  # 0: false; 1: true
if [[ "${CONTINUE_ON_ERR}" = true ]]; then  # -E
   echo_warning "Set to continue despite of an error ..."
else
   echo_warning "set -e  # error stops execution ..."
   set -e  # exits script when a command fails
   set -o errexit
   # ALTERNATE: set -eu pipefail  # pipefail counts as a parameter
fi

RUN_DEBUG=${RUN_DEBUG:-0}  # 0: false; 1: true
# set run error control
if [[ "${RUN_DEBUG}" = true ]]; then
   echo_warning "set -x  # printing each command before executing it ..."
   set -x   # (-o xtrace) to show commands for specific issues.
fi

####################
# CUSTOM FUNCTIONS
####################

function pushd () {
    command pushd "$@" 2>&1 > /dev/null
}

function popd () {
    command popd "$@" 2>&1 > /dev/null
}

function ensure_resourcegroup() {
    rg_exists=$(az group exists --resource-group "$RESOURCE_GROUP_NAME" --output tsv |tail -n1|tr -d "[:cntrl:]")
    if [ "false" = "$rg_exists" ]; then
        echo_info "Resource group ${RESOURCE_GROUP_NAME} does not exist" >&2
        echo_info "Resource group ${RESOURCE_GROUP_NAME} in location: ${LOCATION} does not exist; creating" >&2
        az group create --name "${RESOURCE_GROUP_NAME}" --location "${LOCATION}" --tags "${COMMON_TAGS[@]}" > /dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            echo_failure "Failed to create resource group ${RESOURCE_GROUP_NAME}" >&2
        else
            echo_info "Resource group ${RESOURCE_GROUP_NAME} created successfully" >&2
        fi
    else
        echo_warning "Resource group ${RESOURCE_GROUP_NAME} already exist, skipping creation step..." >&2
    fi
}

function ensure_ml_workspace() {
    workspace_exists=$(az ml workspace list --resource-group "${RESOURCE_GROUP_NAME}" --query "[?name == '$WORKSPACE_NAME']" |tail -n1|tr -d "[:cntrl:]")
    if [[ "${workspace_exists}" = "[]" ]]; then
        echo_info "Workspace ${WORKSPACE_NAME} does not exist; creating" >&2
        CREATE_WORKSPACE=$(az ml workspace create \
            --name "${WORKSPACE_NAME}" \
            --resource-group "${RESOURCE_GROUP_NAME}"  \
            --location "${LOCATION}" \
            --tags "${COMMON_TAGS[@]}" \
            --query id --output tsv  \
            > /dev/null 2>&1)
        if [[ $? -ne 0 ]]; then
            echo_failure "Failed to create workspace ${WORKSPACE_NAME}" >&2
            echo "[---fail---] $CREATE_WORKSPACE."
        else
            echo_info "Workspace ${WORKSPACE_NAME} created successfully" >&2
            ensure_prerequisites_in_workspace
        fi
    else
        echo_warning "Workspace ${WORKSPACE_NAME} already exist, skipping creation step..." >&2
    fi
}

function ensure_aml_compute() {
    COMPUTE_NAME=${1:-cpu-cluster}
    MIN_INSTANCES=${2:-0}
    MAX_INSTANCES=${3:-2}
    COMPUTE_SIZE=${4:-Standard_DS3_v2}
    compute_exists=$(az ml compute list --resource-group "${RESOURCE_GROUP_NAME}" --query "[?name == '$COMPUTE_NAME']" |tail -n1|tr -d "[:cntrl:]")
    if [[ "${compute_exists}" = "[]" ]]; then
        echo_info "Compute ${COMPUTE_NAME} does not exist; creating" >&2
        CREATE_COMPUTE=$(az ml compute create \
            --name "${COMPUTE_NAME}" \
            --resource-group "${RESOURCE_GROUP_NAME}"  \
            --type amlcompute --min-instances "${MIN_INSTANCES}" --max-instances "${MAX_INSTANCES}"  \
            --size "${COMPUTE_SIZE}" \
            --output tsv  \
            > /dev/null 2>&1)
        if [[ $? -ne 0 ]]; then
            echo_failure "Failed to create compute ${COMPUTE_NAME}" >&2
            echo "[---fail---] $CREATE_COMPUTE."
        else
            echo_info "Compute ${COMPUTE_NAME} created successfully" >&2
        fi
    else
        echo_warning "Compute ${COMPUTE_NAME} already exist, skipping creation step..." >&2
    fi
}

function install_packages() {
    echo_info "------------------------------------------------"
    echo_info ">>> Updating packages index"
    echo_info "------------------------------------------------"

    sudo apt-get update > /dev/null 2>&1
    sudo apt-get upgrade -y > /dev/null 2>&1
    sudo apt-get dist-upgrade -y > /dev/null 2>&1

    echo_info "------------------------------------------------"
    echo_info ">>> Installing packages"
    echo_info "------------------------------------------------"

    # jq                - Required for running filters on a stream of JSON data from az
    # uuid-runtime      - Required for containers
    packages_to_install=(
      jq
      uuid-runtime
    )
    for package in "${packages_to_install[@]}"; do
      echo_info "Installing \'$package\'"
      sudo apt-get install "${package}" -y > /dev/null 2>&1
    done
    echo_info "------------------------------------------------"
    echo_info ">>> Clean local cache for packages"
    echo_info "------------------------------------------------"

    sudo apt-get autoclean && sudo apt-get autoremove > /dev/null 2>&1
}

function add_extension() {
    echo_info "az extension add -n $1 "
    az extension add -n "$1" -y
}

function ensure_ml_extension() {
    echo_info "az extension version check ... "
    EXT_VERSION=$( az extension list -o table --query "[?contains(name, 'ml')].{Version:version}" -o tsv |tail -n1|tr -d "[:cntrl:]")
    if [[ -z "${EXT_VERSION}" ]]; then
       echo_info "az extension \"ml\" not found."
       add_extension ml
    else
       echo_info "Remove az extionsion \'ml\' version ${EXT_VERSION}"
       # Per https://docs.microsoft.com/azure/machine-learning/how-to-configure-cli
       az extension remove -n ml
       echo_info "Add latest az extionsion \"ml\":"
       add_extension ml
    fi
}

function ensure_prerequisites_in_workspace() {
    echo_info "Ensuring prerequisites in the workspace" >&2
    deploy_scripts=(
      # setup-repo/copy-data.sh
      setup-repo/create-datasets.sh
      # setup-repo/update-datasets.sh
      setup-repo/create-components.sh
      setup-repo/create-environments.sh
    )
    for package in "${deploy_scripts[@]}"; do
      echo_info "Deploying '${ROOT_DIR}/${package}'"
      if [ -f "${ROOT_DIR}"/"${package}" ]; then
        bash ${ROOT_DIR}/${package};
      else
        echo "---------------------------------------------------------"
        echo_error "${ROOT_DIR}/${package} not found."
        echo "---------------------------------------------------------"
      fi
    done
}

function update_dataset() {
    echo_info "Updating dataset in the workspace" >&2
    deploy_scripts=(
      setup-repo/update-datasets.sh
    )
    for package in "${deploy_scripts[@]}"; do
      echo_info "Deploying '${ROOT_DIR}/${package}'"
      if [ -f "${ROOT_DIR}"/"${package}" ]; then
        bash ${ROOT_DIR}/${package};
      else
        echo "---------------------------------------------------------"
        echo_error "${ROOT_DIR}/${package} not found."
        echo "---------------------------------------------------------"
      fi
    done
}