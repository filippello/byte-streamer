# Imagen del pod streamer: todo lo determinista horneado.
#
# Sale de runpod/base A PROPOSITO: esa imagen es la que levanta sshd e instala
# la PUBLIC_KEY que manda rp_create.py. Si cambiamos de base hay que rehacer
# todo eso a mano y el pod queda sin SSH.
#
# Lo que NO se hornea y por que:
#   - los scripts de pod/: cambian todo el tiempo y pesan nada. Siguen yendo
#     por scp en cada `up`, asi editarlos no obliga a rebuildear la imagen.
#   - el perfil de Chrome y las claves RTMP: son secretos. Una imagen publica
#     en ghcr NO puede tener nada de eso adentro.
#   - el driver NVIDIA: la version de userspace tiene que coincidir con el
#     modulo de kernel del host y cada host trae otra. Ver ARG NVIDIA_DRIVERS
#     mas abajo para el cache opcional.
FROM runpod/base:1.1.0-ubuntu2404

ENV DEBIAN_FRONTEND=noninteractive

# Misma lista que tenia pod-setup.sh. Aca corre una sola vez, en el build.
RUN apt-get update && apt-get install -y --no-install-recommends \
      xvfb x11-utils xdotool imagemagick pulseaudio pulseaudio-utils ffmpeg \
      wget curl ca-certificates gnupg kmod libglvnd-dev pkg-config dbus dbus-x11 \
      fonts-liberation fonts-noto-color-emoji python3-pip \
      libnss3 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libdrm2 \
      libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
      libgbm1 libasound2t64 libpango-1.0-0 libcairo2 libvulkan1 mesa-utils \
    && rm -rf /var/lib/apt/lists/*

RUN wget -q -O /tmp/chrome.deb \
      https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/chrome.deb \
    && rm -f /tmp/chrome.deb && rm -rf /var/lib/apt/lists/*

RUN pip install --quiet --break-system-packages websocket-client

# Cache opcional de instaladores del driver. Vacio por defecto: cada version
# son ~400 MB de imagen y todavia no medimos cuanto pesa realmente la descarga
# en el arranque. Cuando `setup.log` diga que ahi se va el tiempo, se agregan
# las versiones que vimos en campo:
#   --build-arg NVIDIA_DRIVERS="580.95.05 575.57.08"
ARG NVIDIA_DRIVERS=""
RUN mkdir -p /opt/nvidia-cache && for v in $NVIDIA_DRIVERS; do \
      f="NVIDIA-Linux-x86_64-${v}.run"; \
      wget -q "https://us.download.nvidia.com/XFree86/Linux-x86_64/${v}/${f}" \
           -O "/opt/nvidia-cache/${f}" \
        || wget -q "https://download.nvidia.com/XFree86/Linux-x86_64/${v}/${f}" \
           -O "/opt/nvidia-cache/${f}" \
        || { echo "no se pudo bajar el driver ${v}"; exit 1; }; \
      chmod +x "/opt/nvidia-cache/${f}"; \
    done

# La marca que lee pod-setup.sh para saltearse todo lo de arriba.
RUN touch /root/IMAGE_BAKED

LABEL org.opencontainers.image.source=https://github.com/filippello/byte-streamer
LABEL org.opencontainers.image.description="Pod streamer de byte: Chrome + Xvfb + PulseAudio + ffmpeg horneados"
