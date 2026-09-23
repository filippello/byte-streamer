#!/bin/bash
# Prepara el pod. Con la imagen horneada (docker/Dockerfile) esto es SOLO el
# driver NVIDIA; con runpod/base instala todo como siempre, asi el toolkit
# sigue andando si la imagen no esta disponible.
#
# El userspace del driver no se puede hornear de una: tiene que coincidir con el
# modulo de kernel del host y cada host trae otro. Lo que SI se puede es cachear
# los instaladores de las versiones que vemos seguido (ARG NVIDIA_DRIVERS).
#
# Los errores "Device or resource busy" del installer son normales.
set -x
exec > /root/setup.log 2>&1
ts(){ set +x; echo "### $(date -Is) $*"; set -x; }
export DEBIAN_FRONTEND=noninteractive
T0=$(date +%s)
ts "inicio"

DRV=$(head -1 /proc/driver/nvidia/version | sed -E 's/.*Module +([0-9.]+).*/\1/')
echo "DRIVER: $DRV"

if [ -f /root/IMAGE_BAKED ]; then
  ts "imagen horneada: me salteo apt + chrome + pip"
else
  ts "imagen sin hornear: instalando apt + chrome + pip"
  apt-get update
  apt-get install -y --no-install-recommends \
    xvfb x11-utils xdotool imagemagick pulseaudio pulseaudio-utils ffmpeg \
    wget curl ca-certificates gnupg kmod libglvnd-dev pkg-config dbus dbus-x11 \
    fonts-liberation fonts-noto-color-emoji python3-pip \
    libnss3 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libdrm2 \
    libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
    libgbm1 libasound2t64 libpango-1.0-0 libcairo2 libvulkan1 mesa-utils
  ts "apt listo"
  wget -q -O /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  apt-get install -y /tmp/chrome.deb && rm -f /tmp/chrome.deb
  pip install --quiet --break-system-packages websocket-client
  ts "chrome + pip listos"
fi

cd /root
RUN="NVIDIA-Linux-x86_64-${DRV}.run"
if [ -f "/opt/nvidia-cache/$RUN" ]; then
  SRC="/opt/nvidia-cache/$RUN"
  ts "driver $DRV: sale del cache de la imagen"
else
  ts "driver $DRV: NO esta en el cache, bajando"
  wget -q "https://us.download.nvidia.com/XFree86/Linux-x86_64/${DRV}/${RUN}" -O "/root/$RUN" \
    || wget -q "https://download.nvidia.com/XFree86/Linux-x86_64/${DRV}/${RUN}" -O "/root/$RUN"
  chmod +x "/root/$RUN"
  SRC="/root/$RUN"
  ts "driver bajado ($(du -h "/root/$RUN" | cut -f1))"
fi

"$SRC" --silent --no-kernel-module --no-questions --ui=none \
       --no-nouveau-check --no-nvidia-modprobe --no-rebuild-initramfs --install-libglvnd
ldconfig
rm -f "/root/$RUN"   # el del cache NO se toca
ts "driver instalado"

echo "=== libs ==="; ls /usr/lib/x86_64-linux-gnu/ | grep -cE 'EGL_nvidia|nvidia-encode'
touch /root/SETUP_DONE
ts "FIN — $(( $(date +%s) - T0 ))s en total"
