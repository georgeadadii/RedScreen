/**
 * Secret detection on editor text, aligned with RedScreen's native `ContextualSecretDetector` by
 * stable rule ID. Every ID here is one the native detector also emits, so a hint means the same
 * thing on both sides. The parity fixture (test/fixtures/rule-parity.json) is checked against
 * both detectors.
 *
 * Findings hold the matched value in memory only, for computing a keyed digest. They are never
 * logged, stored, or sent.
 */

export const RULE_IDS = [
  'provider.github-token',
  'provider.github-fine-grained-token',
  'provider.gitlab-token',
  'provider.slack-token',
  'provider.stripe-live-key',
  'provider.stripe-test-key',
  'provider.google-api-key',
  'provider.npm-token',
  'provider.anthropic-key',
  'provider.openai-key',
  'provider.jwt',
  'provider.aws-access-key-id',
  'private-key.block',
  'private-key.encrypted-block',
  'connection-string.password',
  'bearer.token',
  'bearer.truncated',
  'assignment.env',
  'assignment.credential',
] as const;

export type RuleId = (typeof RULE_IDS)[number];

export interface Finding {
  readonly ruleId: RuleId;
  /** 0–100, matching the native detector's confidence scale × 100. */
  readonly confidence: number;
  /** UTF-16 offsets into the scanned text. */
  readonly start: number;
  readonly end: number;
  /** The matched value. Memory only: used for the digest, then discarded. */
  readonly value: string;
}

/** The narrow interface the scanner depends on. */
export interface SecretDetector {
  detect(text: string): Finding[];
}

/** Findings below this confidence are not hinted (the native review threshold). */
export const MINIMUM_CONFIDENCE = 45;

interface Pattern {
  readonly ruleId: RuleId;
  readonly expression: RegExp;
  readonly confidence: number;
}

// Same expressions as the native provider patterns, minus the OCR `@`-for-`0` allowance, which
// editor text does not need.
const PROVIDER_PATTERNS: readonly Pattern[] = [
  { ruleId: 'provider.github-token', expression: /(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{36}(?![A-Za-z0-9])/g, confidence: 97 },
  { ruleId: 'provider.github-fine-grained-token', expression: /(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{22,255}/g, confidence: 97 },
  { ruleId: 'provider.gitlab-token', expression: /(?<![A-Za-z0-9_])glpat-[A-Za-z0-9_-]{20,64}/g, confidence: 95 },
  { ruleId: 'provider.slack-token', expression: /(?<![A-Za-z0-9_])xox[abprs]-[A-Za-z0-9-]{10,128}/g, confidence: 95 },
  { ruleId: 'provider.stripe-live-key', expression: /(?<![A-Za-z0-9_])(?:sk|rk)_live_[A-Za-z0-9]{16,128}/g, confidence: 97 },
  { ruleId: 'provider.stripe-test-key', expression: /(?<![A-Za-z0-9_])(?:sk|rk)_test_[A-Za-z0-9]{16,128}/g, confidence: 75 },
  { ruleId: 'provider.google-api-key', expression: /(?<![A-Za-z0-9_])AIza[0-9A-Za-z_-]{35}/g, confidence: 90 },
  { ruleId: 'provider.npm-token', expression: /(?<![A-Za-z0-9_])npm_[A-Za-z0-9]{36}/g, confidence: 95 },
  { ruleId: 'provider.anthropic-key', expression: /(?<![A-Za-z0-9_])sk-ant-[A-Za-z0-9_-]{20,256}/g, confidence: 97 },
  { ruleId: 'provider.openai-key', expression: /(?<![A-Za-z0-9_])sk-(?:proj-)?[A-Za-z0-9_-]{32,256}/g, confidence: 85 },
  {
    ruleId: 'provider.jwt',
    expression: /eyJ[A-Za-z0-9_-]{8,2048}\.eyJ[A-Za-z0-9_-]{8,2048}\.[A-Za-z0-9_-]{8,2048}/g,
    confidence: 85,
  },
];

const AWS_ACCESS_KEY_ID = /(?<![A-Z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Z0-9])/g;
const EXPORTED_ACCESS_KEY = /(?:export\s+)?[A-Z_]*ACCESS_KEY_ID\s*=/i;
const PRIVATE_KEY_BEGIN = /-{2,}\s{0,3}BEGIN\s{1,3}([A-Z0-9 ]{0,40}?)\s{0,3}-{2,}/;
const PRIVATE_KEY_END = /-{2,}\s{0,3}END\s{1,3}[A-Z0-9 ]{0,40}/;
const MAXIMUM_PRIVATE_KEY_LINES = 80;
const CONNECTION_URL =
  /(?<![A-Za-z0-9])([a-zA-Z][a-zA-Z0-9+.-]{1,20}):\/\/([^\s:/@'"`]{0,128}):([^\s@/'"`]{1,256})@([A-Za-z0-9.\-[\]]{1,253})/g;
const BEARER = /\bbearer\s{1,4}([A-Za-z0-9._~+/=-]{1,512})(\.\.\.|\u2026)?/gi;
const ENV_ASSIGNMENT = /^\s{0,8}(?:export\s{1,4})?([A-Z][A-Z0-9_]{0,63})\s{0,3}=\s{0,3}(["']?)([^\s"'#]{1,512})\2/;
const KEYED_ASSIGNMENT =
  /(?<![A-Za-z0-9_])["']?([A-Za-z][A-Za-z0-9_.-]{0,63})["']?\s{0,3}[:=]\s{0,3}(["'])([^"'\s]{1,512})\2/g;

/** Key words that make an assignment's value a credential (the native "strong" keywords). */
const STRONG_KEY_WORD = /(?:pass(?:word|wd)?|pwd|secret|token|api[_-]?key|private[_-]?key|access[_-]?key|auth|credential|client[_-]?secret|signing[_-]?key)/i;
/** Identifiers such as `AWS_ACCESS_KEY_ID` name an ID, not a secret. */
const IDENTIFIER_KEY = /(?:^|[_.-])id$/i;
const STRONG_KEY = { test: (key: string): boolean => STRONG_KEY_WORD.test(key) && !IDENTIFIER_KEY.test(key) };

const PLACEHOLDER_WORDS = new Set([
  'changeme', 'password', 'secret', 'token', 'placeholder', 'redacted', 'example', 'null', 'none',
  'true', 'false', 'undefined', 'xxx', 'todo', 'value', 'your-token', 'your_token',
]);

/** Values that are clearly not real secrets: placeholders, templates, masks, references. */
export function isPlaceholder(value: string): boolean {
  const lower = value.toLowerCase();
  if (value.length < 6) return true;
  if (PLACEHOLDER_WORDS.has(lower)) return true;
  if (/^(.)\1+$/.test(value)) return true; // ******** or xxxxxxxx
  if (/[<>]|\$\{|\{\{|^\$[A-Z_]+$|^%[A-Z_]+%$/.test(value)) return true; // <your-key>, ${VAR}, {{x}}
  if (/^(?:your|my|insert|enter)[-_]/i.test(value)) return true;
  return false;
}

export class EditorSecretDetector implements SecretDetector {
  detect(text: string): Finding[] {
    const lines = splitLines(text);
    const findings: Finding[] = [];
    const consumed = this.privateKeys(lines, findings);
    for (const line of lines) {
      if (consumed.has(line.index)) continue;
      this.providers(line, findings);
      this.connectionStrings(line, findings);
      this.bearers(line, findings);
      this.assignments(line, findings);
    }
    return resolve(findings.filter((finding) => finding.confidence >= MINIMUM_CONFIDENCE));
  }

  private privateKeys(lines: readonly Line[], findings: Finding[]): Set<number> {
    const consumed = new Set<number>();
    for (let position = 0; position < lines.length; position++) {
      const header = lines[position]!;
      const match = PRIVATE_KEY_BEGIN.exec(header.text);
      if (!match || !match[1]!.includes('PRIVATE KEY')) continue;
      let last = position;
      let ended = false;
      while (last + 1 < lines.length && last - position < MAXIMUM_PRIVATE_KEY_LINES) {
        last++;
        if (PRIVATE_KEY_END.test(lines[last]!.text)) {
          ended = true;
          break;
        }
      }
      const block = lines.slice(position, last + 1);
      const encrypted = match[1]!.includes('ENCRYPTED') || block.slice(1, 3).some((line) => line.text.includes('ENCRYPTED'));
      const start = header.start + header.text.search(/\S/);
      const lastLine = lines[last]!;
      const end = lastLine.start + lastLine.text.trimEnd().length;
      findings.push({
        ruleId: encrypted ? 'private-key.encrypted-block' : 'private-key.block',
        confidence: encrypted ? 55 : ended ? 97 : 90,
        start,
        end,
        value: block.map((line) => line.text.trim()).join('\n'),
      });
      block.forEach((line) => consumed.add(line.index));
      position = last;
    }
    return consumed;
  }

  private providers(line: Line, findings: Finding[]): void {
    for (const pattern of PROVIDER_PATTERNS) {
      for (const match of line.text.matchAll(pattern.expression)) {
        findings.push(finding(line, pattern.ruleId, pattern.confidence, match.index, match[0]));
      }
    }
    const exported = EXPORTED_ACCESS_KEY.test(line.text);
    for (const match of line.text.matchAll(AWS_ACCESS_KEY_ID)) {
      findings.push(finding(line, 'provider.aws-access-key-id', exported ? 90 : 60, match.index, match[0]));
    }
  }

  private connectionStrings(line: Line, findings: Finding[]): void {
    for (const match of line.text.matchAll(CONNECTION_URL)) {
      const password = match[3]!;
      if (isPlaceholder(password)) continue;
      const offset = match.index + match[0].indexOf(`:${password}@`, match[1]!.length + 3) + 1;
      findings.push(finding(line, 'connection-string.password', 95, offset, password));
    }
  }

  private bearers(line: Line, findings: Finding[]): void {
    for (const match of line.text.matchAll(BEARER)) {
      const token = match[1]!;
      if (token.length < 8 || isPlaceholder(token)) continue;
      const truncated = match[2] !== undefined;
      const confidence = truncated ? 50 : token.startsWith('eyJ') || token.includes('.eyJ') || token.length >= 16 ? 95 : 55;
      const offset = match.index + match[0].indexOf(token);
      findings.push(finding(line, truncated ? 'bearer.truncated' : 'bearer.token', confidence, offset, token));
    }
  }

  private assignments(line: Line, findings: Finding[]): void {
    const env = ENV_ASSIGNMENT.exec(line.text);
    if (env && STRONG_KEY.test(env[1]!) && !isPlaceholder(env[3]!)) {
      const value = env[3]!;
      const offset = env.index + env[0].lastIndexOf(value);
      findings.push(finding(line, 'assignment.env', valueStrength(value), offset, value));
      return;
    }
    for (const match of line.text.matchAll(KEYED_ASSIGNMENT)) {
      const [, key, , value] = match;
      if (!STRONG_KEY.test(key!) || isPlaceholder(value!)) continue;
      const offset = match.index + match[0].lastIndexOf(value!);
      findings.push(finding(line, 'assignment.credential', valueStrength(value!), offset, value!));
    }
  }
}

/** Longer, more varied values are more likely real, as in the native value scoring. */
function valueStrength(value: string): number {
  const classes = [/[a-z]/, /[A-Z]/, /[0-9]/, /[^A-Za-z0-9]/].filter((pattern) => pattern.test(value)).length;
  if (value.length >= 16 && classes >= 2) return 95;
  if (value.length >= 10 && classes >= 2) return 90;
  return 60;
}

interface Line {
  readonly index: number;
  readonly start: number;
  readonly text: string;
}

function splitLines(text: string): Line[] {
  const lines: Line[] = [];
  let start = 0;
  let index = 0;
  for (const part of text.split(/\r?\n/)) {
    lines.push({ index, start, text: part });
    start += part.length + (text.startsWith('\r\n', start + part.length) ? 2 : 1);
    index++;
  }
  return lines;
}

function finding(line: Line, ruleId: RuleId, confidence: number, index: number | undefined, value: string): Finding {
  const start = line.start + (index ?? 0);
  return { ruleId, confidence, start, end: start + value.length, value };
}

/** Keeps the most confident finding where findings overlap, then orders by position. */
function resolve(findings: Finding[]): Finding[] {
  const ranked = [...findings].sort((a, b) => b.confidence - a.confidence || a.start - b.start);
  const accepted: Finding[] = [];
  for (const candidate of ranked) {
    if (!accepted.some((other) => candidate.start < other.end && other.start < candidate.end)) {
      accepted.push(candidate);
    }
  }
  return accepted.sort((a, b) => a.start - b.start);
}
