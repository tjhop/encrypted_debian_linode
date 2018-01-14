#!/bin/bash
#
# Encrypted Debian Installer -- adapted from encrypted Arch installer
#
# Author: TJ
#
# Prereqs/Assumptions:
# - Must create 3 disk:
#   - /dev/sda = 256 MB, unformatted/raw, for boot disk
#   - /dev/sdb = 256 MB, unformatted/raw, for swap disk
#   - /dev/sdc = remaining storage, unformatted/raw, for system disk
#
# install from finnix with this command to capture all output for debugging purposes:
# ./debian_install.sh 2>&1 | tee -a debian.log
# then, scp 'debian.log' off of finnix before rebooting

# gather info
# ------------

echo "Pick a hostname" && read -rp '> ' HOSTNAME && echo

# get LUKS passphrase
PASS_MATCH='0'
while (( "$PASS_MATCH" == 0 )); do
  echo "Enter LUKS passphrase (this won't produce output)" && read -rsp '> ' LUKSPASSWD && echo
  echo "Confirm LUKS passphrase" && read -rsp '> ' LUKSPASSWD2 && echo

  if [[ "$LUKSPASSWD" == "$LUKSPASSWD2" ]]; then
    PASS_MATCH='1'
    unset LUKSPASSWD2
  else
    echo "LUKS passwords don't match. Try again."
    unset LUKSPASSWD
    unset LUKSPASSWD2
  fi
done

# get root password
PASS_MATCH='0'
while (( "$PASS_MATCH" == 0 )); do
  echo "Enter root password (this won't produce output)" && read -rsp '> ' ROOTPASSWD && echo
  echo "Confirm root password" && read -rsp '> ' ROOTPASSWD2 && echo

  if [[ "$ROOTPASSWD" == "$ROOTPASSWD2" ]]; then
    PASS_MATCH='1'
    unset ROOTPASSWD2
  else
    echo "Root passwords don't match. Try again."
    unset ROOTPASSWD
    unset ROOTPASSWD2
  fi
done

# get username
echo "Pick a username" && read -p '> ' USERNAME && echo

# get user password
PASS_MATCH='0'
while (( "$PASS_MATCH" == 0 )); do
  echo "Enter password for '$USERNAME' (this won't produce output)" && read -rsp '> ' USERPASSWD && echo
  echo "Confirm user password" && read -rsp '> ' USERPASSWD2 && echo

  if [[ "$USERPASSWD" == "$USERPASSWD2" ]]; then
    PASS_MATCH='1'
    unset USERPASSWD2
  else
    echo "User passwords don't match. Try again."
    unset USERPASSWD
    unset USERPASSWD2
  fi
done

# get SSH key
echo "Enter SSH key for '$USERNAME'" && read -rp '> ' SSHKEY && echo

# prompt for static IPs for config later
# NOTE: I guess theoretically, I could start this out as DHCP, curl -4/6
# against icanhazip.com, and then setup static networking fully internally
# that way, but that's just silly amounts of extra effort.
echo "Let's set up static networking, too"
echo 'Enter IPv4' && read -rp '> ' STATIC_IPV4 && echo
echo 'Enter IPv6' && read -rp '> ' STATIC_IPV6 && echo
IPV4_GATEWAY=$(echo "$STATIC_IPV4" | cut -d '.' -f '1-3' | sed 's/$/.1/')

# offer to set up ipv4 if one is assigned already
while true; do
  echo "Setup private IP address too? (y/n): " && read -rp '> ' INPUT && echo

  if [[ "$INPUT" =~ ^[Yy]$ ]]; then
    echo "Alright, gimme a private IP" && read -rp '> ' PRIVATE_IPV4 && echo
    PRIVATE_IPV4="Address=$PRIVATE_IPV4/17"
    break
  elif [[ "$INPUT" =~ ^[Nn]$ ]]; then
    PRIVATE_IPV4=''
    break
  else
    echo 'Need a yes/no answer here'
  fi
done

# do work
# -------
echo "~ Alright, starting to do stuff now. Come back in 5 mins."

# make sure finnix is updated and has the needed packages:
apt-get -o Acquire::ForceIPv4=true update
apt-get -o Acquire::ForceIPv4=true install -y wget binutils debootstrap haveged

# ensure that finnix has enough entropy for encrypted disk creation
service haveged stop
haveged -w 2048

# create and format disks same as normal for arch
echo "~ Making disks"
echo -n "$LUKSPASSWD" | cryptsetup -v --key-size 512 --hash sha512 --iter-time 5000 luksFormat /dev/sdc --key-file=-
echo -n "$LUKSPASSWD" | cryptsetup luksOpen /dev/sdc crypt-sdc --key-file=-
unset LUKSPASSWD
mkfs -t ext2 /dev/sda
mkfs.btrfs --label 'btrfs-root' /dev/mapper/crypt-sdc
cryptsetup -d /dev/urandom create crypt-swap /dev/sdb
mkswap /dev/mapper/crypt-swap
swapon /dev/mapper/crypt-swap

# mount disks and create btrfs subvolumes
mkdir -p /mnt/btrfs-root
mkdir -p /mnt/deb-root
mount -t btrfs /dev/mapper/crypt-sdc /mnt/btrfs-root
btrfs subvolume create /mnt/btrfs-root/root
btrfs subvolume create /mnt/btrfs-root/snapshots
umount /mnt/btrfs-root/
mount -o defaults,noatime,compress=lzo,subvol=root /dev/mapper/crypt-sdc /mnt/deb-root
mkdir -p /mnt/deb-root/boot
mount /dev/sda /mnt/deb-root/boot

# run the bootstrap
debootstrap --arch amd64 --include=openssh-server,btrfs-progs,cryptsetup,sudo stretch /mnt/deb-root http://mirrors.kernel.org/debian

# bind mount needed devices and tmpfses from finnix
for i in dev proc sys; do
  mount --rbind /$i /mnt/deb-root/$i
done

# chroot into the new system:
cat << SYSTEM_BUILD_EOF | chroot /mnt/deb-root/ /bin/bash
echo "~ Configuring system"

# set timezone
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
dpkg-reconfigure -f noninteractive tzdata

# make fstab
cat << fstab_EOF > /etc/fstab
#
# /etc/fstab: static file system information
#
# <file system>	<dir>	<type>	<options>	<dump>	<pass>
/dev/mapper/crypt-sdc	/         	btrfs     	rw,noatime,compress=lzo,space_cache,subvol=root	0 0

/dev/sda            	/boot     	ext2      	rw,relatime,errors=continue,user_xattr,acl	0 2

/dev/mapper/crypt-swap	none      	swap      	defaults  	0 0
fstab_EOF

mount -a

echo "~ Setting up networking"
# create network configs
# Note: Gonna use systemd-networkd here. Not just for consistency with the
# Arch build script, but newer Ubuntu builds are using it by default as well.
# Wouldn't be suprised if Debian switches to it soon.
cat > /etc/systemd/network/05-eth0.network << STATIC_IP_EOF
# static configuration for both IPv4/IPv6
#
[Match]
Name=eth0

[Network]
# IPv4
Gateway=$IPV4_GATEWAY
Address=$STATIC_IPV4/24
$PRIVATE_IPV4

# IPv6
Gateway=fe80::1
Address=$STATIC_IPV6/64

STATIC_IP_EOF
systemctl disable networking
systemctl enable systemd-networkd

cat << resolv_EOF > /etc/resolv.conf
# Google DNS
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 2001:4860:4860::8888
nameserver 2001:4860:4860::8844
resolv_EOF

# set hostname
echo "$HOSTNAME" > /etc/hostname

# populate hosts file
cat << hosts_EOF > /etc/hosts
127.0.0.1       localhost
127.0.1.1       $HOSTNAME

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
hosts_EOF

# extend apt sources.list a bit
echo "deb http://security.debian.org/ stretch/updates main" >> /etc/apt/sources.list
echo "deb-src http://security.debian.org/ stretch/updates main" >> /etc/apt/sources.list

# Build users
echo "~ Setting up users"
echo "root:$ROOTPASSWD" | chpasswd
unset ROOTPASSWD
useradd -m -g users -G sudo -s /bin/bash "$USERNAME"
echo "$USERNAME:$USERPASSWD" | chpasswd
unset USERPASSWD
# debian /etc/sudoers file defaults to allow users in sudo group, so nothing to change in sudoer

# basic SSH config/lockdown
echo "~ sshd config"
sed -i '/^#PasswordAuthentication/c\PasswordAuthentication no' /etc/ssh/sshd_config
sed -i '/^#PermitRoot/c\PermitRootLogin no' /etc/ssh/sshd_config
mkdir "/home/$USERNAME/.ssh"
echo "$SSHKEY" >> "/home/$USERNAME/.ssh/authorized_keys"
chmod -R 700 "/home/$USERNAME/.ssh"
chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
chown -R "$USERNAME:users" "/home/$USERNAME/.ssh"

# install kernel
echo "~ Building kernel"
apt-get -o Acquire::ForceIPv4=true install -y linux-image-amd64
echo 'crypt-sdc /dev/sdc none luks' >> /etc/crypttab
echo 'crypt-swap /dev/sdb /dev/urandom swap' >> /etc/crypttab
update-initramfs -u -k all

# install grub and configure for linode/lish
echo "~ Installing GRUB"
DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::ForceIPv4=true install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" grub-pc
sed -i '/^GRUB_TIMEOUT/c\GRUB_TIMEOUT=3' /etc/default/grub
##################################
# IMPORTANT: Make sure that 'net.ifnames=0' is passed as a kernel param to disable predictable network inteface names
# and keep 'eth0' as the interface
##################################
sed -i '/^GRUB_CMDLINE_LINUX=/c\GRUB_CMDLINE_LINUX=\"console=ttyS0,19200n8 cryptdevice=/dev/sdc:crypt-sdc net.ifnames=0\"' /etc/default/grub
sed -i '/^#GRUB_DISABLE_LINUX_UUID=true/c\GRUB_DISABLE_LINUX_UUID=true' /etc/default/grub
echo 'GRUB_SERIAL_COMMAND="serial --speed=19200 --unit=0 --word=8 --parity=no --stop=1"' >> /etc/default/grub
echo 'GRUB_TERMINAL=serial' >> /etc/default/grub
echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
grub-install --recheck /dev/sda
grub-mkconfig --output /boot/grub/grub.cfg
mkdir -p /boot/boot
cd /boot/boot
ln -s ../grub .
# ln -s /boot/grub /boot/boot

# install standard packages, some supplementary stuff, and cleanup
echo "~ Updating system and installing some default packages"
tasksel install standard

# Install salt from saltstack directly for more up-to-date packages
wget -O - https://repo.saltstack.com/apt/debian/9/amd64/latest/SALTSTACK-GPG-KEY.pub | sudo apt-key add -
echo 'deb http://repo.saltstack.com/apt/debian/9/amd64/latest stretch main' > /etc/apt/sources.list.d/saltstack.list
apt-get -o Acquire::ForceIPv4=true update
apt-get -o Acquire::ForceIPv4=true install -y -- $(cat << PKG_LIST_EOF | tr '\n' ' '
git
nmap
screen
dnsutils
tcpdump
clamav
ufw
salt-minion
PKG_LIST_EOF
) && apt clean

# enable ssh
systemctl enable ssh

exit
SYSTEM_BUILD_EOF

# exit chroot
echo "All done!"
