#!/bin/sh
set -e
#
# This script is meant for quick & easy install via:
#   'curl -sSL https://get.docker.com/ | sh'
# or:
#   'wget -qO- https://get.docker.com/ | sh'
#
#
# Docker Maintainers:
#   To update this script on https://get.docker.com,
#   use hack/release.sh during a normal release,
#   or the following one-liner for script hotfixes:
#     s3cmd put --acl-public -P hack/install.sh s3://get.docker.com/index
#

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
disable_selinux(){
	cur_status=$(getenforce)
	if [ "$cur_status" = "Disabled" ];then
		return 
	fi
	while true ; do
		echo "enalbed selinux feature may reflect with docker."
		read -p "Do you want to disable selinux?[(y/yes)/(n/no)]:" ans
		ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
		case "$ans"  in 
			y|yes)
			setenforce 0 || true
			sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' \
			/etc/selinux/config
			break
			;;
			n|no)
			exit 1
			;;
			*)
			;; 
		esac
	done
}
centos6_binary_install(){
###install  docker  binary  to  /usr/local/bin  directory ###
[ -e /usr/local/bin/docker ]  &&  mv -f /usr/local/bin/docker /usr/local/bin/docker.old
pkg="https://get.docker.com/builds/Linux/x86_64/docker-latest.tgz"
curl -SL "$pkg" | tar -C / -zxvf -

####generate  /etc/default/docker  file #####
echo "generating  /etc/default/docker file ......"
cat  > /etc/default/docker  <<'EOF'
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

###generate  upstart job  /etc/init/docker.conf ###
echo "generating  /etc/init/docker.conf  upstart job....."
cat  > /etc/init/docker.conf  <<'EOF'
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
####use latest binary ,start docker daemon ###
if status docker|grep -q 'start' ;then
	restart docker
else
	start  docker  
fi
}

centos7_binary_install(){
###install  docker  binary  to  /usr/local/bin  directory ###
[ -e /usr/local/bin/docker ]  &&  mv -f /usr/local/bin/docker /usr/local/bin/docker.old
pkg="https://get.docker.com/builds/Linux/x86_64/docker-latest.tgz"
curl -SL "$pkg" | tar -C / -zxvf -

echo "installing docker.service file to  /etc/systemd/system/"

cat  >  /etc/systemd/system/docker.service  <<'EOF'
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

cat > /etc/systemd/system/docker.socket <<'EOF'
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

systemctl  daemon-reload
systemctl  start  docker
systemctl  enable docker
}

centos6_install(){
	local epelpkg="http://download.fedoraproject.org/pub/epel/6/x86_64/epel-release-6-8.noarch.rpm"
	if  ! rpm -q epel-release ;then
		rpm -Uvh $epelpkg 
	fi
	rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-6 
	yum makecache 
	yum -y upgrade device-mapper-libs 
	yum -y install docker-io 
	service docker start 
	chkconfig docker on
}
centos7_install(){
	yum -y install docker 
	service docker start 
	chkconfig docker on  
}
    
url='https://get.docker.com/'

command_exists() {
	command -v "$@" > /dev/null 2>&1
}

case "$(uname -m)" in
	*64)
		;;
	*)
		echo >&2 'Error: you are not using a 64bit platform.'
		echo >&2 'Docker currently only supports 64bit platforms.'
		exit 1
		;;
esac

if command_exists docker || command_exists lxc-docker; then
	echo >&2 'Warning: "docker" or "lxc-docker" command appears to already exist.'
	echo >&2 'Please ensure that you do not already have docker installed.'
	echo >&2 'You may press Ctrl+C now to abort this process and rectify this situation.'
	( set -x; sleep 20 )
fi

user="$(id -un 2>/dev/null || true)"

sh_c='sh -c'
if [ "$user" != 'root' ]; then
	if command_exists sudo; then
		sh_c='sudo -E sh -c'
	elif command_exists su; then
		sh_c='su -c'
	else
		echo >&2 'Error: this installer needs the ability to run commands as root.'
		echo >&2 'We are unable to find either "sudo" or "su" available to make this happen.'
		exit 1
	fi
fi

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
#echo "lsb =$lsb_dist"

case "$lsb_dist" in
	amzn|fedora)
		if [ "$lsb_dist" = 'amzn' ]; then
			(
				set -x
				$sh_c 'sleep 3; yum -y -q install docker'
			)
		else
			(
				set -x
				$sh_c 'sleep 3; yum -y -q install docker-io'
			)
		fi
		if command_exists docker && [ -e /var/run/docker.sock ]; then
			(
				set -x
				$sh_c 'docker version'
			) || true
		fi
		your_user=your-user
		[ "$user" != 'root' ] && your_user="$user"
		echo
		echo 'If you would like to use Docker as a non-root user, you should now consider'
		echo 'adding your user to the "docker" group with something like:'
		echo
		echo '  sudo usermod -aG docker' $your_user
		echo
		echo 'Remember that you will have to log out and back in for this to take effect!'
		echo
		exit 0
		;;
	
	centos*)
		ver=${lsb_dist#centos-}
		if num_cmp $ver '>=' '6.5' && num_cmp $ver '<' '7.0' ;then
			disable_selinux
			( centos6_binary_install )
			elif num_cmp $ver '>=' '7.0' ;then
			disable_selinux
			( centos7_binary_install )
		else
			echo "your centos version is lower 6.5" && exit 1
		fi
		if command_exists docker && [ -e /var/run/docker.sock ]; then
			(
				set -x
				$sh_c 'docker version'
			) || true
		fi
		exit 0
		;;

	ubuntu|debian|linuxmint)
		export DEBIAN_FRONTEND=noninteractive

		did_apt_get_update=
[ -e /usr/local/bin/docker ]  &&  mv /usr/local/bin/docker /usr/local/bin/docker.old
		apt_get_update() {
			if [ -z "$did_apt_get_update" ]; then
				( set -x; $sh_c 'sleep 3; apt-get update' )
				did_apt_get_update=1
			fi
		}

		# aufs is preferred over devicemapper; try to ensure the driver is available.
		if ! grep -q aufs /proc/filesystems && ! $sh_c 'modprobe aufs'; then
			kern_extras="linux-image-extra-$(uname -r)"

			apt_get_update
			( set -x; $sh_c 'sleep 3; apt-get install -y -q '"$kern_extras" ) || true

			if ! grep -q aufs /proc/filesystems && ! $sh_c 'modprobe aufs'; then
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
				( set -x; $sh_c 'sleep 3; apt-get install -y -q apparmor' )
			fi
		fi

		if [ ! -e /usr/lib/apt/methods/https ]; then
			apt_get_update
			( set -x; $sh_c 'sleep 3; apt-get install -y -q apt-transport-https' )
		fi
		if [ -z "$curl" ]; then
			apt_get_update
			( set -x; $sh_c 'sleep 3; apt-get install -y -q curl' )
			curl='curl -sSL'
		fi
		(
			set -x
			if [ "https://get.docker.com/" = "$url" ]; then
				$sh_c "apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 36A1D7869245C8950F966E92D8576A8BA88D21E9"
			elif [ "https://test.docker.com/" = "$url" ]; then
				$sh_c "apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 740B314AE3941731B942C66ADF4FD13717AAD7D6"
			else
				$sh_c "$curl ${url}gpg | apt-key add -"
			fi
			$sh_c "echo deb ${url}ubuntu docker main > /etc/apt/sources.list.d/docker.list"
			$sh_c 'sleep 3; apt-get update; apt-get install -y -q lxc-docker'
		)
		if command_exists docker && [ -e /var/run/docker.sock ]; then
			(
				set -x
				$sh_c 'docker version'
			) || true
		fi
		your_user=your-user
		[ "$user" != 'root' ] && your_user="$user"
		echo
		echo 'If you would like to use Docker as a non-root user, you should now consider'
		echo 'adding your user to the "docker" group with something like:'
		echo
		echo '  sudo usermod -aG docker' $your_user
		echo
		echo 'Remember that you will have to log out and back in for this to take effect!'
		echo
		exit 0
		;;

	gentoo)
		if [ "$url" = "https://test.docker.com/" ]; then
			echo >&2
			echo >&2 '  You appear to be trying to install the latest nightly build in Gentoo.'
			echo >&2 '  The portage tree should contain the latest stable release of Docker, but'
			echo >&2 '  if you want something more recent, you can always use the live ebuild'
			echo >&2 '  provided in the "docker" overlay available via layman.  For more'
			echo >&2 '  instructions, please see the following URL:'
			echo >&2 '    https://github.com/tianon/docker-overlay#using-this-overlay'
			echo >&2 '  After adding the "docker" overlay, you should be able to:'
			echo >&2 '    emerge -av =app-emulation/docker-9999'
			echo >&2
			exit 1
		fi

		(
			set -x
			$sh_c 'sleep 3; emerge app-emulation/docker'
		)
		exit 0
		;;
esac

cat >&2 <<'EOF'

  Either your platform is not easily detectable, is not supported by this
  installer script (yet - PRs welcome! [hack/install.sh]), or does not yet have
  a package for Docker.  Please visit the following URL for more detailed
  installation instructions:

    https://docs.docker.com/en/latest/installation/

EOF
exit 1
