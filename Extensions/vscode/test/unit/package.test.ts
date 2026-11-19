import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';

const root = join(__dirname, '..', '..', '..');
const manifest = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')) as Record<string, any>;

test('the package ships no runtime dependencies and only reviewed dev tools', () => {
  assert.equal(manifest.dependencies, undefined, 'no runtime dependencies');
  assert.deepEqual(Object.keys(manifest.devDependencies).sort(), ['@types/node', '@types/vscode', '@vscode/test-electron', 'typescript']);
  for (const version of Object.values(manifest.devDependencies)) assert.match(version as string, /^\d+\.\d+\.\d+$/, 'exact versions');
});

test('it activates only from its own commands and asks for nothing else', () => {
  assert.deepEqual(manifest.activationEvents, [], 'no startup, file-type, or workspace activation');
  assert.deepEqual(Object.keys(manifest.contributes).sort(), ['commands', 'configuration']);
  assert.deepEqual(manifest.extensionKind, ['ui'], 'runs beside the local RedScreen app, never on a remote host');
  for (const key of ['enabledApiProposals', 'extensionDependencies', 'extensionPack']) assert.equal(manifest[key], undefined, key);
  const settings = Object.keys(manifest.contributes.configuration.properties).sort();
  assert.deepEqual(settings, ['redscreenHints.debounceMilliseconds', 'redscreenHints.rendezvousFile']);
  assert.ok(!JSON.stringify(manifest).toLowerCase().includes('telemetry'));
});

test('the extension code uses no network, process, or telemetry APIs', () => {
  const allowedModules = new Set(['vscode', 'node:crypto', 'node:net', 'node:fs/promises', 'node:os', 'node:path']);
  const forbidden = [/\bfetch\s*\(/, /XMLHttpRequest/, /WebSocket/, /child_process/, /\btelemetry\b/i, /createOutputChannel/, /console\./, /\b(?:globalState|workspaceState)\b|context\.secrets/];
  const sources = readdirSync(join(root, 'src')).filter((name) => name.endsWith('.ts'));
  assert.ok(sources.length >= 6);
  for (const name of sources) {
    const text = readFileSync(join(root, 'src', name), 'utf8');
    for (const match of text.matchAll(/from '([^']+)'/g)) {
      const module = match[1]!;
      assert.ok(module.startsWith('./') || allowedModules.has(module), `${name} imports ${module}`);
    }
    for (const pattern of forbidden) assert.doesNotMatch(text, pattern, `${name}: ${pattern}`);
    // node:net is used only for the local Unix socket.
    if (text.includes("from 'node:net'")) assert.doesNotMatch(text, /connect\(\s*\{|\bport\b|createServer/, `${name}: TCP use`);
  }
});

test('the packaged extension contains only compiled sources and the manifest', () => {
  const ignore = readFileSync(join(root, '.vscodeignore'), 'utf8').split('\n').filter(Boolean);
  assert.deepEqual(ignore, ['**', '!out/src/**', '!package.json', '!README.md']);
});
