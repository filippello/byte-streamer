#!/bin/bash
# Examen del host, antes de confiarle una transmision.
#
# Por que existe: RunPod no deja elegir maquina, solo tipo de GPU y datacenter,
# asi que no se puede "tomar siempre un host bueno" — lo que si se puede es
# DESCARTAR RAPIDO los malos. En unos 30 pods nos tocaron cinco defectuosos, y
# todos se descubrieron tarde, con el stream al aire o sin salir:
#
#   - sin libs graficas de NVIDIA -> Chrome cae a software, 1.4 fps
#   - renderer en llvmpipe        -> idem, aunque las libs esten
#   - Xvfb segfaultea por EGL     -> visto en un A6000 (driver 580.x)
#   - la sonda de NVENC SE CUELGA -> el 2026-10-15 dejo stream.sh trabado para
#                                     siempre; ningun destino abierto y desde
#                                     afuera parecia que X rechazaba la conexion
#
# Imprime APTO o "NO APTO: <motivo>" y sale 0 o 1. Quien lo llama decide si
# destruye el pod y pide otro.
#
# OJO con NVENC: que NO haya es aceptable (x264 anda bien y es lo que usamos la
# mitad de las veces). Lo que NO es aceptable es que la sonda se CUELGUE, porque
# eso traba el arranque entero. Por eso se mide si contesta, no si dice que si.
export DISPLAY=:1
fallas=()

# 1. Xvfb
if ! xdpyinfo -display :1 >/dev/null 2>&1; then
  fallas+=("Xvfb no responde")
fi

# 2. libs graficas de NVIDIA
LIBS=$(ls /usr/lib/x86_64-linux-gnu/ 2>/dev/null | grep -cE 'EGL_nvidia|GLX_nvidia')
if [ "${LIBS:-0}" -lt 2 ]; then
  fallas+=("sin libs graficas de NVIDIA (hay $LIBS) — Chrome iria por software")
fi

# 3. que Chrome dibuje por GPU de verdad
REND=$(timeout 40 python3 /opt/streamer/cdp.py eval \
  '(()=>{const c=document.createElement("canvas");const g=c.getContext("webgl2")||c.getContext("webgl");if(!g)return "NO WEBGL";const d=g.getExtension("WEBGL_debug_renderer_info");return d?g.getParameter(d.UNMASKED_RENDERER_WEBGL):g.getParameter(g.RENDERER);})()' 2>/dev/null | tr -d '"')
case "$REND" in
  *NVIDIA*) : ;;
  "")       fallas+=("no pude leer el renderer (CDP mudo)") ;;
  *)        fallas+=("renderer sin GPU: $REND") ;;
esac

# 4. la sonda de NVENC CONTESTA (diga lo que diga)
t0=$(date +%s)
timeout -k 5 25 ffmpeg -hide_banner -loglevel error -f lavfi \
  -i testsrc=size=320x240:rate=30 -t 1 -c:v h264_nvenc -f null - >/dev/null 2>&1
rc=$?
t1=$(date +%s)
dur=$(( t1 - t0 ))
# 124/137 = la mato el timeout: quedo trabada en el driver.
if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
  fallas+=("la sonda de NVENC se colgo (${dur}s) — este host traba el arranque")
elif [ "$rc" -eq 0 ]; then
  echo "nvenc: si (${dur}s)"
else
  echo "nvenc: no, se usara x264 (${dur}s, rc=$rc)"
fi

echo "renderer: ${REND:-?}"
echo "libs graficas: $LIBS"

if [ "${#fallas[@]}" -eq 0 ]; then
  echo "APTO"
  exit 0
fi
printf 'NO APTO: %s\n' "${fallas[0]}"
for f in "${fallas[@]:1}"; do printf '          + %s\n' "$f"; done
exit 1
