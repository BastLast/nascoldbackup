# nascoldbackup

Sauvegarde froide automatique et notifications pour un NAS Linux sans écran.

**Branche le disque externe, tout se fait seul** : montage, miroir, archive des
configurations, démontage, mise hors tension. Il ne reste qu'à le débrancher et
le ranger ailleurs. L'avancement arrive en message privé Discord.

```
branchement ──udev──▶ ssd-coldbackup ──▶ miroir rsync ──▶ démontage + hors tension
                            │
                            └──▶ nas-notify ──REST──▶ message privé
```

| Composant | Rôle |
|---|---|
| [`coldbackup/`](coldbackup) | Sauvegarde déclenchée au branchement, purge des anciennes copies |
| [`notifier/`](notifier) | Notifications Discord en message privé, sans processus résident |
| [`alerts/`](alerts) | Surveillance : collecte, regroupement et escalade des incidents |

## Pourquoi

Une sauvegarde froide manuelle n'est jamais faite. Celle-ci ne demande qu'un
geste — brancher un disque — et se met elle-même hors tension pour inciter à le
débrancher, ce qui est la seule chose qui la distingue d'une simple copie
supplémentaire dans la même pièce.

## Une alerte utile est une alerte rare

Un canal de supervision meurt de deux façons : parce qu'il ne dit rien, ou parce
qu'il en dit trop. La seconde est la plus fréquente — un service qui échoue
toutes les 5 minutes produit 8 640 messages par mois, et l'on cesse alors de les
lire.

Les producteurs n'envoient donc **rien** directement : ils déposent un incident
via `nas-alert`, et un examen quotidien décide seul de ce qui mérite attention.

| Niveau | Sens | Acheminement |
|---|---|---|
| `critical` | agir maintenant | immédiat, au plus une fois par jour et par cause |
| `warning` | à savoir | récapitulatif — **escalade si ça persiste** |
| `info` | information | récapitulatif uniquement |

**L'escalade se fonde sur la durée, pas sur le nombre.** Un échec toutes les
5 minutes pendant une heure produit 12 occurrences mais peut déjà être résolu ;
un échec quotidien pendant dix jours n'en produit que 10 et révèle un problème
installé. Un `warning` encore actif dont la première occurrence remonte à plus
de 7 jours devient donc urgent et sort sans attendre le récapitulatif.

**Une cause qui ne se manifeste plus depuis 3 jours est tenue pour résolue.**
Sans cette clôture, un incident réglé continuerait de peser sur les
récapitulatifs — et finirait par escalader tout seul, ce qui serait absurde.

**Le récapitulatif n'est émis que s'il a quelque chose à dire.** Tout va bien =
aucun message. En régime normal, le système est silencieux.

Sont couverts : l'échec de n'importe quelle unité systemd (via un modèle
`OnFailure=`, qui vaut aussi pour les unités à venir), les sauvegardes trop
anciennes, les dumps de base absents, les redémarrages inattendus et les disques
remontés à chaud.

Les contrôles d'**absence** méritent une mention à part : une sauvegarde qui n'a
pas eu lieu ne produit aucun événement. Il faut aller la constater, ce qu'aucun
`OnFailure` ne peut faire — d'où `nas-alert-checks`.

## Points de conception

**Aucun processus résident.** Envoyer un message privé Discord ne demande que
deux appels REST ; la passerelle WebSocket ne sert qu'à *recevoir* des
événements. D'où : pas de démon à surveiller, pas de quota d'`IDENTIFY`
(plafonné à 1000/jour), et pas de dépendance à Docker — un conteneur mort ne
peut pas prévenir qu'il est mort.

**Aucune alerte perdue.** Les notifications non délivrées sont écrites sur
disque et réémises pendant ~24 h, dans l'ordre d'émission.

**L'estimation de durée s'auto-calibre.** Le volume nouveau croît avec le temps
écoulé depuis la dernière sauvegarde, d'où le modèle `durée ≈ a + b × heures`,
ajusté par moindres carrés sur l'historique. Aucune mesure préalable n'est
faite : un `rsync --dry-run` parcourrait les deux arborescences en entier, ce
qui *doublerait* le temps total sur un système de fichiers sans index.

**Les suppressions sont défensives.** La purge compare par empreinte, refuse
d'agir si le volume à récupérer dépasse un plafond, et ne supprime rien si la
récupération est incomplète.

## Pièges rencontrés, et pourquoi ils comptent

**exFAT n'a pas d'index de répertoire.** Chaque recherche est en O(n). Sur
200 000 fichiers, le seul parcours domine le coût d'un incrémental : mesuré à
5 min 50 d'analyse pour 29 Mo réellement copiés. C'est ce qui a fait supprimer
l'estimation par simulation.

**exFAT ne stocke ni propriétaire, ni permissions, ni liens symboliques.** Les
configurations partent donc en archive `tar.gz` et non en miroir — sinon la
sauvegarde serait inutilisable en restauration.

**exFAT n'est pas journalisé.** Une écriture interrompue corrompt le volume,
d'où un démontage sur signal (`trap TERM`) et une coupure d'alimentation en fin
de course.

**macOS et Linux ne normalisent pas l'Unicode pareil.** Un fichier écrit en NFC
apparaît dans `ls` sous macOS mais échoue à l'ouverture : `ls` l'affiche,
`open()` répond `ENOENT`. Un volume déclaré corrompu depuis macOS doit être
revérifié sous Linux avant qu'on ne conclue à une perte.

**Un identifiant ne se compare pas à un nom de fichier.** Les gestionnaires de
photos renomment souvent les fichiers à l'import. Comparer par nom conclut alors
que tout est unique — d'où le plafond de volume, qui transforme une hypothèse
fausse en erreur visible plutôt qu'en copie de plusieurs centaines de Go.

## Installation

Voir [`notifier/README.md`](notifier/README.md) pour les notifications, et les
fichiers `*.example` de [`coldbackup/`](coldbackup) pour la sauvegarde.

Aucun secret n'est versionné : jetons et identifiants matériels vivent dans
`/etc/default/`, en `chmod 600`.
