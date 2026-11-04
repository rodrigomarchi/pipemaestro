import { spawnSync } from "node:child_process";
import { basename, resolve } from "node:path";
import { bootstrapOperator } from "./env";

const repoRoot =
  basename(process.cwd()) === "e2e" ? resolve(process.cwd(), "..") : process.cwd();

function runMix(args: string[], description: string) {
  const result = spawnSync("mix", args, {
    cwd: repoRoot,
    encoding: "utf8",
    env: { ...process.env, LOG_LEVEL: "warning", MIX_ENV: "e2e" },
  });

  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error([description, result.stdout, result.stderr].filter(Boolean).join("\n"));
  }
}

export function ensureE2eDatabaseMigrated() {
  runMix(["ecto.create", "--quiet"], "Failed to create the e2e database.");
  runMix(["ecto.migrate", "--quiet"], "Failed to migrate the e2e database.");
}

/** Creates the bootstrap operator unless a previous run already did. */
export function ensureBootstrapOperator() {
  const { email, name, password } = bootstrapOperator;
  // Only the domain app: the e2e server already holds the HTTP port.
  const expression = [
    "Logger.configure(level: :warning)",
    "Application.ensure_all_started(:pipe_maestro)",
    `if !Enum.any?(PipeMaestro.Backoffice.list_operators(), &(&1.email == ${JSON.stringify(email)})),`,
    `do: {:ok, _} = PipeMaestro.Release.create_operator(${JSON.stringify(email)}, ${JSON.stringify(name)}, ${JSON.stringify(password)})`,
  ].join("\n");

  runMix(["run", "--no-start", "-e", expression], "Failed to create the bootstrap operator.");
}
