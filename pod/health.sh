#!/bin/bash
# Chequeo REAL del stream. No alcanza con "ffmpeg esta vivo": ya nos paso
# transmitir media hora una pantalla de error con 30fps y 0 reconexiones.
echo "=== ffmpeg (uno por destino) ==="
echo "procesos: $(pgrep -c -x ffmpeg)"
for f in /root/ffmpeg.*.log; do
  [ -e "$f" ] || continue
  n="$(basename "$f" .log)"; n="${n#ffmpeg.}"
  printf '%-8s %s | reintentos: %s\n' "$n" \
    "$(grep -a -oE 'frame=[^\r]*' "$f" | tail -1)" \
    "$(grep -ac reintentando "$f")"
  grep -aiE 'broken pipe|refused|denied|invalid' "$f" | tail -1 | sed "s/^/         /"
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
