import { randomBytes } from 'node:crypto';
import type { Finding, SecretDetector } from './rules';

/** The editor document as the scanner sees it: an opaque key, a version, and its text. */
export interface ScannedDocument {
  /** In-memory identity for this editor session only. Never sent. */
  readonly key: string;
  readonly version: number;
  getText(): string;
}

export interface Scheduler {
  set(callback: () => void, milliseconds: number): unknown;
  clear(handle: unknown): void;
}

export const systemScheduler: Scheduler = {
  set: (callback, milliseconds) => setTimeout(callback, milliseconds),
  clear: (handle) => clearTimeout(handle as NodeJS.Timeout),
};

export interface HintSink {
  /** Replaces the hints for `doc` with these findings. */
  send(doc: Buffer, findings: readonly Finding[]): void;
  /** Withdraws the hints for `doc`. */
  clear(doc: Buffer): void;
}

export type ScanOutcome =
  | { kind: 'scanned'; findings: number }
  | { kind: 'too-large' }
  | { kind: 'stale' };

/** Larger documents are skipped rather than scanned, to keep the editor responsive. */
export const MAX_SCANNED_CHARACTERS = 1_000_000;

/**
 * Scans one document at a time, only when asked. Edits are debounced; a newer edit, a cancel, or a
 * document switch makes any pending scan stale, and a stale scan's results are dropped. Each
 * document gets a random nonce for this session, used only to replace or withdraw its hints.
 */
export class HintScanner {
  private pending: { handle: unknown; generation: number } | undefined;
  private generation = 0;
  private readonly nonces = new Map<string, Buffer>();

  constructor(
    private readonly detector: SecretDetector,
    private readonly sink: HintSink,
    private readonly debounceMilliseconds: () => number,
    private readonly scheduler: Scheduler = systemScheduler,
  ) {}

  /** Scans now, for an explicit user action. */
  scanNow(document: ScannedDocument): ScanOutcome {
    this.cancel();
    return this.scan(document, document.version, this.generation);
  }

  /** Scans after the debounce interval, unless something newer happens first. */
  schedule(document: ScannedDocument): void {
    this.cancel();
    const generation = this.generation;
    const version = document.version;
    const handle = this.scheduler.set(() => {
      if (this.pending?.generation === generation) this.pending = undefined;
      this.scan(document, version, generation);
    }, this.debounceMilliseconds());
    this.pending = { handle, generation };
  }

  /** Cancels any pending scan. */
  cancel(): void {
    this.generation++;
    if (this.pending) this.scheduler.clear(this.pending.handle);
    this.pending = undefined;
  }

  /** Withdraws a document's hints and forgets its nonce, for example when it closes. */
  forget(key: string): void {
    const nonce = this.nonces.get(key);
    if (!nonce) return;
    this.sink.clear(nonce);
    this.nonces.delete(key);
  }

  /** Withdraws every document's hints. */
  forgetAll(): void {
    this.cancel();
    for (const key of [...this.nonces.keys()]) this.forget(key);
  }

  get hasPendingScan(): boolean {
    return this.pending !== undefined;
  }

  private scan(document: ScannedDocument, version: number, generation: number): ScanOutcome {
    // Superseded by a newer schedule or cancel, or the text changed since it was scheduled.
    if (generation !== this.generation || document.version !== version) return { kind: 'stale' };
    const text = document.getText();
    if (text.length > MAX_SCANNED_CHARACTERS) return { kind: 'too-large' };
    const findings = this.detector.detect(text);
    if (generation !== this.generation || document.version !== version) return { kind: 'stale' };
    let nonce = this.nonces.get(document.key);
    if (!nonce) {
      nonce = randomBytes(16);
      this.nonces.set(document.key, nonce);
    }
    this.sink.send(nonce, findings);
    return { kind: 'scanned', findings: findings.length };
  }
}
