#!/bin/bash
# Vigila la corrida DESDE EL POD y corta el stream cuando termina.
#
# Por que existe: una run se acaba sola (presupuesto de 400 requests del juego
# API, tope de 2h, o limite de pasos) y ffmpeg NO se entera: sigue empujando la
# pantalla de un agente muerto a 30fps y 0 reconexiones. Nos paso dos veces:
# 100 minutos al aire sin que nadie hablara, con el health en verde.
#
# Vive en el pod a proposito: asi corta aunque se muera la sesion de Claude.
# NO puede destruir el pod (haria falta la API key de RunPod aca adentro, en una
# maquina alquilada a un tercero). De eso se encarga `byte-stream.sh guard`
# desde la maquina local, que lee el marcador que este script deja.
POLL="${POLL:-60}"
MARK=/root/RUN_ENDED
LOG=/root/watchdog.log
rm -f "$MARK"
echo "$(date -Is) watchdog arrancado (poll ${POLL}s)" >> "$LOG"

# Devuelve "<status>|<sessionId>". Los dos importan: ver mas abajo.
estado() {
  python3 /opt/streamer/cdp.py eval \
    'document.getElementById("byte-state")?.textContent ?? ""' 2>/dev/null \
    | python3 -c 'import sys,json
raw=sys.stdin.read().strip()
try: raw=json.loads(raw)
except Exception: pass
try:
    d=json.loads(raw); print("%s|%s" % (d.get("status",""), d.get("sessionId","")))
except Exception: print("|")' 2>/dev/null
}

SID=""
while true; do
  R=$(estado); S="${R%%|*}"; ID="${R#*|}"
  [ -n "$ID" ] && [ -z "$SID" ] && { SID="$ID"; echo "$(date -Is) vigilando la corrida $SID" >> "$LOG"; }

  FIN=""
  # Lista EXPLICITA de estados finales. Antes era al reves —cortaba con
  # cualquier cosa que no fuera "running"— y `waiting`, que es el estado de
  # TRANSICION entre corridas, mataba el stream y destruia el pod al pedo.
  # Con la lista al reves, un estado nuevo que no conozcamos no corta nada:
  # el riesgo de seguir al aire de mas es mucho mas barato que el de cortar
  # una transmision viva.
  case "$S" in
    finished|failed|error|stopped|cancelled|canceled|ended) FIN="status=$S" ;;
  esac

  # byte encadena solo: cuando una corrida termina, deploya al agente a la
  # siguiente y la pagina salta a una sesion NUEVA que ya esta "running", asi
  # que el estado final no se llega a ver nunca. Nos paso con Fly Brain: siguio
  # al aire 16 minutos transmitiendo Solana Survivors. Si cambio el sessionId,
  # la corrida que nos pidieron termino.
  [ -n "$SID" ] && [ -n "$ID" ] && [ "$ID" != "$SID" ] && FIN="cambio de sesion ($SID -> $ID)"

  if [ -n "$FIN" ]; then
    echo "$(date -Is) la run termino ($FIN) — cortando stream" >> "$LOG"
    pkill -9 -f 'opt/streamer/str' 2>/dev/null
    sleep 1
    ps -eo pid,comm --no-headers | grep '[f]fmpeg' | awk '{print $1}' | xargs -r kill -9
    printf '%s' "$FIN" > "$MARK"
    echo "$(date -Is) ffmpeg detenido. Marcador en $MARK" >> "$LOG"
    exit 0
  fi
  sleep "$POLL"
done
