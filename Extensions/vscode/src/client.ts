import { connect, type Socket } from 'node:net';
import { FrameDecoder, RateLimiter, encodeFrame } from './framing';
import {
  HINT_LIFETIME_MS,
  PROTOCOL_VERSION,
  ProtocolError,
  SequenceGuard,
  base64url,
  clientProof,
  connectionKey,
  decodeBase64url,
  digestKey,
  equalBytes,
  parseFrame,
  randomNonce,
  seal,
  serverProof,
  valueDigest,
  verifyTag,
  type Hint,
  type ProtocolFailure,
} from './protocol';
import type { Rendezvous } from './rendezvous';
import type { Finding } from './rules';

export type ConnectionState =
  | { kind: 'disconnected' }
  | { kind: 'connecting' }
  | { kind: 'connected' }
  | { kind: 'failed'; reason: ProtocolFailure | 'unreachable' | 'closed' };

const HANDSHAKE_TIMEOUT_MS = 3_000;

/**
 * One authenticated connection to RedScreen. It sends only hints: rule IDs, confidences, and
 * keyed digests. Any protocol violation by the peer closes the connection.
 */
export class HintClient {
  private socket: Socket | undefined;
  private sendKey: Buffer | undefined;
  private receiveKey: Buffer | undefined;
  private hintKey: Buffer | undefined;
  private sendSeq = 0;
  private receiveGuard = new SequenceGuard();
  private readonly limiter: RateLimiter;
  private pending: { doc: Buffer; hints: Hint[] } | undefined;
  private retry: NodeJS.Timeout | undefined;
  private stateValue: ConnectionState = { kind: 'disconnected' };

  constructor(
    private readonly onState: (state: ConnectionState) => void = () => {},
    private readonly now: () => number = Date.now,
    perSecond = 4,
    burst = 8,
  ) {
    this.limiter = new RateLimiter(perSecond, burst, now);
  }

  get state(): ConnectionState {
    return this.stateValue;
  }

  /** Connects and runs the mutual-authentication handshake. Rejects, and closes, on any failure. */
  async connect(rendezvous: Rendezvous): Promise<void> {
    this.close();
    // Sequence numbers are per connection: a new connection starts both directions at zero.
    this.sendSeq = 0;
    this.receiveGuard = new SequenceGuard();
    this.setState({ kind: 'connecting' });
    const socket = connect(rendezvous.socketPath);
    this.socket = socket;
    const decoder = new FrameDecoder();
    const clientNonce = randomNonce();
    let serverNonce: Buffer | undefined;

    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => fail('unreachable'), HANDSHAKE_TIMEOUT_MS);
      const fail = (reason: ProtocolFailure | 'unreachable' | 'closed'): void => {
        clearTimeout(timer);
        this.teardown({ kind: 'failed', reason });
        reject(new Error(reason));
      };
      socket.once('error', () => fail('unreachable'));
      socket.on('close', () => {
        if (this.socket === socket) fail('closed');
      });
      socket.once('connect', () => {
        this.write({ t: 'hello', v: PROTOCOL_VERSION, session: base64url(rendezvous.sessionId), nonce: base64url(clientNonce) });
      });
      socket.on('data', (chunk: Buffer) => {
        try {
          for (const frame of decoder.push(chunk)) {
            if (!serverNonce) {
              const challenge = parseFrame(frame, ['challenge']);
              const nonce = decodeBase64url(challenge.nonce, clientNonce.length);
              const proof = decodeBase64url(challenge.proof, 32);
              // A peer without the session key cannot produce this proof: this is the spoofing check.
              if (!equalBytes(proof, serverProof(rendezvous, clientNonce, nonce))) {
                throw new ProtocolError('authentication-failed');
              }
              serverNonce = nonce;
              this.write({ t: 'auth', v: PROTOCOL_VERSION, proof: base64url(clientProof(rendezvous, clientNonce, nonce)) });
              this.sendKey = connectionKey(rendezvous, clientNonce, nonce, 'client-to-server');
              this.receiveKey = connectionKey(rendezvous, clientNonce, nonce, 'server-to-client');
              this.hintKey = digestKey(rendezvous);
            } else if (this.state.kind === 'connecting') {
              const ready = verifyTag(this.receiveKey!, parseFrame(frame, ['ready']));
              this.receiveGuard.accept(ready.seq);
              clearTimeout(timer);
              this.setState({ kind: 'connected' });
              resolve();
            } else {
              const ack = verifyTag(this.receiveKey!, parseFrame(frame, ['ack']));
              this.receiveGuard.accept(ack.seq);
            }
          }
        } catch (error) {
          fail(error instanceof ProtocolError ? error.reason : 'malformed-message');
        }
      });
    });
  }

  /**
   * Sends the hints for one scan of one document version. `doc` is a random nonce for that
   * scan, never derived from the file name or path. Rate-limited: if messages are coming too
   * fast, only the newest pending scan is sent when allowed.
   */
  sendFindings(doc: Buffer, findings: readonly Finding[]): void {
    if (this.state.kind !== 'connected' || !this.hintKey) return;
    const key = this.hintKey;
    this.pending = {
      doc,
      hints: findings.slice(0, 64).map((finding) => ({
        rule: finding.ruleId,
        conf: Math.round(finding.confidence),
        digest: valueDigest(key, finding.ruleId, finding.value),
      })),
    };
    this.flush();
  }

  /** Withdraws the hints for a document scan, for example when hints are turned off. */
  clear(doc: Buffer): void {
    if (this.state.kind !== 'connected') return;
    if (this.pending && equalBytes(this.pending.doc, doc)) this.pending = undefined;
    this.writeSealed({ t: 'clear', v: PROTOCOL_VERSION, doc: base64url(doc) });
  }

  close(): void {
    this.teardown({ kind: 'disconnected' });
  }

  private flush(): void {
    if (!this.pending || this.retry) return;
    if (!this.limiter.tryTake()) {
      this.retry = setTimeout(() => {
        this.retry = undefined;
        this.flush();
      }, 250);
      return;
    }
    const { doc, hints } = this.pending;
    this.pending = undefined;
    const sent = this.now();
    this.writeSealed({ t: 'hints', v: PROTOCOL_VERSION, sent, expires: sent + HINT_LIFETIME_MS, doc: base64url(doc), hints });
  }

  private writeSealed(body: Record<string, unknown>): void {
    if (!this.sendKey || !this.socket) return;
    const frame = seal(this.sendKey, { ...body, seq: this.sendSeq++ });
    this.socket.write(encodeFrame(frame));
  }

  private write(message: Record<string, unknown>): void {
    this.socket?.write(encodeFrame(Buffer.from(JSON.stringify(message), 'utf8')));
  }

  private teardown(state: ConnectionState): void {
    if (this.retry) clearTimeout(this.retry);
    this.retry = undefined;
    this.pending = undefined;
    const socket = this.socket;
    this.socket = undefined;
    this.sendKey?.fill(0);
    this.receiveKey?.fill(0);
    this.receiveKey = undefined;
    this.hintKey?.fill(0);
    this.sendKey = undefined;
    this.hintKey = undefined;
    socket?.destroy();
    if (this.stateValue.kind !== state.kind || state.kind === 'failed') this.setState(state);
  }

  private setState(state: ConnectionState): void {
    this.stateValue = state;
    this.onState(state);
  }
}
