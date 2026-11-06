import type { FullConfig } from "@playwright/test";
import { ensureBootstrapOperator, ensureE2eDatabaseMigrated } from "./helpers/e2eState";
import { startFakeForgejo } from "./helpers/fakeForgejo";

export default async function globalSetup(_config: FullConfig) {
  ensureE2eDatabaseMigrated();
  ensureBootstrapOperator();
  // The git host the integration specs connect to; stopped when the run ends.
  return await startFakeForgejo();
}
