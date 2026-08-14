# nas-discord-notifier

Notifications du NAS Banane en **message privé Discord**.

Le NAS est sans écran ni interface graphique : c'est le canal par lequel il
rend compte de ce qu'il fait — sauvegardes, alertes SMART, incidents disque.

```
script système ──▶ nas-notify ──REST──▶ message privé
                        │
                        └─ échec réseau ─▶ /var/spool/nas-notify
                                              ▲
                              nas-notify-flush.timer (5 min)
```

## Aucun processus résident

Envoyer un message privé ne demande que deux appels REST : ouvrir le canal
privé, puis y poster. La passerelle WebSocket de Discord ne sert qu'à
*recevoir* des événements, ce dont ce projet n'a pas l'usage.

Conséquences directes :

- **pas de démon** à surveiller, ni de fuite mémoire possible ;
- **pas de quota d'`IDENTIFY`** — Discord en limite à 1000 par jour et par bot,
  ce qui pénaliserait un bot démarré à chaque alerte ;
- **pas de dépendance à Docker**, qui créerait une boucle : un conteneur mort
  ne peut pas prévenir qu'il est mort ;
- ~200 ms par alerte, contre 2 à 5 s pour établir une session passerelle.

Le canal privé est mis en cache sur disque, ce qui ramène l'envoi courant à un
seul appel REST.

## Prérequis

⚠️ **Discord n'autorise un bot à écrire en privé qu'à une personne avec qui il
partage un serveur.** Il faut donc l'inviter sur un serveur dont tu es membre,
même vide. Sans cela l'API répond `50007 Cannot send messages to this user`.

Aucun intent ni permission n'est nécessaire : le bot n'écoute rien.

## Installation

```bash
sudo mkdir -p /opt/nas-discord-notifier
sudo rsync -a --exclude node_modules --exclude .git ./ /opt/nas-discord-notifier/
cd /opt/nas-discord-notifier && sudo npm ci && sudo npm run build

sudo install -m 755 bin/nas-notify /usr/local/bin/nas-notify
sudo install -m 600 nas-notify.env.example /etc/default/nas-notify
sudo nano /etc/default/nas-notify        # renseigner DISCORD_TOKEN

sudo install -m 644 deploy/nas-notify-flush.service deploy/nas-notify-flush.timer \
    /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nas-notify-flush.timer
```

Les dépendances de développement (TypeScript) peuvent être retirées après la
compilation : **le code produit n'a aucune dépendance d'exécution**.

## Utilisation

```bash
nas-notify --title "Sauvegarde terminée" \
           --level success \
           --source ssd-coldbackup \
           --description "360 Go copiés" \
           --field "Durée=26 min" --field "Débit=232 Mo/s"

nas-notify --flush     # réémet les notifications en attente
```

Niveaux : `info`, `success`, `warning`, `error` — ils déterminent la couleur.

## Garanties

**Le client ne fait jamais échouer le script appelant.** Il sort toujours en 0,
sauf erreur d'usage (`--title` manquant, option inconnue). Une notification
perdue ne doit pas interrompre une sauvegarde.

**Une alerte n'est pas perdue sur incident réseau.** Elle est déposée dans le
spool et réémise par le timer, pendant environ 24 h. L'ordre d'émission est
préservé : en cas d'échec la reprise s'arrête sur l'élément courant, pour ne
jamais annoncer la fin d'une sauvegarde avant son début.

**Les échecs définitifs ne bouclent pas.** Un jeton invalide ou l'absence de
serveur commun renvoie un `4xx` : la notification part alors dans
`spool/failed/` pour analyse, au lieu d'être réessayée indéfiniment. Seuls les
`5xx`, les `429` et les erreurs réseau donnent lieu à une reprise.

**Les valeurs trop longues sont tronquées, jamais rejetées** : une alerte
verbeuse doit arriver amputée plutôt que disparaître.

## Diagnostic

```bash
ls /var/spool/nas-notify/*.json          # notifications en attente
ls /var/spool/nas-notify/failed/         # abandons, avec leur contenu
systemctl list-timers nas-notify-flush   # prochaine reprise
journalctl -u nas-notify-flush -n 20     # échecs de reprise

nas-notify --title "Test" --level info --source manuel
```

## Sécurité

Le jeton vit dans `/etc/default/nas-notify`, en `chmod 600` root. Les scripts
émetteurs (sauvegardes, smartd) tournent déjà sous root ; aucun service exposé
ne le lit, et aucun port n'est ouvert.
