#!/bin/bash
# Placa a pantalla completa para tapar la transicion entre juegos.
#
# Por que: cambiar de juego obliga a pasar por el dashboard, y eso son 36-40
# segundos de menu de seleccion al aire. Medido en la corrida del 2026-10-02:
# "19:28:12 redeployando" -> "19:28:48 al aire de nuevo".
#
# Por que una VENTANA APARTE y no un overlay en la pagina: el overlay vive en el
# DOM y la navegacion al dashboard lo destruye justo cuando hace falta. Esta es
# una segunda instancia de Chrome en kiosk, con su propio perfil para no tocar
# el perfil logueado, que se levanta encima y se cierra cuando la arena nueva ya
# cargo. ffmpeg captura la PANTALLA, asi que lo que tape la pantalla tapa el
# stream, sin reconectar nada.
#
# Uso:  placa.sh "Meme Kart"   prende la placa
#       placa.sh --off         la apaga
PERFIL=/root/chrome-placa
PAT="user-data-dir=$PERFIL"

if [ "${1:-}" = "--off" ]; then
  pkill -f "$PAT" 2>/dev/null
  exit 0
fi

TXT="${1:-...}"
python3 - "$TXT" <<'PY'
import html, sys
t = html.escape(sys.argv[1])
open("/root/placa.html", "w").write("""<!doctype html><meta charset=utf-8>
<style>
 html,body{margin:0;height:100%%;background:#000;overflow:hidden}
 body{display:flex;flex-direction:column;align-items:center;justify-content:center;
      font-family:system-ui,sans-serif;color:#fff}
 .k{font-size:22px;letter-spacing:.42em;text-transform:uppercase;color:#7b7b8a;margin-bottom:28px}
 .j{font-size:76px;font-weight:700;letter-spacing:-.01em;text-align:center;padding:0 8vw}
 .p{margin-top:46px;display:flex;gap:10px}
 .p i{width:10px;height:10px;border-radius:50%%;background:#2e2e38;animation:b 1.4s infinite}
 .p i:nth-child(2){animation-delay:.2s} .p i:nth-child(3){animation-delay:.4s}
 @keyframes b{0%%,80%%{background:#2e2e38}40%%{background:#fff}}
</style>
<div class=k>a continuacion</div>
<div class=j>%s</div>
<div class=p><i></i><i></i><i></i></div>
""" % t)
PY

export DISPLAY=:1
pkill -f "$PAT" 2>/dev/null
sleep 1
nohup google-chrome-stable --user-data-dir="$PERFIL" --no-sandbox --test-type \
  --no-first-run --no-default-browser-check --disable-session-crashed-bubble \
  --kiosk --window-position=0,0 --window-size=1920,1080 \
  "file:///root/placa.html" >/root/placa.log 2>&1 &

# Esperar a que la ventana exista ANTES de devolver el control: si no, el que
# llama se va al dashboard mientras la placa todavia no tapo nada.
for i in $(seq 1 20); do
  sleep 1
  if xdotool search --class "chrome" >/dev/null 2>&1 && pgrep -f "$PAT" >/dev/null; then
    sleep 2; exit 0
  fi
done
echo "la placa no llego a levantarse" >&2
exit 1
