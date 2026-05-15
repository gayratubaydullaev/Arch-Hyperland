#!/bin/bash
# ============================================
# Arch Linux + Hyprland Auto-Install Script
# ============================================
# Запускать ПОСЛЕ подключения к Wi-Fi
# Использование: curl -O URL/скрипт.sh && bash скрипт.sh
# ИЛИ: wget URL/скрипт.sh && bash скрипт.sh

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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
   print_info "Выполните: su - (или sudo -i)"
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
# Настройка зеркал (Россия)
# ============================================
print_header "Настройка зеркал"
print_info "Установка российских зеркал..."
cat > /etc/pacman.d/mirrorlist << 'MIRROR_EOF'
Server = https://mirror.yandex.ru/archlinux/$repo/os/$arch
Server = https://mirror.truenetwork.ru/archlinux/$repo/os/$arch
Server = https://archlinux.arkane.online/$repo/os/$arch
Server = https://mirror.rol.ru/archlinux/$repo/os/$arch
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

# Определяем тип диска
if [[ "$DISK" == *"nvme"* ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

# ============================================
# Принудительная очистка (если диск занят)
# ============================================
print_info "Проверка и очистка диска..."

# Размонтируем всё что связано с этим диском
for mountpoint in $(findmnt -n -o TARGET -S "$DISK" 2>/dev/null); do
    print_info "Размонтирование: $mountpoint"
    umount -R "$mountpoint" 2>/dev/null || umount -lf "$mountpoint" 2>/dev/null || true
done

# Отключаем swap
swapoff "$EFI_PART" 2>/dev/null || true
swapoff "$ROOT_PART" 2>/dev/null || true
swapoff ${DISK}* 2>/dev/null || true

# Убиваем процессы которые используют диск
if command -v fuser &> /dev/null; then
    fuser -km "$DISK" 2>/dev/null || true
fi

# Отключаем LVM если есть
vgchange -an 2>/dev/null || true

# Синхронизация
sync
sleep 2

# ============================================
# ОЧИСТКА ДИСКА БЕЗ УДАЛЕНИЯ ИЗ ЯДРА
# ============================================
print_info "Очистка сигнатур файловых систем..."

# Устанавливаем wipefs если нет
pacman -S --noconfirm util-linux 2>/dev/null || true

# Очищаем сигнатуры на всем диске
if command -v wipefs &> /dev/null; then
    wipefs -af "$DISK" 2>/dev/null || true
fi

# Очищаем заголовок диска
print_info "Очистка заголовка диска..."
dd if=/dev/zero of="$DISK" bs=512 count=2048 status=progress
sync

# Обновляем таблицу разделов в ядре
if command -v partprobe &> /dev/null; then
    partprobe "$DISK" 2>/dev/null || true
fi
if command -v blockdev &> /dev/null; then
    blockdev --rereadpt "$DISK" 2>/dev/null || true
fi

sleep 2

print_info "Разметка диска $DISK..."

# Создаем новую таблицу разделов GPT
parted -s "$DISK" mklabel gpt

# EFI раздел (512MB)
parted -s "$DISK" mkpart primary fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on

# Root раздел (всё оставшееся место)
parted -s "$DISK" mkpart primary ext4 513MiB 100%

# Принудительно обновляем таблицу разделов в ядре
print_info "Обновление таблицы разделов в ядре..."
if command -v partprobe &> /dev/null; then
    partprobe "$DISK" 2>/dev/null || true
fi
if command -v blockdev &> /dev/null; then
    blockdev --rereadpt "$DISK" 2>/dev/null || true
fi

# Ждем пока ядро увидит новые разделы
print_info "Ожидание обнаружения разделов ядром..."
sleep 3

# Проверяем что разделы появились
for i in {1..10}; do
    if [[ -b "$EFI_PART" && -b "$ROOT_PART" ]]; then
        print_success "Разделы обнаружены: $EFI_PART, $ROOT_PART"
        break
    fi
    print_info "Ожидание разделов (попытка $i/10)..."
    sleep 1
    # Повторно обновляем
    partprobe "$DISK" 2>/dev/null || true
    blockdev --rereadpt "$DISK" 2>/dev/null || true
done

if [[ ! -b "$EFI_PART" || ! -b "$ROOT_PART" ]]; then
    print_error "Разделы не обнаружены! Попробуйте перезагрузиться и запустить скрипт заново."
    exit 1
fi

print_success "Разметка завершена"

# ============================================
# Форматирование
# ============================================
print_header "Форматирование разделов"

print_info "Форматирование EFI раздела..."
mkfs.fat -F32 "$EFI_PART"

print_info "Форматирование Root раздела..."
mkfs.ext4 -F "$ROOT_PART"

print_success "Форматирование завершено"

# ============================================
# Монтирование
# ============================================
print_header "Монтирование разделов"

# Убедимся что ничего не смонтировано в /mnt
umount -R /mnt 2>/dev/null || true

mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

print_success "Разделы смонтированы"

# ============================================
# Установка базовой системы
# ============================================
print_header "Установка базовой системы"

print_info "Установка пакетов (это займет несколько минут)..."
pacstrap -K /mnt base base-devel linux linux-firmware linux-headers \
    vim nano git curl wget networkmanager network-manager-applet \
    sudo man-db man-pages texinfo

print_success "Базовая система установлена"

# ============================================
# Генерация fstab
# ============================================
print_header "Генерация fstab"
genfstab -U /mnt >> /mnt/etc/fstab
cat /mnt/etc/fstab
print_success "fstab создан"

# ============================================
# Настройка системы внутри chroot
# ============================================
print_header "Настройка системы"

# Создаем скрипт для выполнения внутри chroot - ВСЕ функции встроены!
cat > /mnt/root/chroot_setup.sh << 'CHROOT_EOF'
#!/bin/bash
set -e

# Встроенные функции (не зависят от внешнего скрипта)
print_header() {
    echo "========================================"
    echo "$1"
    echo "========================================"
}

print_info() {
    echo "[INFO] $1"
}

print_success() {
    echo "[OK] $1"
}

# Локаль
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Время
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

# Hostname
read -p "Введите имя компьютера (hostname): " HOSTNAME
echo "$HOSTNAME" > /etc/hostname

cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# Пароль root
print_header "Установка пароля root"
passwd

# Создание пользователя
read -p "Введите имя пользователя: " USERNAME
useradd -m -G wheel,audio,video,optical,storage -s /bin/bash "$USERNAME"
echo "Установите пароль для $USERNAME:"
passwd "$USERNAME"

# Sudo
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# Загрузчик (GRUB)
pacman -S --noconfirm grub efibootmgr os-prober
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Сервисы
systemctl enable NetworkManager

# Микрокод
CPU_VENDOR=$(grep vendor_id /proc/cpuinfo | head -n1 | awk '{print $3}')
if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
    pacman -S --noconfirm intel-ucode
elif [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
    pacman -S --noconfirm amd-ucode
fi

# Перегенерация GRUB с микрокодом
grub-mkconfig -o /boot/grub/grub.cfg

# Сохраняем имя пользователя для следующего скрипта
echo "$USERNAME" > /root/.install_username

print_success "Настройка chroot завершена!"
CHROOT_EOF

chmod +x /mnt/root/chroot_setup.sh

# Запускаем скрипт внутри chroot
arch-chroot /mnt /root/chroot_setup.sh

print_success "Базовая система настроена"

# ============================================
# Установка Hyprland и окружения (внутри chroot)
# ============================================
print_header "Установка Hyprland и окружения"

# Получаем имя пользователя
USERNAME=$(cat /mnt/root/.install_username 2>/dev/null || ls /mnt/home | head -n1)

# Создаем скрипт для Hyprland - ВСЕ функции встроены!
cat > /mnt/root/hyprland_setup.sh << HYPR_EOF
#!/bin/bash
set -e

# Встроенные функции
print_header() {
    echo "========================================"
    echo "$1"
    echo "========================================"
}

print_info() {
    echo "[INFO] $1"
}

print_success() {
    echo "[OK] $1"
}

print_warning() {
    echo "[WARN] $1"
}

# Получаем имя пользователя
USERNAME=$(cat /root/.install_username 2>/dev/null || ls /home | head -n1)
USER_HOME="/home/\$USERNAME"

print_header "Обновление системы"
pacman -Syu --noconfirm

print_header "Установка Hyprland"
pacman -S --noconfirm hyprland waybar wofi kitty mako polkit-gnome \
    pipewire pipewire-pulse pipewire-jack wireplumber pavucontrol \
    thunar thunar-archive-plugin gvfs gvfs-mtp ttf-jetbrains-mono-nerd \
    noto-fonts noto-fonts-cjk noto-fonts-emoji \
    xdg-desktop-portal-hyprland grim slurp wl-clipboard \
    swww hyprpaper brightnessctl pamixer \
    zsh zsh-completions zsh-syntax-highlighting zsh-autosuggestions \
    git curl wget neovim firefox \
    papirus-icon-theme \
    xdg-user-dirs sddm

# Создание стандартных папок
su - "\$USERNAME" -c "xdg-user-dirs-update"

# AUR Helper (yay)
print_header "Установка yay (AUR helper)"
su - "\$USERNAME" -c "cd /tmp && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm"

# Установка пакетов из AUR
print_header "Установка пакетов из AUR"
su - "\$USERNAME" -c "yay -S --noconfirm rofi-lbonn-wayland catppuccin-gtk-theme-mocha \
    bibata-cursor-theme-bin swaylock-effects wlogout sddm-catppuccin-git"

# SDDM (менеджер входа)
print_header "Настройка SDDM"
pacman -S --noconfirm sddm
systemctl enable sddm

# Настройка PipeWire
print_info "Настройка PipeWire..."
su - "\$USERNAME" -c "systemctl --user enable pipewire pipewire-pulse"

print_success "Hyprland установлен"
HYPR_EOF

chmod +x /mnt/root/hyprland_setup.sh
arch-chroot /mnt /root/hyprland_setup.sh

# ============================================
# Создание конфигов Hyprland
# ============================================
print_header "Создание конфигурационных файлов"

USERNAME=$(cat /mnt/root/.install_username 2>/dev/null || ls /mnt/home | head -n1)
USER_HOME="/mnt/home/$USERNAME"
CONFIG_DIR="$USER_HOME/.config"

mkdir -p "$CONFIG_DIR/hypr"
mkdir -p "$CONFIG_DIR/waybar"
mkdir -p "$CONFIG_DIR/kitty"
mkdir -p "$CONFIG_DIR/wofi"
mkdir -p "$CONFIG_DIR/mako"
mkdir -p "$CONFIG_DIR/swww"
mkdir -p "$USER_HOME/.local/share/fonts"
mkdir -p "$USER_HOME/Pictures/wallpapers"
mkdir -p "$USER_HOME/.themes"
mkdir -p "$USER_HOME/.icons"

# Hyprland config
cat > "$CONFIG_DIR/hypr/hyprland.conf" << 'EOF'
# ============================================
# Hyprland Config - Auto-generated
# ============================================

# Монитор
monitor=,preferred,auto,auto

# Программы по умолчанию
$terminal = kitty
$menu = wofi --show drun
$fileManager = thunar
$browser = firefox

# Автозапуск
exec-once = waybar & mako & swww init & polkit-gnome-authentication-agent-1 & nm-applet
exec-once = swww img ~/Pictures/wallpapers/wallpaper.jpg

# Ввод
input {
    kb_layout = us,ru
    kb_options = grp:alt_shift_toggle
    follow_mouse = 1
    sensitivity = 0
    touchpad {
        natural_scroll = true
        clickfinger_behavior = true
    }
}

general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(89b4faff) rgba(b4befeff) 45deg
    col.inactive_border = rgba(595959aa)
    layout = dwindle
    allow_tearing = false
}

decoration {
    rounding = 12
    blur {
        enabled = true
        size = 6
        passes = 2
        new_optimizations = true
    }
    shadow {
        enabled = true
        range = 15
        render_power = 3
        color = rgba(1a1a1aee)
    }
}

animations {
    enabled = true
    bezier = myBezier, 0.05, 0.9, 0.1, 1.05
    animation = windows, 1, 7, myBezier
    animation = windowsOut, 1, 7, default, popin 80%
    animation = border, 1, 10, default
    animation = fade, 1, 7, default
    animation = workspaces, 1, 6, default
}

dwindle {
    pseudotile = true
    preserve_split = true
}

master {
    new_status = master
}

gestures {
    workspace_swipe = true
    workspace_swipe_fingers = 3
}

misc {
    force_default_wallpaper = 0
    disable_hyprland_logo = true
}

# Клавиши
$mainMod = SUPER

# Основные
bind = $mainMod, Return, exec, $terminal
bind = $mainMod, Q, killactive
bind = $mainMod, M, exit
bind = $mainMod, E, exec, $fileManager
bind = $mainMod, B, exec, $browser
bind = $mainMod, V, togglefloating
bind = $mainMod, R, exec, $menu
bind = $mainMod, P, pseudo
bind = $mainMod, J, togglesplit
bind = $mainMod, F, fullscreen
bind = $mainMod SHIFT, F, exec, hyprctl dispatch fullscreenstate 2

# Фокус
bind = $mainMod, left, movefocus, l
bind = $mainMod, right, movefocus, r
bind = $mainMod, up, movefocus, u
bind = $mainMod, down, movefocus, d

# Перемещение окон
bind = $mainMod SHIFT, left, movewindow, l
bind = $mainMod SHIFT, right, movewindow, r
bind = $mainMod SHIFT, up, movewindow, u
bind = $mainMod SHIFT, down, movewindow, d

# Рабочие столы
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

# Перемещение окон на рабочие столы
bind = $mainMod SHIFT, 1, movetoworkspace, 1
bind = $mainMod SHIFT, 2, movetoworkspace, 2
bind = $mainMod SHIFT, 3, movetoworkspace, 3
bind = $mainMod SHIFT, 4, movetoworkspace, 4
bind = $mainMod SHIFT, 5, movetoworkspace, 5
bind = $mainMod SHIFT, 6, movetoworkspace, 6
bind = $mainMod SHIFT, 7, movetoworkspace, 7
bind = $mainMod SHIFT, 8, movetoworkspace, 8
bind = $mainMod SHIFT, 9, movetoworkspace, 9
bind = $mainMod SHIFT, 0, movetoworkspace, 10

# Специальные рабочие столы
bind = $mainMod, S, togglespecialworkspace, magic
bind = $mainMod SHIFT, S, movetoworkspace, special:magic

# Скриншоты (grim + slurp вместо grimblast)
bind = $mainMod SHIFT, S, exec, grim -g "$(slurp)" - | wl-copy
bind = $mainMod, Print, exec, grim ~/Pictures/screenshot-$(date +%Y%m%d-%H%M%S).png

# Громкость/яркость
bindel = ,XF86AudioRaiseVolume, exec, pamixer -i 5
bindel = ,XF86AudioLowerVolume, exec, pamixer -d 5
bindel = ,XF86AudioMute, exec, pamixer -t
bindel = ,XF86AudioMicMute, exec, pamixer --default-source -t
bindel = ,XF86MonBrightnessUp, exec, brightnessctl s +5%
bindel = ,XF86MonBrightnessDown, exec, brightnessctl s 5%-

# Медиа клавиши
bindl = ,XF86AudioPlay, exec, playerctl play-pause
bindl = ,XF86AudioNext, exec, playerctl next
bindl = ,XF86AudioPrev, exec, playerctl previous

# Блокировка экрана
bind = $mainMod, L, exec, swaylock --clock --effect-blur 7x5

# Выход из системы
bind = $mainMod SHIFT, E, exec, wlogout

# Ресайз
bind = $mainMod, R, submap, resize
submap = resize
binde = , right, resizeactive, 10 0
binde = , left, resizeactive, -10 0
binde = , up, resizeactive, 0 -10
binde = , down, resizeactive, 0 10
bind = , escape, submap, reset
submap = reset

# Правила окон
windowrulev2 = float,class:^(pavucontrol)$
windowrulev2 = size 800 600,class:^(pavucontrol)$
windowrulev2 = float,class:^(nm-connection-editor)$
windowrulev2 = float,class:^(wlogout)$
windowrulev2 = fullscreen,class:^(wlogout)$
windowrulev2 = float,title:^(Picture-in-Picture)$
windowrulev2 = pin,title:^(Picture-in-Picture)$
windowrulev2 = float,class:^(blueman-manager)$
EOF

# Waybar config
cat > "$CONFIG_DIR/waybar/config" << 'EOF'
{
    "layer": "top",
    "position": "top",
    "height": 36,
    "spacing": 4,
    "modules-left": ["hyprland/workspaces", "hyprland/window"],
    "modules-center": ["clock"],
    "modules-right": ["tray", "cpu", "memory", "pulseaudio", "network", "battery", "custom/power"],

    "hyprland/workspaces": {
        "format": "{name}",
        "format-icons": {
            "1": "1",
            "2": "2",
            "3": "3",
            "4": "4",
            "5": "5",
            "active": "",
            "default": ""
        },
        "persistent-workspaces": {
            "*": 5
        }
    },

    "hyprland/window": {
        "format": "{title}",
        "max-length": 50,
        "separate-outputs": true
    },

    "clock": {
        "format": "{:%H:%M | %d.%m.%Y}",
        "tooltip-format": "<big>{:%Y %B}</big>\n<tt>{calendar}</tt>",
        "calendar": {
            "mode": "year",
            "mode-mon-col": 3,
            "weeks-pos": "right",
            "on-scroll": 1,
            "format": {
                "months": "<span color='#cdd6f4'><b>{}</b></span>",
                "days": "<span color='#a6adc8'><b>{}</b></span>",
                "weeks": "<span color='#89b4fa'><b>W{}</b></span>",
                "weekdays": "<span color='#f9e2af'><b>{}</b></span>",
                "today": "<span color='#f38ba8'><b><u>{}</u></b></span>"
            }
        }
    },

    "cpu": {
        "format": " {usage}%",
        "tooltip": true,
        "interval": 2
    },

    "memory": {
        "format": " {}%",
        "tooltip-format": "{used:0.1f}GB / {total:0.1f}GB",
        "interval": 2
    },

    "battery": {
        "states": {
            "warning": 30,
            "critical": 15
        },
        "format": "{icon} {capacity}%",
        "format-charging": " {capacity}%",
        "format-plugged": " {capacity}%",
        "format-icons": ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
    },

    "network": {
        "format-wifi": "󰤨 {essid}",
        "format-ethernet": "󰈀 {ipaddr}",
        "format-disconnected": "󰤭 Offline",
        "tooltip-format": "{ifname} via {gwaddr}",
        "tooltip-format-wifi": "{essid} ({signalStrength}%)\n{ipaddr}/{cidr}",
        "tooltip-format-ethernet": "{ipaddr}/{cidr}",
        "tooltip-format-disconnected": "Disconnected"
    },

    "pulseaudio": {
        "format": "{icon} {volume}%",
        "format-muted": "󰖁 Muted",
        "format-icons": {
            "headphone": "",
            "hands-free": "",
            "headset": "",
            "phone": "",
            "portable": "",
            "car": "",
            "default": ["󰕿", "󰖀", "󰕾"]
        },
        "on-click": "pavucontrol"
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
cat > "$CONFIG_DIR/waybar/style.css" << 'EOF'
* {
    font-family: "JetBrainsMono Nerd Font", "Font Awesome 6 Free", sans-serif;
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
    border-bottom: 2px solid rgba(137, 180, 250, 0.3);
}

#workspaces {
    margin: 4px 4px;
    padding: 0 4px;
}

#workspaces button {
    padding: 0 10px;
    margin: 2px 2px;
    color: #cdd6f4;
    border-radius: 8px;
    transition: all 0.3s ease;
}

#workspaces button.active {
    background-color: #89b4fa;
    color: #1e1e2e;
    font-weight: bold;
}

#workspaces button:hover {
    background-color: #313244;
    color: #f5e0dc;
}

#workspaces button.urgent {
    background-color: #f38ba8;
    color: #1e1e2e;
}

#window {
    color: #a6adc8;
    padding: 0 12px;
}

#clock, #cpu, #memory, #battery, #network, #pulseaudio, #custom-power {
    padding: 0 12px;
    margin: 4px 2px;
    border-radius: 8px;
    background-color: #313244;
    color: #cdd6f4;
    transition: all 0.3s ease;
}

#clock {
    background-color: #89b4fa;
    color: #1e1e2e;
    font-weight: bold;
}

#cpu {
    background-color: #f9e2af;
    color: #1e1e2e;
}

#memory {
    background-color: #a6e3a1;
    color: #1e1e2e;
}

#battery {
    background-color: #a6e3a1;
    color: #1e1e2e;
}

#battery.warning {
    background-color: #f9e2af;
}

#battery.critical {
    background-color: #f38ba8;
    color: #1e1e2e;
}

#network {
    background-color: #cba6f7;
    color: #1e1e2e;
}

#network.disconnected {
    background-color: #313244;
    color: #cdd6f4;
}

#pulseaudio {
    background-color: #89dceb;
    color: #1e1e2e;
}

#pulseaudio.muted {
    background-color: #313244;
    color: #cdd6f4;
}

#custom-power {
    background-color: #f38ba8;
    color: #1e1e2e;
    font-size: 16px;
    padding: 0 14px;
}

#custom-power:hover {
    background-color: #eba0ac;
}

#tray {
    margin: 4px 4px;
    padding: 0 8px;
}

#tray > .passive {
    -gtk-icon-effect: dim;
}

#tray > .needs-attention {
    -gtk-icon-effect: highlight;
    background-color: #f38ba8;
}
EOF

# Kitty config
cat > "$CONFIG_DIR/kitty/kitty.conf" << 'EOF'
# ============================================
# Kitty Config - Catppuccin Mocha
# ============================================

font_family JetBrainsMono Nerd Font
font_size 11.0
bold_font auto
italic_font auto
bold_italic_font auto

# Прозрачность
background_opacity 0.95
background #1e1e2e
foreground #cdd6f4
selection_background #353749
selection_foreground #cdd6f4
cursor #f5e0dc
cursor_text_color #1e1e2e

# Цвета (Catppuccin Mocha)
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

# Прокрутка
scrollback_lines 10000
wheel_scroll_multiplier 5.0

# Курсор
cursor_shape beam
cursor_blink_interval 0.5
cursor_stop_blinking_after 15.0

# Окно
window_padding_width 8
remember_window_size yes
initial_window_width 100c
initial_window_height 30c
hide_window_decorations no

# Табы
tab_bar_edge top
tab_bar_style powerline
tab_powerline_style slanted
tab_title_template {title}{' :{}:'.format(num_windows) if num_windows > 1 else ''}
active_tab_background #89b4fa
active_tab_foreground #1e1e2e
inactive_tab_background #313244
inactive_tab_foreground #cdd6f4

# URL
url_color #89b4fa
url_style curly
open_url_modifiers kitty_mod
open_url_with default

# Копирование
strip_trailing_spaces smart
enable_audio_bell no
visual_bell_duration 0.0

# Клавиши
kitty_mod ctrl+shift
map kitty_mod+c copy_to_clipboard
map kitty_mod+v paste_from_clipboard
map kitty_mod+up scroll_line_up
map kitty_mod+down scroll_line_down
map kitty_mod+page_up scroll_page_up
map kitty_mod+page_down scroll_page_down
map kitty_mod+home scroll_home
map kitty_mod+end scroll_end
map kitty_mod+t new_tab
map kitty_mod+q close_tab
map kitty_mod+right next_tab
map kitty_mod+left previous_tab
EOF

# Wofi config
cat > "$CONFIG_DIR/wofi/config" << 'EOF'
width=500
height=400
location=center
show=drun
prompt=Search...
filter_rate=100
allow_markup=true
no_actions=true
halign=fill
orientation=vertical
content_halign=fill
insensitive=true
allow_images=true
image_size=32
EOF

# Wofi style
cat > "$CONFIG_DIR/wofi/style.css" << 'EOF'
window {
    margin: 0px;
    border: 2px solid #89b4fa;
    border-radius: 16px;
    background-color: #1e1e2e;
    font-family: "JetBrainsMono Nerd Font";
}

#input {
    margin: 12px;
    padding: 8px 16px;
    border: none;
    border-radius: 12px;
    color: #cdd6f4;
    background-color: #313244;
    font-size: 14px;
}

#input:focus {
    border: 2px solid #89b4fa;
}

#inner-box {
    margin: 8px;
    border: none;
    background-color: transparent;
}

#outer-box {
    margin: 8px;
    border: none;
    background-color: transparent;
}

#scroll {
    margin: 0px;
    border: none;
}

#text {
    margin: 4px;
    border: none;
    color: #cdd6f4;
    font-size: 13px;
}

#entry {
    margin: 4px 8px;
    padding: 8px;
    border-radius: 10px;
    background-color: transparent;
}

#entry:selected {
    background-color: #313244;
    border: 1px solid #89b4fa;
}

#entry:selected #text {
    color: #89b4fa;
    font-weight: bold;
}

#img {
    margin-right: 12px;
}
EOF

# Mako config
cat > "$CONFIG_DIR/mako/config" << 'EOF'
# Mako Notification Daemon Config
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
icon-path=/usr/share/icons/hicolor
max-icon-size=48
layer=overlay
anchor=top-right

[urgency=low]
border-color=#a6e3a1

[urgency=normal]
border-color=#89b4fa

[urgency=critical]
border-color=#f38ba8
background-color=#313244
default-timeout=0
EOF

# Wlogout config
cat > "$CONFIG_DIR/wlogout/layout" << 'EOF'
{
    "label" : "lock",
    "action" : "swaylock --clock --effect-blur 7x5",
    "text" : "Lock",
    "keybind" : "l"
}
{
    "label" : "logout",
    "action" : "hyprctl dispatch exit",
    "text" : "Logout",
    "keybind" : "e"
}
{
    "label" : "suspend",
    "action" : "systemctl suspend",
    "text" : "Suspend",
    "keybind" : "u"
}
{
    "label" : "reboot",
    "action" : "systemctl reboot",
    "text" : "Reboot",
    "keybind" : "r"
}
{
    "label" : "shutdown",
    "action" : "systemctl poweroff",
    "text" : "Shutdown",
    "keybind" : "s"
}
EOF

# Wlogout style
cat > "$CONFIG_DIR/wlogout/style.css" << 'EOF'
* {
    font-family: "JetBrainsMono Nerd Font", sans-serif;
    font-size: 16px;
    background-image: none;
    transition: 20ms;
    box-shadow: none;
}

window {
    background-color: rgba(30, 30, 46, 0.85);
}

button {
    color: #cdd6f4;
    background-color: #313244;
    border: 2px solid #45475a;
    border-radius: 16px;
    background-repeat: no-repeat;
    background-position: center;
    background-size: 25%;
    margin: 16px;
    padding: 32px;
    min-width: 120px;
    min-height: 120px;
}

button:focus, button:active, button:hover {
    background-color: #89b4fa;
    color: #1e1e2e;
    border-color: #89b4fa;
    outline-style: none;
}

#lock {
    background-image: image(url("/usr/share/wlogout/icons/lock.png"), url("/usr/local/share/wlogout/icons/lock.png"));
}

#logout {
    background-image: image(url("/usr/share/wlogout/icons/logout.png"), url("/usr/local/share/wlogout/icons/logout.png"));
}

#suspend {
    background-image: image(url("/usr/share/wlogout/icons/suspend.png"), url("/usr/local/share/wlogout/icons/suspend.png"));
}

#reboot {
    background-image: image(url("/usr/share/wlogout/icons/reboot.png"), url("/usr/local/share/wlogout/icons/reboot.png"));
}

#shutdown {
    background-image: image(url("/usr/share/wlogout/icons/shutdown.png"), url("/usr/local/share/wlogout/icons/shutdown.png"));
}
EOF

# Zsh config
cat > "$USER_HOME/.zshrc" << 'EOF'
# ============================================
# Zsh Config
# ============================================

# Путь
export PATH="$HOME/.local/bin:$PATH"

# Тема и плагины
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh

# Приглашение (Starship-like)
autoload -Uz vcs_info
precmd() { vcs_info }

zstyle ':vcs_info:git:*' formats '%F{blue}(%b)%f '
zstyle ':vcs_info:*' enable git

setopt PROMPT_SUBST
PROMPT='%F{cyan}%~%f ${vcs_info_msg_0_}%F{green}❯%f '

# История
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE

# Автодополнение
autoload -Uz compinit
compinit

# Клавиши
bindkey "^[[A" history-search-backward
bindkey "^[[B" history-search-forward
bindkey "^[[H" beginning-of-line
bindkey "^[[F" end-of-line
bindkey "^[[3~" delete-char

# Алиасы
alias ls='ls --color=auto'
alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias update='sudo pacman -Syu'
alias install='sudo pacman -S'
alias remove='sudo pacman -Rns'
alias search='pacman -Ss'
alias cls='clear'

# Переменные окружения
export EDITOR=nvim
export VISUAL=nvim
export BROWSER=firefox
export TERMINAL=kitty

# Wayland
export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM=wayland
export SDL_VIDEODRIVER=wayland
export _JAVA_AWT_WM_NONREPARENTING=1

# NVM (если установите Node.js позже)
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
EOF

# Установка zsh по умолчанию
chroot /mnt chsh -s /bin/zsh "$USERNAME"

# Настройка GTK темы
cat > "$USER_HOME/.config/gtk-3.0/settings.ini" << 'EOF'
[Settings]
gtk-theme-name=Catppuccin-Mocha
gtk-icon-theme-name=Papirus-Dark
gtk-cursor-theme-name=Bibata-Modern-Ice
gtk-font-name=JetBrainsMono Nerd Font 11
gtk-application-prefer-dark-theme=1
EOF

mkdir -p "$USER_HOME/.config/gtk-4.0"
cp "$USER_HOME/.config/gtk-3.0/settings.ini" "$USER_HOME/.config/gtk-4.0/settings.ini"

# Настройка прав
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.local"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.zshrc"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.themes"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.icons"

# ============================================
# Загрузка обоев
# ============================================
print_info "Загрузка обоев..."

if command -v curl &> /dev/null; then
    curl -L -o "$USER_HOME/Pictures/wallpapers/wallpaper.jpg" \
        "https://raw.githubusercontent.com/catppuccin/wallpapers/main/misc/gradient-blue.png" 2>/dev/null || true
fi

chown -R "$USERNAME:$USERNAME" "$USER_HOME/Pictures"

# ============================================
# Финализация
# ============================================
print_header "Финализация установки"

# Очистка
rm -f /mnt/root/chroot_setup.sh
rm -f /mnt/root/hyprland_setup.sh
rm -f /mnt/root/.install_username

# Размонтирование
umount -R /mnt

print_success "========================================"
print_success "УСТАНОВКА ЗАВЕРШЕНА!"
print_success "========================================"
echo ""
print_info "Что дальше:"
echo "  1. Перезагрузите компьютер: reboot"
echo "  2. Извлеките установочную флешку"
echo "  3. Войдите через SDDM"
echo "  4. Наслаждайтесь Hyprland!"
echo ""
print_info "Горячие клавиши:"
echo "  SUPER + Enter  - Терминал (Kitty)"
echo "  SUPER + R      - Меню приложений (Wofi)"
echo "  SUPER + Q      - Закрыть окно"
echo "  SUPER + F      - Полный экран"
echo "  SUPER + L      - Блокировка экрана"
echo "  SUPER + Shift + E - Выход (Wlogout)"
echo "  SUPER + 1-9    - Рабочие столы"
echo "  SUPER + Shift + 1-9 - Переместить окно"
echo ""
print_info "Для настройки: редактируйте ~/.config/hypr/hyprland.conf"
