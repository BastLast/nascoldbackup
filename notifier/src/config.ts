import { readFileSync } from "node:fs";

const CONFIG_FILE = process.env.NAS_NOTIFY_CONFIG ?? "/etc/default/nas-notify";

/**
 * Lit un fichier de type EnvironmentFile systemd (`CLE=valeur`).
 *
 * Le client est invoque en ligne de commande, sans passer par systemd : il
 * doit donc charger lui-meme sa configuration.
 */
function readEnvFile(path: string): Record<string, string> {
	let content: string;
	try {
		content = readFileSync(path, "utf8");
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT") {
			return {};
		}
		throw new Error(`configuration ${path} illisible : ${String(error)}`);
	}

	const values: Record<string, string> = {};
	for (const line of content.split("\n")) {
		const trimmed = line.trim();
		if (trimmed === "" || trimmed.startsWith("#")) {
			continue;
		}
		const separator = trimmed.indexOf("=");
		if (separator === -1) {
			continue;
		}
		const key = trimmed.slice(0, separator).trim();
		values[key] = trimmed.slice(separator + 1).trim().replace(/^["']|["']$/gu, "");
	}
	return values;
}

export type Config = {
	discordToken: string;
	ownerId: string;
	spoolDir: string;
};

export function loadConfig(): Config {
	const file = readEnvFile(CONFIG_FILE);
	const get = (key: string): string | undefined => process.env[key]?.trim() || file[key]?.trim();

	const discordToken = get("DISCORD_TOKEN");
	const ownerId = get("OWNER_ID");

	if (!discordToken) {
		throw new Error(`DISCORD_TOKEN absent de ${CONFIG_FILE}`);
	}
	if (!ownerId) {
		throw new Error(`OWNER_ID absent de ${CONFIG_FILE}`);
	}

	return {
		discordToken,
		ownerId,
		spoolDir: get("SPOOL_DIR") ?? "/var/spool/nas-notify"
	};
}
