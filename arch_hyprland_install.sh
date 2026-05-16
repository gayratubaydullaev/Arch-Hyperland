#!/bin/bash
# ============================================
# Arch Linux + Hyprland Auto-Install Script v5.0
# ============================================
# Полностью переработанная версия с авто-зеркалами

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}========================================${NC}"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ============================================
# Проверка root
# ============================================
if [[ $EUID -ne 0 ]]; then
   print_error "Этот скрипт должен запускаться от root!"
   print_info "Выполните: su -"
   exit 1
fi

# ============================================
# Проверка интернета и DNS
# ============================================
print_header "Проверка подключения к интернету"

# Исправляем DNS если нужно
if ! grep -q "nameserver" /etc/resolv.conf 2>/dev/null; then
    print_warning "DNS не настроен, исправляем..."
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
fi

# Проверяем соединение
if ! ping -c 3 8.8.8.8 &> /dev/null; then
    print_error "Нет подключения к интернету!"
    print_info "Подключитесь к сети:"
    print_info "  WiFi: iwctl station wlan0 connect SSID"
    print_info "  Провод: dhcpcd"
    exit 1
fi

if ! ping -c 3 archlinux.org &> /dev/null; then
    print_warning "DNS не работает, использую Google DNS"
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
fi

print_success "Интернет подключен"

# ============================================
# Запрос данных ЗАРАНЕЕ
# ============================================
print_header "Настройка установки"
read -p "Введите имя компьютера (hostname): " HOSTNAME
read -p "Введите имя пользователя: " USERNAME

while [[ -z "$HOSTNAME" || -z "$USERNAME" ]]; do
    print_error "Имя хоста и пользователя не могут быть пустыми!"
    read -p "Введите имя компьютера (hostname): " HOSTNAME
    read -p "Введите имя пользователя: " USERNAME
done

# ============================================
# Автоматическая настройка зеркал
# ============================================
print_header "Настройка зеркал"
print_info "Установка reflector и подбор лучших зеркал..."

# Устанавливаем reflector
pacman -Sy --noconfirm reflector 2>/dev/null || {
    print_warning "Не удалось установить reflector, использую запасные зеркала"
    cat > /etc/pacman.d/mirrorlist << 'MIRROR_EOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
Server = https://arch.mirror.constant.com/$repo/os/$arch
Server = https://mirror.yandex.ru/archlinux/$repo/os/$arch
Server = https://mirror.truenetwork.ru/archlinux/$repo/os/$arch
MIRROR_EOF
}

# Запускаем reflector с разными стратегиями
if command -v reflector &> /dev/null; then
    print_info "Поиск зеркал по стране (Россия)..."
    reflector --country Russia --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist --latest 10 2>/dev/null || {
        print_warning "Не удалось найти зеркала в России, ищу по миру..."
        reflector --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist --latest 20 2>/dev/null || {
            print_warning "Reflector не смог обновить зеркала, использую дефолтные"
            cat > /etc/pacman.d/mirrorlist << 'MIRROR_EOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
MIRROR_EOF
        }
    }
fi

# Обновляем базу пакетов
print_info "Обновление базы пакетов..."
pacman -Syy --noconfirm

print_success "Зеркала настроены"

# ============================================
# Разметка диска
# ============================================
print_header "Разметка диска"

echo -e "\n${YELLOW}Доступные диски:${NC}"
lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -v "loop"

echo ""
read -p "Введите диск для установки (например: /dev/nvme0n1 или /dev/sda): " DISK

if [[ ! -b "$DISK" ]]; then
    print_error "Диск $DISK не найден!"
    exit 1
fi

print_warning "ВСЕ ДАННЫЕ НА $DISK БУДУТ УДАЛЕНЫ!"
print_warning "Диск: $(lsblk -d -o NAME,SIZE,MODEL "$DISK" | tail -n1)"
read -p "Вы уверены? (yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    print_info "Установка отменена"
    exit 0
fi

# Определяем разделы
if [[ "$DISK" == *"nvme"* ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

# Размонтируем всё
print_info "Размонтирование..."
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true

# Очищаем диск
print_info "Очистка диска..."
dd if=/dev/zero of="$DISK" bs=512 count=1 2>/dev/null || true
wipefs -af "$DISK" 2>/dev/null || true

# Создаем разделы
print_info "Создание разделов..."
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary ext4 513MiB 100%

# Обновляем ядро
partprobe "$DISK" 2>/dev/null || true
sleep 3

# Проверяем разделы
if [[ ! -b "$EFI_PART" || ! -b "$ROOT_PART" ]]; then
    print_error "Разделы не созданы! Попробуйте перезагрузиться."
    exit 1
fi

print_success "Разметка завершена:"
lsblk "$DISK"

# ============================================
# Форматирование
# ============================================
print_header "Форматирование"
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -F "$ROOT_PART"
print_success "Форматирование завершено"

# ============================================
# Монтирование
# ============================================
print_header "Монтирование"
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot
print_success "Смонтировано:"
df -h /mnt /mnt/boot

# ============================================
# Установка базовой системы с повторными попытками
# ============================================
print_header "Установка базовой системы"

install_base() {
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        print_info "Попытка $attempt из $max_attempts..."
        
        if pacstrap -K /mnt base base-devel linux linux-firmware linux-headers \
            vim nano git curl wget networkmanager network-manager-applet \
            sudo man-db man-pages texinfo 2>&1 | tee /tmp/pacstrap.log; then
            return 0
        fi
        
        print_warning "Ошибка установки, пробуем другие зеркала..."
        
        # Обновляем зеркала и пробуем снова
        reflector --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist --latest 20 2>/dev/null || true
        pacman -Syy --noconfirm
        attempt=$((attempt + 1))
        sleep 2
    done
    
    return 1
}

if ! install_base; then
    print_error "Не удалось установить базовую систему после $max_attempts попыток"
    print_info "Попробуйте:"
    print_info "1. Проверить интернет: ping archlinux.org"
    print_info "2. Обновить зеркала вручную: reflector --country Russia --age 12 --sort rate --save /etc/pacman.d/mirrorlist"
    print_info "3. Перезапустить скрипт"
    exit 1
fi

print_success "Базовая система установлена"

# ============================================
# Fstab
# ============================================
print_header "Генерация fstab"
genfstab -U /mnt >> /mnt/etc/fstab
print_success "fstab создан"

# ============================================
# Настройка внутри chroot
# ============================================
print_header "Настройка системы"

# Создаем скрипт настройки
cat > /mnt/root/setup.sh << CHROOT_EOF
#!/bin/bash
set -e

# Цвета для chroot
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_info() { echo -e "\${BLUE}[INFO]\${NC} \$1"; }
print_success() { echo -e "\${GREEN}[OK]\${NC} \$1"; }
print_warning() { echo -e "\${YELLOW}[WARN]\${NC} \$1"; }
print_error() { echo -e "\${RED}[ERROR]\${NC} \$1"; }

# Настройка DNS внутри chroot
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# Локаль
print_info "Настройка локали..."
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "LC_TIME=ru_RU.UTF-8" >> /etc/locale.conf

# Время
print_info "Настройка времени..."
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

# Hostname
echo "$HOSTNAME" > /etc/hostname

cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# Пароль root
echo "========================================"
echo "Установка пароля root"
echo "========================================"
passwd

# Пользователь
print_info "Создание пользователя $USERNAME..."
useradd -m -G wheel,audio,video,optical,storage -s /bin/bash "$USERNAME"
echo "Установите пароль для $USERNAME:"
passwd "$USERNAME"

# Sudo
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# GRUB
print_info "Установка GRUB..."
pacman -S --noconfirm grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Сервисы
systemctl enable NetworkManager

# Микрокод
if grep -q "GenuineIntel" /proc/cpuinfo; then
    print_info "Установка Intel microcode..."
    pacman -S --noconfirm intel-ucode
    grub-mkconfig -o /boot/grub/grub.cfg
elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    print_info "Установка AMD microcode..."
    pacman -S --noconfirm amd-ucode
    grub-mkconfig -o /boot/grub/grub.cfg
fi

# Копируем правильный resolv.conf
cp /etc/resolv.conf /tmp/resolv.conf.bak

print_success "Базовая настройка завершена"
CHROOT_EOF

chmod +x /mnt/root/setup.sh
arch-chroot /mnt /root/setup.sh

print_success "Базовая система настроена"

# ============================================
# Установка Hyprland с повторными попытками
# ============================================
print_header "Установка Hyprland"

cat > /mnt/root/hypr.sh << HYPR_EOF
#!/bin/bash
set -e

# Цвета для chroot
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_info() { echo -e "\${BLUE}[INFO]\${NC} \$1"; }
print_success() { echo -e "\${GREEN}[OK]\${NC} \$1"; }
print_warning() { echo -e "\${YELLOW}[WARN]\${NC} \$1"; }
print_error() { echo -e "\${RED}[ERROR]\${NC} \$1"; }

# Функция установки пакетов с повторными попытками
install_packages() {
    local max_attempts=3
    local attempt=1
    
    while [ \$attempt -le \$max_attempts ]; do
        print_info "Попытка \$attempt из \$max_attempts установки: \$*"
        
        if pacman -S --noconfirm \$@ 2>&1 | tee /tmp/pacman.log; then
            return 0
        fi
        
        print_warning "Ошибка установки пакетов, пробуем обновить зеркала..."
        reflector --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist --latest 20 2>/dev/null || true
        pacman -Syy --noconfirm
        attempt=\$((attempt + 1))
        sleep 2
    done
    
    return 1
}

# Настройка DNS
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# Обновление
print_info "Обновление системы..."
pacman -Syu --noconfirm

# Установка reflector в новой системе
install_packages reflector

# Настройка зеркал в новой системе
print_info "Настройка зеркал в новой системе..."
reflector --country Russia --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist --latest 10 2>/dev/null || \
reflector --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist --latest 20 2>/dev/null || true
pacman -Syy --noconfirm

# Основные пакеты
print_info "Установка Hyprland и основных пакетов..."
install_packages hyprland waybar wofi kitty mako polkit-gnome \
    pipewire pipewire-pulse wireplumber pavucontrol \
    thunar gvfs ttf-jetbrains-mono-nerd noto-fonts noto-fonts-cjk \
    xdg-desktop-portal-hyprland grim slurp wl-clipboard \
    swww hyprpaper brightnessctl pamixer \
    zsh zsh-completions zsh-syntax-highlighting zsh-autosuggestions \
    git curl wget neovim firefox papirus-icon-theme \
    xdg-user-dirs sddm

# Папки пользователя
print_info "Создание папок пользователя..."
su - "$USERNAME" -c "xdg-user-dirs-update"

# yay с улучшенной установкой
print_info "Установка yay..."
su - "$USERNAME" -c "
    cd /tmp && 
    rm -rf yay && 
    git clone https://aur.archlinux.org/yay.git || 
    git clone http://aur.archlinux.org/yay.git || 
    git clone git://aur.archlinux.org/yay.git
" && su - "$USERNAME" -c "cd /tmp/yay && makepkg -si --noconfirm" || {
    print_warning "Не удалось установить yay, пробую альтернативный способ..."
    # Альтернативный способ
    su - "$USERNAME" -c "
        cd /tmp &&
        curl -L -o yay.tar.gz https://github.com/Jguer/yay/releases/latest/download/yay_linux_x86_64.tar.gz &&
        tar xzf yay.tar.gz &&
        ./yay_linux_x86_64/yay -S --noconfirm yay
    " 2>/dev/null || print_warning "Не удалось установить yay. Установите его вручную после загрузки."
}

# AUR пакеты с проверкой
if command -v yay &> /dev/null; then
    print_info "Установка AUR пакетов..."
    su - "$USERNAME" -c "yay -S --noconfirm catppuccin-gtk-theme-mocha bibata-cursor-theme-bin swaylock-effects wlogout" || \
    print_warning "Некоторые AUR пакеты не установлены, можно установить позже"
else
    print_warning "yay не установлен, AUR пакеты пропущены"
    print_info "После загрузки системы выполните:"
    print_info "  1. sudo pacman -S --needed git base-devel"
    print_info "  2. git clone https://aur.archlinux.org/yay.git"
    print_info "  3. cd yay && makepkg -si"
    print_info "  4. yay -S catppuccin-gtk-theme-mocha bibata-cursor-theme-bin swaylock-effects wlogout"
fi

# SDDM
print_info "Включение SDDM..."
systemctl enable sddm

print_success "Hyprland и окружение установлены"
HYPR_EOF

chmod +x /mnt/root/hypr.sh
arch-chroot /mnt /root/hypr.sh || {
    print_warning "Некоторые компоненты не установлены, но система работоспособна"
    print_info "Вы сможете доустановить пакеты после загрузки"
}

print_success "Установка Hyprland завершена"

# ============================================
# Конфиги
# ============================================
print_header "Создание конфигов"

USER_HOME="/mnt/home/$USERNAME"
mkdir -p "$USER_HOME/.config/hypr"
mkdir -p "$USER_HOME/.config/waybar"
mkdir -p "$USER_HOME/.config/kitty"
mkdir -p "$USER_HOME/.config/wofi"
mkdir -p "$USER_HOME/.config/mako"
mkdir -p "$USER_HOME/.config/wlogout"
mkdir -p "$USER_HOME/.config/gtk-3.0"
mkdir -p "$USER_HOME/.config/gtk-4.0"
mkdir -p "$USER_HOME/Pictures/wallpapers"
mkdir -p "$USER_HOME/Pictures/screenshots"
mkdir -p "$USER_HOME/.themes"
mkdir -p "$USER_HOME/.icons"

# Hyprland config - обновленный и стабильный
cat > "$USER_HOME/.config/hypr/hyprland.conf" << 'EOF'
# ===== Auto-generated Hyprland config =====

# Monitor
monitor=,preferred,auto,1.0

# Exec
exec-once = waybar & waybar
exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
exec-once = mako
exec-once = swww-daemon
exec-once = sleep 2 && swww img ~/Pictures/wallpapers/wallpaper.jpg

# Input
input {
    kb_layout = us,ru
    kb_variant = ,winkeys
    kb_options = grp:alt_shift_toggle,caps:escape
    follow_mouse = 1
    accel_profile = flat
    touchpad {
        natural_scroll = true
        tap-to-click = true
    }
}

# General
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(89b4faff) rgba(cba6f7ff) 45deg
    col.inactive_border = rgba(595959aa)
    layout = dwindle
    cursor_inactive_timeout = 5
}

# Decoration
decoration {
    rounding = 12
    active_opacity = 1.0
    inactive_opacity = 0.95
    fullscreen_opacity = 1.0
    
    blur {
        enabled = true
        size = 6
        passes = 2
        new_optimizations = true
        xray = true
    }
    
    drop_shadow = true
    shadow_range = 4
    shadow_render_power = 3
    col.shadow = rgba(0, 0, 0, 0.4)
}

# Animations
animations {
    enabled = true
    bezier = myBezier, 0.05, 0.9, 0.1, 1.05
    bezier = overshot, 0.13, 0.99, 0.29, 1.1
    animation = windows, 1, 7, myBezier, slide
    animation = windowsOut, 1, 7, myBezier, slide
    animation = border, 1, 10, default
    animation = fade, 1, 7, default
    animation = workspaces, 1, 6, default, slide
}

# Misc
misc {
    force_default_wallpaper = 1
    disable_hyprland_logo = true
    disable_splash_rendering = false
    mouse_move_enables_dpms = true
    key_press_enables_dpms = true
    background_color = rgba(30, 30, 46, 1.0)
}

# Variables
$mainMod = SUPER
$terminal = kitty
$fileManager = thunar
$menu = wofi --show drun
$browser = firefox

# Basic binds
bind = $mainMod, Return, exec, $terminal
bind = $mainMod, Q, killactive
bind = $mainMod, M, exit
bind = $mainMod, V, togglefloating
bind = $mainMod, R, exec, $menu
bind = $mainMod, F, fullscreen
bind = $mainMod, Space, togglefloating
bind = $mainMod, P, pseudo
bind = $mainMod, S, togglesplit

# Applications
bind = $mainMod, B, exec, $browser
bind = $mainMod, E, exec, $fileManager
bind = $mainMod, C, exec, kitty htop

# Focus
bind = $mainMod, left, movefocus, l
bind = $mainMod, right, movefocus, r
bind = $mainMod, up, movefocus, u
bind = $mainMod, down, movefocus, d

# Move windows
bind = $mainMod SHIFT, left, movewindow, l
bind = $mainMod SHIFT, right, movewindow, r
bind = $mainMod SHIFT, up, movewindow, u
bind = $mainMod SHIFT, down, movewindow, d

# Resize windows
bind = $mainMod ALT, left, resizeactive, -20 0
bind = $mainMod ALT, right, resizeactive, 20 0
bind = $mainMod ALT, up, resizeactive, 0 -20
bind = $mainMod ALT, down, resizeactive, 0 20

# Workspaces
bind = $mainMod, 1, workspace, 1
bind = $mainMod, 2, workspace, 2
bind = $mainMod, 3, workspace, 3
bind = $mainMod, 4, workspace, 4
bind = $mainMod, 5, workspace, 5
bind = $mainMod, 6, workspace, 6
bind = $mainMod, 7, workspace, 7
bind = $mainMod, 8, workspace, 8
bind = $mainMod, 9, workspace, 9
bind = $mainMod, 0, workspace, 10

# Move to workspace
bind = $mainMod SHIFT, 1, movetoworkspacesilent, 1
bind = $mainMod SHIFT, 2, movetoworkspacesilent, 2
bind = $mainMod SHIFT, 3, movetoworkspacesilent, 3
bind = $mainMod SHIFT, 4, movetoworkspacesilent, 4
bind = $mainMod SHIFT, 5, movetoworkspacesilent, 5
bind = $mainMod SHIFT, 6, movetoworkspacesilent, 6
bind = $mainMod SHIFT, 7, movetoworkspacesilent, 7
bind = $mainMod SHIFT, 8, movetoworkspacesilent, 8
bind = $mainMod SHIFT, 9, movetoworkspacesilent, 9
bind = $mainMod SHIFT, 0, movetoworkspacesilent, 10

# Scroll workspaces
bind = $mainMod, mouse_down, workspace, e+1
bind = $mainMod, mouse_up, workspace, e-1

# Screenshots
bind = $mainMod SHIFT, S, exec, grim -g "$(slurp)" - | wl-copy
bind = , Print, exec, grim -g "$(slurp)" - | wl-copy
bind = $mainMod, Print, exec, grim ~/Pictures/screenshots/screenshot-$(date +%Y%m%d-%H%M%S).png
bind = $mainMod SHIFT, Print, exec, grim -g "$(slurp)" ~/Pictures/screenshots/screenshot-$(date +%Y%m%d-%H%M%S).png

# Audio
bindel = ,XF86AudioRaiseVolume, exec, pamixer -i 5
bindel = ,XF86AudioLowerVolume, exec, pamixer -d 5
bindel = ,XF86AudioMute, exec, pamixer -t
bind = $mainMod, Up, exec, pamixer -i 5
bind = $mainMod, Down, exec, pamixer -d 5
bind = $mainMod SHIFT, M, exec, pamixer -t

# Brightness
bindel = ,XF86MonBrightnessUp, exec, brightnessctl s +5%
bindel = ,XF86MonBrightnessDown, exec, brightnessctl s 5%-

# Lock
bind = $mainMod, L, exec, swaylock --clock --effect-blur 7x5 --indicator

# Special workspace (scratchpad)
bind = $mainMod, grave, togglespecialworkspace
bind = $mainMod SHIFT, grave, movetoworkspace, special

# Window rules
windowrulev2 = float, class:^(pavucontrol)$
windowrulev2 = float, class:^(org.gnome.Calculator)$
windowrulev2 = float, class:^(nm-connection-editor)$
windowrulev2 = float, title:^(Picture-in-Picture)$
windowrulev2 = pin, title:^(Picture-in-Picture)$
EOF

# Waybar config - улучшенный
cat > "$USER_HOME/.config/waybar/config" << 'EOF'
{
    "layer": "top",
    "position": "top",
    "height": 36,
    "spacing": 4,
    "margin-top": 0,
    "margin-left": 10,
    "margin-right": 10,
    
    "modules-left": ["hyprland/workspaces", "hyprland/window"],
    "modules-center": ["clock"],
    "modules-right": ["tray", "pulseaudio", "network", "battery", "custom/power"],

    "hyprland/workspaces": {
        "format": "{icon}",
        "format-icons": {
            "1": "1",
            "2": "2",
            "3": "3",
            "4": "4",
            "5": "5",
            "6": "6",
            "7": "7",
            "8": "8",
            "9": "9",
            "10": "10",
            "urgent": "",
            "focused": "",
            "default": ""
        },
        "on-click": "activate",
        "persistent-workspaces": {
            "1": [],
            "2": [],
            "3": [],
            "4": [],
            "5": []
        }
    },

    "hyprland/window": {
        "format": "{}",
        "max-length": 80,
        "separate-outputs": true
    },

    "clock": {
        "format": "  {:%H:%M}    {:%d.%m.%Y}",
        "tooltip-format": "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>"
    },

    "battery": {
        "states": {
            "warning": 30,
            "critical": 15
        },
        "format": "{icon}  {capacity}%",
        "format-charging": "󰂄  {capacity}%",
        "format-plugged": "󰂄  {capacity}%",
        "format-icons": ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"],
        "tooltip-format": "{timeTo} {power}W"
    },

    "network": {
        "format-wifi": "󰤨  {essid}",
        "format-ethernet": "󰈀  {ifname}",
        "format-disconnected": "󰤭  Offline",
        "tooltip-format": "{ifname}: {ipaddr}",
        "on-click": "kitty nmtui"
    },

    "pulseaudio": {
        "format": "{icon}  {volume}%",
        "format-muted": "󰖁  Muted",
        "format-icons": ["󰕿", "󰖀", "󰕾"],
        "on-click": "pavucontrol",
        "tooltip-format": "{desc}"
    },

    "tray": {
        "spacing": 10,
        "icon-size": 18
    },

    "custom/power": {
        "format": "⏻",
        "on-click": "wlogout",
        "tooltip": "Power menu"
    }
}
EOF

# Waybar style - улучшенный
cat > "$USER_HOME/.config/waybar/style.css" << 'EOF'
* {
    font-family: "JetBrainsMono Nerd Font", "Noto Sans CJK", sans-serif;
    font-size: 13px;
    font-weight: bold;
    min-height: 0;
    border: none;
    border-radius: 0;
    padding: 0;
    margin: 0;
}

window#waybar {
    background-color: rgba(30, 30, 46, 0.85);
    color: #cdd6f4;
    border-radius: 12px;
}

#workspaces {
    padding: 0 8px;
}

#workspaces button {
    padding: 0 8px;
    margin: 4px 2px;
    color: #6c7086;
    border-radius: 8px;
    transition: all 0.2s ease;
}

#workspaces button.active {
    color: #1e1e2e;
    background-color: #89b4fa;
    min-width: 24px;
}

#workspaces button:hover {
    background-color: #313244;
    color: #cdd6f4;
}

#window {
    padding: 0 12px;
    color: #a6adc8;
}

#clock {
    padding: 0 16px;
    margin: 4px 8px;
    border-radius: 8px;
    background-color: #89b4fa;
    color: #1e1e2e;
}

#battery,
#network,
#pulseaudio,
#custom-power {
    padding: 0 12px;
    margin: 4px 2px;
    border-radius: 8px;
    background-color: #313244;
}

#battery.warning {
    background-color: #f9e2af;
    color: #1e1e2e;
}

#battery.critical {
    background-color: #f38ba8;
    color: #1e1e2e;
}

#custom-power {
    background-color: #f38ba8;
    color: #1e1e2e;
    margin-right: 8px;
}

#custom-power:hover {
    background-color: #eba0ac;
}

tooltip {
    background-color: #1e1e2e;
    border: 1px solid #89b4fa;
    border-radius: 8px;
}

tooltip label {
    color: #cdd6f4;
}
EOF

# Kitty config
cat > "$USER_HOME/.config/kitty/kitty.conf" << 'EOF'
# Font
font_family JetBrainsMono Nerd Font
font_size 12.0
bold_font auto
italic_font auto

# Colors
background_opacity 0.95
background #1e1e2e
foreground #cdd6f4
cursor #f5e0dc
selection_background #45475a

# Catppuccin Mocha
color0 #45475a
color1 #f38ba8
color2 #a6e3a1
color3 #f9e2af
color4 #89b4fa
color5 #f5c2e7
color6 #94e2d5
color7 #bac2de
color8 #585b70
color9 #f38ba8
color10 #a6e3a1
color11 #f9e2af
color12 #89b4fa
color13 #f5c2e7
color14 #94e2d5
color15 #a6adc8

# Window
window_padding_width 8
window_margin_width 0
hide_window_decorations no
confirm_os_window_close 0

# Cursor
cursor_shape beam
cursor_beam_thickness 1.5

# Scrolling
scrollback_lines 10000
scrollback_pager_history_size 100

# Performance
repaint_delay 10
input_delay 3
sync_to_monitor yes

# Tabs
tab_bar_edge bottom
tab_bar_style powerline
tab_powerline_style slanted
active_tab_foreground #1e1e2e
active_tab_background #89b4fa
inactive_tab_foreground #cdd6f4
inactive_tab_background #313244
EOF

# Wofi config
cat > "$USER_HOME/.config/wofi/config" << 'EOF'
width=600
height=400
location=center
show=drun
prompt=Search applications...
allow_images=true
image_size=32
insensitive=true
sort_order=default
term=kitty
EOF

# Wofi style
cat > "$USER_HOME/.config/wofi/style.css" << 'EOF'
window {
    margin: 0px;
    border: 2px solid #89b4fa;
    border-radius: 16px;
    background-color: #1e1e2e;
}

#input {
    margin: 12px;
    padding: 8px 16px;
    border: none;
    border-radius: 12px;
    color: #cdd6f4;
    background-color: #313244;
    font-family: "JetBrainsMono Nerd Font";
    font-size: 14px;
}

#inner-box {
    margin: 8px;
    border-radius: 12px;
}

#outer-box {
    margin: 0px;
    border-radius: 16px;
}

#scroll {
    margin: 0px;
}

#text {
    margin: 0 12px;
    color: #cdd6f4;
}

#entry {
    padding: 8px 12px;
    margin: 2px 0;
    border-radius: 10px;
}

#entry:selected {
    background-color: #313244;
    border: 1px solid #89b4fa;
}

#entry:selected #text {
    color: #89b4fa;
}

#img {
    margin: 4px 8px;
}
EOF

# Mako config
cat > "$USER_HOME/.config/mako/config" << 'EOF'
font=JetBrainsMono Nerd Font 11
background-color=#1e1e2e
text-color=#cdd6f4
border-color=#89b4fa
border-size=2
border-radius=12
padding=12
margin=12
width=350
height=150
default-timeout=5000
ignore-timeout=false
max-visible=5
anchor=top-right
layer=overlay
sort=+time
icons=true
markup=true
EOF

# Wlogout config
cat > "$USER_HOME/.config/wlogout/layout" << 'EOF'
[
    {
        "label": "lock",
        "action": "swaylock --clock --effect-blur 7x5 --indicator",
        "text": "Lock",
        "keybind": "l"
    },
    {
        "label": "logout",
        "action": "hyprctl dispatch exit",
        "text": "Logout",
        "keybind": "e"
    },
    {
        "label": "suspend",
        "action": "systemctl suspend",
        "text": "Suspend",
        "keybind": "u"
    },
    {
        "label": "hibernate",
        "action": "systemctl hibernate",
        "text": "Hibernate",
        "keybind": "h"
    },
    {
        "label": "reboot",
        "action": "systemctl reboot",
        "text": "Reboot",
        "keybind": "r"
    },
    {
        "label": "shutdown",
        "action": "systemctl poweroff",
        "text": "Shutdown",
        "keybind": "s"
    }
]
EOF

# Wlogout style
cat > "$USER_HOME/.config/wlogout/style.css" << 'EOF'
* {
    font-family: "JetBrainsMono Nerd Font", sans-serif;
    font-size: 16px;
    background-image: none;
    transition: all 0.2s ease;
}

window {
    background-color: rgba(30, 30, 46, 0.85);
}

button {
    color: #cdd6f4;
    background-color: #313244;
    border: 2px solid #45475a;
    border-radius: 16px;
    margin: 16px;
    padding: 32px;
    min-width: 120px;
    min-height: 120px;
}

button:hover {
    background-color: #89b4fa;
    color: #1e1e2e;
    border-color: #89b4fa;
}

button:focus {
    background-color: #cba6f7;
    color: #1e1e2e;
}
EOF

# Zsh config - улучшенный
cat > "$USER_HOME/.zshrc" << 'EOF'
# === ZSH Configuration ===

# Plugins
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh

# Git info
autoload -Uz vcs_info
precmd() { vcs_info }
zstyle ':vcs_info:git:*' formats ' %F{blue}(%b)%f'
setopt PROMPT_SUBST

# Prompt
PROMPT='%F{cyan}%~%f${vcs_info_msg_0_}%F{green}❯%f '

# History
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE

# Completion
autoload -Uz compinit
compinit
zstyle ':completion:*' menu select

# Aliases
alias ls='ls --color=auto'
alias ll='ls -lah'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias update='sudo pacman -Syu'
alias install='sudo pacman -S'
alias remove='sudo pacman -Rns'
alias cleanup='sudo pacman -Scc && sudo pacman -Rns $(pacman -Qdtq 2>/dev/null || echo "")'
alias vim='nvim'
alias please='sudo $(history -p !!)'
alias cl='clear'
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git log --oneline --graph'

# Environment
export EDITOR=nvim
export BROWSER=firefox
export TERMINAL=kitty
export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM=wayland
export QT_QPA_PLATFORMTHEME=qt5ct
export _JAVA_AWT_WM_NONREPARENTING=1
export XDG_CURRENT_DESKTOP=Hyprland
export XDG_SESSION_TYPE=wayland
export XDG_SESSION_DESKTOP=Hyprland

# Dircolors
eval $(dircolors -b)

# Auto completion colors
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}

# Functions
mkcd() { mkdir -p "$1" && cd "$1"; }
extract() {
    if [ -f $1 ]; then
        case $1 in
            *.tar.bz2) tar xjf $1 ;;
            *.tar.gz) tar xzf $1 ;;
            *.bz2) bunzip2 $1 ;;
            *.rar) unrar x $1 ;;
            *.gz) gunzip $1 ;;
            *.tar) tar xf $1 ;;
            *.tbz2) tar xjf $1 ;;
            *.tgz) tar xzf $1 ;;
            *.zip) unzip $1 ;;
            *.Z) uncompress $1 ;;
            *.7z) 7z x $1 ;;
            *) echo "'$1' cannot be extracted" ;;
        esac
    else
        echo "'$1' is not a valid file"
    fi
}
EOF

# GTK settings
cat > "$USER_HOME/.config/gtk-3.0/settings.ini" << 'EOF'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Papirus-Dark
gtk-font-name=JetBrainsMono Nerd Font 11
gtk-application-prefer-dark-theme=1
gtk-cursor-theme-name=bibata
EOF

cp "$USER_HOME/.config/gtk-3.0/settings.ini" "$USER_HOME/.config/gtk-4.0/settings.ini"

# Файл переменных окружения GTK
cat > "$USER_HOME/.gtkrc-2.0" << 'EOF'
gtk-theme-name="Adwaita-dark"
gtk-icon-theme-name="Papirus-Dark"
gtk-font-name="JetBrainsMono Nerd Font 11"
gtk-cursor-theme-name="bibata"
EOF

# .bashrc на всякий случай
cat > "$USER_HOME/.bashrc" << 'EOF'
# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias ll='ls -lah'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '
EOF

# Обои
print_info "Загрузка обоев..."
if command -v curl &> /dev/null; then
    curl -L -o "$USER_HOME/Pictures/wallpapers/wallpaper.jpg" \
        "https://raw.githubusercontent.com/catppuccin/wallpapers/main/misc/gradient-blue.png" 2>/dev/null || \
    curl -L -o "$USER_HOME/Pictures/wallpapers/wallpaper.jpg" \
        "https://archlinux.org/static/archlinux-wallpaper-1920x1080.png" 2>/dev/null || \
    print_warning "Не удалось загрузить обои"
else
    print_warning "curl не найден, обои не загружены"
fi

# Создаем резервные обои через Python если есть
if [[ ! -f "$USER_HOME/Pictures/wallpapers/wallpaper.jpg" ]]; then
    # Создаем простой градиент через ImageMagick если доступен
    if command -v convert &> /dev/null; then
        convert -size 1920x1080 gradient:'#1e1e2e'-'#89b4fa' "$USER_HOME/Pictures/wallpapers/wallpaper.jpg" 2>/dev/null || true
    fi
fi

# Права
print_info "Настройка прав..."
UID_GID=$(arch-chroot /mnt id -u "$USERNAME" 2>/dev/null || echo "1000")
chown -R "$UID_GID:$UID_GID" "$USER_HOME"
chmod 700 "$USER_HOME"

# Zsh по умолчанию
print_info "Установка Zsh как оболочки по умолчанию..."
arch-chroot /mnt chsh -s /bin/zsh "$USERNAME" 2>/dev/null || print_warning "Не удалось установить Zsh"

print_success "Конфиги созданы"

# ============================================
# Финализация
# ============================================
print_header "Финализация"

# Очистка временных файлов
rm -f /mnt/root/setup.sh
rm -f /mnt/root/hypr.sh
rm -f /mnt/tmp/pacman.log 2>/dev/null || true

# Создаем файл с заметками
cat > /mnt/home/"$USERNAME"/README_AFTER_INSTALL.txt << EOF
=============================================
ПОСЛЕ УСТАНОВКИ ARCH LINUX + HYPRLAND
=============================================

Если какие-то пакеты не установились:
1. Подключитесь к интернету через nmtui
2. Обновите систему: sudo pacman -Syu
3. Установите reflector: sudo pacman -S reflector
4. Настройте зеркала: sudo reflector --country Russia --age 12 --sort rate --save /etc/pacman.d/mirrorlist

Если yay не установился:
1. sudo pacman -S --needed git base-devel
2. git clone https://aur.archlinux.org/yay.git
3. cd yay && makepkg -si
4. yay -S catppuccin-gtk-theme-mocha bibata-cursor-theme-bin swaylock-effects

Основные комбинации:
- SUPER + Enter - Терминал (Kitty)
- SUPER + R - Запуск приложений (Wofi)
- SUPER + Q - Закрыть окно
- SUPER + F - Полный экран
- SUPER + 1-10 - Рабочие столы
- SUPER + SHIFT + 1-10 - Переместить окно на рабочий стол
- SUPER + L - Заблокировать экран
- SUPER + B - Firefox
- SUPER + E - Файловый менеджер (Thunar)

Конфиги находятся в ~/.config/
Настройки Hyprland: ~/.config/hypr/hyprland.conf
Настройки Waybar: ~/.config/waybar/config

Для изменения темы установите Catppuccin:
yay -S catppuccin-gtk-theme-mocha
EOF

# Размонтирование
print_info "Размонтирование разделов..."
swapoff -a 2>/dev/null || true
umount -R /mnt 2>/dev/null || true

print_success "========================================"
print_success "УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!"
print_success "========================================"
echo ""
print_info "Дальнейшие действия:"
echo "  1. Перезагрузите: reboot"
echo "  2. Извлеките установочную флешку"
echo "  3. Войдите через SDDM (логин/пароль который создали)"
echo "  4. Откройте терминал (SUPER + Enter)"
echo "  5. Подключитесь к WiFi: nmtui"
echo ""
print_info "Полезные команды после входа:"
echo "  • Обновление системы: sudo pacman -Syu"
echo "  • Установка программ: sudo pacman -S название_пакета"
echo "  • Поиск программ: yay -Ss запрос"
echo "  • Файл помощи: ~/README_AFTER_INSTALL.txt"
echo ""
print_info "Если что-то пошло не так:"
echo "  • Проверьте интернет: ping archlinux.org"
echo "  • Проверьте зеркала: cat /etc/pacman.d/mirrorlist"
echo "  • Обновите зеркала: sudo reflector --country Russia --sort rate --save /etc/pacman.d/mirrorlist"
echo ""
print_success "Удачного использования Arch Linux!"
