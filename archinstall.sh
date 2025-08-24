#!/bin/bash
# arch-auto-install-interactive.sh
# Интерактивная установка Arch Linux: Btrfs + EFISTUB + bspwm + PipeWire
# Без паролей в коде, с подтверждением перед форматированием

set -euo pipefail

# ============== Цвета для вывода ==============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function print_info { echo -e "${GREEN}[INFO] $1${NC}"; }
function print_warn { echo -e "${YELLOW}[WARN] $1${NC}"; }
function print_error { echo -e "${RED}[ERROR] $1${NC}"; }

# ============== Интерактивный ввод ==============
print_info "Добро пожаловать в установщик Arch Linux (Btrfs + EFISTUB + bspwm)"

read -p "🔹 Имя пользователя: " USERNAME
while [[ -z "$USERNAME" ]]; do
    print_error "Имя пользователя не может быть пустым."
    read -p "🔹 Имя пользователя: " USERNAME
done

read -sp "🔹 Пароль для пользователя $USERNAME: " USER_PASS
echo
while [[ -z "$USER_PASS" ]]; do
    print_error "Пароль не может быть пустым."
    read -sp "🔹 Пароль для пользователя $USERNAME: " USER_PASS
    echo
done

read -sp "🔹 Пароль для root: " ROOT_PASS
echo
while [[ -z "$ROOT_PASS" ]]; do
    print_error "Пароль root не может быть пустым."
    read -sp "🔹 Пароль для root: " ROOT_PASS
    echo
done

read -p "🔹 Имя хоста (например, archbox): " HOSTNAME
HOSTNAME=${HOSTNAME:-"archbox"}

echo "🔹 Доступные диски:"
lsblk -d -e7 -o NAME,SIZE,MODEL
read -p "Введите диск для установки (например, sda): " DISK_DEVICE
DISK="/dev/$DISK_DEVICE"

if [[ ! -b "$DISK" ]]; then
    print_error "Устройство $DISK не существует."
    exit 1
fi

print_warn "ВНИМАНИЕ: весь диск $DISK будет ОТФОРМАТИРОВАН!"
read -p "Продолжить? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    print_info "Установка отменена."
    exit 0
fi

read -p "Размер EFI-раздела (по умолчанию 512M): " EFI_SIZE
EFI_SIZE=${EFI_SIZE:-"512M"}

SWAP_ENABLE=""
read -p "Создать swap-раздел? (y/N): " SWAP_ENABLE_INPUT
if [[ "$SWAP_ENABLE_INPUT" =~ ^[Yy]$ ]]; then
    read -p "Размер swap (например, 4G, по умолчанию 4G): " SWAP_SIZE
    SWAP_SIZE=${SWAP_SIZE:-"4G"}
    SWAP_ENABLE="yes"
fi

read -p "Часовой пояс (например, Europe/Moscow): " TIMEZONE
TIMEZONE=${TIMEZONE:-"Europe/Moscow"}

read -p "Локаль (например, en_US.UTF-8): " LOCALE
LOCALE=${LOCALE:-"en_US.UTF-8"}

read -p "Раскладка клавиатуры (us, ru и т.п.): " KEYMAP
KEYMAP=${KEYMAP:-"us"}

read -p "Шрифт консоли (по умолчанию latarcyrheb-sun16): " FONT
FONT=${FONT:-"latarcyrheb-sun16"}

read -p "Компрессия Btrfs (zstd/lzo/zlib, по умолчанию zstd): " COMPRESS
COMPRESS=${COMPRESS:-"zstd"}

CPU_VENDOR="intel"
read -p "Процессор (intel/amd, по умолчанию intel): " CPU_INPUT
CPU_VENDOR=${CPU_INPUT:-"intel"}
if [[ ! "$CPU_VENDOR" =~ ^(intel|amd)$ ]]; then
    print_error "Неверный выбор: $CPU_VENDOR. Используем intel."
    CPU_VENDOR="intel"
fi

print_info "Проверка UEFI..."
if [ ! -d /sys/firmware/efi/efivars ]; then
    print_error "Система не в режиме UEFI!"
    exit 1
fi

print_info "Проверка интернета..."
if ! ping -c 1 archlinux.org &> /dev/null; then
    print_error "Нет интернета. Проверьте подключение."
    exit 1
fi

print_info "Все параметры приняты. Начинаем установку..."

# ============== 1. Разметка диска ==============
print_info "Размечаем $DISK..."
sgdisk --zap-all "$DISK" || { print_error "Ошибка при очистке диска."; exit 1; }

END_SECTOR=2047

# EFI
sgdisk -n 1:$END_SECTOR:+$EFI_SIZE -t 1:EF00 -c 1:"EFI System" "$DISK"
END_SECTOR=$(sgdisk -F "$DISK")

# Swap (если включён)
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

# ============== 2. Форматирование ==============
print_info "Форматируем разделы..."
mkfs.fat -F32 "${DISK}1" || { print_error "Ошибка форматирования EFI."; exit 1; }
mkfs.btrfs -f "$ROOT_PART" || { print_error "Ошибка форматирования Btrfs."; exit 1; }

if [[ -n "$SWAP_PART" ]]; then
    mkswap "$SWAP_PART"
    # Не включаем пока — будет в fstab
fi

# ============== 3. Btrfs subvolumes ==============
print_info "Создаём Btrfs subvolumes..."
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

# ============== 4. Установка пакетов ==============
print_info "Устанавливаем базовые пакеты..."
pacstrap /mnt base base-devel linux linux-firmware btrfs-progs efibootmgr
if [[ "$CPU_VENDOR" == "intel" ]]; then
    pacstrap /mnt intel-ucode
elif [[ "$CPU_VENDOR" == "amd" ]]; then
    pacstrap /mnt amd-ucode
fi

# ============== 5. fstab ==============
print_info "Генерируем fstab..."
genfstab -U /mnt >> /mnt/mnt/fstab

# Если есть swap — добавим в fstab
if [[ -n "$SWAP_PART" ]]; then
    UUID_SWAP=$(blkid -s UUID -o value "$SWAP_PART")
    echo "UUID=$UUID_SWAP none swap sw 0 0" >> /mnt/mnt/fstab
fi

# ============== 6. chroot + настройка ==============
print_info "Входим в chroot и настраиваем систему..."

arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

echo "🔸 Настройка локали и времени..."
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

echo "🔸 Настройка пользователя..."
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$USER_PASS" | chpasswd
sed -i 's/# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

echo "🔸 Установка X11, bspwm, PipeWire..."
pacman -Sy --noconfirm xorg-server xorg-xinit xorg-xrandr xorg-xsetroot xorg-xbacklight
pacman -Sy --noconfirm bspwm sxhkd picom alacritty nitrogen dmenu firefox neovim git

# Конфиги bspwm
su - $USERNAME -c '
mkdir -p ~/.config/{bspwm,sxhkd}
cp /usr/share/doc/bspwm/examples/bspwmrc ~/.config/bspwm/bspwmrc
cp /usr/share/doc/bspwm/examples/sxhkdrc ~/.config/sxhkd/sxhkdrc
chmod +x ~/.config/bspwm/bspwmrc
chmod +x ~/.config/sxhkd/sxhkdrc
echo "sxhkd &" > ~/.xinitrc
echo "exec bspwm" >> ~/.xinitrc
'

echo "🔸 Установка PipeWire..."
pacman -Sy --noconfirm pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber
systemctl --user enable pipewire pipewire-pulse wireplumber

echo "🔸 Сеть: NetworkManager..."
pacman -Sy --noconfirm networkmanager
systemctl enable NetworkManager

echo "🔸 EFISTUB: копируем ядро в EFI..."
mkdir -p /boot/EFI/arch
cp /boot/vmlinuz-linux /boot/EFI/arch/vmlinuz-linux.efi
cp /boot/initramfs-linux.img /boot/EFI/arch/initramfs-linux.img

echo "🔸 Добавляем запись в UEFI..."
PARTUUID=\$(blkid -s PARTUUID -o value $ROOT_PART)
KERNEL_PARAMS="root=PARTUUID=\$PARTUUID rootflags=subvol=@ rw add_efi_memmap"

efibootmgr --create --disk $DISK --part 1 \
    --label "Arch Linux" \
    --loader /EFI/arch/vmlinuz-linux.efi \
    --unicode "\$KERNEL_PARAMS" \
    --verbose || echo "⚠️ efibootmgr завершился с ошибкой (возможно, уже есть)"

echo "🔸 Включаем fstrim.timer (для SSD)..."
systemctl enable fstrim.timer

echo "🔸 Готово! Выход из chroot."
EOF

# ============== 7. Завершение ==============
print_info "Завершаем установку..."
if [[ -n "$SWAP_PART" ]]; then
    swapoff "$SWAP_PART"
fi

umount -R /mnt
print_info "✅ Установка завершена."
print_info "Отключите USB и перезагрузитесь."
read -p "Продолжить? (Enter для перезагрузки)..."
reboot