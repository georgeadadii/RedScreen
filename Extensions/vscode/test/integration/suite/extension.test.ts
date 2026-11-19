import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { join } from 'node:path';
import * as vscode from 'vscode';
import type { HintsApi } from '../../../src/extension';
import { digestKey, valueDigest } from '../../../src/protocol';
import { FakePeer } from '../../support/fakePeer';

const EXTENSION_ID = 'georgeadadi.redscreen-secret-hints';
const workspaceRoot = (): string => vscode.workspace.workspaceFolders![0]!.uri.fsPath;
const sleep = (milliseconds: number) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function api(): Promise<HintsApi> {
  const extension = vscode.extensions.getExtension<HintsApi>(EXTENSION_ID);
  assert.ok(extension, 'extension is installed');
  return extension.activate();
}

async function waitFor(condition: () => boolean, what: string, timeout = 5_000): Promise<void> {
  const deadline = Date.now() + timeout;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await sleep(50);
  }
}

async function configure(peer: FakePeer | undefined, debounce = 200): Promise<void> {
  const config = vscode.workspace.getConfiguration('redscreenHints');
  await config.update('rendezvousFile', peer?.rendezvousPath ?? '', vscode.ConfigurationTarget.Global);
  await config.update('debounceMilliseconds', debounce, vscode.ConfigurationTarget.Global);
}

export const tests: [string, () => Promise<void>][] = [
  [
    'opening files does not activate or scan anything',
    async () => {
      const extension = vscode.extensions.getExtension(EXTENSION_ID);
      assert.ok(extension);
      const document = await vscode.workspace.openTextDocument(join(workspaceRoot(), 'service.env'));
      await vscode.window.showTextDocument(document);
      await sleep(300);
      assert.equal(extension.isActive, false, 'only an explicit command activates the extension');
    },
  ],
  [
    'it is off and disconnected by default',
    async () => {
      const hints = await api();
      assert.equal(hints.isEnabled, false);
      assert.equal(hints.connectionState.kind, 'disconnected');
      assert.equal(hints.lastScanFindingCount, undefined);
    },
  ],
  [
    'a one-off scan with no connection sends nothing and reports only a count',
    async () => {
      await vscode.commands.executeCommand('redscreenHints.scanActiveEditor');
      const hints = await api();
      assert.equal(hints.lastScanFindingCount, 2);
      assert.equal(hints.connectionState.kind, 'disconnected');
    },
  ],
  [
    'connect, scan the active editor, and deliver digests the peer can match',
    async () => {
      const peer = await FakePeer.start();
      try {
        await configure(peer);
        await vscode.commands.executeCommand('redscreenHints.connect');
        const hints = await api();
        assert.equal(hints.connectionState.kind, 'connected');

        await vscode.commands.executeCommand('redscreenHints.scanActiveEditor');
        await peer.waitForHints(1);
        const key = digestKey(peer.secrets);
        const received = peer.received[0]!.hints;
        assert.deepEqual(received.map((h) => h.rule).sort(), ['assignment.env', 'connection-string.password']);
        assert.ok(received.some((h) => h.digest === valueDigest(key, 'assignment.env', 'RSFAKE-pg-7d1c9a42')));
        assert.ok(received.some((h) => h.digest === valueDigest(key, 'connection-string.password', 'RSFAKE-pg-pass-42')));
        for (const raw of ['RSFAKE-pg-7d1c9a42', 'RSFAKE-pg-pass-42', 'DATABASE_PASSWORD', 'service.env', workspaceRoot(), 'RSFAKE-other-file']) {
          assert.ok(!peer.rawReceived.includes(Buffer.from(raw)), `the wire carried ${raw.length} characters of content`);
        }
      } finally {
        await vscode.commands.executeCommand('redscreenHints.disconnect');
        await peer.stop();
      }
    },
  ],
  [
    'with hints on, edits are debounced and rescanned; turning off withdraws them',
    async () => {
      const peer = await FakePeer.start();
      try {
        await configure(peer, 200);
        await vscode.commands.executeCommand('redscreenHints.connect');
        assert.equal((await api()).connectionState.kind, 'connected');
        await vscode.commands.executeCommand('redscreenHints.enable');
        assert.equal((await api()).isEnabled, true);
        await peer.waitForHints(1);
        const editor = vscode.window.activeTextEditor!;
        const token = ['gh', 'p_RSFAKE0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c'].join('');
        for (const character of `\nGITHUB_TOKEN=${token}`) {
          await editor.edit((edit) => edit.insert(editor.document.lineAt(editor.document.lineCount - 1).range.end, character));
        }
        await peer.waitForHints(2);
        await sleep(500);
        assert.equal(peer.received.length, 2, 'typing produced one debounced rescan, not one per keystroke');
        const rules = peer.received[1]!.hints.map((h) => h.rule);
        assert.ok(rules.includes('provider.github-token'));
        assert.equal(peer.received[1]!.doc, peer.received[0]!.doc, 'a rescan replaces the same document hints');
        assert.ok(!peer.rawReceived.includes(Buffer.from(token)));

        await vscode.commands.executeCommand('redscreenHints.disable');
        await waitFor(() => peer.cleared.length === 1, 'hints withdrawn');
        assert.equal(peer.cleared[0], peer.received[0]!.doc);
        await vscode.commands.executeCommand('undo');
        await vscode.commands.executeCommand('workbench.action.files.revert');
      } finally {
        await vscode.commands.executeCommand('redscreenHints.disconnect');
        await peer.stop();
      }
    },
  ],
  [
    'a spoofed peer is refused and nothing is sent',
    async () => {
      const peer = await FakePeer.start({ proofKey: randomBytes(32) });
      try {
        await configure(peer);
        await vscode.commands.executeCommand('redscreenHints.connect');
        const hints = await api();
        assert.deepEqual(hints.connectionState, { kind: 'failed', reason: 'authentication-failed' });
        await vscode.commands.executeCommand('redscreenHints.scanActiveEditor');
        await sleep(200);
        assert.equal(peer.received.length, 0);
      } finally {
        await peer.stop();
      }
    },
  ],
  [
    'an incompatible or missing RedScreen leaves the extension disconnected',
    async () => {
      const peer = await FakePeer.start();
      try {
        await peer.publish({ version: 2 });
        await configure(peer);
        await vscode.commands.executeCommand('redscreenHints.connect');
        assert.notEqual((await api()).connectionState.kind, 'connected');
      } finally {
        await peer.stop();
      }
      await vscode.commands.executeCommand('redscreenHints.connect');
      assert.notEqual((await api()).connectionState.kind, 'connected', 'no pairing file: no connection');
      await configure(undefined);
    },
  ],
];
