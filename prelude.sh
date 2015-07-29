#!/bin/sh
# A tool for installing Docker and the cSphere product.
# The Docker installation part is borrowied from http://get.docker.com/
#
# Supported environment variables:
#   AUTH_KEY
#   ROLE
#   CONTROLLER_IP
#   DATA_DIR

set -e
trap 'echo -ne "\e[0m"' EXIT

export PATH=$PATH:/usr/local/bin
# Determine the shell. See http://unix.stackexchange.com/a/37844
if ps h -p $$ -o args=''|cut -f1 -d' '|grep -q bash; then
  set -o pipefail
elif [ -x /bin/bash ]; then
  exec /bin/bash $0
fi

DOCKER_CMD=
DOCKER_VERSION_OK=false
UPGRADE_DOCKER=false
UPGRADE_CSPHERE=false
HAS_DOCKER=true
DOCKER_REPO_URL=https://get.docker.com
DEFAULT_DATA_DIR="/data/csphere"
CONTROLLER_PORT=${CONTROLLER_PORT:-1016}
CSPHERE_VERSION=${CSPHERE_VERSION:-0.12.3}
CSPHERE_IMAGE=${CSPHERE_IMAGE:-"http://csphere-image.stor.sinaapp.com/csphere-${CSPHERE_VERSION}.tar.gz"}
