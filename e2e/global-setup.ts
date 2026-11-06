import type { FullConfig } from "@playwright/test";
import { ensureBootstrapOperator, ensureE2eDatabaseMigrated } from "./helpers/e2eState";
import { startFakeForgejo } from "./helpers/fakeForgejo";
import { startFakeGitHub } from "./helpers/fakeGitHub";

export default async function globalSetup(_config: FullConfig) {
  ensureE2eDatabaseMigrated();
  ensureBootstrapOperator();
  // The git hosts the integration specs connect to; stopped when the run ends.
  const stopForgejo = await startFakeForgejo();
  const stopGitHub = await startFakeGitHub();
  return async () => {
    await stopForgejo();
    await stopGitHub();
  };
}
