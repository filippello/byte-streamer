#!/bin/bash
# Arranca el stream. El pkill usa un patron que NO matchea este script.
# Los destinos ya vienen escritos en /root/.dests (uno por linea,
# "<bitrate> <URL completa>") — los pone byte-stream.sh.
# Ojo con el orden: primero mueren los loops de reintento, despues los ffmpeg.
# Al reves, cada loop volveria a levantar el suyo.
pkill -9 -f 'opt/streamer/str' 2>/dev/null; pkill -9 -x ffmpeg 2>/dev/null; sleep 3
export WIDTH=1920 HEIGHT=1080 FPS=30 OUT_W=1280 OUT_H=720 DISPLAY=:1
setsid nohup /opt/streamer/stream.sh >/root/ffmpeg.log 2>&1 </dev/null &
sleep 45
echo "ffmpeg=$(pgrep -c -x ffmpeg)"
grep -a -E '^encoder:|^audio:|^destinos:|^  ->' /root/ffmpeg.log
# Por destino, porque el modo viejo escondia que uno se habia caido.
for f in /root/ffmpeg.*.log; do
  [ -e "$f" ] || continue
  n="$(basename "$f" .log)"; n="${n#ffmpeg.}"
  printf '%-8s %s\n' "$n" "$(grep -a -oE 'frame=[^\r]*' "$f" | tail -1)"
  grep -aiE 'error|failed|invalid|refused|broken pipe' "$f" | head -2 | sed "s/^/         /"
done
