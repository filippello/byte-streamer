#!/bin/bash
# Escritorio remoto para operar el pod a mano (ej: OAuth de Twitch).
# Escucha SOLO en localhost: se entra por tunel SSH, nunca expuesto a internet.
exec > /root/vnc-up.log 2>&1
set -x
# La imagen horneada borra /var/lib/apt/lists, asi que sin un update previo este
# install falla entero. Antes el error se iba por 2>/dev/null y el script seguia
# como si nada: terminaba diciendo "websockify=0" y el tunel daba "Connection
# refused" sin ninguna pista. Ahora se ve y se verifica al final.
if ! command -v websockify >/dev/null || ! command -v x11vnc >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends x11vnc novnc websockify openbox
fi
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
# Lo que importa no es que los procesos existan, sino que el puerto escuche: es
# lo unico que prueba que el tunel va a andar.
if ss -ltn 2>/dev/null | grep -q '127.0.0.1:6080'; then
  echo "noVNC escuchando en 6080 — el tunel SSH ya entra"
else
  echo "NOVNC NO ESCUCHA EN 6080"; tail -5 /root/novnc.log 2>/dev/null; exit 1
fi
echo "OJO: openbox le saca el fullscreen a Chrome -> volver a mandar F11 despues"
