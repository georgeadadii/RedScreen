import * as vscode from 'vscode';
import { HintClient, type ConnectionState } from './client';
import { RendezvousError, defaultRendezvousPath, readRendezvous } from './rendezvous';
import { EditorSecretDetector } from './rules';
import { HintScanner, type ScannedDocument } from './scanner';

/**
 * Entry point. Activates only when one of the extension's commands runs. Nothing is scanned
 * until the user scans once or turns hints on, and nothing is sent until they connect. It reports
 * usage nowhere, uses no network, and has no output channel; status shows counts, never values.
 */
export function activate(context: vscode.ExtensionContext): HintsApi {
  const controller = new HintsController();
  context.subscriptions.push(controller);
  const commands: [string, () => unknown][] = [
    ['redscreenHints.scanActiveEditor', () => controller.scanActiveEditorOnce()],
    ['redscreenHints.enable', () => controller.enable()],
    ['redscreenHints.disable', () => controller.disable()],
    ['redscreenHints.connect', () => controller.connect()],
    ['redscreenHints.disconnect', () => controller.disconnect()],
    ['redscreenHints.showStatus', () => controller.showStatus()],
  ];
  for (const [command, handler] of commands) {
    context.subscriptions.push(vscode.commands.registerCommand(command, handler));
  }
  return controller;
}

export function deactivate(): void {}

/** What the integration test can observe. Contains no document content. */
export interface HintsApi {
  readonly isEnabled: boolean;
  readonly connectionState: ConnectionState;
  readonly lastScanFindingCount: number | undefined;
}

class HintsController implements HintsApi, vscode.Disposable {
  private readonly status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 0);
  private readonly client = new HintClient(() => this.render());
  private readonly scanner = new HintScanner(
    new EditorSecretDetector(),
    { send: (doc, findings) => this.client.sendFindings(doc, findings), clear: (doc) => this.client.clear(doc) },
    () => vscode.workspace.getConfiguration('redscreenHints').get<number>('debounceMilliseconds', 500),
  );
  private listeners: vscode.Disposable[] = [];
  private enabled = false;
  private connectionProblem: string | undefined;
  lastScanFindingCount: number | undefined;

  constructor() {
    this.status.command = 'redscreenHints.showStatus';
    this.render();
    this.status.show();
  }

  get isEnabled(): boolean {
    return this.enabled;
  }

  get connectionState(): ConnectionState {
    return this.client.state;
  }

  scanActiveEditorOnce(): void {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
      void vscode.window.showInformationMessage('RedScreen Hints: open a file to scan.');
      return;
    }
    const outcome = this.scanner.scanNow(scanned(editor.document));
    if (outcome.kind === 'too-large') {
      void vscode.window.showWarningMessage('RedScreen Hints: this file is too large to scan.');
      return;
    }
    if (outcome.kind === 'scanned') {
      this.lastScanFindingCount = outcome.findings;
      const sent = this.client.state.kind === 'connected' ? 'sent to RedScreen as digests' : 'not sent: not connected';
      void vscode.window.showInformationMessage(`RedScreen Hints: ${countText(outcome.findings)} (${sent}).`);
    }
    this.render();
  }

  /** Follows the active editor: rescans it after edits, and when another editor becomes active. */
  enable(): void {
    if (this.enabled) return;
    this.enabled = true;
    this.listeners = [
      vscode.workspace.onDidChangeTextDocument((event) => {
        if (event.document === vscode.window.activeTextEditor?.document) this.scheduleActive();
      }),
      vscode.window.onDidChangeActiveTextEditor(() => this.scheduleActive()),
      vscode.workspace.onDidCloseTextDocument((document) => this.scanner.forget(document.uri.toString())),
    ];
    this.scheduleActive();
    this.render();
  }

  disable(): void {
    if (!this.enabled) return;
    this.enabled = false;
    for (const listener of this.listeners) listener.dispose();
    this.listeners = [];
    this.scanner.forgetAll();
    this.render();
  }

  async connect(): Promise<void> {
    const configured = vscode.workspace.getConfiguration('redscreenHints').get<string>('rendezvousFile', '');
    this.connectionProblem = undefined;
    try {
      const rendezvous = await readRendezvous(configured || defaultRendezvousPath());
      await this.client.connect(rendezvous);
      rendezvous.key.fill(0);
      if (this.enabled) this.scheduleActive();
    } catch (error) {
      this.connectionProblem = problemText(error);
      void vscode.window.showWarningMessage(`RedScreen Hints: ${this.connectionProblem}`);
    }
    this.render();
  }

  disconnect(): void {
    this.scanner.forgetAll();
    this.client.close();
    this.connectionProblem = undefined;
    if (this.enabled) this.scheduleActive();
    this.render();
  }

  showStatus(): void {
    const hints = this.enabled ? 'on for the active editor' : 'off';
    void vscode.window.showInformationMessage(`RedScreen Hints are ${hints}. ${this.connectionText()}`);
  }

  dispose(): void {
    this.disable();
    this.client.close();
    this.status.dispose();
  }

  private scheduleActive(): void {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
      this.scanner.cancel();
      return;
    }
    this.scanner.schedule(scanned(editor.document));
  }

  private connectionText(): string {
    switch (this.client.state.kind) {
      case 'connected':
        return 'Connected to RedScreen.';
      case 'connecting':
        return 'Connecting to RedScreen…';
      case 'failed':
        return `Not connected: ${this.connectionProblem ?? 'the connection ended'}.`;
      case 'disconnected':
        return 'Not connected.';
    }
  }

  private render(): void {
    const connected = this.client.state.kind === 'connected';
    const icon = connected ? '$(shield)' : '$(circle-slash)';
    this.status.text = `${icon} RedScreen ${this.enabled ? 'On' : 'Off'}`;
    this.status.tooltip = `RedScreen Hints are ${this.enabled ? 'on' : 'off'}. ${this.connectionText()}`;
    this.status.accessibilityInformation = { label: this.status.tooltip };
  }
}

function scanned(document: vscode.TextDocument): ScannedDocument {
  return {
    key: document.uri.toString(),
    get version() {
      return document.version;
    },
    getText: () => document.getText(),
  };
}

function countText(count: number): string {
  return count === 1 ? '1 potential secret' : `${count} potential secrets`;
}

function problemText(error: unknown): string {
  if (error instanceof RendezvousError) {
    switch (error.reason) {
      case 'not-found':
        return 'RedScreen is not accepting hints. Turn on hints in RedScreen, then connect again.';
      case 'insecure':
        return 'the pairing file or socket is not private to your account, so it was not used.';
      case 'incompatible':
        return 'this RedScreen uses a different hint protocol version. Update the app or the extension.';
      case 'expired':
        return 'the pairing has expired. Turn hints on again in RedScreen.';
      case 'malformed':
        return 'the pairing file is not valid.';
    }
  }
  const reason = error instanceof Error ? error.message : '';
  if (reason === 'incompatible-version') return 'this RedScreen uses a different hint protocol version.';
  if (reason === 'authentication-failed') return 'the peer could not prove it is RedScreen, so it was disconnected.';
  return 'could not connect to RedScreen.';
}
