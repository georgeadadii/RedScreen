/**
 * A fake RedScreen listener for tests. It is the reference server side of the protocol: it
 * publishes a private pairing file, authenticates the client, and validates every message the
 * way RedScreen must (RED-13). Options let tests make it misbehave.
 */
import { randomBytes } from 'node:crypto';
import { chmod, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { createServer, type Server, type Socket } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { FrameDecoder, RateLimiter, encodeFrame } from '../../src/framing';
import {
  PROTOCOL_NAME,
  PROTOCOL_VERSION,
  ProtocolError,
  SequenceGuard,
  base64url,
  clientProof,
  connectionKey,
  decodeBase64url,
  equalBytes,
  parseFrame,
  randomNonce,
  seal,
  serverProof,
  validateHints,
  verifyTag,
  type Hint,
  type ProtocolFailure,
  type SessionSecrets,
} from '../../src/protocol';

export interface FakePeerOptions {
  /** Answer the challenge with this key instead of the published one (a spoofed peer). */
  readonly proofKey?: Buffer;
  /** Protocol version to answer with. */
  readonly answerVersion?: number;
  /** Messages per second before the peer closes the connection. */
  readonly ratePerSecond?: number;
  readonly now?: () => number;
}

export interface ReceivedHints {
  readonly doc: string;
  readonly hints: Hint[];
}

export class FakePeer {
  readonly directory: string;
  readonly socketPath: string;
  readonly rendezvousPath: string;
  readonly secrets: SessionSecrets;
  /** Every byte any client sent, to prove no raw values were transmitted. */
  rawReceived = Buffer.alloc(0);
  readonly received: ReceivedHints[] = [];
  readonly cleared: string[] = [];
  readonly failures: ProtocolFailure[] = [];
  /** Connection keys of the most recent authenticated connection, for replay tests. */
  lastKeys: { clientToServer: Buffer; serverToClient: Buffer } | undefined;
  private server: Server | undefined;
  private readonly sockets = new Set<Socket>();
  private readonly waiters: (() => void)[] = [];

  private constructor(directory: string, private readonly options: FakePeerOptions) {
    this.directory = directory;
    this.socketPath = join(directory, 'hints.sock');
    this.rendezvousPath = join(directory, 'rendezvous.json');
    this.secrets = { sessionId: randomBytes(16), key: randomBytes(32) };
  }

  static async start(options: FakePeerOptions = {}, expiresIn = 60_000): Promise<FakePeer> {
    const directory = await mkdtemp(join(tmpdir(), 'rs-hints-'));
    await chmod(directory, 0o700);
    const peer = new FakePeer(directory, options);
    await peer.listen();
    await peer.publish({ expires: (options.now ?? Date.now)() + expiresIn });
    return peer;
  }

  /** Writes the pairing file; `overrides` lets tests publish broken ones. */
  async publish(overrides: Record<string, unknown> = {}, mode = 0o600): Promise<void> {
    const body = {
      protocol: PROTOCOL_NAME,
      version: PROTOCOL_VERSION,
      socket: this.socketPath,
      session: base64url(this.secrets.sessionId),
      key: base64url(this.secrets.key),
      expires: Date.now() + 60_000,
      ...overrides,
    };
    await writeFile(this.rendezvousPath, JSON.stringify(body), { mode });
    await chmod(this.rendezvousPath, mode);
  }

  /** Resolves when `count` hint messages have been received in total. */
  async waitForHints(count: number, timeout = 5_000): Promise<void> {
    const deadline = Date.now() + timeout;
    while (this.received.length < count) {
      if (Date.now() > deadline) throw new Error(`timed out waiting for ${count} hint messages`);
      await new Promise<void>((resolve) => {
        this.waiters.push(resolve);
        setTimeout(resolve, 50);
      });
    }
  }

  async stop(): Promise<void> {
    for (const socket of this.sockets) socket.destroy();
    await new Promise<void>((resolve) => (this.server ? this.server.close(() => resolve()) : resolve()));
    await rm(this.directory, { recursive: true, force: true });
  }

  private async listen(): Promise<void> {
    this.server = createServer((socket) => this.accept(socket));
    await new Promise<void>((resolve) => this.server!.listen(this.socketPath, resolve));
    await chmod(this.socketPath, 0o600);
  }

  private accept(socket: Socket): void {
    this.sockets.add(socket);
    socket.on('close', () => this.sockets.delete(socket));
    socket.on('error', () => {});
    const decoder = new FrameDecoder();
    const guard = new SequenceGuard();
    const now = this.options.now ?? Date.now;
    const limiter = new RateLimiter(this.options.ratePerSecond ?? 10, (this.options.ratePerSecond ?? 10) * 2, now);
    let clientNonce: Buffer | undefined;
    let serverNonce: Buffer | undefined;
    let receiveKey: Buffer | undefined;
    let sendKey: Buffer | undefined;
    let sendSeq = 0;
    const write = (message: Record<string, unknown>): void => {
      socket.write(encodeFrame(Buffer.from(JSON.stringify(message), 'utf8')));
    };

    socket.on('data', (chunk: Buffer) => {
      this.rawReceived = Buffer.concat([this.rawReceived, chunk]);
      try {
        for (const frame of decoder.push(chunk)) {
          if (!clientNonce) {
            const hello = parseFrame(frame, ['hello']);
            if (!equalBytes(decodeBase64url(hello.session, 16), this.secrets.sessionId)) {
              throw new ProtocolError('authentication-failed');
            }
            clientNonce = decodeBase64url(hello.nonce, 16);
            serverNonce = randomNonce();
            const proofSecrets = { ...this.secrets, key: this.options.proofKey ?? this.secrets.key };
            write({
              t: 'challenge',
              v: this.options.answerVersion ?? PROTOCOL_VERSION,
              nonce: base64url(serverNonce),
              proof: base64url(serverProof(proofSecrets, clientNonce, serverNonce)),
            });
          } else if (!receiveKey) {
            const auth = parseFrame(frame, ['auth']);
            if (!equalBytes(decodeBase64url(auth.proof, 32), clientProof(this.secrets, clientNonce, serverNonce!))) {
              throw new ProtocolError('authentication-failed');
            }
            receiveKey = connectionKey(this.secrets, clientNonce, serverNonce!, 'client-to-server');
            sendKey = connectionKey(this.secrets, clientNonce, serverNonce!, 'server-to-client');
            this.lastKeys = { clientToServer: receiveKey, serverToClient: sendKey };
            socket.write(encodeFrame(seal(sendKey, { t: 'ready', v: PROTOCOL_VERSION, seq: sendSeq++ })));
          } else {
            if (!limiter.tryTake()) throw new ProtocolError('rate-limited');
            const body = verifyTag(receiveKey, parseFrame(frame, ['hints', 'clear']));
            guard.accept(body.seq);
            if (body.t === 'hints') {
              const hints = validateHints(body, now());
              this.received.push({ doc: body.doc as string, hints });
              socket.write(encodeFrame(seal(sendKey!, { t: 'ack', v: PROTOCOL_VERSION, seq: sendSeq++, accepted: hints.length })));
              this.waiters.splice(0).forEach((resolve) => resolve());
            } else {
              decodeBase64url(body.doc, 16);
              this.cleared.push(body.doc as string);
            }
          }
        }
      } catch (error) {
        this.failures.push(error instanceof ProtocolError ? error.reason : 'malformed-message');
        socket.destroy();
      }
    });
  }
}
