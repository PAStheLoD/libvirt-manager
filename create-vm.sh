#!/bin/bash

set -e

cd $(dirname $(readlink -f $0))

VM_NAME=${VM_NAME:-}
DS=/var/lib/uvtool/libvirt/images/${VM_NAME}-ds.iso
DISK_SIZE=${DISK_SIZE:-20} # gigabytes
VM_RAM=${VM_RAM:-2048} # megabytes
ISO_PATH=/opt/iso/bionic-server-cloudimg-amd64.img
ISO_SOURCE=https://cloud-images.ubuntu.com/bionic/current/bionic-server-cloudimg-amd64.img
LVM_VG=storage-hdd
PUB_NET=no
INT_NET=yes

DNS_RESOLVER="1.1.1.1"
DEFAULT_GW="192.168.1.1"
VM_IP_PREFIX="192.168.1.11/24"

SSH_KEY="$(ssh-add -L | head -n1)"

#################### yo

[[ "$VM_NAME" = "" ]] && { echo "VM_NAME is empty :|"; exit 1 ; }


uvt-kvm --help &>/dev/null || { echo "uvtool seems to be missing. install uvtool and uvtool-libvirt"; exit 1; }

[[ ! -r "$ISO_PATH" ]] && {
   mkdir -p $(dirname "$ISO_PATH")
   wget -q "$ISO_SOURCE" -O "$ISO_PATH"
}
LV=$(lvdisplay /dev/$LVM_VG/$VM_NAME --units g 2>/dev/null)

[[ "$LV" = "" ]] && {
    lvcreate -L${DISK_SIZE}G -n $VM_NAME $LVM_VG
}

current_size=$(echo "$LV" | grep -i size | awk '{ print $(NF-1) }')
[[ "bad" = $(python -c 'from __future__ import print_function ; import sys; print("ok") if float(sys.argv[1]) == float(sys.argv[2]) else print("bad")' $current_size $DISK_SIZE) ]] && {
  echo "ERROR: the requested VM disk size ($DISK_SIZE) is not equal to the size of the existing logical volume ($current_size)"
  exit 1
}

uvt-kvm create --no-start --log-console-output --backing-image-file "$ISO_PATH" --disk $DISK_SIZE --memory $VM_RAM --cpu 2 ${VM_NAME}

[[ $(virsh domiflist ${VM_NAME} | grep -c network) = 1 ]] || { echo "ERROR: no NIC created by uvtool? huh." ; exit 1 ; }

virsh detach-interface --domain ${VM_NAME} --type network --config

cp network-config.template network-config
cp user-data.template user-data
echo 'dsmode: local

' > meta-data


[[ "$PUB_NET" = yes ]] && {
    virsh attach-interface --domain ${VM_NAME} --type network --source PUB --model virtio --config
    MAC_pub=$(virsh domiflist --domain ${VM_NAME} | grep PUB | awk '{ print $5 }')
    sed -i -r -e "s/__MAC_ADDRESS_pub__/$MAC_pub/g" -e "s/__MAC_ADDRESS_int__/$MAC_int/g" ./network-config
}

[[ "$INT_NET" = yes ]] && {
    virsh attach-interface --domain ${VM_NAME} --type network --source INT --model virtio --config
    MAC_int=$(virsh domiflist --domain ${VM_NAME} | grep INT | awk '{ print $5 }')
    sed -i -r -e "s/__MAC_ADDRESS_int__/$MAC_int/g" ./network-config
}



sed -i -r -e "s,__VM_IP_prefix_,$VM_IP_PREFIX,g" ./network-config
sed -i -r -e "s/__default_GW__/$DEFAULT_GW/g" ./network-config
sed -i -r -e "s/__your_DNS_recursive_resolver__/$DNS_RESOLVER/g" ./network-config

sed -i -r -e "s/__VM_NAME__/$VM_NAME/g" ./user-data
sed -i -r -e "s|__your_ssh_key_too__|- $SSH_KEY|g" ./user-data

genisoimage -input-charset utf-8 -output ./data-source.iso -volid cidata -joliet -rock user-data meta-data network-config

cp ./data-source.iso "$DS"

virsh detach-disk --domain ${VM_NAME} --target vdb --config
virsh vol-delete --pool uvtool ${VM_NAME}-ds.qcow

virsh attach-disk --domain ${VM_NAME} --target vdb --source "$DS" --config

virsh vol-create-as --pool $LVM_VG --name ${VM_NAME} --capacity ${DISK_SIZE}g --format raw --print-xml > lvm-vol.definition.xml
virsh vol-create-from --pool $LVM_VG --file lvm-vol.definition.xml --vol ${VM_NAME}.qcow  --inputpool uvtool

virsh vol-dumpxml --pool $LVM_VG ${VM_NAME}
LVM_VOL_PATH=$(virsh vol-list --pool $LVM_VG | grep -P "\b${VM_NAME}\b" | awk '{print $2}')

virsh detach-disk --domain ${VM_NAME} --target vda --config
virsh vol-delete --pool uvtool ${VM_NAME}.qcow

virsh attach-disk --domain ${VM_NAME} --target vda --source $LVM_VOL_PATH --config

virsh start ${VM_NAME}

rm lvm-vol.definition.xml
rm network-config
rm meta-data
rm user-data

