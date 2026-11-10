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

/** Runs `body` in the e2e database, with the domain app started (not the web one). */
function runDomain(body: string[], description: string) {
  const expression = [
    "Logger.configure(level: :warning)",
    "Application.ensure_all_started(:pipe_maestro)",
    "import Ecto.Query",
    ...body,
  ].join("\n");

  runMix(["run", "--no-start", "-e", expression], description);
}

/**
 * Makes the workspace `slug` look as if its files already used `bytes`: the
 * file `path` of one of its jobs is counted as that big. Lets a spec reach a
 * quota of whole MiB with the small files the fake agent leaves.
 */
export function inflateJobFile(slug: string, path: string, bytes: number) {
  runDomain(
    [
      `workspace = PipeMaestro.Workspaces.get_workspace_by_slug(${JSON.stringify(slug)})`,
      `{n, _} = PipeMaestro.Repo.update_all(from(f in PipeMaestro.Jobs.JobFile, where: f.workspace_id == ^workspace.id and f.path == ${JSON.stringify(path)}), set: [byte_size: ${bytes}])`,
      `if n == 0, do: raise("no file ${path} in ${slug}")`,
    ],
    "Failed to inflate a job file.",
  );
}

/**
 * Moves the workspace `slug`'s files and finished jobs `days` into the past,
 * then runs the housekeeping (`PipeMaestro.Maintenance.run/2`), as it would
 * once their retention passed.
 */
export function expireRetention(slug: string, days: number) {
  runDomain(
    [
      `workspace = PipeMaestro.Workspaces.get_workspace_by_slug(${JSON.stringify(slug)})`,
      `past = DateTime.add(DateTime.utc_now(:second), -${days}, :day)`,
      "PipeMaestro.Repo.update_all(from(f in PipeMaestro.Jobs.JobFile, where: f.workspace_id == ^workspace.id), set: [inserted_at: past])",
      "PipeMaestro.Repo.update_all(from(j in PipeMaestro.Jobs.Job, where: j.workspace_id == ^workspace.id and not is_nil(j.finished_at)), set: [finished_at: past])",
      "PipeMaestro.Maintenance.run(DateTime.utc_now())",
    ],
    "Failed to expire the workspace's retention.",
  );
}

