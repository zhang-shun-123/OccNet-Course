#!/bin/bash

TOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${TOP_DIR}"/scripts/qcraft_base.sh
. "${TOP_DIR}"/scripts/car_release_run_error_code
#shellcheck disable=SC2034
readonly MAX_LOOKBACK_SECS=10

# Tune network buffer size to increase networking performance
# Arguments:
#   None
# Ref: https://www.cyberciti.biz/faq/linux-tcp-tuning
# Returns:
#   None
#############################################################
function IncNetWorkBufSize() {
  readonly sz=104857600 # 100M
  readonly proc_dir="/proc/sys/net/core"

  local rmem_default
  rmem_default="$(read_one_line_file "${proc_dir}/rmem_default")"
  local rmem_max
  rmem_max="$(read_one_line_file "${proc_dir}/rmem_max")"

  if [[ "${rmem_default}" -eq "${sz}" && "${rmem_max}" -eq "${sz}" ]]; then
    info "Network buffers size has already been set."
  else
    info "Tune network buffers size to increase networking performance:"
    echo "net.core.rmem_max=${sz}" | sudo tee -a /etc/sysctl.conf
    echo "net.core.rmem_default=${sz}" | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p > /dev/null
  fi
}

# Note(jiaming): to-be-deprecated
#shellcheck disable=SC2199
#shellcheck disable=SC2076
function CheckOffice() {
  local office=
  office="$(canonical_office "$1")"
  if [[ " ${AVAILABLE_OFFICES[@]} " =~ " ${office} " ]]; then
    return 0
  else
    return 1
  fi
}

function MountExternalDiskForLogs() {
  local runs_dir=$1
  local run_disk_name=$2
  local warning_threshold=$3
  local qpad_enabled=$4
  local run_disk_id
  #shellcheck disable=SC2010
  run_disk_id=$(basename "$(ls -l /dev/disk/by-label | grep "$run_disk_name " | awk '{print $NF}')")
  if [ -z "$run_disk_id" ]; then
    run_disk_id=$(blkid | grep "nvme0n1" | awk '{print substr($0,6,7)}')
    if [ -z "$run_disk_id" ]; then
      echo 'Failed to detect the run disk, make sure it is inserted.'
      return 1
    fi
  fi

  run_disk_id="/dev/$run_disk_id"
  echo "run_disk_id is $run_disk_id"

  if [ ! -d "$runs_dir" ]; then
    q_sudo mkdir -p "$runs_dir"
  fi

  echo "Disk is detected."
  q_sudo umount "$run_disk_id"
  q_sudo mount "$run_disk_id" "$runs_dir"

  # 0 means qpad enabled, if qpad enabled, don't ask for user interaction
  if [ "$qpad_enabled" = "0" ]; then
    echo "qpad enabled, skip disk check and quit the function"
    return 0
  fi
  #############################################################################################################################
  local available_space
  available_space=$(timeout --preserve-status 10 df -k | grep "$run_disk_id" | awk '{print $4}')
  if [ "$available_space" = '' ]; then
    error "Cannot check the available space on HD through df command. Please make sure external HD $run_disk_id is mounted."
    q_sudo umount "$run_disk_id"
    return 1
  fi
  ############ do not put any code here between "timeout" above and $? below
  # shellcheck disable=SC2181
  if [ $? != "0" ]; then
    error "df command timeout. Cannot check the available space on external HD."
    q_sudo umount "$run_disk_id"
    return 1
  fi
  #############################################################################################################################
  if [[ "$available_space" -lt "$warning_threshold" ]]; then
    error "Less than 100G available on external HD."
    q_sudo umount "$run_disk_id"
    return 1
  fi
}

function get_repo_address() {
  local REPO_TYPE=$1
  local REPO_ADDRESS
  case "$REPO_TYPE" in
    OFFICE)
      echo -e "Using OFFICE Repo\n"
      REPO_ADDRESS="office.qcraft.ai"
      ;;

    REMOTE)
      echo -e "Using REMOTE Repo\n"
      REPO_ADDRESS="qcraft-docker.qcraft.ai"
      # shellcheck disable=SC2034
      IMG="${REMOTE_IMG}"
      ;;

    ECR)
      echo -e "Using ECR Repo\n"
      REPO_ADDRESS="548416963446.dkr.ecr.cn-northwest-1.amazonaws.com.cn"
      # login aws, key should provide with docker environment
      aws ecr get-login-password --region cn-northwest-1 | docker login --username AWS --password-stdin 548416963446.dkr.ecr.cn-northwest-1.amazonaws.com.cn
      ;;

    ALI)
      echo -e "Using ALI Repo\n"
      REPO_ADDRESS="registry.qcraftai.com"
      ;;

    *)
      echo -e "REPO_TYPE=$REPO_TYPE, Unknown REPO_TYPE (OFFICE,REMOTE,ECR,ALI), exit"
      exit 1
      ;;
  esac

  eval "$2='$REPO_ADDRESS'"
}

function login_registry() {
  local REPO_TYPE=$1
  case "$REPO_TYPE" in
    ALIYUN_CN)
      echo -e "Using ALIYUN_CN Repo\n"
      docker login registry.qcraftai.com --username="$ALIYUN_REGISTRY_USERNAME" --password "$ALIYUN_REGISTRY_PASSWORD"
      ;;

    ALIYUN_US)
      echo -e "Using ALIYUN_US Repo\n"
      docker login registry.us-west-1.aliyuncs.com --username="$ALIYUN_REGISTRY_USERNAME" --password "$ALIYUN_REGISTRY_PASSWORD"
      ;;

    AWS_ECR_CN)
      echo -e "Using AWS ECR CN Repo\n"
      aws ecr get-login-password --region cn-northwest-1 | docker login --username AWS --password-stdin 548416963446.dkr.ecr.cn-northwest-1.amazonaws.com.cn
      ;;

    AWS_ECR_US)
      echo -e "Using AWS ECR US Repo\n"
      aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin 661656117900.dkr.ecr.us-west-2.amazonaws.com
      ;;

    *)
      echo -e "REPO_TYPE=$REPO_TYPE, Unknown REPO_TYPE, exit"
      exit 1
      ;;
  esac
}

function EnableCoreDump() {
  ulimit -c unlimited
  mkdir -p ~/release-cache/core
  find ~/release-cache/core/ -mtime +7 -name "core-*" -exec rm -rf {} \;
  sudo sh -c "echo '/hosthome/release-cache/core/core-%e-%p-%t' > /proc/sys/kernel/core_pattern"
}

function FindCIHostLocation() {
  local CI_HOST_LOCATION=""
  # us bay area office
  if [ "$HOSTNAME" = "qcraft-ci-01" ] \
    || [ "$HOSTNAME" = "qcraft-ci-02" ] \
    || [ "$HOSTNAME" = "qcraft-ci-03" ] \
    || [ "$HOSTNAME" = "q9001" ] \
    || [ "$HOSTNAME" = "q9999" ] \
    || [ "$HOSTNAME" = "qcraft-xavier" ] \
    || [ "$HOSTNAME" = "ml12w" ]; then
    CI_HOST_LOCATION="bayarea-scott"
  # arm us
  elif [ "$HOSTNAME" = "ip-172-31-3-96" ] \
    || [ "$HOSTNAME" = "ip-172-31-13-91" ]; then
    CI_HOST_LOCATION="arm-aws-us"
  # arm cn
  elif [ "$HOSTNAME" = "ip-172-31-26-151" ] \
    || [ "$HOSTNAME" = "ip-172-31-31-86" ]; then
    CI_HOST_LOCATION="arm-aws-cn"
  # us bay area office within edge-us cluster
  elif [ "$HOSTNAME" = "pc-012" ] \
    || [ "$HOSTNAME" = "pc-027" ]; then
    CI_HOST_LOCATION="bayarea-scott-edge-us"
  # shenzhen office
  elif [ "$HOSTNAME" = "nvidia-desktop" ] \
    || [ "$HOSTNAME" = "qcraft" ] \
    || [ "$HOSTNAME" = "sky" ] \
    || [ "$HOSTNAME" = "ocean" ]; then
    CI_HOST_LOCATION="shenzhen-office"
  # beijing office (bj-edge-01 in edge-cn cluster)
  elif [ "$HOSTNAME" = "bj-edge-01" ]; then
    CI_HOST_LOCATION="beijing-office"
  # edge-cn-aws-bj
  elif [ "$HOSTNAME" = "edge-cn-aws-bj01" ]; then
    CI_HOST_LOCATION="edge-cn-aws-bj"
  # edge-cn-aliyun
  elif [ "$HOSTNAME" = "aliyun-edge-ci-01" ] \
    || [ "$HOSTNAME" = "aliyun-edge-ci-02" ] \
    || [ "$HOSTNAME" = "aliyun-edge-ci-03" ] \
    || [ "$HOSTNAME" = "aliyun-edge-ci-04" ] \
    || [ "$HOSTNAME" = "aliyun-edge-ci-05" ] \
    || [ "$HOSTNAME" = "aliyun-edge-ci-06" ] \
    || [ "$HOSTNAME" = "aliyun-edge-ci-07" ] \
    || [ "$HOSTNAME" = "aliyun-edge-ci-08" ] \
    || [ "$HOSTNAME" = "aliyun-edge-ci-09" ] \
    || [ "$HOSTNAME" = "aliyun-edge-ci-10" ]; then
    CI_HOST_LOCATION="edge-cn-aliyun"
  # edge-cn-aliyun-gpu
  elif [ "$HOSTNAME" = "aliyun-edge-2080ti-01" ] \
    || [ "$HOSTNAME" = "aliyun-edge-2080ti-02" ] \
    || [ "$HOSTNAME" = "aliyun-edge-2080ti-03" ] \
    || [ "$HOSTNAME" = "aliyun-edge-2080ti-04" ] \
    || [ "$HOSTNAME" = "aliyun-edge-2080ti-05" ] \
    || [ "$HOSTNAME" = "aliyun-edge-2080ti-06" ]; then
    CI_HOST_LOCATION="edge-cn-aliyun-gpu"
  # edge-us-aliyun
  elif [ "$HOSTNAME" = "us-edge-02" ] \
    || [ "$HOSTNAME" = "us-edge-03" ] \
    || [ "$HOSTNAME" = "us-edge-04" ] \
    || [ "$HOSTNAME" = "us-edge-05" ] \
    || [ "$HOSTNAME" = "us-edge-06" ] \
    || [ "$HOSTNAME" = "us-edge-07" ] \
    || [ "$HOSTNAME" = "us-edge-08" ] \
    || [ "$HOSTNAME" = "us-edge-09" ] \
    || [ "$HOSTNAME" = "us-edge-10" ] \
    || [ "$HOSTNAME" = "us-edge-11" ]; then
    CI_HOST_LOCATION="edge-us-aliyun"
  # dev box testing
  elif [ "$HOSTNAME" = "qcraft-desktop" ]; then
    CI_HOST_LOCATION="dev-box"
  fi
  echo "$CI_HOST_LOCATION"
}