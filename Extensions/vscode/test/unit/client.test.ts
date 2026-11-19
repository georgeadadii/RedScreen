import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { chmod, symlink } from 'node:fs/promises';
import { connect } from 'node:net';
import { join } from 'node:path';
import { after, test } from 'node:test';
import { HintClient, type ConnectionState } from '../../src/client';
import { FrameDecoder, encodeFrame } from '../../src/framing';
import { base64url, clientProof, connectionKey, digestKey, seal, valueDigest } from '../../src/protocol';
import { RendezvousError, readRendezvous } from '../../src/rendezvous';
import { EditorSecretDetector } from '../../src/rules';
import { FakePeer } from '../support/fakePeer';
import { joinLines, loadParityFixture } from '../support/parity';

const peers: FakePeer[] = [];
async function peer(...args: Parameters<typeof FakePeer.start>): Promise<FakePeer> {
  const started = await FakePeer.start(...args);
  peers.push(started);
  return started;
}
after(async () => Promise.all(peers.map((p) => p.stop())));

const rendezvousReason = (expected: string) => (error: unknown) => error instanceof RendezvousError && error.reason === expected;

test('the client authenticates, sends hints with matching digests, and no raw values', async () => {
  const fake = await peer();
  const client = new HintClient();
  await client.connect(await readRendezvous(fake.rendezvousPath));
  assert.equal(client.state.kind, 'connected');

  const detector = new EditorSecretDetector();
  const fixture = loadParityFixture();
  const text = fixture.positives.map((p) => joinLines(p.lines)).join('\n');
  const findings = detector.detect(text);
  assert.ok(findings.length >= fixture.positives.length);
  client.sendFindings(randomBytes(16), findings);
  await fake.waitForHints(1);

  const key = digestKey(fake.secrets);
  const received = fake.received[0]!.hints;
  for (const testCase of fixture.positives) {
    const value = testCase.value.join('');
    // Multi-line values are digested line by line, joined with "\n" (see normalizeValue).
    const canonical = testCase.lines.length > 1 ? testCase.lines.map((parts) => parts.join('')).join('\n') : value;
    const digest = valueDigest(key, testCase.rule as never, canonical);
    assert.ok(received.some((h) => h.rule === testCase.rule && h.digest === digest), `${testCase.id}: RedScreen can match the digest`);
    assert.ok(!fake.rawReceived.includes(Buffer.from(value)), `${testCase.id}: raw value on the wire`);
  }
  assert.ok(!fake.rawReceived.includes(Buffer.from(text.slice(0, 40))), 'document text on the wire');
  assert.deepEqual(fake.failures, []);
  client.close();
});

test('one client reconnects to new sessions, starting sequence numbers afresh', async () => {
  const client = new HintClient();
  for (let round = 0; round < 3; round++) {
    const fake = await peer();
    await client.connect(await readRendezvous(fake.rendezvousPath));
    assert.equal(client.state.kind, 'connected', `round ${round}`);
    client.sendFindings(randomBytes(16), []);
    client.sendFindings(randomBytes(16), []);
    await fake.waitForHints(2);
    assert.deepEqual(fake.failures, []);
    client.close();
  }
});

test('a spoofed peer without the session key is rejected', async () => {
  const fake = await peer({ proofKey: randomBytes(32) });
  const states: ConnectionState[] = [];
  const client = new HintClient((state) => states.push(state));
  await assert.rejects(client.connect(await readRendezvous(fake.rendezvousPath)), /authentication-failed/);
  assert.deepEqual(states.at(-1), { kind: 'failed', reason: 'authentication-failed' });
  client.sendFindings(randomBytes(16), new EditorSecretDetector().detect('API_TOKEN=RSFAKE-x-0a1b2c3d4e'));
  assert.equal(fake.received.length, 0, 'nothing is sent after a failed handshake');
});

test('a peer answering another protocol version fails closed', async () => {
  const fake = await peer({ answerVersion: 2 });
  const client = new HintClient();
  await assert.rejects(client.connect(await readRendezvous(fake.rendezvousPath)), /incompatible-version/);
  assert.equal(client.state.kind, 'failed');
});

test('a client without the session key never completes the handshake', async () => {
  const fake = await peer();
  const rendezvous = await readRendezvous(fake.rendezvousPath);
  const client = new HintClient();
  // The real peer's proof does not verify under the wrong key, so the client stops first.
  await assert.rejects(client.connect({ ...rendezvous, key: randomBytes(32) }), /authentication-failed/);
  assert.equal(fake.lastKeys, undefined, 'the peer never accepted an auth message');
  assert.equal(fake.received.length, 0);
});

test('the peer refuses an auth proof made without the session key', async () => {
  const fake = await peer();
  const raw = connect(fake.socketPath);
  await new Promise<void>((resolve) => raw.once('connect', resolve));
  const write = (message: object) => raw.write(encodeFrame(Buffer.from(JSON.stringify(message))));
  write({ t: 'hello', v: 1, session: base64url(fake.secrets.sessionId), nonce: base64url(randomBytes(16)) });
  await new Promise((resolve) => raw.once('data', resolve));
  write({ t: 'auth', v: 1, proof: base64url(randomBytes(32)) });
  await new Promise<void>((resolve) => raw.once('close', () => resolve()));
  assert.deepEqual(fake.failures, ['authentication-failed']);
  assert.equal(fake.lastKeys, undefined);
});

test('the peer refuses a hello for another session', async () => {
  const fake = await peer();
  const raw = connect(fake.socketPath);
  await new Promise<void>((resolve) => raw.once('connect', resolve));
  raw.write(encodeFrame(Buffer.from(JSON.stringify({ t: 'hello', v: 1, session: base64url(randomBytes(16)), nonce: base64url(randomBytes(16)) }))));
  await new Promise<void>((resolve) => raw.once('close', () => resolve()));
  assert.deepEqual(fake.failures, ['authentication-failed']);
});

/** A hand-driven, fully authenticated connection, for sending exact bytes. */
async function rawSession(fake: FakePeer) {
  const socket = connect(fake.socketPath);
  await new Promise<void>((resolve) => socket.once('connect', resolve));
  const decoder = new FrameDecoder();
  const nextFrame = () =>
    new Promise<Record<string, unknown>>((resolve) => {
      const onData = (chunk: Buffer) => {
        const [frame] = decoder.push(chunk);
        if (frame) {
          socket.off('data', onData);
          resolve(JSON.parse(frame.toString()) as Record<string, unknown>);
        }
      };
      socket.on('data', onData);
    });
  const write = (message: object) => socket.write(encodeFrame(Buffer.from(JSON.stringify(message))));
  const clientNonce = randomBytes(16);
  write({ t: 'hello', v: 1, session: base64url(fake.secrets.sessionId), nonce: base64url(clientNonce) });
  const challenge = await nextFrame();
  const serverNonce = Buffer.from(challenge.nonce as string, 'base64url');
  write({ t: 'auth', v: 1, proof: base64url(clientProof(fake.secrets, clientNonce, serverNonce)) });
  await nextFrame(); // ready
  const key = connectionKey(fake.secrets, clientNonce, serverNonce, 'client-to-server');
  const closed = new Promise<void>((resolve) => socket.once('close', () => resolve()));
  return { key, socket, closed, sendBytes: (frame: Buffer) => socket.write(encodeFrame(frame)) };
}

function hintsFrame(key: Buffer, seq: number): Buffer {
  const now = Date.now();
  return seal(key, { t: 'hints', v: 1, seq, sent: now, expires: now + 10_000, doc: base64url(randomBytes(16)), hints: [] });
}

test('a message replayed on the same connection is rejected', async () => {
  const fake = await peer();
  const session = await rawSession(fake);
  const frame = hintsFrame(session.key, 0);
  session.sendBytes(frame);
  await fake.waitForHints(1);
  session.sendBytes(frame);
  await session.closed;
  assert.equal(fake.received.length, 1);
  assert.deepEqual(fake.failures, ['replayed-or-out-of-order']);
});

test('a message from an earlier connection is rejected on a new one', async () => {
  const fake = await peer();
  const first = await rawSession(fake);
  const captured = hintsFrame(first.key, 0);
  first.sendBytes(captured);
  await fake.waitForHints(1);
  first.socket.destroy();

  const second = await rawSession(fake);
  second.sendBytes(captured);
  await second.closed;
  assert.equal(fake.received.length, 1);
  assert.deepEqual(fake.failures, ['authentication-failed'], 'its tag is bound to the old connection keys');
});

test('a message tagged for a different session is rejected', async () => {
  const fake = await peer();
  const other = await peer();
  const otherSession = await rawSession(other);
  const foreign = hintsFrame(otherSession.key, 0);
  const session = await rawSession(fake);
  session.sendBytes(foreign);
  await session.closed;
  assert.deepEqual(fake.failures, ['authentication-failed']);
  otherSession.socket.destroy();
});

test('an unauthenticated message is never accepted', async () => {
  const fake = await peer();
  const raw = connect(fake.socketPath);
  await new Promise<void>((resolve) => raw.once('connect', resolve));
  raw.write(encodeFrame(hintsFrame(randomBytes(32), 0)));
  await new Promise<void>((resolve) => raw.once('close', () => resolve()));
  assert.deepEqual(fake.failures, ['unexpected-message']);
  assert.equal(fake.received.length, 0);
});

test('the client rate-limits and coalesces rapid scans', async () => {
  const fake = await peer({ ratePerSecond: 5 });
  const client = new HintClient(undefined, Date.now, 2, 2);
  await client.connect(await readRendezvous(fake.rendezvousPath));
  const doc = randomBytes(16);
  for (let index = 0; index < 50; index++) client.sendFindings(doc, []);
  await fake.waitForHints(3, 3_000);
  await new Promise((resolve) => setTimeout(resolve, 400));
  assert.ok(fake.received.length <= 4, `sent ${fake.received.length} of 50 rapid scans`);
  assert.deepEqual(fake.failures, [], 'the peer never had to rate-limit the client');
  client.close();
});

test('the peer closes a flooding connection', async () => {
  const fake = await peer({ ratePerSecond: 2 });
  const states: string[] = [];
  const flooding = new HintClient((state) => states.push(state.kind), Date.now, 1_000, 1_000);
  await flooding.connect(await readRendezvous(fake.rendezvousPath));
  for (let index = 0; index < 20; index++) flooding.sendFindings(randomBytes(16), []);
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.ok(fake.failures.includes('rate-limited'));
  assert.equal(states.at(-1), 'failed');
});

test('pairing files that are not private, are symlinks, expired, or another version are refused', async () => {
  const fake = await peer();
  await chmod(fake.rendezvousPath, 0o644);
  await assert.rejects(readRendezvous(fake.rendezvousPath), rendezvousReason('insecure'));
  await chmod(fake.rendezvousPath, 0o600);

  const link = join(fake.directory, 'link.json');
  await symlink(fake.rendezvousPath, link);
  await assert.rejects(readRendezvous(link), rendezvousReason('insecure'));

  await fake.publish({ expires: Date.now() - 1 });
  await assert.rejects(readRendezvous(fake.rendezvousPath), rendezvousReason('expired'));
  await fake.publish({ version: 2 });
  await assert.rejects(readRendezvous(fake.rendezvousPath), rendezvousReason('incompatible'));
  await fake.publish({ key: 'short' });
  await assert.rejects(readRendezvous(fake.rendezvousPath), rendezvousReason('malformed'));
  await fake.publish({ extra: 'field' });
  await assert.rejects(readRendezvous(fake.rendezvousPath), rendezvousReason('malformed'));
  await fake.publish({ socket: join(fake.directory, 'missing.sock') });
  await assert.rejects(readRendezvous(fake.rendezvousPath), rendezvousReason('not-found'));
  await assert.rejects(readRendezvous(join(fake.directory, 'absent.json')), rendezvousReason('not-found'));
  await assert.rejects(readRendezvous('relative.json'), rendezvousReason('insecure'));

  await fake.publish();
  await chmod(fake.directory, 0o755);
  await assert.rejects(readRendezvous(fake.rendezvousPath), rendezvousReason('insecure'));
  await chmod(fake.directory, 0o700);
  await assert.doesNotReject(readRendezvous(fake.rendezvousPath));
});

test('without a connection nothing is sent and the client stays disconnected', () => {
  const client = new HintClient();
  client.sendFindings(randomBytes(16), new EditorSecretDetector().detect('API_TOKEN=RSFAKE-x-0a1b2c3d4e'));
  client.clear(randomBytes(16));
  assert.equal(client.state.kind, 'disconnected');
});
