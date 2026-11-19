import { lstat, open } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join } from 'node:path';
import {
  KEY_LENGTH,
  NONCE_LENGTH,
  PROTOCOL_NAME,
  PROTOCOL_VERSION,
  ProtocolError,
  decodeBase64url,
  type SessionSecrets,
} from './protocol';

/**
 * The provisional default pairing-file location. RedScreen's listener (RED-13) owns the final
 * location; the setting overrides it.
 */
export function defaultRendezvousPath(): string {
  return join(homedir(), 'Library', 'Group Containers', 'com.georgeadadi.RedScreen.hints', 'rendezvous.json');
}

export interface Rendezvous extends SessionSecrets {
  readonly socketPath: string;
  readonly expiresAt: number;
}

export type RendezvousFailure = 'not-found' | 'insecure' | 'incompatible' | 'expired' | 'malformed';

export class RendezvousError extends Error {
  constructor(readonly reason: RendezvousFailure) {
    super(`RedScreen pairing file: ${reason}`);
  }
}

const MAX_RENDEZVOUS_BYTES = 4096;

/**
 * Reads RedScreen's pairing file. It must be a regular file (not a symlink) owned by this user
 * and unreadable by anyone else, in a directory only this user can write, and the socket it
 * names must satisfy the same rules. Anything else fails closed.
 */
export async function readRendezvous(path: string, now = Date.now(), uid = process.getuid?.() ?? -1): Promise<Rendezvous> {
  if (!isAbsolute(path)) throw new RendezvousError('insecure');
  let info;
  try {
    info = await lstat(path);
  } catch {
    throw new RendezvousError('not-found');
  }
  if (!info.isFile() || info.uid !== uid || (info.mode & 0o077) !== 0 || info.size > MAX_RENDEZVOUS_BYTES) {
    throw new RendezvousError('insecure');
  }
  await requirePrivateDirectory(dirname(path), uid);

  const handle = await open(path, 'r');
  let text: string;
  try {
    text = (await handle.readFile()).toString('utf8');
  } finally {
    await handle.close();
  }
  let value: Record<string, unknown>;
  try {
    value = JSON.parse(text) as Record<string, unknown>;
  } catch {
    throw new RendezvousError('malformed');
  }
  if (value === null || typeof value !== 'object' || value.protocol !== PROTOCOL_NAME) throw new RendezvousError('malformed');
  if (value.version !== PROTOCOL_VERSION) throw new RendezvousError('incompatible');
  if (Object.keys(value).sort().join(',') !== 'expires,key,protocol,session,socket,version') throw new RendezvousError('malformed');
  const { socket, expires } = value;
  if (typeof socket !== 'string' || !isAbsolute(socket) || typeof expires !== 'number') throw new RendezvousError('malformed');
  if (expires <= now) throw new RendezvousError('expired');
  let sessionId: Buffer;
  let key: Buffer;
  try {
    sessionId = decodeBase64url(value.session, NONCE_LENGTH);
    key = decodeBase64url(value.key, KEY_LENGTH);
  } catch (error) {
    if (error instanceof ProtocolError) throw new RendezvousError('malformed');
    throw error;
  }

  let socketInfo;
  try {
    socketInfo = await lstat(socket);
  } catch {
    throw new RendezvousError('not-found');
  }
  if (!socketInfo.isSocket() || socketInfo.uid !== uid) throw new RendezvousError('insecure');
  await requirePrivateDirectory(dirname(socket), uid);
  return { socketPath: socket, expiresAt: expires, sessionId, key };
}

async function requirePrivateDirectory(path: string, uid: number): Promise<void> {
  const info = await lstat(path).catch(() => {
    throw new RendezvousError('not-found');
  });
  if (!info.isDirectory() || info.uid !== uid || (info.mode & 0o077) !== 0) throw new RendezvousError('insecure');
}
