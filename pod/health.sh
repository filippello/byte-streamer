#!/bin/bash
# Chequeo REAL del stream. No alcanza con "ffmpeg esta vivo": ya nos paso
# transmitir media hora una pantalla de error con 30fps y 0 reconexiones.
echo "=== ffmpeg (uno por destino) ==="
echo "procesos: $(pgrep -c -x ffmpeg)"
for f in /root/ffmpeg.*.log; do
  [ -e "$f" ] || continue
  n="$(basename "$f" .log)"; n="${n#ffmpeg.}"
  ULT="$(grep -a -oE 'frame=[^\r]*' "$f" | tail -1)"
  printf '%-8s %s | reintentos: %s\n' "$n" "$ULT" "$(grep -ac reintentando "$f")"
  grep -aiE 'broken pipe|refused|denied|invalid' "$f" | tail -1 | sed "s/^/         /"
  # SINCRONIA A/V. El 2026-10-02 el audio salio 3,4s adelantado durante una
  # transmision entera y nos enteramos porque Federico lo escucho. El numero
  # estaba en el log todo el tiempo: si el video va alineado, los frames
  # emitidos tienen que ser tiempo*fps. Si faltan, ese hueco ES el desfase.
  FR="$(printf '%s' "$ULT" | grep -oE 'frame= *[0-9]+' | grep -oE '[0-9]+')"
  HMS="$(printf '%s' "$ULT" | grep -oE 'time=[0-9:.]+' | cut -d= -f2)"
  if [ -n "$FR" ] && [ -n "$HMS" ]; then
    SEG="$(echo "$HMS" | awk -F: '{print ($1*3600)+($2*60)+$3}')"
    echo "$FR $SEG ${FPS:-30}" | awk '{
      esp = $2 * $3;
      if (esp <= 0) exit;
      d = (esp - $1) / $3;
      if (d < 0) d = -d;
      if (d > 1.0) printf "         DESFASE A/V: faltan %d frames = %.1fs de audio adelantado\n", esp-$1, d;
      else printf "         sync A/V OK (%.1fs de diferencia)\n", d;
    }'
  fi
done
echo "=== la pagina sigue viva? ==="
python3 /opt/streamer/cdp.py eval 'JSON.stringify({url:location.href, estado:(document.body.innerText.match(/status: [a-z]+/i)||["?"])[0], finRun:/This run is over/i.test(document.body.innerText)})' 2>/dev/null
echo "=== fps de render ==="
python3 /opt/streamer/cdp.py eval '(()=>new Promise(r=>{let n=0;const t0=performance.now();function f(){n++;if(performance.now()-t0<3500)requestAnimationFrame(f);else r((n/((performance.now()-t0)/1000)).toFixed(1)+" fps")}requestAnimationFrame(f)}))()' 2>/dev/null
echo "=== audio: hay voz de verdad? ==="
# stream.sh cae a anullsrc (SILENCIO) si stream.monitor no aparece, y no avisa:
# el avatar sigue moviendo la boca sobre un stream mudo. Esto lo detecta.
grep -a -E '^audio:' /root/ffmpeg.log | tail -1
pactl list sources short 2>/dev/null | grep -q stream.monitor \
  && echo "sink OK" || echo "FALTA stream.monitor -> el stream va MUDO"
echo "=== maquina ==="
cat /proc/loadavg | cut -d' ' -f1-3
nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader 2>/dev/null
