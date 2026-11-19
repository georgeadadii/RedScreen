import { existsSync } from 'node:fs';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { runTests } from '@vscode/test-electron';

/**
 * Runs the integration suite in VS Code. Set VSCODE_EXECUTABLE to use an installed copy; otherwise
 * a local install is used if found, and @vscode/test-electron downloads one as a last resort.
 */
async function main(): Promise<void> {
  const root = resolve(__dirname, '..', '..', '..');
  const candidates = [
    process.env.VSCODE_EXECUTABLE,
    '/Applications/Visual Studio Code.app/Contents/MacOS/Code',
    '/Applications/Visual Studio Code 2.app/Contents/MacOS/Code',
  ].filter((path): path is string => typeof path === 'string' && existsSync(path));
  const userData = mkdtempSync(join(tmpdir(), 'rs-hints-vscode-'));
  await runTests({
    ...(candidates[0] ? { vscodeExecutablePath: candidates[0] } : {}),
    extensionDevelopmentPath: root,
    extensionTestsPath: join(__dirname, 'suite', 'index'),
    launchArgs: [join(root, 'test', 'workspace'), '--disable-extensions', '--user-data-dir', userData, '--disable-workspace-trust'],
  });
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : 'integration tests failed');
  process.exit(1);
});
