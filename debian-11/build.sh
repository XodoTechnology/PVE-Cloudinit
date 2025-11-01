#!/bin/bash

# Create a Debian 11 (bullseye) based VM
IMAGE_URL=https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.raw
IMAGE_NAME=debian-11-generic-amd64.raw
IMAGE_PATH=/var/lib/vz/template/cache/$IMAGE_NAME
TEMPLATE_VM_ID=9402
TEMPLATE_NAME=debian-11-template
RAM=512
CORES=1
BRIDGE=vmbr0
DISKIMAGE_SIZE=10G
STORAGE=local
TAGS=_template,os_debian,v-11,11_2025
DNS=9.9.9.9
USER_NAME=root

#############################################################
echo "Destroy the old template..."
sudo qm stop $TEMPLATE_VM_ID
sudo qm destroy $TEMPLATE_VM_ID --destroy-unreferenced-disks 1 --purge 1

#############################################################
echo "Download the $TEMPLATE_NAME image ..."
if [ -e $IMAGE_PATH ]
then
    echo "The CloudInit image is already downloaded."
else
    wget -O $IMAGE_PATH  $IMAGE_URL
    du -sh $IMAGE_PATH
    qemu-img resize $IMAGE_PATH $DISKIMAGE_SIZE
    du -sh $IMAGE_PATH
fi


#############################################################
echo "Create the new machine ..."
sudo virt-customize --install qemu-guest-agent -a $IMAGE_PATH
sudo virt-customize -a $IMAGE_PATH --run-command "sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/g' /etc/ssh/sshd_config"
sudo virt-customize -a $IMAGE_PATH --run-command "sed -i 's/#PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config"
sudo virt-customize -a $IMAGE_PATH --run-command "sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config"
sudo virt-customize -a $IMAGE_PATH --run-command "sed -i 's/#Port 22/Port 22/g' /etc/ssh/sshd_config"
sudo virt-customize -a $IMAGE_PATH --run-command "sed -i 's/#AddressFamily any/AddressFamily any/g' /etc/ssh/sshd_config"
sudo virt-customize -a $IMAGE_PATH --run-command "sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/g' /etc/ssh/sshd_config"
sudo virt-customize -a $IMAGE_PATH --run-command "sed -i 's/#ListenAddress ::/ListenAddress ::/g' /etc/ssh/sshd_config"

sudo qm create $TEMPLATE_VM_ID --name $TEMPLATE_NAME --net0 virtio,bridge=$BRIDGE --memory $RAM
sudo qm set $TEMPLATE_VM_ID --machine q35
sudo qm set $TEMPLATE_VM_ID --numa 1
sudo qm set $TEMPLATE_VM_ID --bios ovmf
sudo qm set $TEMPLATE_VM_ID --efidisk0 $STORAGE:0,pre-enrolled-keys=0
sudo qm set $TEMPLATE_VM_ID --ostype l26
sudo qm set $TEMPLATE_VM_ID --cores $CORES --cpu cputype=host
sudo qm set $TEMPLATE_VM_ID --scsihw virtio-scsi-single 
sudo qm importdisk $TEMPLATE_VM_ID $IMAGE_PATH $STORAGE
sudo qm set $TEMPLATE_VM_ID --scsi0 $STORAGE:vm-$TEMPLATE_VM_ID-disk-1,aio=io_uring,cache=unsafe,discard=on,iothread=1,ssd=1
sudo qm set $TEMPLATE_VM_ID --boot c --bootdisk scsi0
sudo qm set $TEMPLATE_VM_ID --tablet 0
sudo qm set $TEMPLATE_VM_ID --serial0 socket --vga serial0
sudo qm set $TEMPLATE_VM_ID --agent enabled=1
sudo qm set $TEMPLATE_VM_ID --tags $TAGS
sudo qm set $TEMPLATE_VM_ID --ide2 $STORAGE:cloudinit
sudo qm set $TEMPLATE_VM_ID --ciuser $USER_NAME
sudo qm set $TEMPLATE_VM_ID --autostart
sudo qm set $TEMPLATE_VM_ID --onboot 1
sudo qm set $TEMPLATE_VM_ID --ipconfig0 ip=dhcp,ip6=auto
sudo qm set $TEMPLATE_VM_ID --nameserver $DNS

sudo qm template $TEMPLATE_VM_ID

#############################################################
echo "$TEMPLATE_NAME Template Completed ..."