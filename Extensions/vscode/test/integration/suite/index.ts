import { tests } from './extension.test';

/** Minimal sequential runner, so the suite needs no test framework dependency. */
export async function run(): Promise<void> {
  const failures: string[] = [];
  for (const [name, body] of tests) {
    try {
      await body();
      console.log(`ok - ${name}`);
    } catch (error) {
      failures.push(name);
      console.log(`not ok - ${name}: ${error instanceof Error ? error.message : 'failed'}`);
    }
  }
  console.log(`${tests.length - failures.length}/${tests.length} integration tests passed`);
  if (failures.length > 0) throw new Error(`${failures.length} integration test(s) failed`);
}
