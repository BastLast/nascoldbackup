import { mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import type { Notification, QueuedNotification } from "./notification.js";

/** 288 tentatives a 5 min d'intervalle : environ 24 h de reprise. */
const MAX_ATTEMPTS = 288;

/** Au-dela, les echecs les plus anciens sont purges. */
const MAX_FAILED_FILES = 100;

/**
 * File d'attente sur disque des notifications non delivrees.
 *
 * Sans processus resident, c'est le systeme de fichiers qui tient le role de
 * file : une alerte emise pendant une coupure reseau est deposee ici, puis
 * reprise par le timer `nas-notify-flush`. Une alerte materielle ne doit
 * jamais disparaitre parce que Discord etait momentanement injoignable.
 */
export class Spool {
	readonly #failedDir: string;

	constructor(private readonly dir: string) {
		this.#failedDir = join(dir, "failed");
		mkdirSync(this.#failedDir, { recursive: true, mode: 0o700 });
	}

	get directory(): string {
		return this.dir;
	}

	store(notification: Notification, attempts = 0): string {
		const name = `${Date.now().toString().padStart(14, "0")}-${process.pid}-${Math.random()
			.toString(36)
			.slice(2, 8)}.json`;
		const payload: QueuedNotification = {
			notification,
			queuedAt: new Date().toISOString(),
			attempts
		};
		this.#writeAtomic(join(this.dir, name), payload);
		return name;
	}

	/** Noms des notifications en attente, du plus ancien au plus recent. */
	list(): string[] {
		return readdirSync(this.dir)
			.filter(name => name.endsWith(".json"))
			.sort();
	}

	read(name: string): QueuedNotification | undefined {
		try {
			return JSON.parse(readFileSync(join(this.dir, name), "utf8")) as QueuedNotification;
		} catch {
			return undefined;
		}
	}

	remove(name: string): void {
		rmSync(join(this.dir, name), { force: true });
	}

	/** Enregistre une nouvelle tentative. Renvoie `false` si le maximum est atteint. */
	recordAttempt(name: string, item: QueuedNotification): boolean {
		if (item.attempts + 1 >= MAX_ATTEMPTS) {
			this.giveUp(name);
			return false;
		}
		this.#writeAtomic(join(this.dir, name), { ...item, attempts: item.attempts + 1 });
		return true;
	}

	/** Ecarte definitivement une notification, en la conservant pour analyse. */
	giveUp(name: string): void {
		try {
			renameSync(join(this.dir, name), join(this.#failedDir, name));
		} catch {
			this.remove(name);
		}
		this.#purgeFailed();
	}

	#purgeFailed(): void {
		const files = readdirSync(this.#failedDir).sort();
		for (const name of files.slice(0, Math.max(0, files.length - MAX_FAILED_FILES))) {
			rmSync(join(this.#failedDir, name), { force: true });
		}
	}

	// Ecriture atomique : une coupure en pleine ecriture laisserait sinon un
	// JSON tronque, donc une notification illisible et perdue.
	#writeAtomic(path: string, payload: QueuedNotification): void {
		const temporary = `${path}.tmp`;
		writeFileSync(temporary, JSON.stringify(payload), { encoding: "utf8", mode: 0o600 });
		renameSync(temporary, path);
	}
}
