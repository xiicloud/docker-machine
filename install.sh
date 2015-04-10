#!/bin/bash
set -e -o pipefail

DOCKER_CMD=
DOCKER_VERSION_OK=false
UPGRADE_DOCKER=false
UPGRADE_CSPHERE=false
HAS_DOCKER=true
DOCKER_REPO_URL=https://get.docker.com
DEFAULT_AUTH_KEY="your-secret-key"
DEFAULT_DATA_PATH="/data/csphere"
CSPHERE_IMAGE=${CSPHERE_IMAGE:-"csphere/csphere"}

command_exists() {
  command -v "$@" > /dev/null 2>&1
}

USER="$(id -un 2>/dev/null || true)"

SH_C='sh -c'
if [ "$USER" != 'root' ]; then
  if command_exists sudo; then
    SH_C='sudo -E sh -c'
  elif command_exists su; then
    SH_C='su -c'
  else
    echo >&2 'Error: this installer needs the ability to run commands as root.'
    echo >&2 'We are unable to find either "sudo" or "su" available to make this happen.'
    exit 1
  fi
fi

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

# should be called after 'get_docker_cmd'
check_docker_version() {
  local ask_upgrade=false
  local must_upgrade=false
  local ver=$($SH_C "$DOCKER_CMD version"|grep 'Server version'|cut -d ' ' -f 3|awk -F '.' '{print $1"."$2}')
  if num_cmp $ver "<" 1.3; then
    echo "Your Docker version is not supported."
    ask_upgrade=true
    must_upgrade=true
  elif num_cmp $ver "<" 1.5; then
    echo "Your Docker doesn't support container metrics."
    ask_upgrade=true
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

prepare_csphere() {
  if [ -z "$AUTH_KEY" ]; then
    echo
    echo -ne "\e[31m"
    echo "An auth token is required to secure the network communication between "
    echo "agents and controller."
    echo "If you're installing agent, you must ensure that the token here is the same"
    echo "as what you had provided when installing the controller."
    echo -ne "\e[0m"
    echo
    echo -ne "\e[32m"
    AUTH_KEY=$(get_str_param "Please input the auth token" "$DEFAULT_AUTH_KEY")
    echo -ne "\e[0m"
  fi
  if [ -z "$AUTH_KEY" ]; then
    AUTH_KEY="$DEFAULT_AUTH_KEY"
  fi

  DATA_DIR=/data/csphere
  if [ -z "$DATA_DIR" ]; then
    echo -ne "\e[32m"
    DATA_DIR=$(get_str_param "Please input the data path" "$DEFAULT_DATA_PATH")
    echo -ne "\e[0m"
  fi
  if [ -z "$DATA_DIR" ]; then
    DATA_DIR=$DEFAULT_DATA_PATH
  fi

  $SH_C "[ -d $DATA_DIR ] || mkdir -p $DATA_DIR"
  if command_exists chcon; then
    $SH_C "chcon -Rt svirt_sandbox_file_t $DATA_DIR >/dev/null 2>&1" || true
  fi
  $SH_C "docker pull $CSPHERE_IMAGE"
}

install_csphere_controller() {
  prepare_csphere
  $SH_C '/sbin/iptables -I INPUT -p tcp --dport 1016 -j ACCEPT'
  $SH_C 'docker stop -t 600 csphere-controller 2>/dev/null || true'
  $SH_C 'docker rm csphere-controller 2>/dev/null || true'
  $SH_C "docker run -d --restart=always --name=csphere-controller \
    -v $DATA_DIR:/data:rw \
    -p 1016:80 \
    -e ROLE=controller \
    -e AUTH_KEY=$AUTH_KEY \
    $CSPHERE_IMAGE"
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
  
  $SH_C 'docker rm -f csphere-agent 2>/dev/null || true'
  $SH_C "docker run -d --restart=always --name=csphere-agent -e ROLE=agent \
    -e CONTROLLER_ADDR=$CONTROLLER_IP:1016 \
    -e AUTH_KEY=$AUTH_KEY \
    -v $DATA_DIR:/data:rw \
    -v /proc:/rootfs/proc:ro \
    -v /sys:/sys:ro \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --net=host $CSPHERE_IMAGE"
}

centos6_binary_install() {
  # install  docker  binary  to  /usr/local/bin  directory ###
  [ -e /usr/local/bin/docker ]  &&  $SH_C 'mv -f /usr/local/bin/docker /usr/local/bin/docker.old'
  local pkg="${DOCKER_REPO_URL}/builds/Linux/x86_64/docker-latest.tgz"
  curl -SL "$pkg" | $SH_C 'tar -C / -zxvf -'

  # generate  /etc/default/docker  file #####
  echo "generating  /etc/default/docker file ......"
  cat  > /tmp/docker.default  <<'EOF'
# Docker Upstart and SysVinit configuration file

# Customize location of Docker binary (especially for development testing).
#DOCKER="/usr/local/bin/docker"

# Use DOCKER_OPTS to modify the daemon startup options.
#DOCKER_OPTS="--dns 8.8.8.8 --dns 8.8.4.4"

# If you need Docker to use an HTTP proxy, it can also be specified here.
#export http_proxy="http://127.0.0.1:3128/"

# This is also a handy place to tweak where Docker's temporary files go.
#export TMPDIR="/mnt/bigdrive/docker-tmp"
EOF
  [ -f /etc/default/docker ] || $SH_C 'mv /tmp/docker.default /etc/default/docker'

  ###generate  upstart job  /etc/init/docker.conf ###
  echo "generating  /etc/init/docker.conf  upstart job....."
  cat  > /tmp/docker.conf  <<'EOF'
description "Docker daemon"

start on runlevel [23]
stop on runlevel [!2345]
limit nofile 524288 1048576
limit nproc 524288 1048576

respawn

pre-start script
  if grep -v '^#' /etc/fstab | grep -q cgroup \
    || [ ! -e /proc/cgroups ] ; then
    exit 0
  fi
  [ ! -e /cgroup ] &&  mkdir /cgroup
  if ! mountpoint -q /cgroup; then
    mount -t tmpfs -o uid=0,gid=0,mode=0755 cgroup  /cgroup
  fi
  (
          set -x 
    cd /cgroup
    for sys in $(awk '!/^#/ { if ($4 == 1) print $1 }' /proc/cgroups); do
      mkdir -p $sys
      if ! mountpoint -q $sys; then
        if ! mount -n -t cgroup -o $sys cgroup $sys; then
          rmdir $sys || true
        fi
      fi
    done
  )
end script

script
  # modify these in /etc/default/$UPSTART_JOB (/etc/default/docker)
  DOCKER=/usr/local/bin/$UPSTART_JOB
  DOCKER_OPTS=
  if [ -f /etc/default/$UPSTART_JOB ]; then
    . /etc/default/$UPSTART_JOB
  fi
  exec "$DOCKER" -d $DOCKER_OPTS
end script

# Don't emit "started" event until docker.sock is ready.
# See https://github.com/docker/docker/issues/6647
post-start script
  DOCKER_OPTS=
  if [ -f /etc/default/$UPSTART_JOB ]; then
    . /etc/default/$UPSTART_JOB
  fi
  if ! printf "%s" "$DOCKER_OPTS" | grep -qE -e '-H|--host'; then
    while ! [ -e /var/run/docker.sock ]; do
      initctl status $UPSTART_JOB | grep -q "stop/" && exit 1
      echo "Waiting for /var/run/docker.sock"
      sleep 0.1
    done
    echo "/var/run/docker.sock is up"
  fi
end script
EOF
  $SH_C 'mv /tmp/docker.conf /etc/init/docker.conf'
  ####use latest binary ,start docker daemon ###
  if $SH_C 'status docker'|grep -q 'start' ;then
    $SH_C 'restart docker'
  else
    $SH_C 'start docker'
  fi
}

centos7_binary_install() {
  ###install  docker  binary  to  /usr/local/bin  directory ###
  [ -e /usr/local/bin/docker ]  &&  $SH_C 'mv -f /usr/local/bin/docker /usr/local/bin/docker.old'
  local pkg="${DOCKER_REPO_URL}/builds/Linux/x86_64/docker-latest.tgz"
  curl -SL "$pkg" | $SH_C 'tar -C / -zxvf -'

  echo "installing docker.service file to  /etc/systemd/system/"

  cat > /tmp/docker.service <<'EOF'
[Unit]
Description=Docker Application Container Engine
Documentation=http://docs.docker.com
After=network.target docker.socket
Requires=docker.socket

[Service]
ExecStart=/usr/local/bin/docker -d -H fd://
MountFlags=slave
LimitNOFILE=1048576
LimitNPROC=1048576
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF
  
  echo "installing  docker.socket to /etc/systemd/system/"
  cat > /tmp/docker.socket <<'EOF'
[Unit]
Description=Docker Socket for the API
PartOf=docker.service

[Socket]
ListenStream=/var/run/docker.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
EOF
  $SH_C '
    mv /tmp/docker.socket /etc/systemd/system/
    mv /tmp/docker.service /etc/systemd/system/
    systemctl  daemon-reload
    systemctl  restart docker
    systemctl  enable docker'
}

install_docker() {
  case "$(uname -m)" in
    *64)
      ;;
    *)
      echo >&2 'Error: you are not using a 64bit platform.'
      echo >&2 'Docker currently only supports 64bit platforms.'
      exit 1
      ;;
  esac

  curl=''
  if command_exists curl; then
    curl='curl -sSL'
  elif command_exists wget; then
    curl='wget -qO-'
  elif command_exists busybox && busybox --list-modules | grep -q wget; then
    curl='busybox wget -qO-'
  fi

  # perform some very rudimentary platform detection
  lsb_dist=''
  if command_exists lsb_release; then
    lsb_dist="$(lsb_release -si)"
  fi
  if [ -z "$lsb_dist" ] && [ -r /etc/lsb-release ]; then
    lsb_dist="$(. /etc/lsb-release && echo "$DISTRIB_ID")"
  fi
  if [ -z "$lsb_dist" ] && [ -r /etc/debian_version ]; then
    lsb_dist='debian'
  fi
  if [ -z "$lsb_dist" ] && [ -r /etc/fedora-release ]; then
    lsb_dist='fedora'
  fi
  if [ -z "$lsb_dist" ] && [ -r /etc/centos-release ]; then
    num=$(cat /etc/centos-release|\
      awk '{for(i=1;i<=NF;i++){if($i ~ /[0-9]/) print $i}}')  
    lsb_dist=centos-${num:0:3}
  fi
  if [ -z "$lsb_dist" ] && [ -r /etc/os-release ]; then
    lsb_dist="$(. /etc/os-release && echo "$ID")"
  fi

  lsb_dist="$(echo "$lsb_dist" | tr '[:upper:]' '[:lower:]')"

  case "$lsb_dist" in
    amzn|fedora)
      if [ "$lsb_dist" = 'amzn' ]; then
        (
          set -x
          $SH_C 'yum update -yq;yum -y -q install docker'
        )
      else
        (
          set -x
          $SH_C 'yum update -yq; yum -y -q install docker-io'
        )
      fi
      if command_exists docker && [ -e /var/run/docker.sock ]; then
        $SH_C 'docker version'
      fi
      $SH_C 'service docker start' || true
      $SH_C 'docker version'
      your_user=your-user
      [ "$USER" != 'root' ] && your_user="$USER"
      echo
      echo 'If you would like to use Docker as a non-root user, you should now consider'
      echo 'adding your user to the "docker" group with something like:'
      echo
      echo '  sudo usermod -aG docker' $your_user
      echo
      echo 'Remember that you will have to log out and back in for this to take effect!'
      echo
      ;;
    
    centos*)
      ver=${lsb_dist#centos-}
      if num_cmp $ver '>=' '6.5' && num_cmp $ver '<' '7.0'; then
        centos6_binary_install
      elif num_cmp $ver '>=' '7.0' ;then
        centos7_binary_install
      else
        echo "Your system is not supported by Docker." && exit 1
      fi
      if command_exists docker && [ -e /var/run/docker.sock ]; then
        $SH_C 'docker version'
      fi
      ;;

    ubuntu|debian|linuxmint)
      export DEBIAN_FRONTEND=noninteractive

      did_apt_get_update=
      [ -e /usr/local/bin/docker ]  &&  mv /usr/local/bin/docker /usr/local/bin/docker.old
      apt_get_update() {
        if [ -z "$did_apt_get_update" ]; then
          ( set -x; $SH_C 'apt-get update -yq' )
          did_apt_get_update=1
        fi
      }

      # aufs is preferred over devicemapper; try to ensure the driver is available.
      if ! grep -q aufs /proc/filesystems && ! $SH_C 'modprobe aufs'; then
        kern_extras="linux-image-extra-$(uname -r)"

        apt_get_update
        ( set -x; $SH_C 'apt-get install -y -q '"$kern_extras" ) || true

        if ! grep -q aufs /proc/filesystems && ! $SH_C 'modprobe aufs'; then
          echo >&2 'Warning: tried to install '"$kern_extras"' (for AUFS)'
          echo >&2 ' but we still have no AUFS.  Docker may not work. Proceeding anyways!'
          ( set -x; sleep 10 )
        fi
      fi

      # install apparmor utils if they're missing and apparmor is enabled in the kernel
      # otherwise Docker will fail to start
      if [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" = 'Y' ]; then
        if command -v apparmor_parser &> /dev/null; then
          echo 'apparmor is enabled in the kernel and apparmor utils were already installed'
        else
          echo 'apparmor is enabled in the kernel, but apparmor_parser missing'
          apt_get_update
          ( set -x; $SH_C 'apt-get install -y -q apparmor' )
        fi
      fi

      if [ ! -e /usr/lib/apt/methods/https ]; then
        apt_get_update
        ( set -x; $SH_C 'apt-get install -y -q apt-transport-https' )
      fi
      if [ -z "$curl" ]; then
        apt_get_update
        ( set -x; $SH_C 'apt-get install -y -q curl' )
        curl='curl -sSL'
      fi
      (
        set -x
        $SH_C "apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 36A1D7869245C8950F966E92D8576A8BA88D21E9"
        $SH_C "echo deb ${DOCKER_REPO_URL}/ubuntu docker main > /etc/apt/sources.list.d/docker.list"
        $SH_C 'apt-get update -yq; apt-get install -y -q lxc-docker'
      )
      if command_exists docker && [ -e /var/run/docker.sock ]; then
        $SH_C 'docker version'
      fi
      your_user=your-user
      [ "$USER" != 'root' ] && your_user="$USER"
      echo
      echo 'If you would like to use Docker as a non-root user, you should now consider'
      echo 'adding your user to the "docker" group with something like:'
      echo
      echo '  sudo usermod -aG docker' $your_user
      echo
      echo 'Remember that you will have to log out and back in for this to take effect!'
      echo
      ;;

    gentoo)
      (
        set -x
        $SH_C 'emerge app-emulation/docker'
      )
      ;;
    
    *)
      (
        echo 
        echo "  Either your platform is not easily detectable, is not supported by this"
        echo "  installer script, or does not yet have a package for Docker."
        echo "  Please visit the following URL for more detailed installation instructions:"
        echo
        echo "  https://docs.docker.com/en/latest/installation/"
        echo
        echo "  When docker is properly installed, you can check https://csphere.cn/docs/1-installation.html "
        echo "  for cSphere installation guides."
      )>&2
      exit 1
  esac
}

get_docker_cmd
if $HAS_DOCKER; then
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
fi

echo "============= install cSphere ==========="
echo "cSphere has 2 components: controller and agent."
echo -e "\e[33mThe controller should be installed before the agent.\e[0m"

declare -l ROLE
while true; do
  echo -ne "\e[32m"
  ROLE=$(get_str_param "Please input the role that you want to install")
  echo -ne "\e[0m"
  [ "$ROLE" = "controller" -o "$ROLE" = "agent" ] && break
done

if [ "$ROLE" = "controller" ]; then
  install_csphere_controller
else
  install_csphere_agent
fi
