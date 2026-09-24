#!/bin/bash
# Vigila la corrida DESDE EL POD.
#
# Por que existe: una run se acaba sola (presupuesto de llamadas del juego API,
# tope de 2h, o limite de pasos) y ffmpeg NO se entera: sigue empujando la
# pantalla de un agente muerto a 30fps y 0 reconexiones. Nos paso dos veces:
# 100 minutos al aire sin que nadie hablara, con el health en verde.
#
# Tiene dos modos:
#   - sin /root/.keep  : corta el stream cuando la corrida termina (lo de siempre).
#   - con /root/.keep  : REDEPLOYA el mismo juego y sigue al aire hasta la hora
#                        tope. Sirve para "transmitime esto por 2 horas", que una
#                        sola corrida casi nunca aguanta.
#
# Lo lindo del modo keep: ffmpeg captura la PANTALLA, no la pagina. Redeployar
# es navegar el mismo Chrome a otra arena, asi que el stream no se corta ni se
# reconecta — los espectadores ven el dashboard unos segundos y sigue.
#
# Vive en el pod a proposito: asi corta aunque se muera la sesion de Claude.
# NO puede destruir el pod (haria falta la API key de RunPod aca adentro, en una
# maquina alquilada a un tercero). De eso se encarga `byte-stream.sh guard`
# desde la maquina local, que lee el marcador que este script deja.
POLL="${POLL:-60}"
MARK=/root/RUN_ENDED
LOG=/root/watchdog.log
rm -f "$MARK"

# Config del modo keep. La escribe `byte-stream.sh keep`.
KEEP_GAME=""; KEEP_UNTIL=0; KEEP_PARAMS="remote=1&scene=cinema&avatar=half&chrome=0"
[ -f /root/.keep ] && . /root/.keep
echo "$(date -Is) watchdog arrancado (poll ${POLL}s)" >> "$LOG"
if [ -n "$KEEP_GAME" ]; then
  echo "$(date -Is) modo keep: redeploya \"$KEEP_GAME\" hasta $(date -Is -d @"$KEEP_UNTIL")" >> "$LOG"
fi

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

# Redeploya el juego y vuelve a poner el modo consola. Devuelve el sessionId
# nuevo, o vacio si no pudo.
redeploy() {
  python3 /opt/streamer/deploy-game.py "$KEEP_GAME" >> "$LOG" 2>&1
  local nuevo
  nuevo=$(python3 /opt/streamer/cdp.py eval \
    '(location.href.match(/\/arena\/([a-z0-9_]+)/)||[])[1] ?? ""' 2>/dev/null \
    | tr -d '"' | tr -d '[:space:]')
  [ -n "$nuevo" ] || return 1
  # El deploy deja la arena SIN los params de remote: sin esto vuelve el panel
  # de chat y se pierde el avatar a medio cuerpo.
  python3 /opt/streamer/cdp.py nav "https://app.bytearena.fun/arena/${nuevo}?${KEEP_PARAMS}" >> "$LOG" 2>&1
  sleep 8
  /root/fullscreen.sh >> "$LOG" 2>&1
  printf '%s' "$nuevo"
}

cortar() { # $1 = motivo
  echo "$(date -Is) $1 — cortando stream" >> "$LOG"
  pkill -9 -f 'opt/streamer/str' 2>/dev/null
  sleep 1
  ps -eo pid,comm --no-headers | grep '[f]fmpeg' | awk '{print $1}' | xargs -r kill -9
  printf '%s' "$1" > "$MARK"
  echo "$(date -Is) ffmpeg detenido. Marcador en $MARK" >> "$LOG"
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
    AHORA=$(date +%s)
    if [ -n "$KEEP_GAME" ] && [ "$AHORA" -lt "$KEEP_UNTIL" ]; then
      FALTA=$(( (KEEP_UNTIL - AHORA) / 60 ))
      echo "$(date -Is) la run termino ($FIN) — quedan ${FALTA}min, redeployando \"$KEEP_GAME\"" >> "$LOG"
      NUEVO=$(redeploy)
      if [ -n "$NUEVO" ]; then
        SID="$NUEVO"
        echo "$(date -Is) al aire de nuevo en $SID (el stream nunca se corto)" >> "$LOG"
        sleep "$POLL"; continue
      fi
      # Si no pudo redeployar no tiene sentido seguir emitiendo una pantalla
      # muerta: mejor cortar y que el guard baje el pod.
      cortar "no pude redeployar \"$KEEP_GAME\" despues de $FIN"
      exit 0
    fi
    [ -n "$KEEP_GAME" ] && FIN="se cumplio la hora tope ($FIN)"
    cortar "$FIN"
    exit 0
  fi

  # Tope de tiempo aunque la corrida siga viva: si no, "2 horas" se vuelve
  # "hasta que alguien se acuerde".
  if [ -n "$KEEP_GAME" ] && [ "$(date +%s)" -ge "$KEEP_UNTIL" ]; then
    cortar "se cumplio la hora tope"
    exit 0
  fi
  sleep "$POLL"
done
