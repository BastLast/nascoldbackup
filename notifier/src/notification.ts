/** Couleurs d'embed Discord, par niveau de gravite. */
export const LEVEL_COLORS = {
	info: 0x3498db,
	success: 0x2ecc71,
	warning: 0xf1c40f,
	error: 0xe74c3c
} as const;

export type NotificationLevel = keyof typeof LEVEL_COLORS;

export type NotificationField = {
	name: string;
	value: string;
	inline?: boolean;
};

export type Notification = {
	title: string;
	description?: string;
	level: NotificationLevel;

	/** Service emetteur, affiche en pied d'embed (ex. "ssd-coldbackup"). */
	source?: string;
	fields?: NotificationField[];
};

/** Notification en attente, telle qu'elle est persistee dans le spool. */
export type QueuedNotification = {
	notification: Notification;
	queuedAt: string;
	attempts: number;
};

/** Limites imposees par l'API Discord aux embeds. */
const LIMITS = {
	title: 256,
	description: 4096,
	fieldName: 256,
	fieldValue: 1024,
	fields: 25
} as const;

function truncate(value: string, max: number): string {
	return value.length <= max ? value : `${value.slice(0, max - 1)}…`;
}

export function isNotificationLevel(value: string): value is NotificationLevel {
	return value in LEVEL_COLORS;
}

export type NotificationInput = {
	title: string;
	description?: string;
	level: NotificationLevel;
	source?: string;
	fields?: NotificationField[];
};

/**
 * Normalise une notification aux limites de Discord.
 *
 * Les valeurs trop longues sont tronquees plutot que rejetees : une alerte
 * verbeuse doit arriver amputee, jamais disparaitre.
 */
export function buildNotification(input: NotificationInput): Notification {
	const fields = (input.fields ?? []).slice(0, LIMITS.fields).map(field => ({
		name: truncate(field.name, LIMITS.fieldName),
		value: truncate(field.value, LIMITS.fieldValue),
		...(field.inline === true ? { inline: true } : {})
	}));

	return {
		title: truncate(input.title, LIMITS.title),
		level: input.level,
		...(input.description ? { description: truncate(input.description, LIMITS.description) } : {}),
		...(input.source ? { source: input.source } : {}),
		...(fields.length > 0 ? { fields } : {})
	};
}
