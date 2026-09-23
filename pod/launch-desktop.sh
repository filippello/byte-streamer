#!/bin/bash
# Chrome con el perfil YA LOGUEADO de byte. El pod actua como escritorio.
S=/root/desktop.status; : > "$S"; say(){ echo "$*" >> "$S"; }
pkill -9 -f 'opt/streamer/str' 2>/dev/null; sleep 2
for n in ffmpeg google-chrome Xvfb pulseaudio; do pkill -9 -f "$n" 2>/dev/null; done
sleep 4
export DISPLAY=:1
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
export __GLX_VENDOR_LIBRARY_NAME=nvidia
mkdir -p /run/dbus; dbus-daemon --system --fork 2>/dev/null
# El vendor de NVIDIA es para CHROME, no para el servidor X: si Xvfb hereda
# __EGL_VENDOR_LIBRARY_FILENAMES intenta inicializar GLX por libEGL_nvidia y en
# algunos drivers del host hace segfault (visto en A6000 / 580.x, "Caught signal
# 11" adentro de libEGL_nvidia.so.0). No alcanza con BORRAR la variable: glvnd
# igual enumera todos los vendors del directorio y vuelve a encontrar el de
# NVIDIA. Hay que apuntar a Mesa EXPLICITAMENTE, y solo para Xvfb. El GLX del
# servidor X por software no le quita nada a Chrome, que dibuja por EGL contra
# el device y sigue viendo la GPU (el renderer tiene que decir NVIDIA igual).
__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json \
__GLX_VENDOR_LIBRARY_NAME=mesa \
  Xvfb :1 -screen 0 1920x1080x24 -ac +extension GLX +render -noreset >/root/xvfb.log 2>&1 &
sleep 5
xdpyinfo -display :1 >/dev/null 2>&1 && say "XVFB OK" || { say "XVFB FALLO"; exit 1; }
pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1
pactl load-module module-null-sink sink_name=stream >/dev/null 2>&1
pactl set-default-sink stream >/dev/null 2>&1
# el perfil viene de otra maquina: sacar el lock o Chrome se niega
rm -f /root/chrome-profile/Singleton* 2>/dev/null
mkdir -p /root/chrome-profile/Default
python3 - <<'PY'
import json
p='/root/chrome-profile/Default/Preferences'
try: d=json.load(open(p))
except Exception: d={}
d.setdefault('translate',{})['enabled']=False
d.setdefault('intl',{})['accept_languages']='en-US,en'
d.setdefault('profile',{})['exit_type']='Normal'
json.dump(d,open(p,'w'))
PY
# --password-store=basic: asi se encriptaron las cookies en el origen
nohup google-chrome-stable --lang=en-US \
  --user-data-dir=/root/chrome-profile --password-store=basic \
  --remote-debugging-port=9222 --remote-allow-origins='*' \
  --no-sandbox --test-type --no-first-run --no-default-browser-check \
  --disable-search-engine-choice-screen --disable-session-crashed-bubble \
  --disable-infobars --disable-features=Translate,TranslateUI,InfobarsForPasswordManager \
  --autoplay-policy=no-user-gesture-required \
  --window-position=0,0 --window-size=1920,1080 --start-fullscreen \
  --use-gl=angle --use-angle=gl-egl --enable-gpu-rasterization --ignore-gpu-blocklist \
  "${START_URL:-https://app.bytearena.fun/}" >/root/chrome.log 2>&1 &
for i in $(seq 1 20); do sleep 3
  curl -s --max-time 4 http://127.0.0.1:9222/json/version >/dev/null 2>&1 && { say "CDP OK"; break; }; done
curl -s --max-time 4 http://127.0.0.1:9222/json/version >/dev/null 2>&1 || { say "CHROME FALLO"; tail -5 /root/chrome.log >> "$S"; exit 1; }
sleep 15
say "renderer: $(python3 /opt/streamer/cdp.py eval '(()=>{const c=document.createElement("canvas");const g=c.getContext("webgl2")||c.getContext("webgl");if(!g)return "NO WEBGL";const d=g.getExtension("WEBGL_debug_renderer_info");return d?g.getParameter(d.UNMASKED_RENDERER_WEBGL):g.getParameter(g.RENDERER);})()' 2>&1 | tail -1)"
say "url: $(python3 /opt/streamer/cdp.py eval 'location.href' 2>&1 | tail -1)"
say "logueado: $(python3 /opt/streamer/cdp.py eval '/log out|PROFILE/i.test(document.body.innerText)?"SI":"NO"' 2>&1 | tail -1)"
say FIN
