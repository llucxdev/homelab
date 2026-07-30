#!/usr/bin/env bash

set -Eeuo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

TMP_SUFFIX=".embedtmp.mkv"
LOGFILE="/srv/docker/scripts/embed-subtitles.log"
CONFIG="/srv/docker/scripts/embed-subtitles.conf"

if [[ -f "$CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG"
fi

log() {
    printf '%(%F %T)T | %s\n' -1 "$1" >> "$LOGFILE"
}

notify_sonarr() {

    [[ -n "${SERIES_ID:-}" ]] || return 0
    [[ -n "$MEDIA_ID" ]] || return 0
    [[ -n "${SONARR_URL:-}" ]] || return 0
    [[ -n "${SONARR_API_KEY:-}" ]] || return 0

    log "INFO | Rescan episodio Sonarr | EpisodeId=$MEDIA_ID SeriesId=$SERIES_ID"

    curl -fsS \
        -X POST \
        -H "X-Api-Key: $SONARR_API_KEY" \
        -H "Content-Type: application/json" \
        "$SONARR_URL/api/v3/command" \
        -d "{
            \"name\":\"RescanEpisodes\",
            \"episodeIds\":[${MEDIA_ID}]
        }" >/dev/null || \
    log "WARN | No se pudo actualizar Sonarr"

}

notify_radarr() {

    [[ -z "${SERIES_ID:-}" ]] || return 0
    [[ -n "$MEDIA_ID" ]] || return 0
    [[ -n "${RADARR_URL:-}" ]] || return 0
    [[ -n "${RADARR_API_KEY:-}" ]] || return 0

    log "INFO | Refresh película Radarr | MovieId=$MEDIA_ID"

    curl -fsS \
        -X POST \
        -H "X-Api-Key: $RADARR_API_KEY" \
        -H "Content-Type: application/json" \
        "$RADARR_URL/api/v3/command" \
        -d "{
            \"name\":\"RefreshMovie\",
            \"movieIds\":[${MEDIA_ID}]
        }" >/dev/null || \
    log "WARN | No se pudo actualizar Radarr"

}

notify_arr() {

    if [[ -n "${SERIES_ID:-}" ]]; then
        notify_sonarr
    else
        notify_radarr
    fi

}

TMP=""

cleanup() {
    [[ -n "$TMP" && -f "$TMP" ]] && rm -f "$TMP"
}

trap cleanup EXIT

error_handler() {
    log "ERROR | Línea $1 | ${VIDEO:-desconocido}"
}

trap 'error_handler $LINENO' ERR

########################################
# Procesar un único vídeo
########################################

process_video() {

    local VIDEO="$1"

    log "START | $VIDEO"

    [[ -f "$VIDEO" ]] || return 0

    command -v mkvmerge >/dev/null || {
        echo "mkvmerge no está instalado."
        exit 1
    }

    local DIR FILE NAME EXT
    DIR="$(dirname "$VIDEO")"
    FILE="$(basename "$VIDEO")"

    NAME="${FILE%.*}"
    EXT="${FILE##*.}"
    EXT="${EXT,,}"

    TMP="$DIR/$NAME$TMP_SUFFIX"

    rm -f "$TMP"

    ####################################
    # Buscar subtítulos
    ####################################

    mapfile -d '' SUBS < <(
        find "$DIR" \
            -maxdepth 1 \
            -type f \
            -name "$NAME*.srt" \
            -print0 | sort -z
    )

    VALID_SUBS=()

    for SUB in "${SUBS[@]}"
    do
        [[ -s "$SUB" ]] || continue
        VALID_SUBS+=("$SUB")
    done

    SUBS=("${VALID_SUBS[@]}")

    [[ ${#SUBS[@]} -gt 0 ]] || {
        echo "[SKIP] $(basename "$VIDEO") (sin subtítulos)"
	log "SKIP | Sin subtítulos | $VIDEO"
        return 0
    }

    ####################################
    # ¿Existe algún subtítulo español?
    ####################################

    HAS_SPANISH=0

    for SUB in "${SUBS[@]}"
    do
        case "$(basename "$SUB")" in
            *.es.srt|*.es.hi.srt|*.es.forced.srt|*.spa.srt|*.spa.hi.srt|*.spa.forced.srt)
                HAS_SPANISH=1
                break
            ;;
        esac
    done

    ####################################
    # MKV sin cambios
    ####################################

    if [[ "$EXT" == "mkv" ]]; then

        UPDATE=0

        for SUB in "${SUBS[@]}"
        do
            if [[ "$SUB" -nt "$VIDEO" ]]; then
                UPDATE=1
                break
            fi
        done

        if [[ "$UPDATE" -eq 0 ]]; then

            INTERNAL_SUBS=$(
                mkvmerge -J "$VIDEO" |
                grep -c '"type": "subtitles"' || true
            )

            if [[ "$INTERNAL_SUBS" -eq "${#SUBS[@]}" ]]; then
                echo "[SKIP] $(basename "$VIDEO") (sin cambios)"
		log "SKIP | Sin cambios | $VIDEO"
                return 0
            fi

        fi
    fi

    ####################################
    # mkvmerge
    ####################################

    CMD=(
        mkvmerge
        -o
        "$TMP"
    )

    if [[ "$EXT" == "mkv" ]]; then
        CMD+=(
            --no-subtitles
            "$VIDEO"
        )
    elif [[ "$EXT" == "mp4" ]]; then
        CMD+=("$VIDEO")
    else
        echo "[SKIP] Formato no soportado: $VIDEO"
        return 0
    fi

    DEFAULT_ALREADY_SET=0

    for SUB in "${SUBS[@]}"
    do

        BASE="$(basename "$SUB")"

        LANG="und"
        TITLE="Subtitle"
        DEFAULT=0
        FORCED=0

        case "$BASE" in

            *.es.forced.srt|*.spa.forced.srt)
                LANG="spa"
                TITLE="Español Forzado"
                FORCED=1

                if [[ "$DEFAULT_ALREADY_SET" -eq 0 ]]; then
                    DEFAULT=1
                    DEFAULT_ALREADY_SET=1
                fi
            ;;

            *.es.hi.srt|*.spa.hi.srt)
                LANG="spa"
                TITLE="Español SDH"
            ;;

            *.es.srt|*.spa.srt)
                LANG="spa"
                TITLE="Español"

                if [[ "$DEFAULT_ALREADY_SET" -eq 0 ]]; then
                    DEFAULT=1
                    DEFAULT_ALREADY_SET=1
                fi
            ;;

            *.en.forced.srt|*.eng.forced.srt)
                LANG="eng"
                TITLE="English Forced"
                FORCED=1

                if [[ "$DEFAULT_ALREADY_SET" -eq 0 && "$HAS_SPANISH" -eq 0 ]]; then
                    DEFAULT=1
                    DEFAULT_ALREADY_SET=1
                fi
            ;;

            *.en.hi.srt|*.eng.hi.srt)
                LANG="eng"
                TITLE="English SDH"
            ;;

            *.en.srt|*.eng.srt)
                LANG="eng"
                TITLE="English"

                if [[ "$DEFAULT_ALREADY_SET" -eq 0 && "$HAS_SPANISH" -eq 0 ]]; then
                    DEFAULT=1
                    DEFAULT_ALREADY_SET=1
                fi
            ;;

        esac

        CMD+=(
            --language 0:$LANG
            --track-name 0:"$TITLE"
            --default-track 0:$DEFAULT
            --forced-track 0:$FORCED
            --compression 0:none
            "$SUB"
        )

    done

    ####################################
    # Crear MKV
    ####################################

    log "INFO | Generando MKV | $VIDEO"
    "${CMD[@]}"

    mkvmerge -J "$TMP" >/dev/null
    log "INFO | MKV validado | $VIDEO"

    ####################################
    # Sustituir original
    ####################################

    if [[ "$EXT" == "mp4" ]]; then
        rm -f "$VIDEO"
	mv -f "$TMP" "$DIR/$NAME.mkv"
    [[ -f "$DIR/$NAME.mkv" ]] || {
        log "ERROR | No se pudo crear el MKV final"
        exit 1
    }
	touch "$DIR/$NAME.mkv"
	notify_arr
    else
        mv -f "$TMP" "$VIDEO"
        [[ -f "$VIDEO" ]] || {
            log "ERROR | No se pudo reemplazar el MKV"
            exit 1
        }
        touch "$VIDEO"
        notify_arr
    fi

    echo "[OK] $(basename "${VIDEO%.*}.mkv")"

    log "OK | Procesado correctamente | $VIDEO"

    TMP=""
}

########################################
# MAIN
########################################

[[ $# -ge 1 ]] || {
    echo "Uso:"
    echo "  $0 <video>"
    echo "  $0 <carpeta>"
    exit 1
}

TARGET="$1"

if [[ $# -eq 3 ]]; then
    MEDIA_ID="$2"
    SERIES_ID="$3"
else
    MEDIA_ID=""
    SERIES_ID=""
fi

if [[ -d "$TARGET" ]]; then

    find "$TARGET" \
        -type f \
        \( -iname "*.mkv" -o -iname "*.mp4" \) \
        -print0 |
    while IFS= read -r -d '' FILE
    do
        process_video "$FILE"
    done

elif [[ -f "$TARGET" ]]; then

    process_video "$TARGET"

else

    echo "No existe:"
    echo "$TARGET"
    exit 1

fi

trap - EXIT

echo
echo "Proceso finalizado."
