/**
 * RedScreen hint protocol, version 1. See docs/VSCODE_HINT_PROTOCOL.md.
 *
 * - Peers prove possession of the per-session key from RedScreen's pairing file with HMAC
 *   challenge–response; neither side sends the key.
 * - After the handshake, every message carries a strictly increasing sequence number and an
 *   HMAC-SHA256 tag under a per-connection key derived from both nonces, so a message from one
 *   connection or session is rejected on any other.
 * - Hints carry a rule ID, confidence, and HMAC digest of the normalized value under a
 *   per-session digest key. Values, document text, file names, and paths are never sent.
 * - Anything unexpected (version, field, size, tag, sequence, expiry) fails closed.
 */
import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { RULE_IDS, type RuleId } from './rules';

export const PROTOCOL_NAME = 'redscreen-hints';
export const PROTOCOL_VERSION = 1;
/** Largest frame either side accepts, in bytes of JSON. */
export const MAX_FRAME_BYTES = 16 * 1024;
export const MAX_HINTS_PER_MESSAGE = 64;
/** A hints message is valid for at most this long after it was sent. */
export const HINT_LIFETIME_MS = 30_000;
/** Clock skew tolerated between the peers (same machine, so small). */
export const CLOCK_SKEW_MS = 2_000;

const KEY_BYTES = 32;
const NONCE_BYTES = 16;

export class ProtocolError extends Error {
  constructor(readonly reason: ProtocolFailure) {
    super(`RedScreen hint protocol: ${reason}`);
  }
}

export type ProtocolFailure =
  | 'incompatible-version'
  | 'authentication-failed'
  | 'malformed-message'
  | 'oversized-message'
  | 'unexpected-message'
  | 'replayed-or-out-of-order'
  | 'expired'
  | 'rate-limited';

// MARK: - Encoding and keys

export function base64url(bytes: Buffer): string {
  return bytes.toString('base64url');
}

export function decodeBase64url(value: unknown, length: number): Buffer {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]+$/.test(value)) throw new ProtocolError('malformed-message');
  const bytes = Buffer.from(value, 'base64url');
  if (bytes.length !== length || base64url(bytes) !== value) throw new ProtocolError('malformed-message');
  return bytes;
}

export function randomNonce(): Buffer {
  return randomBytes(NONCE_BYTES);
}

function hmac(key: Buffer, label: string, ...parts: Buffer[]): Buffer {
  const mac = createHmac('sha256', key).update(`rs-hints-v1/${label}`);
  for (const part of parts) mac.update(part);
  return mac.digest();
}

export interface SessionSecrets {
  readonly sessionId: Buffer;
  readonly key: Buffer;
}

export function serverProof(secrets: SessionSecrets, clientNonce: Buffer, serverNonce: Buffer): Buffer {
  return hmac(secrets.key, 'server', secrets.sessionId, clientNonce, serverNonce);
}

export function clientProof(secrets: SessionSecrets, clientNonce: Buffer, serverNonce: Buffer): Buffer {
  return hmac(secrets.key, 'client', secrets.sessionId, serverNonce, clientNonce);
}

/** Per-connection, per-direction message key, so messages cannot be replayed or reflected. */
export function connectionKey(
  secrets: SessionSecrets,
  clientNonce: Buffer,
  serverNonce: Buffer,
  direction: 'client-to-server' | 'server-to-client',
): Buffer {
  return hmac(secrets.key, `conn/${direction}`, secrets.sessionId, clientNonce, serverNonce);
}

export function digestKey(secrets: SessionSecrets): Buffer {
  return hmac(secrets.key, 'digest', secrets.sessionId);
}

/**
 * Canonical text form of a value before digesting, identical on both sides: NFKC, surrounding
 * whitespace and one pair of matching quotes removed. A multi-line value (a private-key block) is
 * each line trimmed, joined with a single "\n", which RedScreen reproduces from its OCR lines.
 */
export function normalizeValue(value: string): string {
  const lines = value
    .normalize('NFKC')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
  return lines.join('\n').replace(/^(["'`])(.*)\1$/s, '$2');
}

/**
 * The keyed digest RedScreen recomputes from OCR text to match a hint. Without the session key
 * it reveals nothing about the value, and it changes with every session.
 */
export function valueDigest(key: Buffer, ruleId: RuleId, value: string): string {
  return base64url(createHmac('sha256', key).update(ruleId).update(Buffer.from([0])).update(normalizeValue(value), 'utf8').digest());
}

export function equalBytes(a: Buffer, b: Buffer): boolean {
  return a.length === b.length && timingSafeEqual(a, b);
}

/** JSON with keys sorted at every level and no whitespace: the bytes that are MAC'd. */
export function canonicalJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${entries.map(([key, entry]) => `${JSON.stringify(key)}:${canonicalJSON(entry)}`).join(',')}}`;
  }
  if (typeof value === 'number' && !Number.isSafeInteger(value)) throw new ProtocolError('malformed-message');
  return JSON.stringify(value);
}

export function messageTag(key: Buffer, body: Record<string, unknown>): string {
  return base64url(createHmac('sha256', key).update(canonicalJSON(body)).digest());
}

// MARK: - Messages

export interface Hint {
  readonly rule: RuleId;
  /** 0–100. */
  readonly conf: number;
  readonly digest: string;
}

export type HandshakeMessage =
  | { t: 'hello'; v: number; session: string; nonce: string }
  | { t: 'challenge'; v: number; nonce: string; proof: string }
  | { t: 'auth'; v: number; proof: string };

export type SessionMessage =
  | { t: 'ready'; v: number; seq: number }
  | { t: 'hints'; v: number; seq: number; sent: number; expires: number; doc: string; hints: Hint[] }
  | { t: 'clear'; v: number; seq: number; doc: string }
  | { t: 'ack'; v: number; seq: number; accepted: number };

const FIELDS: Record<string, readonly string[]> = {
  hello: ['t', 'v', 'session', 'nonce'],
  challenge: ['t', 'v', 'nonce', 'proof'],
  auth: ['t', 'v', 'proof'],
  ready: ['t', 'v', 'seq', 'mac'],
  hints: ['t', 'v', 'seq', 'sent', 'expires', 'doc', 'hints', 'mac'],
  clear: ['t', 'v', 'seq', 'doc', 'mac'],
  ack: ['t', 'v', 'seq', 'accepted', 'mac'],
};
const RULES = new Set<string>(RULE_IDS);

/** Parses one frame into an object with exactly the fields its type allows. */
export function parseFrame(payload: Buffer, expected: readonly string[]): Record<string, unknown> {
  if (payload.length > MAX_FRAME_BYTES) throw new ProtocolError('oversized-message');
  let value: unknown;
  try {
    value = JSON.parse(payload.toString('utf8'));
  } catch {
    throw new ProtocolError('malformed-message');
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new ProtocolError('malformed-message');
  const message = value as Record<string, unknown>;
  if (message.v !== PROTOCOL_VERSION) {
    throw new ProtocolError(typeof message.v === 'number' ? 'incompatible-version' : 'malformed-message');
  }
  const type = message.t;
  if (typeof type !== 'string' || !(type in FIELDS)) throw new ProtocolError('malformed-message');
  if (!expected.includes(type)) throw new ProtocolError('unexpected-message');
  const keys = Object.keys(message).sort();
  if (keys.join(',') !== [...FIELDS[type]!].sort().join(',')) throw new ProtocolError('malformed-message');
  return message;
}

/** Verifies a session message's tag and returns its body (without `mac`). */
export function verifyTag(key: Buffer, message: Record<string, unknown>): Record<string, unknown> {
  const { mac, ...body } = message;
  const expected = Buffer.from(messageTag(key, body), 'base64url');
  const actual = decodeBase64url(mac, 32);
  if (!equalBytes(expected, actual)) throw new ProtocolError('authentication-failed');
  return body;
}

export function seal(key: Buffer, body: Record<string, unknown>): Buffer {
  const frame = Buffer.from(JSON.stringify({ ...body, mac: messageTag(key, body) }), 'utf8');
  if (frame.length > MAX_FRAME_BYTES) throw new ProtocolError('oversized-message');
  return frame;
}

function isSequence(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

/** Field-level checks for a verified hints message, including freshness. */
export function validateHints(body: Record<string, unknown>, now: number): Hint[] {
  const { sent, expires, doc, hints } = body;
  if (!isSequence(body.seq) || !isSequence(sent) || !isSequence(expires)) throw new ProtocolError('malformed-message');
  decodeBase64url(doc, NONCE_BYTES);
  if (expires <= sent || expires - sent > HINT_LIFETIME_MS) throw new ProtocolError('malformed-message');
  if (sent > now + CLOCK_SKEW_MS || expires <= now) throw new ProtocolError('expired');
  if (!Array.isArray(hints) || hints.length > MAX_HINTS_PER_MESSAGE) throw new ProtocolError('malformed-message');
  return hints.map((hint: unknown) => {
    if (hint === null || typeof hint !== 'object' || Array.isArray(hint)) throw new ProtocolError('malformed-message');
    const entry = hint as Record<string, unknown>;
    if (Object.keys(entry).sort().join(',') !== 'conf,digest,rule') throw new ProtocolError('malformed-message');
    if (typeof entry.rule !== 'string' || !RULES.has(entry.rule)) throw new ProtocolError('malformed-message');
    if (!isSequence(entry.conf) || entry.conf > 100) throw new ProtocolError('malformed-message');
    decodeBase64url(entry.digest, 32);
    return { rule: entry.rule as RuleId, conf: entry.conf, digest: entry.digest as string };
  });
}

/** Rejects any sequence number that is not exactly one more than the last. */
export class SequenceGuard {
  private last = -1;

  accept(seq: unknown): void {
    if (!isSequence(seq) || seq !== this.last + 1) throw new ProtocolError('replayed-or-out-of-order');
    this.last = seq;
  }
}

export const KEY_LENGTH = KEY_BYTES;
export const NONCE_LENGTH = NONCE_BYTES;
