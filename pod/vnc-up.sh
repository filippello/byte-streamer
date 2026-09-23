#!/bin/bash
# Escritorio remoto para operar el pod a mano (ej: OAuth de Twitch).
# Escucha SOLO en localhost: se entra por tunel SSH, nunca expuesto a internet.
exec > /root/vnc-up.log 2>&1
set -x
apt-get install -y --no-install-recommends x11vnc novnc websockify openbox 2>/dev/null
pkill -f x11vnc; pkill -f websockify; sleep 2
export DISPLAY=:1
pgrep -f openbox >/dev/null || (openbox &)
sleep 2
# afinado para latencia alta (US -> AR): cachea regiones y usa hilos
x11vnc -display :1 -forever -shared -nopw -localhost -rfbport 5900 \
       -ncache 10 -ncache_cr -threads -wait 10 -defer 10 -noxdamage \
       -bg -o /root/x11vnc.log
sleep 3
setsid websockify --web=/usr/share/novnc 127.0.0.1:6080 127.0.0.1:5900 >/root/novnc.log 2>&1 &
sleep 4
echo "x11vnc=$(pgrep -c x11vnc) websockify=$(pgrep -c websockify)"
echo "OJO: openbox le saca el fullscreen a Chrome -> volver a mandar F11 despues"
