#!/bin/bash
#
# Alerte SMART transmise en message prive Discord.
# Appele par smartd via la directive "-M exec" de /etc/smartd.conf.
#
# Les variables SMARTD_* sont fournies par smartd.

set -u

# Une defaillance annoncee (prefail) laisse le temps d'agir ; une defaillance
# constatee est immediate. Les deux ne meritent pas la meme couleur.
level=error
case "${SMARTD_FAILTYPE:-}" in
    *[Pp]refail*) level=warning ;;
esac

/usr/local/bin/nas-notify \
    --title "Alerte SMART — $(basename "${SMARTD_DEVICE:-disque inconnu}")" \
    --level "$level" \
    --source smartd \
    --description "${SMARTD_MESSAGE:-anomalie signalee par smartd}" \
    --field "Peripherique=${SMARTD_DEVICE:-inconnu}" \
    --field "Type=${SMARTD_FAILTYPE:-non precise}" \
    --field "Premiere occurrence=${SMARTD_TFIRST:-maintenant}"

# Conserve le comportement par defaut de smartd (courriel local).
[ -x /usr/share/smartmontools/smartd-runner ] && /usr/share/smartmontools/smartd-runner "$@"

exit 0
