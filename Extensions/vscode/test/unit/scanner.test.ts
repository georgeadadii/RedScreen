import assert from 'node:assert/strict';
import { test } from 'node:test';
import { EditorSecretDetector, type Finding } from '../../src/rules';
import { HintScanner, MAX_SCANNED_CHARACTERS, type Scheduler } from '../../src/scanner';

class ManualScheduler implements Scheduler {
  private next = 0;
  readonly timers = new Map<number, { callback: () => void; milliseconds: number }>();
  set(callback: () => void, milliseconds: number): unknown {
    const handle = this.next++;
    this.timers.set(handle, { callback, milliseconds });
    return handle;
  }
  clear(handle: unknown): void {
    this.timers.delete(handle as number);
  }
  fireAll(): void {
    const due = [...this.timers.values()];
    this.timers.clear();
    due.forEach((timer) => timer.callback());
  }
}

class Document {
  version = 1;
  constructor(readonly key: string, public text: string) {}
  getText(): string {
    return this.text;
  }
  edit(text: string): void {
    this.text = text;
    this.version++;
  }
}

function harness(debounce = 500) {
  const scheduler = new ManualScheduler();
  const sent: { doc: string; rules: string[] }[] = [];
  const cleared: string[] = [];
  let scans = 0;
  const detector = new EditorSecretDetector();
  const counting = {
    detect: (text: string): Finding[] => {
      scans++;
      return detector.detect(text);
    },
  };
  const scanner = new HintScanner(
    counting,
    {
      send: (doc, findings) => sent.push({ doc: doc.toString('hex'), rules: findings.map((f) => f.ruleId) }),
      clear: (doc) => cleared.push(doc.toString('hex')),
    },
    () => debounce,
    scheduler,
  );
  return { scheduler, sent, cleared, scanner, scans: () => scans };
}

const SECRET_LINE = 'DATABASE_PASSWORD=RSFAKE-pg-7d1c9a42';

test('nothing is scanned until asked', () => {
  const { scheduler, sent, scans } = harness();
  new Document('file:///a', SECRET_LINE);
  assert.equal(scheduler.timers.size, 0);
  assert.equal(scans(), 0);
  assert.equal(sent.length, 0);
});

test('an explicit scan runs immediately', () => {
  const { scanner, sent } = harness();
  const outcome = scanner.scanNow(new Document('file:///a', SECRET_LINE));
  assert.deepEqual(outcome, { kind: 'scanned', findings: 1 });
  assert.deepEqual(sent[0]!.rules, ['assignment.env']);
});

test('rapid edits are debounced into one scan of the latest text', () => {
  const { scanner, scheduler, sent, scans } = harness(400);
  const document = new Document('file:///a', 'x');
  for (let index = 0; index < 10; index++) {
    document.edit(index < 9 ? `draft ${index}` : SECRET_LINE);
    scanner.schedule(document);
  }
  assert.equal(scheduler.timers.size, 1, 'only the newest scan is pending');
  assert.equal([...scheduler.timers.values()][0]!.milliseconds, 400);
  scheduler.fireAll();
  assert.equal(scans(), 1);
  assert.deepEqual(sent.map((s) => s.rules), [['assignment.env']]);
});

test('an edit after scheduling makes the pending scan stale', () => {
  const { scanner, scheduler, sent } = harness();
  const document = new Document('file:///a', SECRET_LINE);
  scanner.schedule(document);
  const [stale] = [...scheduler.timers.values()];
  document.edit('nothing secret');
  stale!.callback(); // fires even though the document moved on
  assert.equal(sent.length, 0, 'results for an old version are dropped');
});

test('cancel drops a pending scan', () => {
  const { scanner, scheduler, sent } = harness();
  const document = new Document('file:///a', SECRET_LINE);
  scanner.schedule(document);
  const [pending] = [...scheduler.timers.values()];
  scanner.cancel();
  assert.equal(scheduler.timers.size, 0);
  assert.ok(!scanner.hasPendingScan);
  pending!.callback();
  assert.equal(sent.length, 0);
});

test('switching documents cancels the previous document scan', () => {
  const { scanner, scheduler, sent } = harness();
  scanner.schedule(new Document('file:///a', SECRET_LINE));
  scanner.schedule(new Document('file:///b', 'no secrets here'));
  scheduler.fireAll();
  assert.equal(sent.length, 1);
  assert.deepEqual(sent[0]!.rules, []);
});

test('each document keeps one random nonce, and forgetting withdraws its hints', () => {
  const { scanner, sent, cleared } = harness();
  const a = new Document('file:///a', SECRET_LINE);
  const b = new Document('file:///b', SECRET_LINE);
  scanner.scanNow(a);
  a.edit(SECRET_LINE + '\n');
  scanner.scanNow(a);
  scanner.scanNow(b);
  assert.equal(sent[0]!.doc, sent[1]!.doc, 'rescans replace the same document hints');
  assert.notEqual(sent[0]!.doc, sent[2]!.doc);
  assert.ok(!sent[0]!.doc.includes(Buffer.from('file:///a').toString('hex')));
  scanner.forget('file:///a');
  assert.deepEqual(cleared, [sent[0]!.doc]);
  scanner.forgetAll();
  assert.deepEqual(cleared, [sent[0]!.doc, sent[2]!.doc]);
});

test('very large documents are skipped', () => {
  const { scanner, sent } = harness();
  const outcome = scanner.scanNow(new Document('file:///big', 'a'.repeat(MAX_SCANNED_CHARACTERS + 1)));
  assert.deepEqual(outcome, { kind: 'too-large' });
  assert.equal(sent.length, 0);
});
