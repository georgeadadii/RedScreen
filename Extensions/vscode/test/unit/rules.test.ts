import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { EditorSecretDetector, RULE_IDS } from '../../src/rules';
import { FIXTURE_PATH, joinLines, loadParityFixture } from '../support/parity';

const detector = new EditorSecretDetector();

test('every parity positive is found with the native rule ID and exact value', () => {
  const fixture = loadParityFixture();
  assert.ok(fixture.positives.length >= 14);
  for (const testCase of fixture.positives) {
    const text = joinLines(testCase.lines);
    const value = testCase.value.join('');
    const findings = detector.detect(text);
    const match = findings.find((finding) => finding.value.replace(/\n/g, '') === value);
    if (!match) {
      assert.fail(`${testCase.id}: no finding for the value (rules found: ${findings.map((f) => f.ruleId).join(', ')})`);
    }
    assert.equal(match.ruleId, testCase.rule, testCase.id);
    assert.equal(text.slice(match.start, match.end).replace(/\n/g, ''), value, `${testCase.id}: offsets`);
  }
});

test('parity negatives produce no findings', () => {
  for (const testCase of loadParityFixture().negatives) {
    assert.deepEqual(detector.detect(joinLines(testCase.lines)).map((f) => f.ruleId), [], testCase.id);
  }
});

test('the fixture covers every rule family the extension emits', () => {
  const covered = new Set(loadParityFixture().positives.map((p) => p.rule));
  for (const rule of covered) assert.ok((RULE_IDS as readonly string[]).includes(rule), rule);
  for (const family of ['provider.', 'private-key.', 'connection-string.', 'bearer.', 'assignment.']) {
    assert.ok([...covered].some((rule) => rule.startsWith(family)), family);
  }
});

test('the fixture file holds no contiguous credential shapes', () => {
  const raw = readFileSync(FIXTURE_PATH, 'utf8');
  for (const shape of [/gh[pousr]_[A-Za-z0-9]{20}/, /glpat-/, /xox[abprs]-/, /sk_live_/, /npm_[A-Za-z0-9]{20}/, /sk-ant-/, /AIza[0-9A-Za-z]/, /eyJ[A-Za-z0-9]{8}/, /BEGIN [A-Z ]*PRIVATE KEY/]) {
    assert.doesNotMatch(raw, shape);
  }
});

test('offsets are UTF-16 positions in multi-line text with CRLF', () => {
  const text = 'line one\r\nAPI_TOKEN=RSFAKE-crlf-0a1b2c3d\r\nend';
  const [finding] = detector.detect(text);
  assert.ok(finding);
  assert.equal(text.slice(finding.start, finding.end), 'RSFAKE-crlf-0a1b2c3d');
});

test('overlapping findings keep the most confident rule', () => {
  const token = ['gh', 'p_RSFAKE0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c'].join('');
  const findings = detector.detect(`GITHUB_TOKEN=${token}`);
  assert.deepEqual(findings.map((f) => f.ruleId), ['provider.github-token']);
});
