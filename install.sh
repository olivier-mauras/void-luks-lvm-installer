#!/bin/bash
set -e

# Explicitely declare our LV array
declare -A LV

# Load config or defaults
if [ -e ./config ]; then
  . ./config
else
  PKG_LIST="base-system lvm2 cryptsetup grub"
  HOSTNAME="dom1.internal"
  KEYMAP="fr_CH"
  TIMEZONE="Europe/Zurich"
  LANG="en_US.UTF-8"
  DEVNAME="sda"
  VGNAME="vgpool"
  CRYPTSETUP_OPTS=""
  SWAP=0
  SWAPSIZE="16G"
  LV[root]="10G"
  LV[var]="5G"
  LV[home]="512M"
fi

# Detect if we're in UEFI or legacy mode
[ -d /sys/firmware/efi ] && UEFI=1
if [ $UEFI ]; then
  PKG_LIST="$PKG_LIST grub-x86_64-efi efibootmgr"
fi

# Install requirements
xbps-install -y -S -f cryptsetup parted lvm2

# Wipe /dev/${DEVNAME}
dd if=/dev/zero of=/dev/${DEVNAME} bs=1M count=100
if [ $UEFI ]; then
  parted /dev/${DEVNAME} mklabel gpt
  parted -a optimal /dev/${DEVNAME} mkpart primary 2048s 100M
  parted -a optimal /dev/${DEVNAME} mkpart primary 100M 1100M
  parted -a optimal /dev/${DEVNAME} mkpart primary 1100M 100%
else
  parted /dev/${DEVNAME} mklabel msdos
  parted -a optimal /dev/${DEVNAME} mkpart primary 2048s 1G
  parted -a optimal /dev/${DEVNAME} mkpart primary 1G 100%
fi
parted /dev/${DEVNAME} set 1 boot on

# Encrypt partitions
if [ $UEFI ]; then
  BOOTPART="2"
  DEVPART="3"
else
  BOOTPART="1"
  DEVPART="2"
fi

echo "[!] Encrypt boot partition"
cryptsetup ${CRYPTSETUP_OPTS} luksFormat -c aes-xts-plain64 -s 512 /dev/${DEVNAME}${BOOTPART}
echo "[!] Open boot partition"
cryptsetup luksOpen /dev/${DEVNAME}${BOOTPART} crypt-boot

echo "[!] Encrypt root partition"
cryptsetup ${CRYPTSETUP_OPTS} luksFormat -c aes-xts-plain64 -s 512 /dev/${DEVNAME}${DEVPART}
echo "[!] Open root partition"
cryptsetup luksOpen /dev/${DEVNAME}${DEVPART} crypt-pool

# Now create VG
pvcreate /dev/mapper/crypt-pool
vgcreate ${VGNAME} /dev/mapper/crypt-pool
for FS in ${!LV[@]}; do
  lvcreate -L ${LV[$FS]} -n ${FS/\//_} ${VGNAME}
done
if [ $SWAP -eq 1 ]; then
  lvcreate -L ${SWAPSIZE} -n swap ${VGNAME}
fi

# Format filesystems
if [ $UEFI ]; then
  mkfs.vfat /dev/${DEVNAME}1
fi
mkfs.ext4 -L boot /dev/mapper/crypt-boot
for FS in ${!LV[@]}; do
  mkfs.ext4 -L $FS /dev/mapper/${VGNAME}-${FS}
done
if [ $SWAP -eq 1 ]; then
  mkswap -L swap /dev/mapper/${VGNAME}-swap
fi


# Mount them
mount /dev/mapper/${VGNAME}-root /mnt
for dir in dev proc sys boot; do
  mkdir /mnt/${dir}
done

## Remove root and sort keys
unset LV[root]
for FS in $(for key in "${!LV[@]}"; do printf '%s\n' "$key"; done| sort); do
  mkdir -p /mnt/${FS}
  mount /dev/mapper/${VGNAME}-${FS/\//_} /mnt/${FS}
done

if [ $UEFI ]; then
  mount /dev/mapper/crypt-boot /mnt/boot
  mkdir /mnt/boot/efi
  mount /dev/${DEVNAME}1 /mnt/boot/efi
else
  mount /dev/mapper/crypt-boot /mnt/boot
fi

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
echo "LABEL=root  /       ext4    rw,relatime,data=ordered,discard    0 0" > /mnt/etc/fstab
echo "LABEL=boot  /boot   ext4    rw,relatime,data=ordered,discard    0 0" >> /mnt/etc/fstab
for FS in ${!LV[@]}; do
  echo "LABEL=${FS}  /${FS}	ext4    rw,relatime,data=ordered,discard    0 0" >> /mnt/etc/fstab
done
echo "tmpfs       /tmp    tmpfs   size=1G,noexec,nodev,nosuid     0 0" >> /mnt/etc/fstab

if [ $UEFI ]; then
  echo "/dev/${DEVNAME}1   /boot/efi   vfat    defaults    0 0" >> /mnt/etc/fstab
fi

if [ $SWAP -eq 1 ]; then
  echo "LABEL=swap  none       swap     defaults    0 0" >> /mnt/etc/fstab
fi

# Link /var/tmp > /tmp
rm -rf /mnt/var/tmp
ln -s /tmp /mnt/var/tmp

# Install grub
cat << EOF >> /mnt/etc/default/grub
GRUB_TERMINAL_INPUT="console"
GRUB_TERMINAL_OUTPUT="console"
GRUB_ENABLE_CRYPTODISK=y
EOF
sed -i 's/GRUB_BACKGROUND.*/#&/' /mnt/etc/default/grub
chroot /mnt grub-install /dev/${DEVNAME}

# Now tune the cryptsetup
KERNEL_VER=$(xbps-query -r /mnt -s linux4 | cut -f 2 -d ' ' | cut -f 1 -d -)

LUKS_BOOT_UUID="$(lsblk -o NAME,UUID | grep ${DEVNAME}${BOOTPART} | awk '{print $2}')"
LUKS_DATA_UUID="$(lsblk -o NAME,UUID | grep ${DEVNAME}${DEVPART} | awk '{print $2}')"
echo "GRUB_CMDLINE_LINUX=\"rd.vconsole.keymap=${KEYMAP} rd.lvm=1 rd.luks=1 rd.luks.allow-discards rd.luks.uuid=${LUKS_BOOT_UUID} rd.luks.uuid=${LUKS_DATA_UUID}\"" >> /mnt/etc/default/grub

chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
chroot /mnt xbps-reconfigure -f ${KERNEL_VER}

# Now add customization to installation
echo "[!] Running custom scripts"
if [ -d ./custom ]; then
  cp -r ./custom /mnt/tmp

  # If we detect any .sh let's run them in the chroot
  for SHFILE in /mnt/tmp/custom/*.sh; do
    chroot /mnt sh /tmp/custom/$(basename $SHFILE)
  done

  # Then cleanup chroot
  rm -rf /mnt/tmp/custom
fi
