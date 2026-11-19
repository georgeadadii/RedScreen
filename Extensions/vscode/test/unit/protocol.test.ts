import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { test } from 'node:test';
import { FrameDecoder, RateLimiter, encodeFrame } from '../../src/framing';
import {
  HINT_LIFETIME_MS,
  MAX_FRAME_BYTES,
  ProtocolError,
  SequenceGuard,
  canonicalJSON,
  connectionKey,
  digestKey,
  normalizeValue,
  parseFrame,
  seal,
  validateHints,
  valueDigest,
  verifyTag,
} from '../../src/protocol';
import { joinLines, loadParityFixture } from '../support/parity';
import { EditorSecretDetector } from '../../src/rules';

const secrets = () => ({ sessionId: randomBytes(16), key: randomBytes(32) });
const reason = (expected: string) => (error: unknown) => error instanceof ProtocolError && error.reason === expected;

function hintsBody(seq: number, now: number, hints: unknown[] = []) {
  return { t: 'hints', v: 1, seq, sent: now, expires: now + HINT_LIFETIME_MS, doc: randomBytes(16).toString('base64url'), hints };
}

test('hint messages contain no raw fixture values, only digests', () => {
  const session = secrets();
  const key = digestKey(session);
  const detector = new EditorSecretDetector();
  const connection = connectionKey(session, randomBytes(16), randomBytes(16), 'client-to-server');
  for (const testCase of loadParityFixture().positives) {
    const findings = detector.detect(joinLines(testCase.lines));
    const hints = findings.map((f) => ({ rule: f.ruleId, conf: f.confidence, digest: valueDigest(key, f.ruleId, f.value) }));
    const frame = seal(connection, hintsBody(0, Date.now(), hints)).toString('utf8');
    const value = testCase.value.join('');
    assert.ok(!frame.includes(value), `${testCase.id}: raw value in message`);
    for (const fragment of value.match(/.{8}/g) ?? []) {
      assert.ok(!frame.includes(fragment), `${testCase.id}: value fragment in message`);
    }
    for (const parts of testCase.lines) assert.ok(!frame.includes(parts.join('')), `${testCase.id}: document text in message`);
  }
});

test('digests change with the session key and are stable within a session', () => {
  const a = digestKey(secrets());
  const b = digestKey(secrets());
  assert.equal(valueDigest(a, 'assignment.env', 'RSFAKE-x-1234'), valueDigest(a, 'assignment.env', '  RSFAKE-x-1234 '));
  assert.notEqual(valueDigest(a, 'assignment.env', 'RSFAKE-x-1234'), valueDigest(b, 'assignment.env', 'RSFAKE-x-1234'));
  assert.notEqual(valueDigest(a, 'assignment.env', 'RSFAKE-x-1234'), valueDigest(a, 'bearer.token', 'RSFAKE-x-1234'));
});

test('the same session ID with a different key yields a different digest key', () => {
  const one = secrets();
  const two = { sessionId: one.sessionId, key: randomBytes(32) };
  assert.notDeepEqual(digestKey(one), digestKey(two));
});

test('normalization matches what RedScreen recomputes from OCR text', () => {
  assert.equal(normalizeValue('  "RSFAKE-q"  '), 'RSFAKE-q');
  assert.equal(normalizeValue('ＲSFAKE'), 'RSFAKE'); // full-width letter, NFKC
  assert.equal(normalizeValue("'a'b'"), "a'b");
});

test('canonical JSON sorts keys at every level and rejects non-integers', () => {
  assert.equal(canonicalJSON({ b: 1, a: [{ d: 2, c: 'x' }] }), '{"a":[{"c":"x","d":2}],"b":1}');
  assert.throws(() => canonicalJSON({ conf: 0.5 }), reason('malformed-message'));
});

test('a tag from another connection or direction is rejected', () => {
  const session = secrets();
  const [cn, sn] = [randomBytes(16), randomBytes(16)];
  const sealed = parseFrame(seal(connectionKey(session, cn, sn, 'client-to-server'), hintsBody(0, Date.now())), ['hints']);
  assert.doesNotThrow(() => verifyTag(connectionKey(session, cn, sn, 'client-to-server'), sealed));
  assert.throws(() => verifyTag(connectionKey(session, cn, sn, 'server-to-client'), sealed), reason('authentication-failed'));
  assert.throws(() => verifyTag(connectionKey(session, randomBytes(16), sn, 'client-to-server'), sealed), reason('authentication-failed'));
  assert.throws(() => verifyTag(connectionKey(secrets(), cn, sn, 'client-to-server'), sealed), reason('authentication-failed'));
});

test('tampering with any field breaks the tag', () => {
  const key = randomBytes(32);
  const message = parseFrame(seal(key, hintsBody(3, Date.now())), ['hints']);
  const changes: [string, unknown][] = [['seq', 4], ['expires', 1], ['doc', randomBytes(16).toString('base64url')], ['hints', [{}]]];
  for (const [field, value] of changes) {
    assert.throws(() => verifyTag(key, { ...message, [field]: value }), reason('authentication-failed'), field);
  }
});

test('replayed and out-of-order sequence numbers are rejected', () => {
  const guard = new SequenceGuard();
  guard.accept(0);
  guard.accept(1);
  assert.throws(() => guard.accept(1), reason('replayed-or-out-of-order'));
  assert.throws(() => guard.accept(3), reason('replayed-or-out-of-order'));
  assert.throws(() => guard.accept(-1), reason('replayed-or-out-of-order'));
  assert.throws(() => guard.accept('2'), reason('replayed-or-out-of-order'));
});

test('expired, future-dated, and over-long hints are rejected', () => {
  const now = 1_700_000_000_000;
  assert.deepEqual(validateHints(hintsBody(0, now), now), []);
  assert.throws(() => validateHints(hintsBody(0, now - HINT_LIFETIME_MS - 1), now), reason('expired'));
  assert.throws(() => validateHints(hintsBody(0, now + 10_000), now), reason('expired'));
  assert.throws(() => validateHints({ ...hintsBody(0, now), expires: now + HINT_LIFETIME_MS + 1 }, now), reason('malformed-message'));
});

test('malformed messages fail closed', () => {
  const now = Date.now();
  const good = { rule: 'assignment.env', conf: 90, digest: randomBytes(32).toString('base64url') };
  const bad: unknown[] = [
    { ...good, rule: 'made.up-rule' },
    { ...good, conf: 101 },
    { ...good, conf: 0.9 },
    { ...good, digest: 'short' },
    { ...good, value: 'RSFAKE-should-never-be-accepted' },
    'not an object',
  ];
  for (const hint of bad) assert.throws(() => validateHints(hintsBody(0, now, [hint]), now), reason('malformed-message'));
  assert.throws(() => validateHints(hintsBody(0, now, Array(65).fill(good)), now), reason('malformed-message'));

  const frames = ['not json', '[]', 'null', '{"t":"hints"}', '{"t":"nope","v":1}', '{"t":"hello","v":1,"session":"x","nonce":"y","extra":1}'];
  for (const text of frames) assert.throws(() => parseFrame(Buffer.from(text), ['hints', 'hello']));
  assert.throws(() => parseFrame(Buffer.from('{"t":"ready","v":1,"seq":0,"mac":"x"}'), ['hints']), reason('unexpected-message'));
});

test('a different protocol version fails closed as incompatible', () => {
  assert.throws(() => parseFrame(Buffer.from('{"t":"challenge","v":2,"nonce":"a","proof":"b"}'), ['challenge']), reason('incompatible-version'));
  assert.throws(() => parseFrame(Buffer.from('{"t":"challenge","v":"1","nonce":"a","proof":"b"}'), ['challenge']), reason('malformed-message'));
});

test('oversized frames are refused before buffering them', () => {
  const decoder = new FrameDecoder();
  const header = Buffer.alloc(4);
  header.writeUInt32BE(MAX_FRAME_BYTES + 1);
  assert.throws(() => decoder.push(header), reason('oversized-message'));
  assert.throws(() => encodeFrame(Buffer.alloc(MAX_FRAME_BYTES + 1)), reason('oversized-message'));
  assert.throws(() => parseFrame(Buffer.alloc(MAX_FRAME_BYTES + 1, 0x20), ['hints']), reason('oversized-message'));
});

test('frames split across chunks are reassembled', () => {
  const decoder = new FrameDecoder();
  const a = encodeFrame(Buffer.from('{"a":1}'));
  const b = encodeFrame(Buffer.from('{"b":2}'));
  const stream = Buffer.concat([a, b]);
  assert.deepEqual(decoder.push(stream.subarray(0, 3)), []);
  const frames = decoder.push(stream.subarray(3));
  assert.deepEqual(frames.map((f) => f.toString()), ['{"a":1}', '{"b":2}']);
});

test('the rate limiter allows a burst, then refills over time', () => {
  let now = 0;
  const limiter = new RateLimiter(4, 2, () => now);
  assert.ok(limiter.tryTake());
  assert.ok(limiter.tryTake());
  assert.ok(!limiter.tryTake());
  now += 250;
  assert.ok(limiter.tryTake());
  assert.ok(!limiter.tryTake());
});
