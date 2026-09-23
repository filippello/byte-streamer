#!/bin/bash
# Un ffmpeg INDEPENDIENTE por destino, cada uno con su propio loop de reintento.
#
# Antes esto era un solo ffmpeg con el muxer `tee`. Se cambio porque tee NO
# reintenta un slave caido y pump corta SIEMPRE la conexion a los ~35s (visto
# 4 de 4, con y sin pre-calentado): adentro de un tee eso lo dejaba afuera para
# siempre mientras los otros destinos seguian al aire, sin que se notara.
# Con un proceso por destino, el que se cae vuelve solo — que es exactamente el
# caso de un destino unico, el unico que ya sabemos que aguanta horas en pump.
#
# Cuesta un encode por destino en vez de uno solo. Da lo mismo: el pod tiene
# 256 cores al 97% idle y un 720p30 x264 veryfast va a speed=1x con uno.
# El premio: cada destino puede ir a SU bitrate, ya no al minimo de todos.
#
# /root/.dests: una linea por destino, "<bitrate> <URL completa con key>".
: "${WIDTH:=1920}" "${HEIGHT:=1080}" "${FPS:=30}"
: "${OUT_W:=1280}" "${OUT_H:=720}"
DESTFILE="${DESTFILE:-/root/.dests}"

mapfile -t LINES < <(grep -v '^[[:space:]]*$' "$DESTFILE" 2>/dev/null)
if [ "${#LINES[@]}" -eq 0 ]; then echo "no hay destinos en $DESTFILE"; exit 1; fi

if ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=size=320x240:rate=30 \
     -t 1 -c:v h264_nvenc -f null - >/dev/null 2>&1; then
  VENC=(-c:v h264_nvenc -preset p4 -tune ll -rc cbr); echo "encoder: NVENC"
else
  # Ojo: que exista libnvidia-encode no alcanza, hay hosts que rechazan el
  # device ("OpenEncodeSessionEx failed: unsupported device"). Por eso se prueba.
  VENC=(-c:v libx264 -preset veryfast -tune zerolatency); echo "encoder: x264"
fi

# thread_queue_size grande: con el default (8) las dos entradas bloquean y ffmpeg
# frena la lectura de una mientras la otra sigue -> el audio se desliza contra el
# video. use_wallclock_as_timestamps les da un reloj comun (X11 y Pulse tienen
# el suyo), y aresample=async corrige la deriva que igual quede.
if pactl list sources short 2>/dev/null | grep -q stream.monitor; then
  AIN=(-thread_queue_size 1024 -use_wallclock_as_timestamps 1 -f pulse -i stream.monitor)
  ASYNC=(-af "aresample=async=1000:first_pts=0"); echo "audio: pulse stream.monitor"
else
  AIN=(-thread_queue_size 1024 -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=44100")
  ASYNC=(); echo "audio: silencio"
fi

nombre(){ case "$1" in *pump*) echo pump ;; *pscp*) echo x ;; *twitch*) echo twitch ;; *) echo "dest$2" ;; esac; }

echo "destinos: ${#LINES[@]}"
rm -f /root/ffmpeg.*.log

i=0
for ln in "${LINES[@]}"; do
  i=$((i+1))
  BR="${ln%% *}"; URL="${ln#* }"
  N="$(nombre "$URL" "$i")"
  echo "  -> $N ($BR): $(echo "$URL" | sed -E 's#(/[^/]{4})[^/]*$#\1…#')"
  (
    while true; do
      ffmpeg -hide_banner -loglevel warning -stats \
        -thread_queue_size 1024 -use_wallclock_as_timestamps 1 \
        -f x11grab -framerate "$FPS" -video_size "${WIDTH}x${HEIGHT}" -i :1 \
        "${AIN[@]}" -map 0:v:0 -map 1:a:0 \
        -vf "scale=${OUT_W}:${OUT_H}" "${ASYNC[@]}" "${VENC[@]}" \
        -b:v "$BR" -maxrate "$BR" -bufsize "$((${BR%k}*2))k" \
        -pix_fmt yuv420p -g $((FPS*2)) -c:a aac -b:a 128k -ar 44100 \
        -f flv "$URL"
      echo "reintentando $N en 5s (exit $?)"
      sleep 5
    done
  ) >"/root/ffmpeg.$N.log" 2>&1 &
done
wait
