#!/bin/bash
#
# Sauvegarde froide automatique sur le SSD externe SanDisk Extreme.
#
# Declenche par udev (/etc/udev/rules.d/99-ssd-coldbackup.rules) des que le
# disque est branche : montage, miroir rsync, archive des configs, demontage
# puis coupure de l'alimentation USB. Le disque peut ensuite etre debranche
# sans aucune manipulation.
#
# L'avancement est rapporte en message prive Discord via nas-notify : le NAS
# n'a pas d'interface graphique.
#
# Journaux : journalctl -t ssd-coldbackup

set -uo pipefail

CONF=/etc/default/ssd-coldbackup
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

SSD_UUID="${SSD_UUID:?absent de /etc/default/ssd-coldbackup}"
MOUNTPOINT="${MOUNTPOINT:-/mnt/coldbackup}"
DEST_ROOT="$MOUNTPOINT/${DEST_SUBDIR:-nas-backup}"
MIN_INTERVAL_HOURS="${MIN_INTERVAL_HOURS:-6}"
KEEP_CONFIG_ARCHIVES="${KEEP_CONFIG_ARCHIVES:-7}"
MIN_FREE_GB="${MIN_FREE_GB:-20}"
STATE_DIR=/var/lib/ssd-coldbackup
STATE_FILE="$STATE_DIR/last-success"
# Historique des executions : horodatage,heures_ecoulees,octets,secondes
HISTORY_FILE="$STATE_DIR/history.csv"
HISTORY_KEEP=20
DEFAULT_GAP_HOURS=24

# Points d'etape : rien avant ce delai, pour ne pas notifier une sauvegarde
# incrementielle qui dure trois minutes.
PROGRESS_FIRST_DELAY_MIN="${PROGRESS_FIRST_DELAY_MIN:-5}"
PROGRESS_INTERVAL_MIN="${PROGRESS_INTERVAL_MIN:-10}"
STAGE_FILE=/run/ssd-coldbackup.stage

log()  { logger -t ssd-coldbackup -p daemon.info -- "$*"; }
warn() { logger -t ssd-coldbackup -p daemon.warning -- "$*"; }

# $1 = niveau, $2 = titre, $3 = description, puis des champs "Nom=Valeur"
notify() {
    local level=$1 title=$2 description=$3
    shift 3
    [ -x /usr/local/bin/nas-notify ] || return 0
    local args=() field
    for field in "$@"; do
        args+=(--field "$field")
    done
    /usr/local/bin/nas-notify --level "$level" --title "$title" \
        --description "$description" --source ssd-coldbackup "${args[@]}" || true
}

# Octets -> "12,3 Go"
human() {
    numfmt --to=iec --suffix=o --format='%.1f' "${1:-0}" 2>/dev/null || echo "${1:-0} o"
}

# Minutes -> "2 h 05" ou "18 min"
duration() {
    local m=${1:-0}
    if [ "$m" -ge 60 ]; then
        printf '%d h %02d' $((m / 60)) $((m % 60))
    else
        printf '%d min' "$m"
    fi
}

unmount_ssd() {
    findmnt -rno TARGET "$MOUNTPOINT" >/dev/null || return 0
    sync
    if umount "$MOUNTPOINT"; then
        log "disque demonte"
    else
        warn "demontage impossible, le disque ne doit pas etre debranche"
    fi
}

progress_pid=""

stop_progress() {
    [ -n "$progress_pid" ] && kill "$progress_pid" 2>/dev/null
    progress_pid=""
    rm -f "$STAGE_FILE"
}

# $1 = horodatage de depart, $2 = octets deja occupes sur le SSD, $3 = estimation
#
# rsync ne peut pas fournir de pourcentage fiable : en recursion incrementielle,
# le sien porte sur ce qui a ete scanne jusque-la, donc il monte a 99 % puis
# redescend. Le rendre exact imposerait --no-inc-recursive, c'est-a-dire un scan
# complet prealable -- precisement ce que l'on a supprime. On rapporte donc ce
# qui est mesurable sans surcout : le temps ecoule face a l'estimation, et le
# volume reellement ecrit.
start_progress() {
    local begin=$1 baseline=$2 estimate=$3
    (
        sleep $((PROGRESS_FIRST_DELAY_MIN * 60))
        while :; do
            elapsed=$(( ($(date +%s) - begin) / 60 ))
            written=$(( ($(df -k --output=used "$MOUNTPOINT" | tail -1) - baseline) * 1024 ))
            [ "$written" -lt 0 ] && written=0
            fields=("Ecoule=$(duration "$elapsed")" "Ecrit=$(human "$written")")
            if [ -n "$estimate" ] && [ "$estimate" -gt 0 ]; then
                percent=$(( elapsed * 100 / estimate ))
                [ "$percent" -gt 99 ] && percent=99
                fields+=("Avancement=~${percent} %" "Estimation=$(duration "$estimate")")
            fi
            [ -r "$STAGE_FILE" ] && fields+=("Etape=$(cat "$STAGE_FILE")")
            notify info "Sauvegarde froide en cours" \
                "Le disque ne doit pas etre debranche." "${fields[@]}"
            sleep $((PROGRESS_INTERVAL_MIN * 60))
        done
    ) &
    progress_pid=$!
}

fail() {
    warn "$1"
    stop_progress
    notify error "Sauvegarde froide interrompue" "$1"
    unmount_ssd
    exit 1
}

# exFAT n'est pas journalise : un arret du service ou du NAS en pleine ecriture
# corrompt le disque. C'est l'origine probable des entrees fantomes existantes.
trap 'warn "interruption recue, demontage en cours"; stop_progress; unmount_ssd; exit 143' TERM INT

# --- Garde-fous -------------------------------------------------------------

# Un branchement genere plusieurs evenements udev (disque puis partition) :
# sans verrou, deux sauvegardes se marcheraient dessus.
exec 9>/run/ssd-coldbackup.lock
if ! flock -n 9; then
    log "une sauvegarde est deja en cours, rien a faire"
    exit 0
fi

for src in /mnt/immich /mnt/data; do
    findmnt -rno TARGET "$src" >/dev/null \
        || fail "$src n'est pas monte. Sans ce controle, rsync --delete verrait une source vide et effacerait la sauvegarde."
done

DEV=$(blkid -U "$SSD_UUID" 2>/dev/null)
[ -n "${DEV:-}" ] || fail "SSD introuvable (UUID $SSD_UUID)"

mkdir -p "$STATE_DIR"

# Un simple rebranchement ne doit pas relancer un balayage de plusieurs
# centaines de Go.
gap_hours=""
if [ -r "$STATE_FILE" ]; then
    gap_hours=$(( ($(date +%s) - $(cat "$STATE_FILE")) / 3600 ))
    if [ "$gap_hours" -lt "$MIN_INTERVAL_HOURS" ]; then
        log "derniere sauvegarde il y a ${gap_hours} h (< ${MIN_INTERVAL_HOURS} h), ignoree"
        notify info "SSD detecte, sauvegarde non necessaire" \
            "La derniere sauvegarde date de moins de ${MIN_INTERVAL_HOURS} h. Le disque peut etre debranche." \
            "Derniere sauvegarde=il y a ${age} h"
        exit 0
    fi
fi

# --- Montage ----------------------------------------------------------------

parent=$(lsblk -no pkname "$DEV" 2>/dev/null)
link_speed=$(cat "/sys/block/${parent}/device/../../speed" 2>/dev/null)
notify info "SSD Extreme detecte" \
    "Montage du disque et analyse du volume a copier." \
    ${link_speed:+"Lien USB=${link_speed} Mbps"}

if ! findmnt -rno TARGET "$MOUNTPOINT" >/dev/null; then
    # Type detecte a chaud plutot que code en dur, pour survivre a un
    # reformatage eventuel du SSD.
    fstype=$(blkid -o value -s TYPE "$DEV")
    [ -n "$fstype" ] || fail "systeme de fichiers de $DEV illisible"
    mount -t "$fstype" -o rw,noatime,uid=0,gid=0,umask=022 "$DEV" "$MOUNTPOINT" \
        || mount -t "$fstype" -o rw,noatime "$DEV" "$MOUNTPOINT" \
        || fail "montage $fstype de $DEV impossible"
fi
log "SSD monte sur $MOUNTPOINT ($DEV)"

free_gb=$(df -BG --output=avail "$MOUNTPOINT" | tail -1 | tr -dc '0-9')
[ "${free_gb:-0}" -ge "$MIN_FREE_GB" ] \
    || fail "seulement ${free_gb} Go libres sur le SSD (minimum ${MIN_FREE_GB} Go)"

mkdir -p "$DEST_ROOT"/{immich,data,configs} \
    || fail "impossible de creer l'arborescence dans $DEST_ROOT"

# --- Options de synchronisation ---------------------------------------------

# Pas de -a : exFAT ne sait stocker ni proprietaire, ni permissions, ni liens
# symboliques (d'ou --copy-links, qui les materialise en vrais fichiers).
# --modify-window absorbe la resolution de 10 ms des dates exFAT ; sans cette
# marge, rsync recopierait l'integralite des donnees a chaque passage.
RSYNC_COMMON=(-rt --copy-links --modify-window=2 --delete --delete-excluded
              --partial --stats
              --exclude=.DS_Store --exclude='._*' --exclude=.Trashes)

IMMICH_ARGS=(--exclude=/thumbs --exclude=/encoded-video
             /mnt/immich/immich/ "$DEST_ROOT/immich/")
DATA_ARGS=(/mnt/data/shared/ "$DEST_ROOT/data/")

# --- Annonce du demarrage ---------------------------------------------------

# Aucune mesure prealable : elle exigerait un "rsync --dry-run", qui parcourt
# les deux arborescences en entier. Or sur exFAT, dont les repertoires sont des
# listes lineaires sans index, ce parcours represente l'essentiel du temps -- il
# serait donc integralement paye deux fois (mesure : 5 min 50 d'analyse pour
# 29 Mo a copier, le 14/08/2026).
#
# L'estimation vient donc de l'historique. Le volume nouveau croit avec le temps
# ecoulé depuis la derniere sauvegarde, d'ou le modele duree = a + b x heures :
# "a" capture le cout fixe du parcours, "b" le rythme d'accumulation. Les deux
# sont ajustes par moindres carres sur les executions precedentes, ce qui fait
# que le systeme se calibre seul (changement de cable, de port, de volumetrie).
estimate_minutes() {
    local gap=$1
    [ -r "$HISTORY_FILE" ] || return 0
    awk -F, -v gap="$gap" '
        NF == 4 && $2 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ {
            x = $2; y = $4 / 60
            n++; sx += x; sy += y; sxx += x * x; sxy += x * y; last = y
        }
        END {
            if (n == 0) exit
            if (n == 1) { printf "%d", (last < 1 ? 1 : last); exit }
            d = n * sxx - sx * sx
            # Toutes les executions au meme intervalle : la pente est
            # indeterminee, on se rabat sur la duree moyenne.
            if (d == 0) { printf "%d", (sy / n < 1 ? 1 : sy / n); exit }
            b = (n * sxy - sx * sy) / d
            a = (sy - b * sx) / n
            e = a + b * gap
            printf "%d", (e < 1 ? 1 : e)
        }
    ' "$HISTORY_FILE"
}

observations=$( [ -r "$HISTORY_FILE" ] && wc -l < "$HISTORY_FILE" || echo 0 )
eta=$(estimate_minutes "${gap_hours:-$DEFAULT_GAP_HOURS}")

log "demarrage, ${gap_hours:-?} h depuis la derniere sauvegarde, estimation ${eta:-inconnue} min"
notify info "Sauvegarde froide demarree" \
    "Copie vers le SSD Extreme en cours. Ne pas debrancher le disque." \
    ${gap_hours:+"Depuis la derniere=$(duration $((gap_hours * 60)))"} \
    ${eta:+"Duree estimee=$(duration "$eta")"} \
    "Estimation calee sur=${observations} execution(s)"

# --- Miroir des donnees -----------------------------------------------------

# $1 = libelle, puis les arguments rsync (options, source, destination)
transferred_total=0
run_rsync() {
    local label=$1 out rc bytes
    shift
    out=$(rsync "${RSYNC_COMMON[@]}" "$@" 2>&1)
    rc=$?
    bytes=$(printf '%s' "$out" \
        | awk -F': *' '/Total transferred file size/ {gsub(/[^0-9]/, "", $2); print $2; exit}')
    transferred_total=$(( transferred_total + ${bytes:-0} ))
    case $rc in
        0)     log "$label : ok, $(human "${bytes:-0}") transferes" ;;
        23|24) warn "$label : termine avec des fichiers ignores (code $rc), $(human "${bytes:-0}") transferes" ;;
        *)     fail "$label : echec rsync (code $rc) — $(printf '%s' "$out" | tail -3 | tr '\n' ' ')" ;;
    esac
}

start=$(date +%s)
start_progress "$start" "$(df -k --output=used "$MOUNTPOINT" | tail -1)" "$eta"

echo "Immich" > "$STAGE_FILE"
run_rsync "Immich" "${IMMICH_ARGS[@]}"
echo "Donnees" > "$STAGE_FILE"
run_rsync "Donnees" "${DATA_ARGS[@]}"
echo "Configurations" > "$STAGE_FILE"

# --- Archive des configurations ---------------------------------------------

# Les configs partent en archive et non en miroir : exFAT perdrait permissions
# et liens symboliques, or c'est justement ce qui compte ici (chmod 600 sur
# /etc/default, liens d'activation dans /etc/systemd/system).
archive="$DEST_ROOT/configs/configs-$(date +%Y%m%d-%H%M).tar.gz"
tar czf "$archive" --warning=no-file-changed --ignore-failed-read \
    /etc/fstab /etc/smartd.conf /etc/samba/smb.conf /etc/nas-backup.exclude \
    /etc/default /etc/systemd/system /etc/udev/rules.d /etc/netplan \
    /usr/local/bin /home/bast/docker /home/bast/immich-app \
    /home/bast/crownicles-prerelease /home/bast/crownicles-beta \
    /home/bast/crownicles-watchtower /home/bast/wireguard \
    /srv/wanderer/docker-compose.yml 2>/dev/null
rc=$?
# tar sort en 1 quand un fichier a bouge pendant l'archivage : ce n'est pas un echec.
if [ $rc -gt 1 ]; then
    fail "echec de l'archive des configurations (code $rc)"
fi
log "configurations archivees ($(du -h "$archive" | cut -f1))"

# shellcheck disable=SC2012
ls -1t "$DEST_ROOT"/configs/configs-*.tar.gz 2>/dev/null \
    | tail -n +$((KEEP_CONFIG_ARCHIVES + 1)) | xargs -r rm -f

# --- Cloture ----------------------------------------------------------------

seconds=$(( $(date +%s) - start ))
minutes=$(( seconds / 60 ))
stop_progress

# Alimente le modele d'estimation de la prochaine execution.
printf '%s,%s,%s,%s\n' "$(date +%s)" "${gap_hours:-$DEFAULT_GAP_HOURS}" \
    "$transferred_total" "$seconds" >> "$HISTORY_FILE"
if [ "$(wc -l < "$HISTORY_FILE")" -gt "$HISTORY_KEEP" ]; then
    tail -n "$HISTORY_KEEP" "$HISTORY_FILE" > "$HISTORY_FILE.tmp" \
        && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
fi

measured=""
if [ "$seconds" -gt 0 ] && [ "$transferred_total" -gt 0 ]; then
    measured=$(( transferred_total / 1048576 / seconds ))
fi

date +%s > "$STATE_FILE"
date '+%Y-%m-%d %H:%M:%S' > "$DEST_ROOT/derniere-sauvegarde.txt"

read -r used avail <<< "$(df -h --output=used,avail "$MOUNTPOINT" | tail -1)"
log "sauvegarde terminee en ${minutes} min, occupation ${used}, libre ${avail}"

unmount_ssd

# Coupe l'alimentation du port : le disque peut etre debranche sans risque.
if [ -n "$parent" ] && udisksctl power-off -b "/dev/$parent" >/dev/null 2>&1; then
    log "alimentation du disque coupee"
    unplug="Le disque est demonte et hors tension : tu peux le debrancher et le ranger."
else
    unplug="Le disque est demonte : tu peux le debrancher."
fi

notify success "Sauvegarde froide terminee" "$unplug" \
    "Duree=$(duration "$minutes")" \
    ${eta:+"Estimation annoncee=$(duration "$eta")"} \
    "Transfere=$(human "$transferred_total")" \
    ${measured:+"Debit moyen=${measured} Mo/s"} \
    "SSD utilise=$used" \
    "SSD libre=$avail"
