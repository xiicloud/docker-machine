#!/bin/sh
num_cmp(){
  if [ $# -lt  3 ];then
    return 1
  fi
  local res=$(echo "$1 $3"|awk "{ res = \$1 $2 \$2; print res;}")
  if [ $res -eq 1 ];then
    return 0
  else
    return 1
  fi
}

get_bool_choice() {
  local choice
  declare -l choice
  while true; do
    read -p "$1 [(y/yes)/(n/no)]:" choice
    case "$choice" in
      y|yes)
        echo y
        return 0
        ;;
      n|no)
        echo n
        return 0
        ;;
    esac
  done
}

get_str_param() {
  local str
  local prompt="$1${2:+ [${2}]}: "
  read -p "$prompt"  str
  echo $str
}

get_docker_cmd() {
  if command_exists docker ; then
    DOCKER_CMD=docker
  elif command_exists lxc-docker; then
    DOCKER_CMD=lxc-docker
  else
    echo "Docker not installed"
    HAS_DOCKER=false
  fi
}

wait_for_docker() {
  echo "Waiting for docker daemon startup..."
  for i in $(seq 1 120); do
    if docker info >/dev/null; then
      return 0
    else
      sleep 1
    fi
  done
  echo "Docker daemon isn't running."
  echo "Please start the Docker daemon and run this script again."
  exit 1
}

# should be called after 'get_docker_cmd'
check_docker_version() {
  local ask_upgrade=false
  local must_upgrade=false
  local ver=$($DOCKER_CMD version|grep 'Server version'|cut -d ' ' -f 3|awk -F '.' '{print $1"."$2}')
  if num_cmp $ver "<" 1.6; then
    echo "The version of Docker is not supported."
    echo "To use cSphere you must upgrade Docker to 1.6 or above."
    ask_upgrade=true
    must_upgrade=true
  fi

  if $ask_upgrade; then
    echo -ne "\e[32m"
    local choice=$(get_bool_choice "Do you want to upgrade your docker?")
    echo -ne "\e[0m"
    if [ $choice = y ]; then
      UPGRADE_DOCKER=true
    elif $must_upgrade; then
      echo "Can't install cSphere without a supported version of Docker."
      exit 1
    fi
  fi
}

progress_bar() {
  local exitval_file=/tmp/csphere-install.$(head -n 100 /dev/urandom|tr -dc 'a-z0-9A-Z'|head -c 10)
  (set -e; eval "$1"; echo $? > "$exitval_file") &
  while [[ ! -e $exitval_file ]]; do
    sleep 1
    echo -en "."
  done
  echo
  local exit_val=$(cat $exitval_file)
  rm $exitval_file
  if [ "$exit_val" != "0" ]; then
    echo $2
    exit $exit_val
  fi
}

prepare_csphere() {
  if [ "$ROLE" = "agent" -a -z "$AUTH_KEY" ]; then
    echo
    echo -ne "\e[31m"
    echo "An auth token is required to secure the network communication between "
    echo "agents and controller."
    echo "If you're installing agent, you must ensure that the token here is the same"
    echo "as what you had provided when installing the controller."
    echo -ne "\e[0m"
    echo
    echo -ne "\e[32m"
    while [ -z "$AUTH_KEY" ]; do
      AUTH_KEY=$(get_str_param "Please input the auth token")
    done
    echo -ne "\e[0m"
  fi

  DATA_DIR=${DATA_DIR:-$DEFAULT_DATA_DIR}
  [ -d $DATA_DIR ] || mkdir -p $DATA_DIR
  if command_exists chcon; then
    chcon -Rt svirt_sandbox_file_t $DATA_DIR >/dev/null 2>&1 || true
  fi

  if docker inspect --format='{{.Id}}' "csphere/csphere:$CSPHERE_VERSION" >/dev/null 2>&1; then
    echo "cSphere Docker image existed "
    CSPHERE_IMAGE=csphere/csphere:$CSPHERE_VERSION
    return 0
  fi

  if echo $CSPHERE_IMAGE|grep -q http; then
    local image_file=/tmp/csphere-image.$(head -n 100 /dev/urandom|tr -dc 'a-z0-9A-Z'|head -c 10).tar.gz
    echo -n "Downloading cSphere Docker image "
    progress_bar "$curl $CSPHERE_IMAGE >$image_file" "Failed to download cSphere Docker image."
    docker load -i $image_file
    CSPHERE_IMAGE=csphere/csphere:$CSPHERE_VERSION
  else
    docker pull $CSPHERE_IMAGE
  fi
}

install_csphere_controller() {
  prepare_csphere
  /sbin/iptables -I INPUT -p tcp --dport $CONTROLLER_PORT -j ACCEPT > /dev/null 2>&1 || true
  docker stop -t 600 csphere-controller 2>/dev/null || true
  docker rm csphere-controller 2>/dev/null || true
  docker run -d --restart=always --name=csphere-controller \
    -v $DATA_DIR:/data:rw \
    -p $CONTROLLER_PORT:80 \
    -e ROLE=controller \
    -e AUTH_KEY=$AUTH_KEY \
    -l CSPHERE_ROLE=controller \
    $CSPHERE_IMAGE
}

install_csphere_agent() {
  prepare_csphere
  if [ -z "$CONTROLLER_IP" ]; then
    while true; do
      echo -ne "\e[32m"
      CONTROLLER_IP=$(get_str_param "Please input the IP address of the controller")
      echo -ne "\e[0m"
      [ -n "$CONTROLLER_IP" ] && break
    done
  fi

  docker rm -f csphere-agent 2>/dev/null || true
  docker run -d --restart=always --name=csphere-agent -e ROLE=agent \
    -e CONTROLLER_ADDR=$CONTROLLER_IP:$CONTROLLER_PORT \
    -e AUTH_KEY=$AUTH_KEY \
    -e SVRPOOLID=$SVRPOOLID \
    -v $DATA_DIR:/data:rw \
    -v /proc:/rootfs/proc:ro \
    -v /sys:/rootfs/sys:ro \
    -v /etc:/rootfs/etc:rw \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -l CSPHERE_ROLE=agent \
    --net=host $CSPHERE_IMAGE
}

start_docker() {
  if docker info >/dev/null 2>&1; then
    return
  fi

  if [ -f /etc/init.d/apparmor ]; then
    service apparmor reload || true
  fi

  # try every possible start methods
  initctl start docker || systemctl start docker || service docker start
}

dist_fixup() {
  if [ -f /etc/centos-release ] && grep -q '7\.0\.' /etc/centos-release; then
    yum update -y device-mapper-libs
  fi
}

main() {
  curl=''
  if command_exists curl; then
    curl='curl -sSL'
  elif command_exists wget; then
    curl='wget -qO-'
  elif command_exists busybox && busybox --list-modules | grep -q wget; then
    curl='busybox wget -qO-'
  fi

  # Install missing dependencies on some distros.
  dist_fixup
  get_docker_cmd
  if $HAS_DOCKER; then
    start_docker
    wait_for_docker
    check_docker_version
    if $UPGRADE_DOCKER; then
      echo "Your docker daemon and all your running containers will be restarted."
      if [ $(get_bool_choice "Continue?") = n ]; then
        echo "Aborted"
        exit 1
      fi
    fi
  fi

  if ! $HAS_DOCKER || $UPGRADE_DOCKER; then
    install_docker
    start_docker
    wait_for_docker
  fi

  echo "============= install cSphere ==========="
  echo "cSphere has 2 components: controller and agent."
  echo -e "\e[33mThe controller should be installed before the agent.\e[0m"

  if [ "$ROLE" != "controller" -a "$ROLE" != "agent" ]; then
    declare -l ROLE
    while true; do
      echo -ne "\e[32m"
      ROLE=$(get_str_param "Please input the role that you want to install")
      echo -ne "\e[0m"
      [ "$ROLE" = "controller" -o "$ROLE" = "agent" ] && break
    done
  fi

  if [ "$ROLE" = "controller" ]; then
    install_csphere_controller
  else
    install_csphere_agent
  fi
}

main
