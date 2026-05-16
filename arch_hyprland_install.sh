#!/bin/bash
# ============================================
# Arch Linux + Hyprland Auto-Install Script v3.0
# ============================================
# Полностью переписанный, стабильный скрипт
# Учтены все ошибки предыдущих версий
# Запускать ПОСЛЕ подключения к Wi-Fi

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
# Проверка интернета
# ============================================
print_header "Проверка подключения к интернету"
if ping -c 3 archlinux.org &> /dev/null; then
    print_success "Интернет подключен"
else
    print_error "Нет подключения к интернету!"
    print_info "Подключитесь к Wi-Fi: iwctl station wlan0 connect SSID"
    exit 1
fi

# ============================================
# Настройка зеркал
# ============================================
print_header "Настройка зеркал"
print_info "Установка российских зеркал..."
cat > /etc/pacman.d/mirrorlist << 'MIRROR_EOF'
Server = https://mirror.yandex.ru/archlinux/$repo/os/$arch
Server = https://mirror.truenetwork.ru/archlinux/$repo/os/$arch
Server = https://archlinux.arkane.online/$repo/os/$arch
MIRROR_EOF
pacman -Sy
print_success "Зеркала обновлены"

# ============================================
# Разметка диска
# ============================================
print_header "Разметка диска"

echo -e "\n${YELLOW}Доступные диски:${NC}"
lsblk -d -o NAME,SIZE,TYPE,MODEL

echo ""
read -p "Введите диск для установки (например: /dev/nvme0n1 или /dev/sda): " DISK

if [[ ! -b "$DISK" ]]; then
    print_error "Диск $DISK не найден!"
    exit 1
fi

print_warning "ВСЕ ДАННЫЕ НА $DISK БУДУТ УДАЛЕНЫ!"
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
if command -v wipefs &> /dev/null; then
    wipefs -af "$DISK" 2>/dev/null || true
fi

# Создаем разделы
print_info "Создание разделов..."
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary ext4 513MiB 100%

# Обновляем ядро
partprobe "$DISK" 2>/dev/null || true
sleep 2

# Проверяем разделы
if [[ ! -b "$EFI_PART" || ! -b "$ROOT_PART" ]]; then
    print_error "Разделы не созданы! Попробуйте перезагрузиться."
    exit 1
fi

print_success "Разметка завершена"

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
print_success "Смонтировано"

# ============================================
# Установка базовой системы
# ============================================
print_header "Установка базовой системы"
pacstrap -K /mnt base base-devel linux linux-firmware linux-headers \
    vim nano git curl wget networkmanager network-manager-applet \
    sudo man-db man-pages texinfo

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

# Запрашиваем данные ЗАРАНЕЕ
read -p "Введите имя компьютера (hostname): " HOSTNAME
read -p "Введите имя пользователя: " USERNAME

# Создаем скрипт настройки
cat > /mnt/root/setup.sh << CHROOT_EOF
#!/bin/bash
set -e

# Локаль
locale-gen

# Время
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
useradd -m -G wheel,audio,video,optical,storage -s /bin/bash "$USERNAME"
echo "Установите пароль для $USERNAME:"
passwd "$USERNAME"

# Sudo
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# GRUB
pacman -S --noconfirm grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Сервисы
systemctl enable NetworkManager

# Микрокод
if grep -q "GenuineIntel" /proc/cpuinfo; then
    pacman -S --noconfirm intel-ucode
    grub-mkconfig -o /boot/grub/grub.cfg
elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    pacman -S --noconfirm amd-ucode
    grub-mkconfig -o /boot/grub/grub.cfg
fi

CHROOT_EOF

chmod +x /mnt/root/setup.sh
arch-chroot /mnt /root/setup.sh

print_success "Базовая система настроена"

# ============================================
# Установка Hyprland
# ============================================
print_header "Установка Hyprland"

cat > /mnt/root/hypr.sh << HYPR_EOF
#!/bin/bash
set -e

# Обновление
pacman -Syu --noconfirm

# Основные пакеты
pacman -S --noconfirm hyprland waybar wofi kitty mako polkit-gnome \
    pipewire pipewire-pulse wireplumber pavucontrol \
    thunar gvfs ttf-jetbrains-mono-nerd noto-fonts noto-fonts-cjk \
    xdg-desktop-portal-hyprland grim slurp wl-clipboard \
    swww hyprpaper brightnessctl pamixer \
    zsh zsh-completions zsh-syntax-highlighting zsh-autosuggestions \
    git curl wget neovim firefox papirus-icon-theme \
    xdg-user-dirs sddm

# Папки пользователя
su - "$USERNAME" -c "xdg-user-dirs-update"

# yay
su - "$USERNAME" -c "cd /tmp && rm -rf yay && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm"

# AUR
su - "$USERNAME" -c "yay -S --noconfirm catppuccin-gtk-theme-mocha bibata-cursor-theme-bin swaylock-effects wlogout"

# SDDM
systemctl enable sddm

HYPR_EOF

chmod +x /mnt/root/hypr.sh
arch-chroot /mnt /root/hypr.sh

print_success "Hyprland установлен"

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
mkdir -p "$USER_HOME/Pictures/wallpapers"

# Hyprland config - УПРОЩЕННЫЙ, без проблемных опций
cat > "$USER_HOME/.config/hypr/hyprland.conf" << 'EOF'
# Monitor
monitor=,preferred,auto,auto

# Exec
exec-once = waybar
exec-once = mako

# Input
input {
    kb_layout = us,ru
    kb_options = grp:alt_shift_toggle
    follow_mouse = 1
}

# General
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(89b4faff)
    col.inactive_border = rgba(595959aa)
    layout = dwindle
}

# Decoration
decoration {
    rounding = 12
    blur {
        enabled = true
        size = 6
        passes = 2
    }
}

# Animations
animations {
    enabled = true
    bezier = myBezier, 0.05, 0.9, 0.1, 1.05
    animation = windows, 1, 7, myBezier
    animation = workspaces, 1, 6, default
}

# Misc
misc {
    force_default_wallpaper = 0
    disable_hyprland_logo = true
}

# Variables
$mainMod = SUPER
$terminal = kitty
$menu = wofi --show drun

# Basic binds
bind = $mainMod, Return, exec, $terminal
bind = $mainMod, Q, killactive
bind = $mainMod, M, exit
bind = $mainMod, V, togglefloating
bind = $mainMod, R, exec, $menu
bind = $mainMod, F, fullscreen

# Focus
bind = $mainMod, left, movefocus, l
bind = $mainMod, right, movefocus, r
bind = $mainMod, up, movefocus, u
bind = $mainMod, down, movefocus, d

# Workspaces
bind = $mainMod, 1, workspace, 1
bind = $mainMod, 2, workspace, 2
bind = $mainMod, 3, workspace, 3
bind = $mainMod, 4, workspace, 4
bind = $mainMod, 5, workspace, 5

# Move to workspace
bind = $mainMod SHIFT, 1, movetoworkspace, 1
bind = $mainMod SHIFT, 2, movetoworkspace, 2
bind = $mainMod SHIFT, 3, movetoworkspace, 3
bind = $mainMod SHIFT, 4, movetoworkspace, 4
bind = $mainMod SHIFT, 5, movetoworkspace, 5

# Screenshots
bind = $mainMod SHIFT, S, exec, grim -g "$(slurp)" - | wl-copy
bind = $mainMod, Print, exec, grim ~/Pictures/screenshot-$(date +%Y%m%d-%H%M%S).png

# Audio
bindel = ,XF86AudioRaiseVolume, exec, pamixer -i 5
bindel = ,XF86AudioLowerVolume, exec, pamixer -d 5
bindel = ,XF86AudioMute, exec, pamixer -t

# Brightness
bindel = ,XF86MonBrightnessUp, exec, brightnessctl s +5%
bindel = ,XF86MonBrightnessDown, exec, brightnessctl s 5%-

# Lock
bind = $mainMod, L, exec, swaylock --clock --effect-blur 7x5
EOF

# Waybar config
cat > "$USER_HOME/.config/waybar/config" << 'EOF'
{
    "layer": "top",
    "position": "top",
    "height": 36,
    "spacing": 4,
    "modules-left": ["hyprland/workspaces", "hyprland/window"],
    "modules-center": ["clock"],
    "modules-right": ["tray", "pulseaudio", "network", "battery", "custom/power"],

    "hyprland/workspaces": {
        "format": "{name}"
    },

    "hyprland/window": {
        "format": "{title}",
        "max-length": 50
    },

    "clock": {
        "format": "{:%H:%M | %d.%m.%Y}"
    },

    "battery": {
        "states": {
            "warning": 30,
            "critical": 15
        },
        "format": "{icon} {capacity}%",
        "format-icons": ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
    },

    "network": {
        "format-wifi": "󰤨 {essid}",
        "format-ethernet": "󰈀 {ipaddr}",
        "format-disconnected": "󰤭 Offline"
    },

    "pulseaudio": {
        "format": "{icon} {volume}%",
        "format-muted": "󰖁 Muted",
        "format-icons": ["󰕿", "󰖀", "󰕾"]
    },

    "tray": {
        "spacing": 10
    },

    "custom/power": {
        "format": "⏻",
        "on-click": "wlogout",
        "tooltip": false
    }
}
EOF

# Waybar style
cat > "$USER_HOME/.config/waybar/style.css" << 'EOF'
* {
    font-family: "JetBrainsMono Nerd Font", sans-serif;
    font-size: 13px;
    min-height: 0;
    border: none;
    border-radius: 0;
    padding: 0;
    margin: 0;
}

window#waybar {
    background-color: rgba(30, 30, 46, 0.85);
    color: #cdd6f4;
}

#workspaces button {
    padding: 0 10px;
    margin: 2px;
    color: #cdd6f4;
    border-radius: 8px;
}

#workspaces button.active {
    background-color: #89b4fa;
    color: #1e1e2e;
}

#workspaces button:hover {
    background-color: #313244;
}

#clock, #battery, #network, #pulseaudio, #custom-power {
    padding: 0 12px;
    margin: 4px 2px;
    border-radius: 8px;
    background-color: #313244;
}

#clock {
    background-color: #89b4fa;
    color: #1e1e2e;
}

#custom-power {
    background-color: #f38ba8;
    color: #1e1e2e;
}
EOF

# Kitty config
cat > "$USER_HOME/.config/kitty/kitty.conf" << 'EOF'
font_family JetBrainsMono Nerd Font
font_size 11.0

background_opacity 0.95
background #1e1e2e
foreground #cdd6f4
cursor #f5e0dc

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

window_padding_width 8
cursor_shape beam
scrollback_lines 10000
EOF

# Wofi config
cat > "$USER_HOME/.config/wofi/config" << 'EOF'
width=500
height=400
location=center
show=drun
prompt=Search...
allow_images=true
image_size=32
EOF

# Wofi style
cat > "$USER_HOME/.config/wofi/style.css" << 'EOF'
window {
    border: 2px solid #89b4fa;
    border-radius: 16px;
    background-color: #1e1e2e;
}

#input {
    margin: 12px;
    padding: 8px 16px;
    border-radius: 12px;
    color: #cdd6f4;
    background-color: #313244;
}

#entry {
    margin: 4px 8px;
    padding: 8px;
    border-radius: 10px;
}

#entry:selected {
    background-color: #313244;
    border: 1px solid #89b4fa;
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
default-timeout=5000
anchor=top-right
EOF

# Wlogout config
cat > "$USER_HOME/.config/wlogout/layout" << 'EOF'
{
    "label" : "lock",
    "action" : "swaylock --clock --effect-blur 7x5",
    "text" : "Lock"
}
{
    "label" : "logout",
    "action" : "hyprctl dispatch exit",
    "text" : "Logout"
}
{
    "label" : "suspend",
    "action" : "systemctl suspend",
    "text" : "Suspend"
}
{
    "label" : "reboot",
    "action" : "systemctl reboot",
    "text" : "Reboot"
}
{
    "label" : "shutdown",
    "action" : "systemctl poweroff",
    "text" : "Shutdown"
}
EOF

# Wlogout style
cat > "$USER_HOME/.config/wlogout/style.css" << 'EOF'
* {
    font-family: "JetBrainsMono Nerd Font", sans-serif;
    font-size: 16px;
    background-image: none;
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
}
EOF

# Zsh config
cat > "$USER_HOME/.zshrc" << 'EOF'
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh

autoload -Uz vcs_info
precmd() { vcs_info }
zstyle ':vcs_info:git:*' formats '%F{blue}(%b)%f '
setopt PROMPT_SUBST
PROMPT='%F{cyan}%~%f ${vcs_info_msg_0_}%F{green}❯%f '

HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY

autoload -Uz compinit
compinit

alias ls='ls --color=auto'
alias ll='ls -la'
alias update='sudo pacman -Syu'

export EDITOR=nvim
export BROWSER=firefox
export TERMINAL=kitty

export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM=wayland
EOF

# GTK theme
cat > "$USER_HOME/.config/gtk-3.0/settings.ini" << 'EOF'
[Settings]
gtk-theme-name=Catppuccin-Mocha
gtk-icon-theme-name=Papirus-Dark
gtk-cursor-theme-name=Bibata-Modern-Ice
gtk-font-name=JetBrainsMono Nerd Font 11
gtk-application-prefer-dark-theme=1
EOF

cp "$USER_HOME/.config/gtk-3.0/settings.ini" "$USER_HOME/.config/gtk-4.0/settings.ini"

# Обои
print_info "Загрузка обоев..."
curl -L -o "$USER_HOME/Pictures/wallpapers/wallpaper.jpg" \
    "https://raw.githubusercontent.com/catppuccin/wallpapers/main/misc/gradient-blue.png" 2>/dev/null || true

# Права через UID (чтобы работало из Live USB)
UID_GID=$(arch-chroot /mnt id -u "$USERNAME")
chown -R "$UID_GID:$UID_GID" "$USER_HOME/.config"
chown -R "$UID_GID:$UID_GID" "$USER_HOME/.local" 2>/dev/null || true
chown -R "$UID_GID:$UID_GID" "$USER_HOME/.zshrc"
chown -R "$UID_GID:$UID_GID" "$USER_HOME/Pictures"

# Zsh по умолчанию
arch-chroot /mnt chsh -s /bin/zsh "$USERNAME"

print_success "Конфиги созданы"

# ============================================
# Финализация
# ============================================
print_header "Финализация"

# Очистка
rm -f /mnt/root/setup.sh
rm -f /mnt/root/hypr.sh

# Размонтирование
umount -R /mnt

print_success "========================================"
print_success "УСТАНОВКА ЗАВЕРШЕНА!"
print_success "========================================"
echo ""
print_info "Что дальше:"
echo "  1. Перезагрузите: reboot"
echo "  2. Извлеките установочную флешку"
echo "  3. Войдите через SDDM"
echo ""
print_info "Горячие клавиши:"
echo "  SUPER + Enter  - Терминал (Kitty)"
echo "  SUPER + R      - Меню приложений (Wofi)"
echo "  SUPER + Q      - Закрыть окно"
echo "  SUPER + F      - Полный экран"
echo "  SUPER + 1-5    - Рабочие столы"
