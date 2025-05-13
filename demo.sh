#!/bin/bash

if [ $# -lt 3 ]; then
  echo "Usage: $0 <HUB_OPENSHIFT_URL> <HUB_USERNAME> <HUB_PASSWORD> <MANAGED_OPENSHIFT_URL> <MANAGED_USERNAME> <MANAGED_PASSWORD>"
  exit 1
fi

HUB_OPENSHIFT_URL=$1
HUB_USERNAME=$2
HUB_PASSWORD=$3
MANAGED_OPENSHIFT_URL=$4
MANAGED_USERNAME=$5
MANAGED_PASSWORD=$6

RED='\033[1;31m' 
GREEN='\033[1;32m' 
YELLOW='\033[1;33m' 
BLUE='\033[1;34m'
NC='\033[0m'

OC_COMMAND=$(command -v oc)
LOG_FILE="deployment.log"
RETRIES=20
DELAY=10
GITOPS_NAMESPACE="openshift-gitops-operator"

handle_error() {
  local exit_code=${2:-$?}
  if [ $exit_code -ne 0 ]; then
    echo -e "${RED} ✘ $1${NC}"
    echo "ERROR: $1" >> $LOG_FILE
    exit $exit_code
  fi
}

check_pods() {
  local namespace="$1"
  local attempts=0
  local max_attempts=12
  local all_pods_ready=false

  echo -e "${BLUE} ➜ Waiting for operator to be ready..."

  while [ $attempts -lt $max_attempts ]; do
    local all_pods_output
    all_pods_output=$(oc get pods -n "$namespace" --no-headers 2>> $LOG_FILE)

    if [ -z "$all_pods_output" ]; then
      attempts=$((attempts + 1))
      echo -e "${YELLOW} ⚠ No pods found in $namespace. New attempt in 10 seconds... ($attempts/$max_attempts)"
      sleep 10
    else
        local total_pods
        total_pods=$(echo "$all_pods_output" | wc -l)

        local running_pods
        running_pods=$(echo "$all_pods_output" | grep -w "Running" | wc -l)

        if [ "$total_pods" -eq "$running_pods" ]; then
          all_pods_ready=true
          break
        else
          local not_running_count=$((total_pods - running_pods))
          echo -e "${BLUE} ➜ $not_running_count pods in namespace '$namespace' are not in 'Running' state."

          attempts=$((attempts + 1))
          if [ $attempts -lt $max_attempts ]; then
            echo -e "${YELLOW} ⚠ New attempt in 10 seconds... ($attempts/$max_attempts)"
            sleep 10
          fi
        fi
    fi
  done

  if $all_pods_ready; then
    echo -e "${GREEN} ✔ Operator installation succeeded!"
    return 0
  else
    return 1
  fi
}

check_oc_installed() {
  if [ -z "$OC_COMMAND" ]; then
    echo -e "${RED} ✘ 'oc' command not found. Please install the OpenShift CLI.${NC}"
    exit 1
  fi
}

login_to_openshift() {
  local url="$1"
  local user="$2"
  local pwd="$3"
  echo -e "${BLUE} ➜ Logging in to OpenShift...${NC}"
  oc login "$url" -u "$user" -p "$pwd" --insecure-skip-tls-verify &>> $LOG_FILE
  handle_error "Failed to log in to OpenShift"
  echo -e "${GREEN} ✔ Successfully logged in to OpenShift.${NC}"
}

add_user_to_admins_group() {
    oc adm groups new cluster-admins &>> $LOG_FILE
    oc adm groups add-users cluster-admins admin &>> $LOG_FILE
}

install_argocd() {
    echo -e "${BLUE} ➜ Installing OpenShift GitOps operator...${NC}"
    oc apply -f argocd &>> $LOG_FILE
    handle_error "Failed to install OpenShift GitOps operator"
}

patch_argocd() {
  local attempts=0
  local max_patch_attempts=5
  local patch_successful=false

  while [ $attempts -lt $max_patch_attempts ]; do
    echo -e "${BLUE} ➜ Attempting override ArgoCD health check (Attempt $((attempts + 1))/$max_patch_attempts)...${NC}"
    oc patch argocd openshift-gitops -n openshift-gitops --type=merge \
    --patch-file ./patches/argocd-customization-patch.yaml &>> $LOG_FILE
    
    if [ $? -eq 0 ]; then
      patch_successful=true
      break
    else
      echo -e "${YELLOW} ⚠ Warning: Patch attempt $((attempts + 1)) failed."
      attempts=$((attempts + 1))
      sleep 5
    fi
  done

  if $patch_successful; then
    echo -e "${GREEN} ✔ ArgoCD instance patched successfully!"
    return 0
  else
    return 1
  fi
}

create_argocd_operators_app() {
  echo -e "${BLUE} ➜ Installing Operators on hub cluster using GitOps...${NC}"
  oc apply -f argocd-apps &>> $LOG_FILE
  handle_error "Failed to install Operators on hub cluster using GitOps"
}

create_acm_managed_cluster_secret() {
  local attempts=0
  local max_patch_attempts=32
  local import_successful=false

  echo -e "${BLUE} ➜ Generating secret to import DR cluster in ACM...${NC}"
  while [ $attempts -lt $max_patch_attempts ]; do
    oc get ns/dr-cluster &>> $LOG_FILE
    
    if [ $? -eq 0 ]; then
      login_to_openshift $MANAGED_OPENSHIFT_URL $MANAGED_USERNAME $MANAGED_PASSWORD &>> "$LOG_FILE"
      local token=$(oc whoami -t)
      login_to_openshift $HUB_OPENSHIFT_URL $HUB_USERNAME $HUB_PASSWORD &>> "$LOG_FILE"
      oc create secret generic auto-import-secret --from-literal=autoImportRetry=5 \
      --from-literal=server="$MANAGED_OPENSHIFT_URL" \
      --from-literal=token="$token" -n dr-cluster &>> "$LOG_FILE"
      handle_error "Unable to create secret to auto-import the managed cluster"
      import_successful=true
      break
    else
      echo -e "${YELLOW} ⚠ Warning: Import attempt $((attempts + 1)) failed."
      attempts=$((attempts + 1))
      sleep 10
    fi
  done

  if $import_successful; then
    echo -e "${GREEN} ✔ Managed cluster imported successfully!"
    return 0
  else
    return 1
  fi
}

check_oc_installed
login_to_openshift $HUB_OPENSHIFT_URL $HUB_USERNAME $HUB_PASSWORD
add_user_to_admins_group
install_argocd
check_pods "$GITOPS_NAMESPACE"
handle_error "OpenShift GitOps operator pods in '$GITOPS_NAMESPACE' did not become ready. Check $LOG_FILE."
patch_argocd
handle_error "Failed to override ArgoCD health check"
create_argocd_operators_app
create_acm_managed_cluster_secret
handle_error "Failed to create secret for managed cluster"