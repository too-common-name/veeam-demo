#!/bin/bash

if [ $# -lt 6 ]; then
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

ANSIBLE_VARS_FILE="./aws-automations/vars/main.yml"
KEYSFOLDER="sealed-secrets-key"
PRIVATEKEY="$KEYSFOLDER/mytls.key"
PUBLICKEY="$KEYSFOLDER/mytls.crt"
SEALED_SECRETS_NAMESPACE="sealed-secrets"
SECRETNAME="mycustomkeys"
S3_CREDENTIALS_FILE="./aws-automations/kasten-backup-user_aws_credentials.yaml"
S3_KASTEN_SECRET_STUB="./secrets_stub/s3-kasten.yaml"
S3_KASTEN_SEALED_SECRET="./operators/subscriptions/templates/s3-kasten-sealed.yaml"
GLOBAL_OPERATORS_VALUE="./operators/subscriptions/global-values.yaml"
VM_CLOUDINIT_SEALED_SECRET="./vms/fedora-cloudinit-sealed-secret.yaml"
SKIP_KEY_GEN=false

handle_error() {
  local exit_code=${2:-$?}
  if [ $exit_code -ne 0 ]; then
    echo -e "${RED}❌ $1${NC}"
    echo "ERROR: $1" >> $LOG_FILE
    exit $exit_code
  fi
}

check_pods() {
  local namespace="$1"
  local attempts=0
  local max_attempts=42
  local all_pods_ready=false

  echo -e "${BLUE}🔄 Waiting for operator to be ready..."

  while [ $attempts -lt $max_attempts ]; do
    local all_pods_output
    all_pods_output=$(oc get pods -n "$namespace" --no-headers 2>> $LOG_FILE)

    if [ -z "$all_pods_output" ]; then
      attempts=$((attempts + 1))
      echo -e "${YELLOW}⚠️  No pods found in $namespace. New attempt in 10 seconds... ($attempts/$max_attempts)"
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
          echo -e "${BLUE}🔄 $not_running_count pods in namespace '$namespace' are not in 'Running' state."

          attempts=$((attempts + 1))
          if [ $attempts -lt $max_attempts ]; then
            echo -e "${YELLOW}⚠️  New attempt in 10 seconds... ($attempts/$max_attempts)"
            sleep 10
          fi
        fi
    fi
  done

  if $all_pods_ready; then
    echo -e "${GREEN}✅ Operator installation succeeded!"
    return 0
  else
    return 1
  fi
}

check_argocd_sync() {
  local namespace="$1"
  local resource_type="$2" 
  local resource_name="$3"
  local attempts=0
  local max_attempts=42

  echo -e "${BLUE}🔄 Waiting for ArgoCD $resource_type '$resource_name' to become Synced..."

  while [ $attempts -lt $max_attempts ]; do
    local sync_status
    sync_status=$(oc get "$resource_type" "$resource_name" -n "$namespace" -o jsonpath='{.status.sync.status}' 2>> $LOG_FILE)

    if [ "$sync_status" == "Synced" ]; then
      echo -e "${GREEN}✅ ArgoCD $resource_type '$resource_name' is Synced!"
      return 0
    else
      echo -e "${YELLOW}⚠️  $resource_type '$resource_name' is not Synced (status: $sync_status). Retrying in 10 seconds... ($((attempts+1))/$max_attempts)"
      attempts=$((attempts + 1))
      sleep 10
    fi
  done

  return 1
}

check_for_argocd_cluster_secrets() {
  local namespace="openshift-gitops"
  local expected_secret_1="passive-cluster-application-manager-cluster-secret"
  local expected_secret_2="local-cluster-application-manager-cluster-secret"
  local attempts=0
  local max_attempts=42
  local interval=10

  echo -e "${BLUE}🔄 Waiting for both ArgoCD cluster secrets to be present..."

  while [ $attempts -lt $max_attempts ]; do
    output=$(oc get secret -n "$namespace" --selector argocd.argoproj.io/secret-type='cluster' -o name 2>/dev/null)

    if echo "$output" | grep -q "$expected_secret_1" && echo "$output" | grep -q "$expected_secret_2"; then
      echo -e "${GREEN}✅ Both ArgoCD cluster secrets are present."
      return 0
    fi

    echo -e "${YELLOW}⚠️  Secrets not ready yet. Attempt $((attempts+1))/$max_attempts. Retrying in ${interval}s..."
    attempts=$((attempts + 1))
    sleep "$interval"
  done

  return 1
}

check_oc_installed() {
  if [ -z "$OC_COMMAND" ]; then
    echo -e "${RED}❌ 'oc' command not found. Please install the OpenShift CLI.${NC}"
    exit 1
  fi
}

login_to_openshift() {
  local url="$1"
  local user="$2"
  local pwd="$3"
  echo -e "${BLUE}🔄 Logging in to OpenShift...${NC}"
  oc login "$url" -u "$user" -p "$pwd" --insecure-skip-tls-verify &>> $LOG_FILE
  handle_error "Failed to log in to OpenShift"
  echo -e "${GREEN}✅ Successfully logged in to OpenShift.${NC}"
}

add_user_to_admins_group() {
    oc adm groups new cluster-admins &>> $LOG_FILE
    oc adm groups add-users cluster-admins admin &>> $LOG_FILE
}

install_argocd() {
    echo -e "${BLUE}🔄 Installing OpenShift GitOps operator...${NC}"
    oc apply -f argocd &>> $LOG_FILE
    handle_error "Failed to install OpenShift GitOps operator"
}

patch_argocd() {
  local attempts=0
  local max_patch_attempts=5
  local patch_successful=false

  while [ $attempts -lt $max_patch_attempts ]; do
    echo -e "${BLUE}🔄 Attempting override ArgoCD health check (Attempt $((attempts + 1))/$max_patch_attempts)...${NC}"
    oc patch argocd openshift-gitops -n openshift-gitops --type=merge \
    --patch-file ./patches/argocd-customization-patch.yaml &>> $LOG_FILE
    
    if [ $? -eq 0 ]; then
      patch_successful=true
      break
    else
      echo -e "${YELLOW}⚠️  Warning: Patch attempt $((attempts + 1)) failed."
      attempts=$((attempts + 1))
      sleep 5
    fi
  done

  if $patch_successful; then
    echo -e "${GREEN}✅ ArgoCD instance patched successfully!"
    return 0
  else
    return 1
  fi
}

create_argocd_operators_app() {
  echo -e "${BLUE}🔄 Installing Operators on hub cluster using GitOps...${NC}"
  oc apply -f argocd-apps/hub_operators.yaml &>> $LOG_FILE
  handle_error "Failed to install Operators on hub cluster using GitOps"
}

create_acm_managed_cluster_secret() {
  local attempts=0
  local max_patch_attempts=42
  local import_successful=false

  echo -e "${BLUE}🔄 Generating secret to import DR cluster in ACM...${NC}"
  while [ $attempts -lt $max_patch_attempts ]; do
    oc get ns/passive-cluster &>> $LOG_FILE
    
    if [ $? -eq 0 ]; then
      login_to_openshift $MANAGED_OPENSHIFT_URL $MANAGED_USERNAME $MANAGED_PASSWORD &>> "$LOG_FILE"
      local token=$(oc whoami -t)
      login_to_openshift $HUB_OPENSHIFT_URL $HUB_USERNAME $HUB_PASSWORD &>> "$LOG_FILE"
      oc create secret generic auto-import-secret --from-literal=autoImportRetry=5 \
      --from-literal=server="$MANAGED_OPENSHIFT_URL" \
      --from-literal=token="$token" -n passive-cluster &>> "$LOG_FILE"
      handle_error "Unable to create secret to auto-import the managed cluster"
      import_successful=true
      break
    else
      echo -e "${YELLOW}⚠️  Warning: Import attempt $((attempts + 1)) failed."
      attempts=$((attempts + 1))
      sleep 10
    fi
  done

  if $import_successful; then
    echo -e "${GREEN}✅ Managed cluster imported successfully!"
    return 0
  else
    return 1
  fi
}

bioc_key_generation() {
  if [[ -f "$PRIVATEKEY" && -f "$PUBLICKEY" ]]; then
    echo -e "${YELLOW}⚠️  Key files already exist, skipping generation.${NC}"
    SKIP_KEY_GEN=true
    return
  fi

  echo -e "${BLUE}🔄 Generating keys for sealed secret controller...${NC}"
  mkdir -p "$KEYSFOLDER" &>> $LOG_FILE
  openssl req -x509 -days 365 -nodes -newkey rsa:4096 -keyout "$PRIVATEKEY" -out "$PUBLICKEY" -subj "/CN=sealed-secret/O=sealed-secret" &>> $LOG_FILE
}

bioc_resource_creation() {
  if [[ "$SKIP_KEY_GEN" == true ]]; then
    echo -e "${YELLOW}⚠️  Skipping resource creation for sealed secret controller because keys already exist.${NC}"
    return
  fi

  local url="$1"
  local user="$2"
  local pwd="$3"
  local cluster_name="$4"
  echo -e "${BLUE}🔄 Creating key secret for sealed secret controller in cluster ${cluster_name}...${NC}"
  login_to_openshift $url $user $pwd &>> "$LOG_FILE"
  oc new-project sealed-secrets &>> $LOG_FILE
  oc -n "$SEALED_SECRETS_NAMESPACE" delete secret "$SECRETNAME" --ignore-not-found &>> $LOG_FILE
  oc -n "$SEALED_SECRETS_NAMESPACE" create secret tls "$SECRETNAME" --cert="$PUBLICKEY" --key="$PRIVATEKEY" &>> $LOG_FILE
  handle_error "Failed to create secret for sealed secret controller"
  oc -n "$SEALED_SECRETS_NAMESPACE" label secret "$SECRETNAME" sealedsecrets.bitnami.com/sealed-secrets-key=active &>> $LOG_FILE
  handle_error "Failed to label secret for sealed secret controller"
  if oc get pod -n "$SEALED_SECRETS_NAMESPACE" -l name=sealed-secrets-controller --no-headers 2>/dev/null | grep -q .; then
    echo -e "${BLUE}🔄 Restarting sealed-secrets controller pod..."
    oc -n "$SEALED_SECRETS_NAMESPACE" delete pod -l name=sealed-secrets-controller &>> $LOG_FILE
  fi
}

create_sealed_secrets_global_app() {
  if [[ "$SKIP_KEY_GEN" == true ]]; then
    echo -e "${YELLOW}⚠️  Skipping app creation for sealed secret because keys already exist.${NC}"
    return
  fi
  
  echo -e "${BLUE}🔄 Installing sealed secrets on all clusters using GitOps...${NC}"
  oc apply -f argocd-apps/global_sealedsecrets.yaml &>> $LOG_FILE
  handle_error "Failed to install sealed secrets on all clusters using GitOps"
}

generate_sealed_secrets() {
  if [[ "$SKIP_KEY_GEN" == true ]]; then
    echo -e "${YELLOW}⚠️  Skipping sealed secret generation because keys already exist.${NC}"
    return
  fi

  echo -e "${BLUE}🔄 Filling S3 secret stub...${NC}"
  local access_key_id=$(yq '.access_key_id' $S3_CREDENTIALS_FILE)
  local secret_access_key=$(yq '.secret_access_key' $S3_CREDENTIALS_FILE)
  yq -i ".data.aws_access_key_id = \"$access_key_id\"" $S3_KASTEN_SECRET_STUB
  yq -i ".data.aws_secret_access_key = \"$secret_access_key\"" $S3_KASTEN_SECRET_STUB
  echo -e "${BLUE}🔄 Generating S3 sealed secret for Kasten...${NC}"
  echo "{{- if eq .Values.kasten.enabled true }}" > "$S3_KASTEN_SEALED_SECRET" 2>> $LOG_FILE
  cat secrets_stub/s3-kasten.yaml | kubeseal --cert "$PUBLICKEY" --format yaml >> "$S3_KASTEN_SEALED_SECRET" 2>> $LOG_FILE
  handle_error "Failed to generate s3-kasten sealed secret"
  echo "{{- end }}" >> "$S3_KASTEN_SEALED_SECRET" 2>> $LOG_FILE
  echo -e "${BLUE}🔄 Generating VM user data sealed secret...${NC}"
  cat secrets_stub/vm-cred.yaml | kubeseal --cert "$PUBLICKEY" --format yaml > "$VM_CLOUDINIT_SEALED_SECRET" 2>> $LOG_FILE
  handle_error "Failed to generate VM user data sealed secret"
}

push_sealed_secrets() {
  if [[ "$SKIP_KEY_GEN" == true ]]; then
    return
  fi

  echo -e "${BLUE}🔄 Pushing S3 sealed secret for Kasten on github...${NC}"
  git add "$S3_KASTEN_SEALED_SECRET" &>> $LOG_FILE
  git add "$VM_CLOUDINIT_SEALED_SECRET" &>> $LOG_FILE
  git commit -m "chore(automatic): add kasten and vm sealed secrets" &>> $LOG_FILE
  handle_error "Failed to commit sealed secret" &>> $LOG_FILE
  git push &>> $LOG_FILE
  handle_error "Failed to push sealed secret"
}

annotate_storageclass_and_volumesnapshotclass() {
  echo -e "${BLUE}🔄 Annotating default StorageClass and VolumeSnapshotClass on both clusters..."
  for CLUSTER in "MANAGED" "HUB"; do
    if [ "$CLUSTER" == "HUB" ]; then
      login_to_openshift "$HUB_OPENSHIFT_URL" "$HUB_USERNAME" "$HUB_PASSWORD" &>> "$LOG_FILE"
    else
      login_to_openshift "$MANAGED_OPENSHIFT_URL" "$MANAGED_USERNAME" "$MANAGED_PASSWORD" &>> "$LOG_FILE"
    fi

    DEFAULT_SC_DRIVER=$(oc get storageclass --no-headers | grep '(default)' | awk '{print $3}')
    SNAPSHOT_CLASS=$(oc get volumesnapshotclass --no-headers | grep $DEFAULT_SC_DRIVER | awk '{print $1}')
    DEFAULT_STORAGE_CLASS=$(oc get storageclass --no-headers | grep '(default)' | awk '{print $1}')

    if [ -z "$SNAPSHOT_CLASS" ]; then
      echo -e "${RED}❌ No suitable VolumeSnapshotClass found for StorageClass '$DEFAULT_SC' in $CLUSTER cluster.${NC}"
      continue
    fi
    if [ -z "$DEFAULT_STORAGE_CLASS" ]; then
      echo -e "${RED}❌ No default StorageClass found in $CLUSTER cluster.${NC}"
      continue
    fi

    oc annotate volumesnapshotclass "$SNAPSHOT_CLASS" k10.kasten.io/is-snapshot-class="true" --overwrite &>> $LOG_FILE
    handle_error "Failed to annotate VolumeSnapshotClass '$SNAPSHOT_CLASS' in $CLUSTER cluster"

    echo -e "${GREEN}✅ Annotated '$SNAPSHOT_CLASS' VolumeSnapshotClass in $CLUSTER cluster.${NC}"

    oc annotate storageclass "$DEFAULT_STORAGE_CLASS" k10.kasten.io/sc-supports-block-mode-exports="true" --overwrite &>> $LOG_FILE
    handle_error "Failed to annotate StorageClass '$DEFAULT_STORAGE_CLASS' in $CLUSTER cluster"

    echo -e "${GREEN}✅ Annotated '$DEFAULT_STORAGE_CLASS' in $CLUSTER cluster.${NC}"
  done
}

add_bucket_info_to_crd() {
  echo -e "${BLUE}🔄 Checking if bucket info needs to be updated in Kasten CRD...${NC}"

  local region=$(yq '.region' "$ANSIBLE_VARS_FILE")
  local bucket_name=$(yq '.bucket_name' "$ANSIBLE_VARS_FILE")

  local current_region=$(yq '.kasten.bucket_region' "$GLOBAL_OPERATORS_VALUE")
  local current_bucket=$(yq '.kasten.bucket_name' "$GLOBAL_OPERATORS_VALUE")

  if [[ "$region" != "$current_region" || "$bucket_name" != "$current_bucket" ]]; then
    echo -e "${BLUE}🔄 Updating bucket info in Kasten CRD...${NC}"
    yq -i ".kasten.bucket_name = \"$bucket_name\"" "$GLOBAL_OPERATORS_VALUE"
    yq -i ".kasten.bucket_region = \"$region\"" "$GLOBAL_OPERATORS_VALUE"
    git add "$GLOBAL_OPERATORS_VALUE" &>> "$LOG_FILE"
    git commit -m "chore(automatic): update bucket info" &>> "$LOG_FILE"
    handle_error "Failed to commit new bucket info" &>> "$LOG_FILE"
    git push &>> "$LOG_FILE"
    handle_error "Failed to push new bucket info"
  else
    echo -e "${GREEN}✅ Bucket info is up to date. No changes needed.${NC}"
  fi
}

create_operator_global_app() {
  echo -e "${BLUE}🔄 Installing Operators on all clusters using GitOps...${NC}"
  oc apply -f argocd-apps/global_operators.yaml &>> $LOG_FILE
  handle_error "Failed to install Operators on all clusters using GitOps"
}

create_vm_app(){
  echo -e "${BLUE}🔄 Creating Fedora VM using GitOps...${NC}"
  oc apply -f argocd-apps/vm_application.yaml &>> $LOG_FILE
  handle_error "Failed to create Fedora VM using GitOps"
}

check_oc_installed
login_to_openshift $HUB_OPENSHIFT_URL $HUB_USERNAME $HUB_PASSWORD
add_user_to_admins_group
install_argocd

check_pods "$GITOPS_NAMESPACE"
handle_error "Timeout: OpenShift GitOps operator pods in namespace '$GITOPS_NAMESPACE' did not become ready. Check $LOG_FILE."

patch_argocd
handle_error "Failed to apply ArgoCD health check override."

create_argocd_operators_app
create_acm_managed_cluster_secret
handle_error "Failed to create secret for managed cluster."

check_argocd_sync "openshift-gitops" "applications.argoproj.io" "cluster-config"
handle_error "Timeout: ArgoCD Application 'cluster-config' in namespace 'openshift-gitops' did not become Healthy. Check $LOG_FILE."

bioc_key_generation
bioc_resource_creation $MANAGED_OPENSHIFT_URL $MANAGED_USERNAME $MANAGED_PASSWORD
bioc_resource_creation $HUB_OPENSHIFT_URL $HUB_USERNAME $HUB_PASSWORD

check_for_argocd_cluster_secrets
handle_error "Timeout: ArgoCD secrets in namespace 'openshift-gitops' not found. Check $LOG_FILE."

create_sealed_secrets_global_app

check_argocd_sync "openshift-gitops" "applications.argoproj.io" "local-cluster-sealedsecrets-operator"
handle_error "Timeout: ArgoCD ApplicationSet 'local-cluster-sealedsecrets-operator' in namespace 'openshift-gitops' did not become Healthy. Check $LOG_FILE."
check_argocd_sync "openshift-gitops" "applications.argoproj.io" "passive-cluster-sealedsecrets-operator"
handle_error "Timeout: ArgoCD ApplicationSet 'passive-cluster-sealedsecrets-operator' in namespace 'openshift-gitops' did not become Healthy. Check $LOG_FILE."

check_pods "$SEALED_SECRETS_NAMESPACE"
handle_error "Timeout: Sealed Secrets operator pods in namespace '$SEALED_SECRETS_NAMESPACE' did not become ready. Check $LOG_FILE."

generate_sealed_secrets 
push_sealed_secrets

annotate_storageclass_and_volumesnapshotclass
add_bucket_info_to_crd
create_operator_global_app
create_vm_app