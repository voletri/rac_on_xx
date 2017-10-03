#!/bin/bash

VIRT_TYPE="docker-machine"

cd ..
source ./commonutil.sh
#### VIRT_TYPE specific processing  (must define)###
#$1 nodename $2 ip $3 nodenumber $4 hostgroup#####
run(){
	
	NODENAME=$1
	INSTANCE_ID=$NODENAME
	IP=$2
	NODENUMBER=$3
	HOSTGROUP=$4
	eval $(docker-machine env $NODENAME)
	IsDeviceMapper=`docker info | grep devicemapper | grep -v grep | wc -l`

	StorageOps="-v $DOCKER_VOLUME_PATH/$NODENAME:/u01:rw"



	docker run $DOCKER_START_OPS $DOCKER_CAPS -d -h ${NODENAME}.${DOMAIN_NAME} --name $NODENAME --net=$BRNAME --ip=$2 $TMPFS_OPS -v /boot/:/boot:ro  $StorageOps $IMAGE /sbin/init

	#$NODENAME $IP $INSTANCE_ID $NODENUMBER $HOSTGROUP
	common_update_ansible_inventory $NODENAME $IP $INSTANCE_ID $NODENUMBER $HOSTGROUP

}

#### VIRT_TYPE specific processing  (must define)###
#$1 nodecount                                  #####
runonly(){
	if [ "$1" = "" ]; then
		nodecount=3
	else
		nodecount=$1
	fi
	
	cd vagrant-vbox
	bash vagrant-vboxutil.sh create_box $nodecount $VIRT_TYPE

	cd ../$VIRT_TYPE

	vagrant ssh storage -c "sudo yum -y install docker-engine && sudo usermod -aG docker ${ansible_ssh_user} && sudo rm -f /etc/systemd/system/docker.service.d/docker-sysconfig.conf"
	docker-machine create --driver generic --generic-ip-address=`get_External_IP storage` --generic-ssh-key  $ansible_ssh_private_key_file --generic-ssh-user $ansible_ssh_user storage
 
	for i in `seq 1 $nodecount`;
	do
		NODENAME="$NODEPREFIX"`printf "%.3d" $i`
		vagrant ssh $NODENAME -c "sudo yum -y install docker-engine && sudo usermod -aG docker ${ansible_ssh_user} && sudo rm -f /etc/systemd/system/docker.service.d/docker-sysconfig.conf"
		docker-machine create --driver generic --generic-ip-address=`get_External_IP $i` --generic-ssh-key  $ansible_ssh_private_key_file --generic-ssh-user $ansible_ssh_user $NODENAME
	done
	
	setup_host_vxlan

	STORAGEIP=`get_Internal_IP storage`
	run "storage" $STORAGEIP 0 "storage"
	
	common_update_all_yml "STORAGE_SERVER: $STORAGEIP"
	
	for i in `seq 1 $nodecount`;
	do
		NODEIP=`get_Internal_IP $i`
		NODENAME="$NODEPREFIX"`printf "%.3d" $i`
		run $NODENAME $NODEIP $i "dbserver"
	done
	
	
	run_init "storage" 0
	for i in `seq 1 $nodecount`;
	do
		NODENAME="$NODEPREFIX"`printf "%.3d" $i`
		run_init $NODENAME $i
	done
	
#	CLIENTNUM=70
#	NUM=`expr $BASE_IP + $CLIENTNUM`
#	CLIENTIP="${SEGMENT}$NUM"	
#	run "client01" $CLIENTIP $CLIENTNUM "client"
	
}

deleteall(){
   	common_deleteall $*
	hostlist=`docker-machine ls -q`
	for host in $hostlist;
	do
		docker-machine rm -y $host
	done 
  	
	vagrant destroy -f
	
	rm -rf /tmp/$CVUQDISK
}

buildimage(){
	docker build -t $IMAGE --no-cache=true ./images/OEL7
}
replaceinventory(){
	echo ""
}

get_External_IP(){
		if [ "$1" = "storage" ]; then
		NUM=`expr $BASE_IP`
	else
		NUM=`expr $BASE_IP + $1`
	fi
	SEGMENT=`echo $VBOXSUBNET | grep -Po '\d{1,3}\.\d{1,3}\.\d{1,3}\.'`
	External_IP="${SEGMENT}$NUM"

	echo $External_IP	
}

get_Internal_IP(){
	if [ "$1" = "storage" ]; then
		NUM=`expr $BASE_IP`
	else
		NUM=`expr $BASE_IP + $1`
	fi
	SEGMENT=`echo $DOCKERSUBNET | grep -Po '\d{1,3}\.\d{1,3}\.\d{1,3}\.'`
	Internal_IP="${SEGMENT}$NUM"

	echo $Internal_IP	
}


setup_host_vxlan(){
	hostlist="localhost `docker-machine ls -q`"
	
	cnt=0
	for src in $hostlist;
	do
		

	SEGMENT=`echo $DOCKERSUBNET | grep -Po '\d{1,3}\.\d{1,3}\.'`

		if [ "$src" = "localhost" ]; then
			sudo ip link add vxlan100 type vxlan id 100 ttl 4 dev $LOCALMACHINE_VXLAN_DEV
			sudo ip link set vxlan100 up
			sudo ip addr add ${SEGMENT}${cnt}.254/16 dev vxlan100
			bridgecmd="sudo $LOCALMACHINE_BRIDGE_CMD"
		else
			docker-machine ssh $src docker network create -d bridge --subnet=$DOCKERSUBNET --gateway="${SEGMENT}${cnt}.254" --opt "com.docker.network.bridge.name"=$BRNAME --opt "com.docker.network.driver.mtu"=$MTU $BRNAME
			docker-machine ssh $src sudo ip link add vxlan100 type vxlan id 100 ttl 4 dev $DOCKERMACHINE_VXLAN_DEV
			docker-machine ssh $src sudo ip link set dev vxlan100 master $BRNAME
			docker-machine ssh $src sudo ip link set vxlan100 up	
			bridgecmd="docker-machine ssh $src sudo $DOCKERMACHINE_BRIDGE_CMD"

		fi
		for dst in $hostlist;
		do
			if [ "$src" = "$dst" ]; then
				continue;
			fi
			if [ "$dst" = "localhost" ]; then
				dstip=`ip addr show $LOCALMACHINE_VXLAN_DEV | grep "inet " | awk -F '[/ ]' '{print $6}'`
			else
				dstip=`docker-machine ip $dst`
			fi
			$bridgecmd fdb append 00:00:00:00:00:00 dev vxlan100 dst $dstip
		done
	
		cnt=`expr $cnt + 1`
	
	done
}

run_init(){
	NODENAME=$1
	eval $(docker-machine env $NODENAME)

	docker exec ${NODENAME} useradd $ansible_ssh_user                                                                                                          
	docker exec ${NODENAME} bash -c "echo \"$ansible_ssh_user ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/$ansible_ssh_user"
	docker exec ${NODENAME} bash -c "mkdir /home/$ansible_ssh_user/.ssh"
	
	docker cp ${ansible_ssh_private_key_file} ${NODENAME}:/home/$ansible_ssh_user/.ssh/id_rsa
	
	docker exec ${NODENAME} bash -c "ssh-keygen -yf /home/$ansible_ssh_user/.ssh/id_rsa > /home/$ansible_ssh_user/.ssh/authorized_keys"
	
	docker exec ${NODENAME} bash -c "chown -R ${ansible_ssh_user} /home/$ansible_ssh_user/.ssh && chmod 700 /home/$ansible_ssh_user/.ssh && chmod 600 /home/$ansible_ssh_user/.ssh/*"
  
	docker exec ${NODENAME} systemctl start sshd
	docker exec ${NODENAME} systemctl enable sshd
}

install(){
#	common_execansible rac.yml --tags security,vxlan_conf,dnsmasq,setresolvconf
#	common_execansible rac.yml --skip-tags security,dnsmasq,vxlan_conf
	NODENAME="$NODEPREFIX"`printf "%.3d" 1`
	
	eval $(docker-machine env $NODENAME)
	docker exec -ti $NODENAME bash -c "cd /root/rac_on_xx/docker-machine && bash docker-machineutil.sh execansible rac.yml"
}

create_box()
{
	nodecount=$1
	VIRT_TYPE=$2
	source ./commonutil.sh
	cd $VIRT_TYPE
	vagrant plugin install vagrant-disksize
	STORAGEIP=`get_Internal_IP storage`
	cat > Vagrantfile <<EOF
Vagrant.configure(2) do |config|
	config.vm.box = "$VBOX_URL"
	config.ssh.insert_key = false
	config.vm.define "storage" do |node|
 		node.vm.hostname = "storage"
 		node.disksize.size = '100GB'
		node.vm.network "private_network", ip: "$STORAGEIP"
		node.vm.provider "virtualbox" do |vb|
			vb.memory = "$VBOX_MEMORY"
		end
	end

EOF

	
	for i in `seq 1 $nodecount`;
	do
		NODEIP=`get_Internal_IP $i`
		NODENAME="$NODEPREFIX"`printf "%.3d" $i`
	cat >> Vagrantfile <<EOF
	config.vm.define "$NODENAME" do |node|
 		node.vm.hostname = "$NODENAME"
		node.vm.network "private_network", ip: "$NODEIP"
		node.disksize.size = '100GB'
		node.vm.provider "virtualbox" do |vb|
			vb.memory = "$VBOX_MEMORY"
		end
	end
	
EOF
	done

cat >> Vagrantfile <<EOF
end
EOF
vagrant up
}

case "$1" in
  "install" ) shift;install $*;;
  "setup_host_vxlan" ) shift;setup_host_vxlan $*;;
  "create_box" ) shift;create_box $*;;
esac
source ./common_menu.sh


