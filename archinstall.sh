#!/bin/bash
# arch-auto-install-interactive.sh
# Interactive installation Arch Linux: Btrfs + EFISTUB + bspwm + PipeWire
# No passwords in the code, with confirmation before formatting

set -euo pipefail

# ============== Colors for output ==============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function print_info { echo -e "${GREEN}[INFO] $1${NC}"; }
function print_warn { echo -e "${YELLOW}[WARN] $1${NC}"; }
function print_error { echo -e "${RED}[ERROR] $1${NC}"; }

# ============== Interactive input ==============
print_info "Welcome to the installer Arch Linux (Btrfs + EFISTUB + bspwm)"

read -p "🔹 Username: " USERNAME
while [[ -z "$USERNAME" ]]; do
    print_error "Username cannot be empty."
    read -p "🔹 Username: " USERNAME
done

read -sp "🔹 Password for user $USERNAME: " USER_PASS
echo
while [[ -z "$USER_PASS" ]]; do
    print_error "Password cannot be empty."
    read -sp "🔹 Password for user $USERNAME: " USER_PASS
    echo
done

read -sp "🔹 Password for root: " ROOT_PASS
echo
while [[ -z "$ROOT_PASS" ]]; do
    print_error "The root password cannot be empty."
    read -sp "🔹 Password for root: " ROOT_PASS
    echo
done

read -p "🔹 Host name (For example, archbox): " HOSTNAME
HOSTNAME=${HOSTNAME:-"archbox"}

echo "🔹 Available disks:"
lsblk -d -e7 -o NAME,SIZE,MODEL
read -p "Enter the installation disk (For example, sda): " DISK_DEVICE
DISK="/dev/$DISK_DEVICE"

if [[ ! -b "$DISK" ]]; then
    print_error "Device $DISK does not exist."
    exit 1
fi

print_warn "ATTENTION: the entire disk $DISK will be FORMATTED!"
read -p "Continue? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    print_info "Installation cancelled."
    exit 0
fi

read -p "EFI partition size (by default 512M): " EFI_SIZE
EFI_SIZE=${EFI_SIZE:-"512M"}

SWAP_ENABLE=""
read -p "Create swap partition? (y/N): " SWAP_ENABLE_INPUT
if [[ "$SWAP_ENABLE_INPUT" =~ ^[Yy]$ ]]; then
    read -p "Swap size (For example, 4G, by default 4G): " SWAP_SIZE
    SWAP_SIZE=${SWAP_SIZE:-"4G"}
    SWAP_ENABLE="yes"
fi

read -p "Time zone (For example, Europe/Moscow): " TIMEZONE
TIMEZONE=${TIMEZONE:-"Europe/Moscow"}

read -p "Locale (For example, en_US.UTF-8): " LOCALE
LOCALE=${LOCALE:-"en_US.UTF-8"}

read -p "Keyboard Layout (us, ru etc.): " KEYMAP
KEYMAP=${KEYMAP:-"us"}

read -p "Console font (by default latarcyrheb-sun16): " FONT
FONT=${FONT:-"latarcyrheb-sun16"}

read -p "Btrfs compression (zstd/lzo/zlib, by default zstd): " COMPRESS
COMPRESS=${COMPRESS:-"zstd"}

CPU_VENDOR="intel"
read -p "CPU  (intel/amd, by default intel): " CPU_INPUT
CPU_VENDOR=${CPU_INPUT:-"intel"}
if [[ ! "$CPU_VENDOR" =~ ^(intel|amd)$ ]]; then
    print_error "Wrong choice: $CPU_VENDOR. We use intel."
    CPU_VENDOR="intel"
fi

print_info "Checking UEFI..."
if [ ! -d /sys/firmware/efi/efivars ]; then
    print_error "The system is not in mode UEFI!"
    exit 1
fi

print_info "Checking the Internet..."
if ! ping -c 1 archlinux.org &> /dev/null; then
    print_error "No internet. Check your connection.."
    exit 1
fi

print_info "All parameters accepted. Let's start the installation..."

# ============== 1. Disk Partitioning ==============
print_info "Marking up $DISK..."
sgdisk --zap-all "$DISK" || { print_error "Error while cleaning disk."; exit 1; }

END_SECTOR=2047

# EFI
sgdisk -n 1:$END_SECTOR:+$EFI_SIZE -t 1:EF00 -c 1:"EFI System" "$DISK"
END_SECTOR=$(sgdisk -F "$DISK")

# Swap (if enabled)
SWAP_PART=""
if [[ "$SWAP_ENABLE" == "yes" ]]; then
    sgdisk -n 2:$END_SECTOR:+$SWAP_SIZE -t 2:8200 -c 2:"Linux swap" "$DISK"
    END_SECTOR=$(sgdisk -F "$DISK")
    SWAP_PART="${DISK}2"
    ROOT_PART="${DISK}3"
else
    ROOT_PART="${DISK}2"
fi

# Root
sgdisk -n ${SWAP_ENABLE:+3} -t ${SWAP_ENABLE:+3}:8300 -c ${SWAP_ENABLE:+3}:"Linux root" "$DISK"

sleep 2

# ============== 2. Formatting ==============
print_info "Format partitions..."
mkfs.fat -F32 "${DISK}1" || { print_error "Formatting error EFI."; exit 1; }
mkfs.btrfs -f "$ROOT_PART" || { print_error "Formatting error Btrfs."; exit 1; }

if [[ -n "$SWAP_PART" ]]; then
    mkswap "$SWAP_PART"
    # Don't turn it on yet - it will be в fstab
fi

# ============== 3. Btrfs subvolumes ==============
print_info "We create Btrfs subvolumes..."
mount "$ROOT_PART" /mnt
for subvol in @ @home @var @tmp @snapshots; do
    btrfs subvolume create "/mnt/$subvol"
done
umount /mnt

MOUNT_OPTS="noatime,compress=$COMPRESS,space_cache=v2"

mount -o $MOUNT_OPTS,subvol=@ "$ROOT_PART" /mnt
mkdir -p /mnt/{home,var,tmp,.snapshots,boot}
mount -o $MOUNT_OPTS,subvol=@home "$ROOT_PART" /mnt/home
mount -o $MOUNT_OPTS,subvol=@var "$ROOT_PART" /mnt/var
mount -o $MOUNT_OPTS,subvol=@tmp "$ROOT_PART" /mnt/tmp
mount -o $MOUNT_OPTS,subvol=@snapshots "$ROOT_PART" /mnt/.snapshots
mount "${DISK}1" /mnt/boot

if [[ -n "$SWAP_PART" ]]; then
    swapon "$SWAP_PART"
fi

# ============== 4. Installing packages ==============
print_info "Installing basic packages..."
pacstrap /mnt base base-devel linux linux-firmware btrfs-progs efibootmgr
if [[ "$CPU_VENDOR" == "intel" ]]; then
    pacstrap /mnt intel-ucode
elif [[ "$CPU_VENDOR" == "amd" ]]; then
    pacstrap /mnt amd-ucode
fi

# ============== 5. fstab ==============
print_info "We generate fstab..."
genfstab -U /mnt >> /mnt/mnt/fstab

# If there is swap, add it to fstab
if [[ -n "$SWAP_PART" ]]; then
    UUID_SWAP=$(blkid -s UUID -o value "$SWAP_PART")
    echo "UUID=$UUID_SWAP none swap sw 0 0" >> /mnt/mnt/fstab
fi

# ============== 6. chroot + setting ==============
print_info "Enter chroot and configure the system..."

arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

echo "🔸 Setting up locale and time..."
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

echo "$LOCALE UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
echo "FONT=$FONT" >> /etc/vconsole.conf

echo "$HOSTNAME" > /etc/hostname

cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

echo "🔸 User setup..."
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$USER_PASS" | chpasswd
sed -i 's/# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

echo "🔸 Installation X11, bspwm, PipeWire..."
pacman -Sy --noconfirm xorg-server xorg-xinit xorg-xrandr xorg-xsetroot xorg-xbacklight
pacman -Sy --noconfirm bspwm sxhkd picom alacritty nitrogen dmenu firefox neovim git

# Configs bspwm
su - $USERNAME -c '
mkdir -p ~/.config/{bspwm,sxhkd}
cp /usr/share/doc/bspwm/examples/bspwmrc ~/.config/bspwm/bspwmrc
cp /usr/share/doc/bspwm/examples/sxhkdrc ~/.config/sxhkd/sxhkdrc
chmod +x ~/.config/bspwm/bspwmrc
chmod +x ~/.config/sxhkd/sxhkdrc
echo "sxhkd &" > ~/.xinitrc
echo "exec bspwm" >> ~/.xinitrc
'

echo "🔸 Installation PipeWire..."
pacman -Sy --noconfirm pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber
systemctl --user enable pipewire pipewire-pulse wireplumber

echo "🔸 Net: NetworkManager..."
pacman -Sy --noconfirm networkmanager
systemctl enable NetworkManager

echo "🔸 EFISTUB: copy the kernel to EFI..."
mkdir -p /boot/EFI/arch
cp /boot/vmlinuz-linux /boot/EFI/arch/vmlinuz-linux.efi
cp /boot/initramfs-linux.img /boot/EFI/arch/initramfs-linux.img

echo "🔸 Add a record to UEFI..."
PARTUUID=\$(blkid -s PARTUUID -o value $ROOT_PART)
KERNEL_PARAMS="root=PARTUUID=\$PARTUUID rootflags=subvol=@ rw add_efi_memmap"

efibootmgr --create --disk $DISK --part 1 \
    --label "Arch Linux" \
    --loader /EFI/arch/vmlinuz-linux.efi \
    --unicode "\$KERNEL_PARAMS" \
    --verbose || echo "⚠️ efibootmgr ended with an error (maybe already exists)"

echo "🔸 Let's turn it on fstrim.timer (для SSD)..."
systemctl enable fstrim.timer

echo "🔸 Done! Exit chroot."
EOF

# ============== 7. Completion ==============
print_info "We are completing the installation..."
if [[ -n "$SWAP_PART" ]]; then
    swapoff "$SWAP_PART"
fi

umount -R /mnt
print_info "✅ Installation complete."
print_info "Disconnect USB and reboot."
read -p "Continue? (Enter to reboot)..."
reboot