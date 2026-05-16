#!/bin/bash
# ============================================
# Arch + Hyprland - Дозапуск установки
# ============================================
# Запускать ВНУТРИ arch-chroot /mnt
# ИЛИ с Live USB: arch-chroot /mnt /root/finish_install.sh

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
# Проверка что мы в chroot
# ============================================
if [[ ! -f /etc/arch-release ]]; then
    print_error "Этот скрипт должен запускаться ВНУТРИ chroot!"
    print_info "Выполните: arch-chroot /mnt"
    exit 1
fi

# ============================================
# Создание пользователя
# ============================================
print_header "Создание пользователя"

# Проверяем есть ли уже пользователи
EXISTING_USER=$(ls /home 2>/dev/null | head -n1)

if [[ -n "$EXISTING_USER" && -d "/home/$EXISTING_USER" ]]; then
    print_info "Найден существующий пользователь: $EXISTING_USER"
    read -p "Использовать этого пользователя? (yes/no): " USE_EXISTING
    if [[ "$USE_EXISTING" == "yes" ]]; then
        USERNAME="$EXISTING_USER"
    else
        read -p "Введите имя нового пользователя: " USERNAME
        useradd -m -G wheel,audio,video,optical,storage -s /bin/bash "$USERNAME"
        echo "Установите пароль для $USERNAME:"
        passwd "$USERNAME"
    fi
else
    read -p "Введите имя пользователя: " USERNAME
    useradd -m -G wheel,audio,video,optical,storage -s /bin/bash "$USERNAME"
    echo "Установите пароль для $USERNAME:"
    passwd "$USERNAME"
fi

print_success "Пользователь $USERNAME создан"

# ============================================
# Sudo
# ============================================
print_header "Настройка sudo"
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel
print_success "Sudo настроен"

# ============================================
# AUR Helper (yay)
# ============================================
print_header "Установка yay (AUR helper)"

if ! command -v yay &> /dev/null; then
    su - "$USERNAME" -c "cd /tmp && rm -rf yay && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm"
    print_success "yay установлен"
else
    print_success "yay уже установлен"
fi

# ============================================
# AUR пакеты
# ============================================
print_header "Установка AUR пакетов"

su - "$USERNAME" -c "yay -S --noconfirm rofi-lbonn-wayland catppuccin-gtk-theme-mocha bibata-cursor-theme-bin swaylock-effects wlogout sddm-catppuccin-git"

print_success "AUR пакеты установлены"

# ============================================
# SDDM
# ============================================
print_header "Настройка SDDM"

if ! systemctl is-enabled sddm &>/dev/null; then
    systemctl enable sddm
fi

print_success "SDDM настроен"

# ============================================
# PipeWire
# ============================================
print_header "Настройка PipeWire"

su - "$USERNAME" -c "systemctl --user enable pipewire pipewire-pulse 2>/dev/null || true"

print_success "PipeWire настроен"

# ============================================
# Создание конфигов
# ============================================
print_header "Создание конфигурационных файлов"

USER_HOME="/home/$USERNAME"
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
mkdir -p "$USER_HOME/.config/gtk-3.0"
mkdir -p "$USER_HOME/.config/gtk-4.0"

# Hyprland config
cat > "$CONFIG_DIR/hypr/hyprland.conf" << 'EOF'
# ============================================
# Hyprland Config
# ============================================

monitor=,preferred,auto,auto

$terminal = kitty
$menu = wofi --show drun
$fileManager = thunar
$browser = firefox

exec-once = waybar & mako & swww init & polkit-gnome-authentication-agent-1 & nm-applet
exec-once = swww img ~/Pictures/wallpapers/wallpaper.jpg

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

$mainMod = SUPER

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

bind = $mainMod, left, movefocus, l
bind = $mainMod, right, movefocus, r
bind = $mainMod, up, movefocus, u
bind = $mainMod, down, movefocus, d

bind = $mainMod SHIFT, left, movewindow, l
bind = $mainMod SHIFT, right, movewindow, r
bind = $mainMod SHIFT, up, movewindow, u
bind = $mainMod SHIFT, down, movewindow, d

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

bind = $mainMod, S, togglespecialworkspace, magic
bind = $mainMod SHIFT, S, movetoworkspace, special:magic

bind = $mainMod SHIFT, S, exec, grim -g "$(slurp)" - | wl-copy
bind = $mainMod, Print, exec, grim ~/Pictures/screenshot-$(date +%Y%m%d-%H%M%S).png

bindel = ,XF86AudioRaiseVolume, exec, pamixer -i 5
bindel = ,XF86AudioLowerVolume, exec, pamixer -d 5
bindel = ,XF86AudioMute, exec, pamixer -t
bindel = ,XF86AudioMicMute, exec, pamixer --default-source -t
bindel = ,XF86MonBrightnessUp, exec, brightnessctl s +5%
bindel = ,XF86MonBrightnessDown, exec, brightnessctl s 5%-

bindl = ,XF86AudioPlay, exec, playerctl play-pause
bindl = ,XF86AudioNext, exec, playerctl next
bindl = ,XF86AudioPrev, exec, playerctl previous

bind = $mainMod, L, exec, swaylock --clock --effect-blur 7x5
bind = $mainMod SHIFT, E, exec, wlogout

bind = $mainMod, R, submap, resize
submap = resize
binde = , right, resizeactive, 10 0
binde = , left, resizeactive, -10 0
binde = , up, resizeactive, 0 -10
binde = , down, resizeactive, 0 10
bind = , escape, submap, reset
submap = reset

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
        "tooltip-format": "<big>{:%Y %B}</big>\n<tt>{calendar}</tt>"
    },

    "cpu": {
        "format": " {usage}%",
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
        "format-disconnected": "󰤭 Offline"
    },

    "pulseaudio": {
        "format": "{icon} {volume}%",
        "format-muted": "󰖁 Muted",
        "format-icons": {
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

#tray {
    margin: 4px 4px;
    padding: 0 8px;
}
EOF

# Kitty config
cat > "$CONFIG_DIR/kitty/kitty.conf" << 'EOF'
font_family JetBrainsMono Nerd Font
font_size 11.0
bold_font auto
italic_font auto
bold_italic_font auto

background_opacity 0.95
background #1e1e2e
foreground #cdd6f4
selection_background #353749
selection_foreground #cdd6f4
cursor #f5e0dc
cursor_text_color #1e1e2e

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

scrollback_lines 10000
wheel_scroll_multiplier 5.0

cursor_shape beam
cursor_blink_interval 0.5
cursor_stop_blinking_after 15.0

window_padding_width 8
remember_window_size yes
initial_window_width 100c
initial_window_height 30c
hide_window_decorations no

tab_bar_edge top
tab_bar_style powerline
tab_powerline_style slanted
active_tab_background #89b4fa
active_tab_foreground #1e1e2e
inactive_tab_background #313244
inactive_tab_foreground #cdd6f4

url_color #89b4fa
url_style curly

strip_trailing_spaces smart
enable_audio_bell no

kitty_mod ctrl+shift
map kitty_mod+c copy_to_clipboard
map kitty_mod+v paste_from_clipboard
map kitty_mod+t new_tab
map kitty_mod+q close_tab
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

#inner-box, #outer-box {
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
EOF

# Zsh config
cat > "$USER_HOME/.zshrc" << 'EOF'
export PATH="$HOME/.local/bin:$PATH"

source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh

autoload -Uz vcs_info
precmd() { vcs_info }

zstyle ':vcs_info:git:*' formats '%F{blue}(%b)%f '
zstyle ':vcs_info:*' enable git

setopt PROMPT_SUBST
PROMPT='%F{cyan}%~%f ${vcs_info_msg_0_}%F{green}❯%f '

HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE

autoload -Uz compinit
compinit

bindkey "^[[A" history-search-backward
bindkey "^[[B" history-search-forward
bindkey "^[[H" beginning-of-line
bindkey "^[[F" end-of-line
bindkey "^[[3~" delete-char

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

export EDITOR=nvim
export VISUAL=nvim
export BROWSER=firefox
export TERMINAL=kitty

export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM=wayland
export SDL_VIDEODRIVER=wayland
export _JAVA_AWT_WM_NONREPARENTING=1
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
if command -v curl &> /dev/null; then
    curl -L -o "$USER_HOME/Pictures/wallpapers/wallpaper.jpg" \
        "https://raw.githubusercontent.com/catppuccin/wallpapers/main/misc/gradient-blue.png" 2>/dev/null || true
fi

# Права
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.local"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.zshrc"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.themes"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.icons"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/Pictures"

# Zsh по умолчанию
chsh -s /bin/zsh "$USERNAME"

print_success "Конфиги созданы"

# ============================================
# Финализация
# ============================================
print_header "Финализация"

# Очистка
rm -f /root/chroot_setup.sh
rm -f /root/hyprland_setup.sh
rm -f /root/.install_username
rm -f /root/finish_install.sh

print_success "========================================"
print_success "УСТАНОВКА ЗАВЕРШЕНА!"
print_success "========================================"
echo ""
print_info "Что дальше:"
echo "  1. Выйдите из chroot: exit"
echo "  2. Размонтируйте: umount -R /mnt"
echo "  3. Перезагрузите: reboot"
echo "  4. Извлеките установочную флешку"
echo ""
print_info "Горячие клавиши:"
echo "  SUPER + Enter  - Терминал (Kitty)"
echo "  SUPER + R      - Меню приложений (Wofi)"
echo "  SUPER + Q      - Закрыть окно"
echo "  SUPER + F      - Полный экран"
echo "  SUPER + L      - Блокировка экрана"
echo "  SUPER + Shift + E - Выход (Wlogout)"
