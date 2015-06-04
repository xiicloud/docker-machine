#!/bin/bash
# Init script of aliyun image

CSPHERE_IMAGE=csphere/csphere:0.11.2
DATA_DIR=/data/csphere

cleanup(){
  rm ${BASH_SOURCE[0]}
  sed -i '/csphere-init/d' /etc/rc.local
}
trap cleanup EXIT

route=$(ip r|grep '172.16.0.0/12')
[ -n "$route" ] && ip r del $route
sed -i '/net 172.16.0.0 netmask/d' /etc/network/interfaces

initctl start docker || true

# Wait for docker daemon
docker_ok=false
for i in $(seq 1 120); do
  if docker version; then
    docker_ok=true
    break
  fi
  sleep 1
done

$docker_ok || {
  logger -p local3.error "Failed to start Docker daemon"
  exit 1
}

[ -d $DATA_DIR ] && rm -r $DATA_DIR
mkdir -p $DATA_DIR

AUTH_KEY=$(head -c 1000 /dev/urandom|tr -dc '0-9a-zA-Z'|tail -c 80|tee $DATA_DIR/auth-key)

# Wait for network to be ready
network_ok=false
for i in $(seq 1 360); do
  if curl --connect-timeout 1 -Ss -o /dev/null http://mirrors.aliyun.com/ubuntu; then
    network_ok=true
    break
  fi
  sleep 1
done

$network_ok || {
  logger -p local3.error "Network not ready."
  exit 1
}

docker run -itd --restart=always -e ROLE=controller -e AUTH_KEY=$AUTH_KEY\
  --name=csphere-controller -p 1016:80 -v $DATA_DIR:/data:rw $CSPHERE_IMAGE

ip=$(ip a show eth0|grep -w inet|awk '{print $2}'|cut -d / -f 1)
# Wait for controller to start
controller_ok=false
for i in $(seq 1 120); do
  if curl --connect-timeout 1 -Ss -o /dev/null http://$ip:1016/; then
    controller_ok=true
    break
  fi
  sleep 1
done

$controller_ok || {
  logger -p local3.error "Couldn't start csphere-controller. "\
    "See docker logs or $DATA_DIR/logs/csphere.err"
  exit 1
}

docker run -itd --restart=always --name=csphere-agent -e ROLE=agent\
  -e CONTROLLER_ADDR=${ip}:1016 -e AUTH_KEY=$AUTH_KEY -v /data/csphere:/data:rw\
  -v /proc:/rootfs/proc:ro -v /sys:/rootfs/sys:ro -v /etc:/rootfs/etc:rw\
  -v /var/run/docker.sock:/var/run/docker.sock --net=host $CSPHERE_IMAGE
