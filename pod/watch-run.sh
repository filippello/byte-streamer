#!/bin/bash
# Vigila la corrida DESDE EL POD.
#
# Por que existe: una run se acaba sola (presupuesto de llamadas del juego API,
# tope de 2h, o limite de pasos) y ffmpeg NO se entera: sigue empujando la
# pantalla de un agente muerto a 30fps y 0 reconexiones. Nos paso dos veces:
# 100 minutos al aire sin que nadie hablara, con el health en verde.
#
# Tiene tres modos:
#   - sin /root/.keep       : corta el stream cuando la corrida termina.
#   - .keep con KEEP_GAME   : redeploya ESE juego hasta la hora tope.
#   - .keep con KEEP_GAMES  : CARRUSEL. Rota entre varios juegos, dandole a cada
#                             uno un turno de KEEP_TURNO segundos.
#
# La rotacion se mide por TIEMPO pero el cambio ocurre al FIN DE PARTIDA: cuando
# una corrida termina se mira el reloj; si el turno del juego todavia no vencio
# se redeploya el mismo, y si vencio se pasa al siguiente. Asi no se corta
# ninguna partida por la mitad: se espera al primer final despues del turno.
#
# Lo lindo de todo esto: ffmpeg captura la PANTALLA, no la pagina. Cambiar de
# juego es navegar el mismo Chrome, asi que el stream no se corta ni se
# reconecta. Los 36-40s de dashboard se tapan con placa.sh.
#
# Vive en el pod a proposito: asi corta aunque se muera la sesion de Claude.
# NO puede destruir el pod (haria falta la API key de RunPod aca adentro, en una
# maquina alquilada a un tercero). De eso se encarga `byte-stream.sh guard`
# desde la maquina local, que lee el marcador que este script deja.
POLL="${POLL:-60}"
MARK=/root/RUN_ENDED
LOG=/root/watchdog.log
rm -f "$MARK"

# Config. La escribe `byte-stream.sh keep` o `byte-stream.sh carrusel`.
KEEP_GAME=""; KEEP_GAMES=""; KEEP_TURNO=1800; KEEP_UNTIL=0
KEEP_PARAMS="remote=1&scene=cinema&avatar=half&chrome=0"
[ -f /root/.keep ] && . /root/.keep
echo "$(date -Is) watchdog arrancado (poll ${POLL}s)" >> "$LOG"

JUEGOS=(); IDX=0
if [ -n "$KEEP_GAMES" ]; then
  IFS='|' read -r -a JUEGOS <<< "$KEEP_GAMES"
  echo "$(date -Is) CARRUSEL de ${#JUEGOS[@]} juegos, turno ${KEEP_TURNO}s, hasta $(date -Is -d @"$KEEP_UNTIL")" >> "$LOG"
  for j in "${JUEGOS[@]}"; do echo "$(date -Is)   · $j" >> "$LOG"; done
elif [ -n "$KEEP_GAME" ]; then
  JUEGOS=("$KEEP_GAME")
  echo "$(date -Is) modo keep: redeploya \"$KEEP_GAME\" hasta $(date -Is -d @"$KEEP_UNTIL")" >> "$LOG"
fi
# El estado del carrusel vive en disco, NO en memoria del proceso. El 2026-10-03
# reinicie el watchdog dos veces para arreglar otra cosa y cada reinicio volvia a
# IDX=0 con el turno en cero: el carrusel se quedo tres horas en Hells Agents.
ESTADO=/root/.carrusel-estado
if [ -f "$ESTADO" ]; then
  . "$ESTADO"
  echo "$(date -Is) retomo el carrusel donde estaba: ${JUEGOS[$IDX]:-?} (turno vence $(date -Is -d @"$TURNO_FIN"))" >> "$LOG"
else
  TURNO_FIN=$(( $(date +%s) + KEEP_TURNO ))
fi
guardar_estado(){ printf 'IDX=%s\nTURNO_FIN=%s\n' "$IDX" "$TURNO_FIN" > "$ESTADO"; }
guardar_estado

# Cuanto se tolera que una partida se pase de su turno. La rotacion espera al fin
# de partida para no cortar nada al medio, pero sin tope eso deja de ser "30
# minutos por juego": el 2026-10-03 una corrida de Hells Agents duro 81 minutos
# sobre un turno de 30. Pasado el turno + esta gracia, se corta la partida.
GRACIA=${KEEP_GRACIA:-$(( KEEP_TURNO / 2 ))}

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

# Deploya $1 y vuelve a poner el modo consola. Devuelve el sessionId nuevo, o
# vacio si no pudo. La placa tapa todo el tramo del dashboard.
cambiar_a() {
  local juego="$1" nuevo
  /root/placa.sh "$juego" >> "$LOG" 2>&1

  # Cerrar lo anterior antes de abrir lo nuevo: si queda una sesion viva del lado
  # del servidor, el deploy choca con "this agent is already playing". byte
  # encadena solo, asi que puede haber una aunque la que vigilabamos ya termino.
  python3 /opt/streamer/cdp.py eval \
    '(async()=>{try{return JSON.stringify((await byte.stop()) ?? "ok")}catch(e){return "sin byte: "+e.message}})()' \
    >> "$LOG" 2>&1
  sleep 5

  if ! python3 /opt/streamer/deploy-game.py "$juego" >> "$LOG" 2>&1; then
    echo "$(date -Is) deploy-game fallo con \"$juego\" (el motivo quedo arriba)" >> "$LOG"
    /root/placa.sh --off
    return 1
  fi
  nuevo=$(python3 /opt/streamer/cdp.py eval \
    '(location.href.match(/\/arena\/([a-z0-9_]+)/)||[])[1] ?? ""' 2>/dev/null \
    | tr -d '"' | tr -d '[:space:]')
  if [ -z "$nuevo" ]; then /root/placa.sh --off; return 1; fi

  # El deploy deja la arena SIN los params de remote: sin esto vuelve el panel
  # de chat, se pierde el medio cuerpo y la escala del avatar.
  python3 /opt/streamer/cdp.py nav "https://app.bytearena.fun/arena/${nuevo}?${KEEP_PARAMS}" >> "$LOG" 2>&1
  sleep 8
  /root/fullscreen.sh >> "$LOG" 2>&1
  # El CSS inyectado no sobrevive a la navegacion: sin esto el zoom del iframe
  # se perdia en cada cambio y nadie se enteraba hasta mirar el stream.
  python3 /opt/streamer/inject-css.py >> "$LOG" 2>&1
  sleep 2
  /root/placa.sh --off          # recien aca se descubre, con el juego ya puesto
  printf '%s' "$nuevo"
}

cortar() { # $1 = motivo
  echo "$(date -Is) $1 — cortando stream" >> "$LOG"
  /root/placa.sh --off 2>/dev/null
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
    if [ "${#JUEGOS[@]}" -gt 0 ] && [ "$AHORA" -lt "$KEEP_UNTIL" ]; then
      # Aca se decide si rota o repite.
      if [ "$AHORA" -ge "$TURNO_FIN" ] && [ "${#JUEGOS[@]}" -gt 1 ]; then
        IDX=$(( (IDX + 1) % ${#JUEGOS[@]} ))
        TURNO_FIN=$(( AHORA + KEEP_TURNO )); guardar_estado
        echo "$(date -Is) se cumplio el turno — paso a \"${JUEGOS[$IDX]}\"" >> "$LOG"
      else
        echo "$(date -Is) la run termino ($FIN) — sigue el turno de \"${JUEGOS[$IDX]}\"" >> "$LOG"
      fi
      NUEVO=$(cambiar_a "${JUEGOS[$IDX]}")
      if [ -n "$NUEVO" ]; then
        SID="$NUEVO"
        echo "$(date -Is) al aire en $SID con \"${JUEGOS[$IDX]}\" (el stream nunca se corto)" >> "$LOG"
        sleep "$POLL"; continue
      fi
      # Que UN juego falle no tiene por que terminar la transmision entera:
      # en un carrusel se prueba con el siguiente antes de bajar la persiana.
      if [ "${#JUEGOS[@]}" -gt 1 ]; then
        IDX=$(( (IDX + 1) % ${#JUEGOS[@]} ))
        TURNO_FIN=$(( AHORA + KEEP_TURNO )); guardar_estado
        echo "$(date -Is) fallo el anterior — intento con \"${JUEGOS[$IDX]}\"" >> "$LOG"
        NUEVO=$(cambiar_a "${JUEGOS[$IDX]}")
        if [ -n "$NUEVO" ]; then
          SID="$NUEVO"
          echo "$(date -Is) al aire en $SID con \"${JUEGOS[$IDX]}\"" >> "$LOG"
          sleep "$POLL"; continue
        fi
      fi
      cortar "no pude deployar ningun juego del carrusel despues de $FIN"
      exit 0
    fi
    [ "${#JUEGOS[@]}" -gt 0 ] && FIN="se cumplio la hora tope ($FIN)"
    cortar "$FIN"
    exit 0
  fi

  # La partida se paso MUCHO de su turno: se la corta para que el carrusel siga
  # siendo un carrusel. byte.stop() dispara el fin de corrida y la rotacion sale
  # por el camino normal de arriba.
  if [ "${#JUEGOS[@]}" -gt 1 ] && [ "$(date +%s)" -ge $(( TURNO_FIN + GRACIA )) ]; then
    echo "$(date -Is) \"${JUEGOS[$IDX]}\" se paso $((GRACIA/60))min de su turno — corto la partida para rotar" >> "$LOG"
    python3 /opt/streamer/cdp.py eval \
      '(async()=>{try{return JSON.stringify((await byte.stop()) ?? "ok")}catch(e){return "sin byte: "+e.message}})()' \
      >> "$LOG" 2>&1
    sleep 10
    continue
  fi

  # Tope de tiempo aunque la corrida siga viva: si no, "4 horas" se vuelve
  # "hasta que alguien se acuerde".
  if [ "${#JUEGOS[@]}" -gt 0 ] && [ "$(date +%s)" -ge "$KEEP_UNTIL" ]; then
    cortar "se cumplio la hora tope"
    exit 0
  fi
  sleep "$POLL"
done
