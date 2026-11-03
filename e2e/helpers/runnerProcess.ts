import { spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const runnerDir = resolve(process.cwd(), "..", "apps", "claude_control_plane_runner");

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

  constructor() {
    this.configDir = mkdtempSync(join(tmpdir(), "cp-runner-e2e-"));
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
