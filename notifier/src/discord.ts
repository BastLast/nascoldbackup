import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { LEVEL_COLORS, type Notification } from "./notification.js";

const API_BASE = "https://discord.com/api/v10";
const REQUEST_TIMEOUT_MS = 10_000;
const MAX_RATE_LIMIT_RETRIES = 3;

/**
 * Echec qu'il est inutile de reessayer : jeton invalide, bot absent du
 * serveur commun, destinataire introuvable. Une mise en file ne ferait que
 * repeter l'erreur indefiniment.
 */
export class PermanentDeliveryError extends Error {}

function sleep(ms: number): Promise<void> {
	return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * Client REST minimal de l'API Discord, limite a l'envoi de messages prives.
 *
 * Aucune connexion permanente : la passerelle WebSocket ne sert qu'a recevoir
 * des evenements, dont on n'a pas l'usage ici. On evite ainsi un demon
 * resident et le quota de 1000 IDENTIFY par jour.
 */
export class DiscordRest {
	readonly #channelCacheFile: string;

	constructor(
		private readonly token: string,
		private readonly ownerId: string,
		cacheDir: string
	) {
		this.#channelCacheFile = join(cacheDir, "dm-channel-id");
	}

	async #request(path: string, body: unknown): Promise<unknown> {
		for (let attempt = 0; attempt <= MAX_RATE_LIMIT_RETRIES; attempt++) {
			const response = await fetch(`${API_BASE}${path}`, {
				method: "POST",
				headers: {
					Authorization: `Bot ${this.token}`,
					"Content-Type": "application/json"
				},
				body: JSON.stringify(body),
				signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS)
			});

			if (response.ok) {
				return await response.json();
			}

			const detail = await response.text().catch(() => "");

			if (response.status === 429) {
				const retryAfter = Number(response.headers.get("retry-after") ?? "1");
				await sleep(Math.min(retryAfter, 60) * 1000);
				continue;
			}

			// 5xx et 408 sont transitoires : ils meritent une nouvelle tentative
			// plus tard, donc une mise en file plutot qu'un abandon.
			if (response.status >= 500 || response.status === 408) {
				throw new Error(`Discord a repondu ${response.status} : ${detail}`);
			}

			throw new PermanentDeliveryError(
				`Discord a refuse la requete (${response.status}) : ${detail}`
			);
		}
		throw new Error("limite de debit Discord persistante");
	}

	#readCachedChannel(): string | undefined {
		try {
			const cached = readFileSync(this.#channelCacheFile, "utf8").trim();
			return cached === "" ? undefined : cached;
		} catch {
			return undefined;
		}
	}

	async #openDmChannel(): Promise<string> {
		const cached = this.#readCachedChannel();
		if (cached) {
			return cached;
		}

		const channel = await this.#request("/users/@me/channels", {
			recipient_id: this.ownerId
		});
		const id = (channel as { id?: unknown }).id;
		if (typeof id !== "string") {
			throw new Error("reponse inattendue a l'ouverture du canal prive");
		}

		// Le canal prive est stable : le mettre en cache economise un appel
		// REST par notification.
		try {
			writeFileSync(this.#channelCacheFile, id, "utf8");
		} catch {
			// Un cache non ecrit ne justifie pas de perdre la notification.
		}
		return id;
	}

	async send(notification: Notification): Promise<void> {
		const embed = {
			title: notification.title,
			color: LEVEL_COLORS[notification.level],
			timestamp: new Date().toISOString(),
			footer: { text: notification.source ? `NAS · ${notification.source}` : "NAS" },
			...(notification.description ? { description: notification.description } : {}),
			...(notification.fields ? { fields: notification.fields } : {})
		};

		const channelId = await this.#openDmChannel();
		try {
			await this.#request(`/channels/${channelId}/messages`, { embeds: [embed] });
		} catch (error) {
			// Un canal en cache peut avoir ete invalide : on retente une fois
			// avec un canal fraichement ouvert avant de conclure a un echec.
			if (error instanceof PermanentDeliveryError && this.#readCachedChannel()) {
				writeFileSync(this.#channelCacheFile, "", "utf8");
				const retryChannel = await this.#openDmChannel();
				await this.#request(`/channels/${retryChannel}/messages`, { embeds: [embed] });
				return;
			}
			throw error;
		}
	}
}
