#!/bin/bash
set -e

PKG_LIST="base-system lvm2 cryptsetup grub-x86_64-efi efibootmgr vim"
HOSTNAME="dom1.internal"
KEYMAP="fr_CH"
TIMEZONE="Europe/Zurich"
LANG="en_US.UTF-8"
CRYPTDEVNAME="crypt-pool"
VGNAME="vgpool"


# Install requirements
xbps-install -y -S -f cryptsetup parted lvm2

# Wipe /dev/sda
dd if=/dev/zero of=/dev/sda bs=1M count=100
parted /dev/sda mklabel gpt
parted -a optimal /dev/sda mkpart primary 2048s 100M
parted -a optimal /dev/sda mkpart primary 100M 1100M
parted -a optimal /dev/sda mkpart primary 1100M 100%
parted /dev/sda set 1 boot on

# Encrypt /dev/sda3 partition
cryptsetup luksFormat -c aes-xts-plain64 -s 512 /dev/sda3
cryptsetup luksOpen /dev/sda3 ${CRYPTDEVNAME}

# Now create VG
pvcreate /dev/mapper/${CRYPTDEVNAME}
vgcreate ${VGNAME} /dev/mapper/${CRYPTDEVNAME}
lvcreate -L 10G -n root ${VGNAME}
lvcreate -L 5G -n var ${VGNAME}
lvcreate -L 512M -n home ${VGNAME}

# Format filesystems
mkfs.vfat /dev/sda1
mkfs.ext4 -L boot /dev/sda2
mkfs.ext4 -L root /dev/mapper/${VGNAME}-root
mkfs.ext4 -L var /dev/mapper/${VGNAME}-var
mkfs.ext4 -L home /dev/mapper/${VGNAME}-home

# Mount them
mount /dev/mapper/${VGNAME}-root /mnt
for dir in dev proc sys boot home var; do
  mkdir /mnt/${dir}
done

mount /dev/mapper/${VGNAME}-home /mnt/home
mount /dev/mapper/${VGNAME}-var /mnt/var

mount /dev/sda2 /mnt/boot
mkdir /mnt/boot/efi

mount /dev/sda1 /mnt/boot/efi

for fs in dev proc sys; do
  mount -o bind /${fs} /mnt/${fs}
done

# Now install void
xbps-install -y -S -R http://repo.voidlinux.eu/current -r /mnt $PKG_LIST

# Do a bit of customization
echo "[!] Setting root password"
passwd -R /mnt root
echo $HOSTNAME > /mnt/etc/hostname
echo "TIMEZONE=${TIMEZONE}" >> /mnt/etc/rc.conf
echo "KEYMAP=${KEYMAP}" >> /mnt/etc/rc.conf
echo "TTYS=2" >> /mnt/etc/rc.conf

echo "LANG=$LANG" > /mnt/etc/locale.conf
echo "$LANG $(echo ${LANG} | cut -f 2 -d .)" >> /mnt/etc/default/libc-locales
chroot /mnt xbps-reconfigure -f glibc-locales

# Add fstab entries
cat << EOF >> /mnt/etc/fstab
LABEL=root  /       ext4    rw,relatime,data=ordered,discard    0 0
LABEL=boot  /boot	ext4    rw,relatime,data=ordered,discard    0 0
LABEL=var   /var	ext4    rw,relatime,data=ordered,discard    0 0
LABEL=home  /home	ext4    rw,relatime,data=ordered,discard    0 0
/dev/sda1   /boot/efi   vfat    defaults    0 0
tmpfs       /tmp    tmpfs   size=1G,noexec,nodev,nosuid     0 0
EOF

# Link /var/tmp > /tmp
rm -rf /mnt/var/tmp
ln -s /tmp /mnt/var/tmp

# Install grub
chroot /mnt grub-install /dev/sda

# Now tune the cryptsetup
KERNEL_VER=$(xbps-query -r /mnt -s linux4 | cut -f 2 -d ' ' | cut -f 1 -d -)

echo -e "${CRYPTDEVNAME}\t/dev/sda3\tnone\tluks" > /mnt/etc/crypttab
mkdir -p /mnt/etc/dracut.conf.d/
echo 'install_items+="/etc/crypttab"' > /mnt/etc/dracut.conf.d/00-crypttab.conf
echo 'hostonly=yes' > /mnt/etc/dracut.conf.d/00-hostonly.conf

echo 'GRUB_CRYPTODISK_ENABLE=y' >> /mnt/etc/default/grub
echo "GRUB_CMDLINE_LINUX=\"rd.auto=1 rd.vconsole.keymap=${KEYMAP} cryptsetup=/dev/sda3:${CRYPTDEVNAME}\"" >> /mnt/etc/default/grub

chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
chroot /mnt xbps-reconfigure -f ${KERNEL_VER}

