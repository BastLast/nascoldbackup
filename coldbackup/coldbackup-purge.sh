#!/bin/bash
#
# Purge les anciennes copies froides du SSD, apres avoir mis a l'abri ce
# qu'elles seules detiennent. Concu pour tourner sans surveillance.
#
# Reference = ce qui est reellement protege par restic (Immich + data/shared).
# DCIM et signal-media en sont exclus a dessein : ils vivent sur le meme disque
# que le depot restic, donc ne sont pas sauvegardes -- les prendre pour
# reference reviendrait a tenir pour protege ce qui ne l'est pas.
#
# L'appariement se fait par EMPREINTE, jamais par nom : Immich renomme chaque
# fichier en UUID a l'import, donc les noms d'origine ne correspondent
# structurellement jamais. Une comparaison par nom conclut a tort que tout est
# unique (incident du 14/08/2026 : 114 Go recopies, disque data sature).

set -uo pipefail

# shellcheck source=/dev/null
[ -r /etc/default/ssd-coldbackup ] && . /etc/default/ssd-coldbackup

SSD="${MOUNTPOINT:-/mnt/coldbackup}"
DEST=/mnt/data/shared/recuperation-coldbackup-20260814
CANDIDATES=("Cold backup 2026-08-06" "Cold backup photos 03052024" "images")

REFERENCE=/var/tmp/reference-hashes.txt
SSD_HASHES=/var/tmp/ssd-hashes.txt
UNIQUES=/var/tmp/ssd-uniques.txt

# Au-dela, on considere que la comparaison a echoue plutot que de recopier
# des centaines de Go : c'est le garde-fou qui manquait lors de l'incident.
MAX_RECOVERY_GB=50

log() { logger -t coldbackup-purge -p daemon.info -- "$*"; echo "$*"; }
notify() {
    local level=$1 title=$2 description=$3
    shift 3
    local args=() f
    for f in "$@"; do args+=(--field "$f"); done
    /usr/local/bin/nas-notify --level "$level" --title "$title" \
        --description "$description" --source coldbackup-purge "${args[@]}" || true
}

fail() {
    log "ECHEC : $1"
    notify error "Purge des copies froides : echec" "$1"
    exit 1
}

findmnt -rno TARGET "$SSD" >/dev/null || fail "$SSD n'est pas monte"
findmnt -rno TARGET /mnt/data >/dev/null || fail "/mnt/data n'est pas monte"

notify info "Purge des copies froides demarree" \
    "Comparaison par empreinte des anciennes copies froides avec ce que detient le NAS. Ne pas debrancher le disque."

log "empreintes de reference"
find /mnt/immich/immich/upload /mnt/immich/immich/library /mnt/data/shared \
     -type f -print0 2>/dev/null \
    | xargs -0 -P 4 -n 64 sha256sum 2>/dev/null \
    | cut -d' ' -f1 | sort -u > "$REFERENCE"
reference_count=$(wc -l < "$REFERENCE")
[ "$reference_count" -gt 1000 ] || fail "index de reference anormalement petit ($reference_count)"
log "  $reference_count empreintes"

log "empreintes du SSD"
: > "$SSD_HASHES"
for dir in "${CANDIDATES[@]}"; do
    [ -d "$SSD/$dir" ] || continue
    find "$SSD/$dir" -type f -print0 2>/dev/null \
        | xargs -0 -P 2 -n 64 sha256sum 2>/dev/null >> "$SSD_HASHES"
    log "  $dir traite"
done

awk -v ref="$REFERENCE" '
    BEGIN { while ((getline line < ref) > 0) seen[line] }
    {
        hash = $1
        sub(/^[0-9a-f]+  /, "")
        if (!(hash in seen)) print
    }' "$SSD_HASHES" > "$UNIQUES"

unique_count=$(wc -l < "$UNIQUES")
unique_bytes=$(awk '{ printf "%s\n", $0 }' "$UNIQUES" \
    | while IFS= read -r f; do stat -c%s "$f" 2>/dev/null; done \
    | awk '{s += $1} END {print s + 0}')
unique_gb=$(awk -v b="$unique_bytes" 'BEGIN { printf "%.2f", b / 1073741824 }')
log "$unique_count fichier(s) unique(s), $unique_gb Go"

if awk -v b="$unique_bytes" -v max="$MAX_RECOVERY_GB" \
    'BEGIN { exit !(b / 1073741824 > max) }'; then
    fail "volume unique anormal ($unique_gb Go > $MAX_RECOVERY_GB Go) : comparaison suspecte, aucune suppression"
fi

available_bytes=$(( $(df -k --output=avail /mnt/data | tail -1) * 1024 ))
[ "$available_bytes" -gt $(( unique_bytes + 10737418240 )) ] \
    || fail "espace insuffisant sur /mnt/data pour la recuperation"

if [ "$unique_count" -gt 0 ]; then
    log "recuperation vers $DEST"
    while IFS= read -r file; do
        relative=${file#"$SSD"/}
        mkdir -p "$DEST/$(dirname "$relative")" || fail "creation de repertoire impossible"
        cp -p "$file" "$DEST/$relative" || fail "copie impossible : $relative"
    done < "$UNIQUES"
    chown -R bast-nas-user:bast-nas-user "$DEST"
    copied=$(find "$DEST" -type f | wc -l)
    [ "$copied" -eq "$unique_count" ] \
        || fail "recuperation incomplete ($copied/$unique_count), aucune suppression"
    log "  $copied fichier(s) recupere(s)"
fi

log "suppression des anciennes copies froides"
freed_before=$(df -k --output=used "$SSD" | tail -1)
for dir in "${CANDIDATES[@]}"; do
    [ -d "$SSD/$dir" ] || continue
    rm -rf "$SSD/$dir" || fail "suppression impossible : $dir"
    log "  $dir supprime"
done
freed_gb=$(awk -v a="$freed_before" -v b="$(df -k --output=used "$SSD" | tail -1)" \
    'BEGIN { printf "%.1f", (a - b) / 1048576 }')

read -r used avail <<< "$(df -h --output=used,avail "$SSD" | tail -1)"
log "termine : $freed_gb Go liberes, $avail disponibles"

sync
umount "$SSD" && log "disque demonte"
if [ -n "${SSD_UUID:-}" ]; then
    parent=$(lsblk -no pkname "$(blkid -U "$SSD_UUID")" 2>/dev/null)
    [ -n "$parent" ] && udisksctl power-off -b "/dev/$parent" >/dev/null 2>&1
fi

notify success "Purge des copies froides terminee" \
    "Le disque est demonte et hors tension : tu peux le debrancher et le ranger." \
    "Libere=${freed_gb} Go" \
    "Recuperes=${unique_count} fichier(s), ${unique_gb} Go" \
    "SSD utilise=$used" \
    "SSD libre=$avail"
