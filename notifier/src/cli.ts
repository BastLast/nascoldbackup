#!/usr/bin/env node
import { closeSync, openSync, rmSync } from "node:fs";
import { join } from "node:path";

import { loadConfig } from "./config.js";
import { DiscordRest, PermanentDeliveryError } from "./discord.js";
import {
	buildNotification,
	isNotificationLevel,
	type NotificationField,
	type NotificationLevel
} from "./notification.js";
import { Spool } from "./spool.js";

const USAGE = `Usage :
  nas-notify --title <titre> [options]
  nas-notify --flush

Options :
  --title <texte>        Titre de l'alerte (obligatoire)
  --description <texte>  Corps du message
  --level <niveau>       info | success | warning | error   (defaut : info)
  --source <nom>         Service emetteur, affiche en pied de message
  --field <Nom=Valeur>   Champ additionnel, repetable
  --flush                Reemet les notifications en attente puis quitte
`;

type Arguments = {
	flush: boolean;
	title: string;
	description: string;
	level: NotificationLevel;
	source: string;
	fields: NotificationField[];
};

function parseArguments(argv: string[]): Arguments {
	const result: Arguments = {
		flush: false,
		title: "",
		description: "",
		level: "info",
		source: "",
		fields: []
	};

	for (let index = 0; index < argv.length; index++) {
		const flag = argv[index];
		if (flag === "--flush") {
			result.flush = true;
			continue;
		}
		if (flag === "--help" || flag === "-h") {
			process.stdout.write(USAGE);
			process.exit(0);
		}

		const value = argv[++index];
		if (value === undefined) {
			throw new Error(`valeur manquante pour ${flag}`);
		}
		switch (flag) {
			case "--title":
				result.title = value;
				break;
			case "--description":
				result.description = value;
				break;
			case "--source":
				result.source = value;
				break;
			case "--level":
				if (!isNotificationLevel(value)) {
					throw new Error(`niveau inconnu : ${value}`);
				}
				result.level = value;
				break;
			case "--field": {
				const separator = value.indexOf("=");
				if (separator <= 0) {
					throw new Error(`champ invalide : ${value} (format attendu Nom=Valeur)`);
				}
				result.fields.push({
					name: value.slice(0, separator),
					value: value.slice(separator + 1),
					inline: true
				});
				break;
			}
			default:
				throw new Error(`option inconnue : ${flag}`);
		}
	}
	return result;
}

function warn(message: string): void {
	process.stderr.write(`[nas-notify] ${message}\n`);
}

/** Empeche deux reprises simultanees de traiter le meme fichier. */
function acquireLock(path: string): (() => void) | undefined {
	try {
		closeSync(openSync(path, "wx"));
		return () => rmSync(path, { force: true });
	} catch {
		return undefined;
	}
}

async function flush(discord: DiscordRest, spool: Spool): Promise<void> {
	const release = acquireLock(join(spool.directory, ".flush.lock"));
	if (!release) {
		warn("une reprise est deja en cours");
		return;
	}

	try {
		for (const name of spool.list()) {
			const item = spool.read(name);
			if (!item) {
				spool.giveUp(name);
				continue;
			}
			try {
				await discord.send(item.notification);
				spool.remove(name);
			} catch (error) {
				if (error instanceof PermanentDeliveryError) {
					warn(`abandon de "${item.notification.title}" : ${error.message}`);
					spool.giveUp(name);
					continue;
				}
				// Echec transitoire : on s'arrete pour preserver l'ordre
				// d'emission, la prochaine reprise repartira d'ici.
				if (spool.recordAttempt(name, item)) {
					warn(`reprise impossible pour l'instant : ${String(error)}`);
				} else {
					warn(`abandon apres trop de tentatives : ${item.notification.title}`);
				}
				return;
			}
		}
	} finally {
		release();
	}
}

async function main(): Promise<void> {
	let args: Arguments;
	try {
		args = parseArguments(process.argv.slice(2));
	} catch (error) {
		process.stderr.write(`${String(error)}\n\n${USAGE}`);
		process.exit(2);
	}

	if (!args.flush && args.title === "") {
		process.stderr.write(`--title est obligatoire\n\n${USAGE}`);
		process.exit(2);
	}

	const config = loadConfig();
	const spool = new Spool(config.spoolDir);
	const discord = new DiscordRest(config.discordToken, config.ownerId, config.spoolDir);

	if (args.flush) {
		await flush(discord, spool);
		return;
	}

	const notification = buildNotification({
		title: args.title,
		level: args.level,
		...(args.description ? { description: args.description } : {}),
		...(args.source ? { source: args.source } : {}),
		...(args.fields.length > 0 ? { fields: args.fields } : {})
	});

	// Les notifications deja en attente partent d'abord, pour ne pas annoncer
	// la fin d'une sauvegarde avant son debut.
	if (spool.list().length > 0) {
		await flush(discord, spool);
	}

	try {
		await discord.send(notification);
	} catch (error) {
		if (error instanceof PermanentDeliveryError) {
			warn(`notification refusee par Discord, abandon : ${error.message}`);
			return;
		}
		spool.store(notification);
		warn(`envoi differe (${String(error)})`);
	}
}

main().catch((error: unknown) => {
	// Le client ne doit jamais faire echouer le script appelant : une
	// notification perdue ne justifie pas d'interrompre une sauvegarde.
	warn(String(error));
	process.exit(0);
});
