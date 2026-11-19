import { readFileSync } from 'node:fs';
import { join } from 'node:path';

export interface ParityFixture {
  positives: { id: string; lines: string[][]; value: string[]; rule: string }[];
  negatives: { id: string; lines: string[][] }[];
}

/** test/fixtures, resolved from the compiled out/test/... location. */
export const FIXTURE_PATH = join(__dirname, '..', '..', '..', 'test', 'fixtures', 'rule-parity.json');

export function loadParityFixture(): ParityFixture {
  return JSON.parse(readFileSync(FIXTURE_PATH, 'utf8')) as ParityFixture;
}

export function joinLines(lines: string[][]): string {
  return lines.map((parts) => parts.join('')).join('\n');
}
