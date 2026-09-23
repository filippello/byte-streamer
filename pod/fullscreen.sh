#!/bin/bash
# Manda F11 a Chrome. Necesario despues de: navegar, o de levantar el VNC
# (openbox le saca el fullscreen y la barra de direcciones sale AL AIRE).
export DISPLAY=:1
W=$(xdotool search --onlyvisible --class chrome | head -1)
[ -z "$W" ] && { echo "no encuentro la ventana de chrome"; exit 1; }
xdotool windowactivate "$W"; sleep 2
xdotool key --window "$W" F11
sleep 4
echo "fullscreen enviado a $W"
