#!/bin/bash
__cache_dir=$(mktemp -d)
test -d "$__cache_dir" && rm -rf "$__cache_dir"
trap 'rm -rf "$__cache_dir"' EXIT
mkdir -p "$__cache_dir"

LOG_FILE="install-$$.log"
MIN_OC_VERSION=4.9
DEFAULT_CSI_PLUGIN_NAMESPACE=csi-wekafs

HUGE_PAGE_SIZE=2  # 2 for 2Mi, 1024 for Gi
HUGE_PAGES_MB_PER_CORE=2048
MEMORY_PER_CORE=2048
BASE_POD_RAM_ALLOCATION=2048

DEFAULT_CSI_SYSTEM_ORGANIZATION='Root'
DEFAULT_CSI_HTTP_SCHEME='http'

CLIENT_REPOSITORY_URL="quay.io/weka.io/weka-in-container"
DRIVERS_REPOSITORY_URL="quay.io/weka.io/weka-coreos-drivers"
DRIVERS_SOURCES_BASE_URL="https://kvc-weka.s3.eu-west-1.amazonaws.com/drivers_"

CSI_REPO_URL="https://weka.github.io/csi-wekafs"
CSI_GIT_URL="https://raw.githubusercontent.com/weka/csi-wekafs/v0.8.4/deploy/helm/csi-wekafsplugin"

INTERNAL_REGISTRY_URL="image-registry.openshift-image-registry.svc:5000"

# Those are removed when running offline installation from internal registry
DRIVERS_IMAGE_PULL_SECRET="pullSecret: {'name': 'weka-oc-pull-secret'}"
CLIENT_IMAGE_PULL_SECRET="imagePullSecrets: [name: weka-oc-pull-secret]"

set -e

usage() {
  cat <<DELIM

Install Weka client software on OpenShift cluster

Usage: $0 --version <WEKA_SOFTWARE_VERSION> --backend-ip-address <BACKEND_IP_ADDRESS> --backend-net <NIC[,NIC...]> [--core-count <IONODE_COUNT>]
   or  $0 --from-offline-package <PACKAGE_FILE> --image-registry-url <REGISTRY_URL> --backend-ip-address <BACKEND_IP_ADDRESS> --backend-net <NIC[,NIC...]> [--core-count <IONODE_COUNT>]
   or: $0 --prepare-offline-package --version <WEKA_SOFTWARE_VERSION> --offline-ocp-version <OCP_VERSION>
   or: $0 --create-csi-secret --endpoint-ip-address <BACKEND_IP_ADDRESS> --system-username <USERNAME> --system-password <PASSWORD> [--system-organization <ORGANIZATION>]


Notes: - You must be already logged in to OpenShift cluster
       - Current context must be set to desired OpenShift cluster context
       - unless specified otherwise, all objects will be installed in namespace "weka"

Online Install Arguments
  --version STRING                Weka client software version
  --backend-ip-address STRING     one of the Weka cluster backend Management IP addresses (on DATA network)
  --backend-net STRING            comma-separated list of network adapters to use (e.g. ens256), must be equal to number of ionodes
  --core-count NUMBER           number of IO nodes, default 1, must be equal to number of network adapters

Offline Install Arguments
  --image-registry-url STRING     The URL on which OpenShift Container Platform internal registry is exposed
  --backend-ip-address STRING     one of the Weka cluster backend Management IP addresses (on DATA network)
  --backend-net STRING            comma-separated list of network adapters to use (e.g. ens256), must be equal to number of ionodes
  --core-count NUMBER           number of IO nodes, default 1, must be equal to number of network adapters

Prepare Offline Install Package Arguments
  --version STRING                Weka client software version
  --offline-ocp-version STRING    Version of OpenShift Container Platform package is intended for

Create CSI Secret Arguments
  --endpoint-ip-address STRING    one or more Weka cluster Management IP addresses, comma separated
  --system-username STRING        username for API connectivity to Weka cluster
  --system-password STRING        password for API connectivity to Weka cluster
  --system-organization STRING    organization the user belongs to on Weka cluster, default 'Root'

Optional arguments for installation (online or offline):
  --namespace STRING              namespace to install the product in, default weka
  --csi-plugin-namespace STRING   namespace where CSI plugin is (going to) be installed, default csi-wekafs
DELIM
}

export GRAY="\033[1;30m"
export LIGHT_GRAY="\033[0;37m"
export CYAN="\033[0;36m"
export LIGHT_CYAN="\033[1;36m"
export PURPLE="\033[1;35m"
export YELLOW="\033[1;33m"
export LIGHT_RED="\033[1;31m"
export NO_COLOUR="\033[0m"

log_message() {
  # just add timestamp and redirect logs to stderr
  local LEVEL COLOR
  [[ ${1} =~ TRACE|DEBUG|INFO|NOTICE|WARN|WARNING|ERROR|CRITICAL|FATAL ]] && LEVEL="${1}" && shift || LEVEL="INFO"

  case $LEVEL in
  DEBUG) COLOR="$LIGHT_GRAY" ;;
  INFO) COLOR="$CYAN" ;;
  NOTICE) COLOR="$PURPLE" ;;
  WARNING | WARN) COLOR="$YELLOW" ;;
  ERROR | CRITICAL) COLOR="$LIGHT_RED" ;;
  esac

  ts "$(echo -e "$COLOR")[%Y-%m-%d %H:%M:%S] $(echo -e "${LEVEL}$NO_COLOUR")"$'\t' <<<"$*" | tee -a "$LOG_FILE" >&2
}

log_fatal() {
  log_message CRITICAL "$@"
  exit 1
}

check_jq_installed() {
  log_message DEBUG Checking for existence of jq package...
  if ! command -v jq &>/dev/null; then
    log_message ERROR "'jq' executable was not found. Please install jq and rerun the script (refer to your Linux distribution documentation)"
    exit 1
  fi
}

check_oc_installed() {
  log_message DEBUG Checking for existence of oc package...
  if ! command -v oc &>/dev/null; then
    log_message ERROR "'oc' executable was not found. Please install oc and rerun the script"
    exit 1
  fi
}

check_helm_installed() {
  log_message DEBUG Checking for existence of helm package...
  if ! command -v helm &>/dev/null; then
    log_message ERROR "'helm' executable was not found. Please install helm and rerun the script (refer to your Linux distribution documentation)"
    exit 1
  fi
}

check_oc_logged_in() {
  # check if logged in into OC cluster
  if ! oc whoami &>/dev/null; then
    log_fatal "You must log in into OC first"
  fi
}

check_weka_version_specified() {
  if ! [[ ${WEKA_SOFTWARE_VERSION} ]]; then
    usage
    log_fatal "Must specify Weka software version"
  fi
}

compare_versions () {
    v1="${1/#v/}" v2="${1/#v/}"
    if [[ "$v1" == "$v2" ]]
    then
        return 0
    fi
    local IFS=.
    local i ver1=("$v1") ver2=("$v2")
    # fill empty fields in ver1 with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
    do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++))
    do
        if [[ -z ${ver2[i]} ]]
        then
            # fill empty fields in ver2 with zeros
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]}))
        then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]}))
        then
            return 2
        fi
    done
    return 0
}

check_oc_supported_version() {
  OC_VERSION=$(oc version -o json | jq -r .openshiftVersion)
  err_code=0
  compare_versions "$MIN_OC_VERSION" "$OC_VERSION" || err_code=$?
  if [[ $err_code == 1 ]]; then
    log_fatal "Unsupported OpenShift version: required $MIN_OC_VERSION, actual: $OC_VERSION"
    return 1
  fi
  log_message INFO "Supported OpenShift version detected: $OC_VERSION"
  return 0
}

create_docker_pull_secret() {
  log_message NOTICE "Creating Docker PullSecrets"
  oc -n "${NAMESPACE}" apply -f weka-pull-secret/weka-oc-pull-secret.yaml
}

update_core_counts() {
  log_message NOTICE "Configuring core count for Weka Client"
  REAL_CORE_COUNT=$((CORE_COUNT+1))
  ALLOCATED_HUGE_PAGES=$(( HUGE_PAGES_MB_PER_CORE * CORE_COUNT ))
  POD_ALLOCATED_MEMORY="$(( MEMORY_PER_CORE * REAL_CORE_COUNT + BASE_POD_RAM_ALLOCATION ))"Mi
  POD_HUGE_PAGE_VAL="${ALLOCATED_HUGE_PAGES}Mi"
  if [[ $HUGE_PAGE_SIZE == 1024 ]]; then
    DEFAULT_HUGE_PAGE_SIZE_SETTING="1G"
    POD_HUGE_PAGE_KEY="hugepages-1Gi"
  else
    DEFAULT_HUGE_PAGE_SIZE_SETTING="2M"
    POD_HUGE_PAGE_KEY="hugepages-2Mi"
  fi
  sed performance_addon/performance-profile-weka.yaml.tmpl \
    -e "s|DEFAULT_HUGE_PAGE_SIZE_SETTING|$DEFAULT_HUGE_PAGE_SIZE_SETTING|g" \
      >| \
        "$__cache_dir/performance-profile-weka.yaml"
}

install_performance_addon_operator() {
  log_message NOTICE "Installing performance addon operator"
  oc get nodes | grep worker | awk '{print $1}' | xargs -n 1 -I{} oc label node "{}" \
    node-role.kubernetes.io/worker-perf="" \
    machineconfiguration.openshift.io/role=worker-perf \
    csi.weka.io/selinux_enabled="true" --overwrite
  oc apply -f performance_addon/performance-addon-namespace.yaml
  oc apply -f performance_addon/performance-addon-operatorgroup.yaml
  oc apply -f performance_addon/performance-addon-subscription.yaml
  oc apply -f performance_addon/performance-addon-machineconfigpool.yaml
}

check_offline_package_vars() {
  if [[ -z $OFFLINE_OCP_VERSION ]] && [[ $PREPARE_OFFLINE_PACKAGE ]]; then
    log_fatal "Cannot prepare offline package without specifying OCP version, e.g. '--offline-ocp-version 4.10.21'"
  fi
  if [[ $INSTALL_FROM_OFFLINE_PACKAGE ]] &&  [[ -z $OFFLINE_PACKAGE_FILE ]]; then
    log_fatal "Cannot install, offline package is not specified"
  fi
  if [[ $INSTALL_FROM_OFFLINE_PACKAGE ]] && ! [[ -f $OFFLINE_PACKAGE_FILE ]]; then
    log_fatal "Cannot install, offline package does not exist"
  fi
  if [[ $INSTALL_FROM_OFFLINE_PACKAGE ]] && [[ -z $IMAGE_REGISTRY_URL ]]; then
    log_fatal "Cannot install, must specify image registry URL"
  fi
}

obtain_oc_toolkit_url() {
  [[ $OC_RELEASE ]] || OC_RELEASE="${OFFLINE_OCP_VERSION:-$(oc adm release info -o json | jq .metadata.version -r)}"
  log_message INFO "Obtaining kernel driver toolkit build image URL for release $OC_RELEASE"
  [[ $OC_BUILD_TOOLKIT_IMAGE_URL ]] || OC_BUILD_TOOLKIT_IMAGE_URL="$(oc adm release info "${OC_RELEASE}" --image-for=driver-toolkit)"
  log_message DEBUG "$OC_BUILD_TOOLKIT_IMAGE_URL"
}

update_driver_buildconfig() {
  # obtain OC release in order to fetch correct build toolkit image
  log_message NOTICE "Updating Driver Builder based on OpenShift version"
  DRIVER_SOURCES_ARCHIVE_URL="${DRIVERS_SOURCES_BASE_URL}${WEKA_SOFTWARE_VERSION}.tar.gz"
  DRIVERS_IMAGE_URL="${DRIVERS_REPOSITORY_URL}:${WEKA_SOFTWARE_VERSION}"

  # update the driver builder container with correct toolkit image
  sed weka-driver-toolkit/weka-driver-toolkit-buildconfig.yaml.tmpl \
    -e "s|WEKA_SOFTWARE_VERSION|$WEKA_SOFTWARE_VERSION|g" \
    -e "s|DRIVERS_IMAGE_URL|$DRIVERS_IMAGE_URL|g" \
    -e "s|NAMESPACE|$NAMESPACE|g" \
    -e "s|OC_BUILD_TOOLKIT_IMAGE_URL|$OC_BUILD_TOOLKIT_IMAGE_URL|g" \
    -e "s|DRIVERS_IMAGE_PULL_SECRET|$DRIVERS_IMAGE_PULL_SECRET|g" \
      >| \
        "$__cache_dir/weka-driver-toolkit-buildconfig.yaml"

  sed weka-driver-toolkit/weka-driver-toolkit-daemonset.yaml.tmpl \
    -e "s|NAMESPACE|$NAMESPACE|g" \
    -e "s|WEKA_SOFTWARE_VERSION|$WEKA_SOFTWARE_VERSION|g" \
    -e "s|INTERNAL_REGISTRY_URL|$INTERNAL_REGISTRY_URL|g" \
      >| \
        "$__cache_dir/weka-driver-toolkit-daemonset.yaml"

  sed weka-driver-toolkit/weka-driver-toolkit-namespace.yaml.tmpl \
    -e "s|NAMESPACE|$NAMESPACE|g" \
      >| \
        "$__cache_dir/weka-driver-toolkit-namespace.yaml"

  cp weka-driver-toolkit/*.yaml "$__cache_dir"
}

create_kernel_driver() {
  log_message NOTICE "Deploying Weka Kernel Driver Components"
  oc apply -n "${NAMESPACE}" -f "$__cache_dir/weka-driver-toolkit-namespace.yaml"
  oc apply -n "${NAMESPACE}" -f "$__cache_dir/weka-driver-toolkit-serviceaccount.yaml"
  oc apply -n "${NAMESPACE}" -f "$__cache_dir/weka-driver-toolkit-role.yaml"
  oc apply -n "${NAMESPACE}" -f "$__cache_dir/weka-driver-toolkit-rolebinding.yaml"
  oc apply -n "${NAMESPACE}" -f "$__cache_dir/weka-driver-toolkit-imagestream.yaml"
  oc delete -n "${NAMESPACE}" -f "$__cache_dir/weka-driver-toolkit-buildconfig.yaml" || true
  oc apply -n "${NAMESPACE}" -f "$__cache_dir/weka-driver-toolkit-buildconfig.yaml"
  oc apply -n "${NAMESPACE}" -f "$__cache_dir/weka-driver-toolkit-daemonset.yaml"
}

update_client_manifest() {
  log_message NOTICE "Updating Weka Client Deployment based on Weka version"
  CLIENT_IMAGE_URL="${CLIENT_REPOSITORY_URL}:${WEKA_SOFTWARE_VERSION}"

  # update the weka-client-daemonset.yaml:
  sed weka-client/weka-client-daemonset.yaml.tmpl \
    -e "s|CLIENT_IMAGE_URL|$CLIENT_IMAGE_URL|g" \
    -e "s|WEKA_SOFTWARE_VERSION|$WEKA_SOFTWARE_VERSION|g" \
    -e "s|NAMESPACE|$NAMESPACE|g" \
    -e "s|POD_HUGE_PAGE_KEY|$POD_HUGE_PAGE_KEY|g" \
    -e "s|POD_HUGE_PAGE_VAL|$POD_HUGE_PAGE_VAL|g" \
    -e "s|REAL_CORE_COUNT|$REAL_CORE_COUNT|g" \
    -e "s|CORE_COUNT|$CORE_COUNT|g" \
    -e "s|POD_ALLOCATED_MEMORY|$POD_ALLOCATED_MEMORY|g" \
    -e "s|CLIENT_IMAGE_PULL_SECRET|$CLIENT_IMAGE_PULL_SECRET|g" \
      >| \
        "$__cache_dir/weka-client-daemonset.yaml"
}

update_client_config_map() {
  # update the weka-client-config.yaml:
  sed weka-client/weka-client-config.yaml.tmpl \
    -e "s|BACKEND_IP_ADDRESS|$BACKEND_IP_ADDRESS|g" \
    -e "s|BACKEND_NET|$BACKEND_NET|g" \
      >| \
        "$__cache_dir/weka-client-config.yaml"
}

ensure_namespace() {
  log_message NOTICE "Ensuring namespace exists"
  oc get namespace "$NAMESPACE" &>/dev/null || oc create namespace "$NAMESPACE"
  CSI_PLUGIN_NAMESPACE=${CSI_PLUGIN_NAMESPACE:-$(get_csi_plugin_namespace)}
}

create_client_config_map() {
  log_message NOTICE "Creating Weka Client ConfigMap"
  update_client_config_map
  oc -n "$NAMESPACE" apply -f "$__cache_dir/weka-client-config.yaml"
}

create_client_daemonset() {
  log_message NOTICE "Deploying Weka Client Components"
  oc -n "$NAMESPACE" apply -f "$__cache_dir/weka-client-daemonset.yaml"
}

wait_performance_addon() {
  local MAX_ITERATIONS=180
  local counter=0
  log_message INFO "Waiting for Performance Addon Operator Initialization"
  while [[ "$(oc get pod -n openshift-performance-addon-operator -o json | jq -r .items[0].status.phase || true)" != "Running" ]]; do
    sleep 1
    ((++counter))
    if (( counter >= MAX_ITERATIONS )); then
      log_fatal "Failed to initialize Performance Addon Operator after $MAX_ITERATIONS seconds"
    fi
  done
}

create_csi_selinux_policy() {
  log_message INFO "Applying Selinux policy for Weka CSI plugin"
  oc apply -f weka-csi-driver/csi-wekafs-selinux-policy-machineconfig.yaml
}

create_weka_performance_profile() {
  oc apply -f "$__cache_dir/performance-profile-weka.yaml"
}

get_csi_plugin_namespace() {
  log_message INFO "Checking for existing Weka CSI Plugin Helm release"
  local ns
  ns="$(helm list --all-namespaces -o json | jq -r '.[] | select(.chart |contains("csi-wekafs")) | .namespace')"
  if [[ $ns ]]; then
    log_message INFO "Found an existing Weka CSI Plugin Helm release named in namespace '$ns'"
    echo -n "$ns"
  else
    log_message INFO "Did not find an existing Weka CSI Plugin Helm release, defaulting namespace to $DEFAULT_CSI_PLUGIN_NAMESPACE"
    echo -n "$DEFAULT_CSI_PLUGIN_NAMESPACE"
  fi
}

bind_csi_plugin_service_accounts() {
  log_message DEBUG "Ensuring existence of CSI plugin namespace $CSI_PLUGIN_NAMESPACE"
  oc get namespace "$CSI_PLUGIN_NAMESPACE" || oc create namespace "$CSI_PLUGIN_NAMESPACE"
  oc adm policy add-scc-to-user privileged "system:serviceaccount:${CSI_PLUGIN_NAMESPACE}:${CSI_PLUGIN_NAMESPACE}-node"
  oc adm policy add-scc-to-user privileged "system:serviceaccount:${CSI_PLUGIN_NAMESPACE}:${CSI_PLUGIN_NAMESPACE}-controller"
}

install_csi_plugin() {
  bind_csi_plugin_service_accounts
  helm repo add csi-wekafs "$CSI_REPO_URL" || true
  helm repo update
  helm upgrade --install "$CSI_PLUGIN_NAMESPACE" csi-wekafs/csi-wekafsplugin --namespace "$CSI_PLUGIN_NAMESPACE" \
    --create-namespace --set selinuxSupport=enforced $CSI_OFFLINE_REPO_SETTINGS
}

docker_login_weka() {
  docker login -u="weka.io+weka_oc" -p="KRZUQPGKVZE4ITYNH85GGVCGQU5MLM06STB5PKI5OPVRK7F53E7PX3LUZ5IN88I9" quay.io
}

# ------------------ OFFLINE PACKAGE CREATION -------------------------
docker_login_redhat() {
  export DOCKER_CONFIG=$PWD/weka-pull-secret
}

docker_login_internal_registry() {
  docker login -u kubeadmin -p "$(oc whoami --show-token)" "$IMAGE_REGISTRY_URL"
}

docker_logout_redhat() {
  unset DOCKER_CONFIG
}

export_docker_image() {
  local category image_url tag repo package_name new_url
  image_url="$1" category="$2"
  tag="$(echo -n "$image_url" | sed s'/.*:\(.*\)/\1/1')"
  repo="$(echo -n "$image_url" | sed s'/\([^:]*\).*$/\1/1')"
  package_name="$(basename "$repo" | cut -d"@" -f1)"
  digest_signature="$(basename "$repo" | cut -d"@" -f2 -s)"
  new_url="$package_name:$tag"
  filename="$package_name:$tag.tar"
  filepath="$__cache_dir/$filename"
  log_message INFO "Downloading docker image from URL '$image_url'"
  docker pull "$image_url"
  if [[ $digest_signature ]]; then
    log_message WARNING "Tag is a $digest_signature digest, replacing it with regular tag"
    digest_signature=\"$digest_signature\"
  else
    digest_signature=null
  fi
  log_message INFO "Tagging docker image with new name '$new_url'"
  docker tag "$image_url" "$package_name:$tag"
  log_message INFO "Saving image '$new_url' to '$filepath'"
  docker save "$new_url" > "$filepath"
  log_message INFO "Image saved"
  manifest="{
  \"$package_name\": {
    \"category\": \"$category\",
    \"image_url\": \"$image_url\",
    \"repo\": \"$repo\",
    \"package_name\": \"$package_name\",
    \"digest_signature\": $digest_signature,
    \"filename\": \"$filename\",
    \"tag\": \"$tag\"
  }
}"

  manifests="$(jq --slurp 'add' <(echo "$manifests") <(echo "$manifest"))"
}

export_weka_images() {
  export_docker_image "${CLIENT_REPOSITORY_URL}:${WEKA_SOFTWARE_VERSION}" "weka_client"
  export_docker_image "${DRIVERS_REPOSITORY_URL}:${WEKA_SOFTWARE_VERSION}" "weka_client"
}

export_csi_plugin_images() {
  local VALUES_YAML image_type driver_url driver_version
  log_message INFO "Exporting CSI plugin images"
  VALUES_YAML="$(curl $CSI_GIT_URL/values.yaml)"

  local IMAGE_TYPES="livenessprobesidecar attachersidecar provisionersidecar registrarsidecar resizersidecar"
  for image_type in $IMAGE_TYPES; do
    log_message DEBUG "$image_type"
    url="$(echo "$VALUES_YAML" | grep -w "$image_type" | sed 's/.*: //1')"
    export_docker_image "$url" "csi_plugin"
  done
  driver_url="$(echo "$VALUES_YAML" | grep -w "csidriver" | sed 's/.*: //1')"
  driver_version="$(echo "$VALUES_YAML" | grep -w "csiDriverVersion:" | sed 's/.*: \(&csiDriverVersion \)*//1')"
  export_docker_image "${driver_url}:v${driver_version}" "csi_plugin"
}

export_driver_toolkit_image() {
  log_message INFO "Exporting OpenShift driver toolkit build image"
  docker_login_redhat
  export_docker_image "$OC_BUILD_TOOLKIT_IMAGE_URL" "build_image"
  docker_logout_redhat
}

prepare_offline_package() {
  echo '{}' > "$__cache_dir/MANIFEST.json"
  docker_login_weka
  export_weka_images
  export_csi_plugin_images
  export_driver_toolkit_image
  OFFLINE_PACKAGE_FILE="offline-package-$WEKA_SOFTWARE_VERSION-ocp$OFFLINE_OCP_VERSION.tar"
  log_message INFO "Creating offline package file $OFFLINE_PACKAGE_FILE"
  manifest="{
  \"images\": $manifests,
  \"version_info\": {
    \"weka_version\": \"$WEKA_SOFTWARE_VERSION\",
    \"ocp_version\": \"$OFFLINE_OCP_VERSION\",
    \"build_time\": \"$(date --utc +'%Y-%m-%d %H:%M:%S%Z')\",
    \"build_host\": \"$(hostname)\"
  }
}"
  echo "$manifest" | jq . >| "$__cache_dir/MANIFEST.json"
  log_message INFO "Creating MD5 signature of distributed files"
  (cd "$__cache_dir" && md5sum * | tee CHECKSUM)
  log_message INFO "Creating tar archive"
  tar cvf "$OFFLINE_PACKAGE_FILE" -C "$__cache_dir" .
  log_message INFO "Done!"
}

get_namespace_by_category() {
  case "$1" in
    weka_client) echo -n "$NAMESPACE";;
    csi_plugin) echo -n "$CSI_PLUGIN_NAMESPACE";;
    build_image) echo -n "$NAMESPACE";;
  esac
}

# ------------------------- INSTALLATION FROM OFFLINE PACKAGE -------------------------
import_docker_image() {
  # gets a json manifest of a package
  local package_name tag filename new_url digest_signature filepath manifest namespace category
  manifest="$1"
  package_name="$(echo "$manifest" | jq -r .package_name)"
  tag="$(echo "$manifest" | jq -r .tag)"
  filename="$(echo "$manifest" | jq -r .filename)"
  digest_signature="$(echo "$manifest" | jq -r .digest_signature)"
  category="$(echo "$manifest" | jq -r .category)"
  namespace=$(get_namespace_by_category "$category")
  new_url="$IMAGE_REGISTRY_URL/$namespace/$package_name:$tag"
  filepath="$__cache_dir/$filename"
  log_message INFO "Loading docker image $tag from file '$filepath'"
  docker load -i "$filepath"
  if [[ $digest_signature != null ]]; then
    log_message WARNING "Image for $package_name had a $digest_signature signature that is invalid after re-import!"
  fi
  log_message INFO "Tagging docker image with new name '$new_url'"
  docker tag "$package_name:$tag" "$new_url"
  log_message INFO "Pushing image $new_url"
  docker push "$new_url"
  log_message INFO "Done"
  oc set image-lookup -n $namespace $package_name
}

import_docker_images() {
  docker_login_internal_registry
  for image in $(jq '.images | keys[]' "$MANIFEST_FILE"); do
    image_metadata="$(jq -r ".images[$image]" "$MANIFEST_FILE")"
    import_docker_image "$image_metadata"
  done
  oc set image-lookup -n $NAMESPACE weka-kmod-drivers-container

}

unpack_offline_package() {
    log_message INFO "Attempting to unpack the file"
  (
    if test "$(basename "$OFFLINE_PACKAGE_FILE")" == "$OFFLINE_PACKAGE_FILE"; then
      OFFLINE_PACKAGE_FILE="$PWD/$OFFLINE_PACKAGE_FILE"
    fi
    cd "$__cache_dir"
    tar xvf "$OFFLINE_PACKAGE_FILE"
  )
}

patch_offline_parameters() {
  log_message NOTICE "Updating offline installation parameters"
  MANIFEST_FILE="$__cache_dir/MANIFEST.json"
  test -f "$MANIFEST_FILE" || log_fatal "Could not find MANIFEST.json"
  WEKA_SOFTWARE_VERSION=$(jq -r '.version_info.weka_version' "$MANIFEST_FILE")
  OFFLINE_OCP_VERSION=$(jq -r '.version_info.ocp_version' "$MANIFEST_FILE")
  OC_RELEASE="$(oc adm release info -o json | jq .metadata.version -r)"

  if compare_versions $OC_RELEASE $OFFLINE_OCP_VERSION; then
    log_message INFO "Package version matches OpenShift cluster, proceeding with install"
  else
    log_fatal "Cannot install, OC version $OC_RELEASE differs from package $OFFLINE_OCP_VERSION"
  fi
  OC_RELEASE=$OFFLINE_OCP_VERSION
  CLIENT_REPOSITORY_URL="$INTERNAL_REGISTRY_URL/$NAMESPACE/weka-in-container"
  DRIVERS_REPOSITORY_URL="$INTERNAL_REGISTRY_URL/$NAMESPACE/weka-coreos-drivers"
  OC_BUILD_TOOLKIT_IMAGE_NAME=$(jq -r '.images["ocp-v4.0-art-dev"].package_name' $MANIFEST_FILE)
  OC_BUILD_TOOLKIT_IMAGE_TAG=$(jq -r '.images["ocp-v4.0-art-dev"].tag' $MANIFEST_FILE)
  OC_BUILD_TOOLKIT_IMAGE_URL="$INTERNAL_REGISTRY_URL/$NAMESPACE/$OC_BUILD_TOOLKIT_IMAGE_NAME:$OC_BUILD_TOOLKIT_IMAGE_TAG"
  unset DRIVERS_IMAGE_PULL_SECRET
  unset CLIENT_IMAGE_PULL_SECRET
}

update_csi_variables() {
  log_message INFO "Updating CSI plugin images"
  local IMAGE_TYPES package_name tag image_type url driver_version
  IMAGE_TYPES="livenessprobe attacher provisioner registrar resizer"
  for image_type in $IMAGE_TYPES; do
    package_name=$(jq -r ".images | keys[]" $MANIFEST_FILE | grep $image_type)
    tag=$(jq -r ".images[\"$package_name\"].tag" $MANIFEST_FILE)
    url="$INTERNAL_REGISTRY_URL/$CSI_PLUGIN_NAMESPACE/$package_name:$tag"
    log_message INFO "Setting ${image_type}sidecar URL to $url"
    CSI_OFFLINE_REPO_SETTINGS+=" --set images.${image_type}sidecar=$url"
  done
  package_name="csi-wekafs"
  tag=$(jq -r ".images[\"$package_name\"].tag" $MANIFEST_FILE)
  driver_version=$(echo -n "$tag" | sed 's/^v//1')
  CSI_OFFLINE_REPO_SETTINGS+=" --set csiDriverVersion=$driver_version"
  CSI_OFFLINE_REPO_SETTINGS+=" --set images.csidriver=$INTERNAL_REGISTRY_URL/$CSI_PLUGIN_NAMESPACE/$package_name"
  CSI_OFFLINE_REPO_SETTINGS+=" --set images.csidriverTag=$driver_version"
  log_message INFO "Setting CSI driver URL to $INTERNAL_REGISTRY_URL/$CSI_PLUGIN_NAMESPACE/$package_name:$tag"
}

process_offline_package() {
  unpack_offline_package
  check_oc_logged_in
  patch_offline_parameters
  update_csi_variables
  import_docker_images
}

check_pre_install() {
  if ((NUM_NICS != CORE_COUNT)); then
    log_fatal "Number of NICs ($NUM_NICS) is not equal to number of cores ($CORE_COUNT)"
  fi
  if ! [[ ${BACKEND_IP_ADDRESS} ]]; then
    usage
    log_fatal "Must specify a valid IP address of Weka backend server"
  fi
  if ! [[ ${BACKEND_NET} ]]; then
    usage
    log_fatal "Must specify a valid name of network interface to use on OCP node, e.g. ens256"
  fi
}

check_pre_csi_secret() {
  if [[ -z "$SYSTEM_USERNAME" ]]; then
    usage
    log_fatal "Must specify SYSTEM_USERNAME for CSI secret installation"
  fi
  if [[ -z "$SYSTEM_PASSWORD" ]]; then
    echo "$SYSTEM_PASSWORD"
    usage
    log_fatal "Must specify SYSTEM_PASSWORD for CSI secret installation"
  fi
  if [[ -z "$ENDPOINT_IP_ADDRESS" ]]; then
    usage
    log_fatal "Must specify BACKEND_IP_ADDRESS for CSI secret installation"
  fi
}

install_csi_secret() {
  log_message NOTICE "Ensuring CSI plugin secret"
  local ip endpoint_ips endpoint_ip_string CSI_ENDPOINTS_ENCODED
  endpoint_ips="$(echo "$ENDPOINT_IP_ADDRESS" | tr ',' ' ')"
  for ip in $endpoint_ips; do
    endpoint_ip_string+=" $ip:14000"
  done
  endpoint_ip_string=$(echo -n $endpoint_ip_string | tr ' ' ',')
  CSI_ENDPOINTS_ENCODED="$(echo -n "$endpoint_ip_string" | base64)"
  CSI_SYSTEM_USERNAME_ENCODED="$(echo -n "$SYSTEM_USERNAME" | base64)"
  CSI_SYSTEM_PASSWORD_ENCODED="$(echo -n "$SYSTEM_PASSWORD" | base64)"
  CSI_SYSTEM_ORGANIZATION_ENCODED="$(echo -n "${SYSTEM_ORGANIZATION:-$DEFAULT_CSI_SYSTEM_ORGANIZATION}" | base64)"
  CSI_HTTP_SCHEME_ENCODED="$(echo -n "${SYSTEM_HTTP_SCHEME:-$DEFAULT_CSI_HTTP_SCHEME}" | base64)"

  sed weka-csi-driver/csi-wekafs-api-secret.yaml.tmpl \
    -e "s|CSI_ENDPOINTS_ENCODED|$CSI_ENDPOINTS_ENCODED|g" \
    -e "s|CSI_SYSTEM_USERNAME_ENCODED|$CSI_SYSTEM_USERNAME_ENCODED|g" \
    -e "s|CSI_SYSTEM_PASSWORD_ENCODED|$CSI_SYSTEM_PASSWORD_ENCODED|g" \
    -e "s|CSI_SYSTEM_ORGANIZATION_ENCODED|$CSI_SYSTEM_ORGANIZATION_ENCODED|g" \
    -e "s|CSI_HTTP_SCHEME_ENCODED|$CSI_HTTP_SCHEME_ENCODED|g" \
    -e "s|CSI_PLUGIN_NAMESPACE|$CSI_PLUGIN_NAMESPACE|g" \
      >| \
        "$__cache_dir/csi-wekafs-api-secret.yaml"

  oc apply -f "$__cache_dir/csi-wekafs-api-secret.yaml"
}

main() {
  [[ $# -eq 0 ]] && usage && exit 1
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --help|-h)
      usage
      exit
      ;;
    --version)
      shift
      WEKA_SOFTWARE_VERSION="$1"
      ;;
    --core-count)
      shift
      CORE_COUNT="$1"
      ;;
    --backend-ip-address)
      shift
      BACKEND_IP_ADDRESS="$1"
      ;;
    --backend-net)
      shift
      BACKEND_NET="$1"
      ;;
    --namespace)
      shift
      NAMESPACE="$1"
      ;;
    --csi-plugin-namespace)
      shift
      CSI_PLUGIN_NAMESPACE="$1"
      ;;
    --prepare-offline-package)
      PREPARE_OFFLINE_PACKAGE=1
      ;;
    --from-offline-package)
      shift
      OFFLINE_PACKAGE_FILE="$1"
      INSTALL_FROM_OFFLINE_PACKAGE=1
      ;;
    --offline-ocp-version)
      shift
      OFFLINE_OCP_VERSION="$1"
      ;;
    --image-registry-url)
      shift
      IMAGE_REGISTRY_URL="$1"
      ;;
    --create-csi-secret)
      CREATE_CSI_SECRET=1
      ;;
    --system-username)
      shift
      SYSTEM_USERNAME="$1"
      ;;
    --system-password)
      shift
      SYSTEM_PASSWORD="$1"
      ;;
    --system-organization)
      shift
      SYSTEM_ORGANIZATION="$1"
      ;;
    --system-http-scheme)
      shift
      SYSTEM_HTTP_SCHEME="$1"
      ;;
    --endpoint-ip-address)
      shift
      ENDPOINT_IP_ADDRESS="$1"
      ;;
    *)
      log_message ERROR "Could not parse remaining arguments: $*"
      exit 1
      ;;
    esac
    shift || log_fatal "Could not parse arguments, please check command line"
  done
  NAMESPACE="${NAMESPACE:-weka}"
  CORE_COUNT=${CORE_COUNT:-1}
  NUM_NICS=$(echo "$BACKEND_NET" | tr ',' ' ' | wc -w)

  log_message NOTICE "Checking for installed dependencies..."
  check_jq_installed
  check_oc_installed
  check_helm_installed

  if [[ $PREPARE_OFFLINE_PACKAGE ]]; then
    check_weka_version_specified
    obtain_oc_toolkit_url
    check_offline_package_vars
    prepare_offline_package
    exit
  fi

  ensure_namespace
  if [[ $CREATE_CSI_SECRET ]]; then
    check_pre_csi_secret
    install_csi_secret
    exit
  fi

  obtain_oc_toolkit_url

  if [[ $INSTALL_FROM_OFFLINE_PACKAGE ]]; then
    log_message INFO "Assuming installation from offline package"
    check_offline_package_vars
    process_offline_package
  fi

  check_weka_version_specified
  check_pre_install

  check_oc_logged_in
  check_oc_supported_version

  install_performance_addon_operator

  # configure core allocation
  wait_performance_addon
  update_core_counts
  create_weka_performance_profile

  update_driver_buildconfig

  create_csi_selinux_policy

  update_client_manifest

  create_docker_pull_secret

  create_kernel_driver

  create_client_config_map

  create_client_daemonset

  install_csi_plugin

  log_message INFO "All done!"
}

main "$@"

