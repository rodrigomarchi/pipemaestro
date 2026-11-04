import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const runnerDir = resolve(process.cwd(), "..", "apps", "pipe_maestro_runner");

// Specs never call a real model: jobs run the runner's fake agent CLI, which
// prints the same kind of stream a real run prints.
const fakeClaude = join(runnerDir, "test", "support", "fake_claude");

/**
 * A real runner CLI (`mix runner.*`) run as a child process, the way a person
 * runs it in a terminal. Its credentials live in a throwaway directory so a
 * spec never touches the developer's own runner.
 */
export class RunnerProcess {
  readonly configDir: string;
  private child?: ChildProcess;
  private output = "";
  private exit?: Promise<number | null>;

  private readonly version?: string;

  /** `version`, when given, is the version the runner is built as (`CP_VERSION`). */
  constructor(options: { version?: string } = {}) {
    this.configDir = mkdtempSync(join(tmpdir(), "pipemaestro-e2e-"));
    this.version = options.version;
  }

  /** Starts `mix <task> <args>` in the runner app (MIX_ENV=e2e, like the server). */
  start(task: string, args: string[] = []): void {
    this.output = "";
    this.child = spawn("mix", [task, ...args], {
      cwd: runnerDir,
      env: {
        ...process.env,
        MIX_ENV: "e2e",
        RUNNER_CONFIG_DIR: this.configDir,
        CLAUDE_BIN: fakeClaude,
        // Without a pinned version, the checkout's own (never the server's).
        CP_VERSION: this.version ?? "",
      },
    });
    this.child.stdout?.on("data", (chunk) => (this.output += chunk.toString()));
    this.child.stderr?.on("data", (chunk) => (this.output += chunk.toString()));
    const child = this.child;
    this.exit = new Promise((done) => child.on("exit", (code) => done(code)));
  }

  /** The runner's working directory, where its jobs run. */
  get workdir(): string {
    return join(this.configDir, "workdir");
  }

  /**
   * A code root for `runner.start --root`, inside the throwaway directory:
   * `app`, a git repository with one commit, and `notas`, a plain folder.
   */
  createCodeRoot(): string {
    const root = join(this.configDir, "src");
    const app = join(root, "app");
    mkdirSync(app, { recursive: true });
    mkdirSync(join(root, "notas"), { recursive: true });
    writeFileSync(join(app, "README.md"), "# app\n");

    const git = (...args: string[]) => execFileSync("git", ["-C", app, ...args], { stdio: "ignore" });
    git("init", "-q", "-b", "main");
    git("add", ".");
    git("-c", "user.email=e2e@e2e.test", "-c", "user.name=e2e", "commit", "-q", "-m", "init");

    // Installed dependencies git does not carry: the runner clones them into
    // each task's worktree.
    mkdirSync(join(app, "deps", "jason"), { recursive: true });
    writeFileSync(join(app, "deps", "jason", "mix.exs"), "jason\n");
    return root;
  }

  /** Everything the process printed so far. */
  get text(): string {
    return this.output;
  }

  /** Waits until the output matches `pattern`; returns the match. */
  async waitFor(pattern: RegExp, timeoutMs = 90_000): Promise<RegExpMatchArray> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const match = this.output.match(pattern);
      if (match) return match;
      if (Date.now() > deadline) {
        throw new Error(`Runner output never matched ${pattern}. Output:\n${this.output}`);
      }
      await new Promise((r) => setTimeout(r, 200));
    }
  }

  /** Waits for the process to end and returns its exit code. */
  async waitForExit(timeoutMs = 60_000): Promise<number | null> {
    const timeout = new Promise<never>((_, reject) =>
      setTimeout(() => reject(new Error(`Runner did not exit. Output:\n${this.output}`)), timeoutMs),
    );
    return Promise.race([this.exit!, timeout]);
  }

  stop(): void {
    if (this.child && this.child.exitCode === null) this.child.kill("SIGTERM");
  }

  cleanup(): void {
    this.stop();
    rmSync(this.configDir, { recursive: true, force: true });
  }
}
