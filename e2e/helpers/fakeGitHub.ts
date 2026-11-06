/**
 * GitHub in memory for the suite: the parts the platform's GitHub App uses to
 * be installed and to link a repository (`config/e2e.exs` points the App at
 * `fakeGitHub.url`).
 *
 * Installing redirects at once to the platform's setup URL with a new
 * installation id and the sign-in code `e2e-code`, as GitHub does with
 * "Request user authorization (OAuth) during installation" on. Specs create
 * repositories (`createGitHubRepo`), which the installation reaches.
 */
import http from "node:http";

export const fakeGitHub = {
  port: Number(process.env.E2E_GITHUB_PORT || 4014),
  get url() {
    return `http://localhost:${this.port}`;
  },
  platformUrl: `http://localhost:${process.env.E2E_PORT || 4003}`,
};

type Json = Record<string, any>;

const repos = new Map<string, Json>();
let nextId = 1;
// Each installation is a new one, as on GitHub: an installation belongs to one connection.
let nextInstallation = Math.floor(Date.now() / 1000);
const installations: number[] = [];

function send(res: http.ServerResponse, status: number, body?: unknown) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(body === undefined ? "" : JSON.stringify(body));
}

async function readBody(req: http.IncomingMessage): Promise<Json> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  const text = Buffer.concat(chunks).toString();
  if (!text) return {};
  if ((req.headers["content-type"] || "").includes("application/x-www-form-urlencoded")) return Object.fromEntries(new URLSearchParams(text));
  return JSON.parse(text);
}

async function handle(req: http.IncomingMessage, res: http.ServerResponse) {
  const url = new URL(req.url || "/", fakeGitHub.url);
  const parts = url.pathname.split("/").filter(Boolean).map(decodeURIComponent);
  const method = req.method || "GET";
  const body = await readBody(req);

  if (method === "POST" && url.pathname === "/__e2e/repos") {
    repos.set(body.full_name, { id: nextId++, full_name: body.full_name, default_branch: "main", labels: [] });
    return send(res, 201, {});
  }

  // Installing the App goes straight back to the platform.
  if (method === "GET" && parts[0] === "apps" && parts[2] === "installations" && parts[3] === "new") {
    const back = new URL(`${fakeGitHub.platformUrl}/integrations/github/setup`);
    const installation = nextInstallation++;
    installations.push(installation);
    back.searchParams.set("installation_id", String(installation));
    back.searchParams.set("setup_action", "install");
    back.searchParams.set("code", "e2e-code");
    back.searchParams.set("state", url.searchParams.get("state") || "");
    res.writeHead(302, { location: back.toString() });
    return res.end();
  }

  if (method === "POST" && url.pathname === "/login/oauth/access_token") {
    return body.code === "e2e-code" ? send(res, 200, { access_token: "ghu_e2e" }) : send(res, 200, { error: "bad_verification_code" });
  }

  if (method === "GET" && url.pathname === "/user") return send(res, 200, { login: "gil", id: 8 });
  if (method === "GET" && url.pathname === "/user/installations") {
    return send(res, 200, { installations: installations.map((id) => ({ id, account: { type: "Organization", login: "acme" } })) });
  }
  if (method === "GET" && url.pathname === "/user/memberships/orgs/acme") return send(res, 200, { role: "admin", state: "active" });

  if (method === "POST" && parts[0] === "app" && parts[1] === "installations" && parts[3] === "access_tokens") {
    return send(res, 201, { token: `ghs_e2e_${nextId++}`, expires_at: new Date(Date.now() + 3_600_000).toISOString() });
  }

  if (method === "GET" && url.pathname === "/installation/repositories") {
    const all = [...repos.values()].map(({ labels, ...repo }) => repo);
    return send(res, 200, { total_count: all.length, repositories: all });
  }

  if (parts[0] === "repos" && parts.length >= 3) {
    const repo = repos.get(`${parts[1]}/${parts[2]}`);
    if (!repo) return send(res, 404, { message: "Not Found" });
    const rest = parts.slice(3).join("/");
    if (method === "GET" && rest === "") return send(res, 200, { id: repo.id, full_name: repo.full_name, default_branch: "main" });
    if (method === "GET" && rest === "labels") return send(res, 200, repo.labels);
    if (method === "POST" && rest === "labels") {
      repo.labels.push(body);
      return send(res, 201, body);
    }
  }

  return send(res, 404, { message: "Not Found" });
}

/** Starts the fake; resolves to a function that stops it. */
export async function startFakeGitHub(): Promise<() => Promise<void>> {
  const server = http.createServer((req, res) => {
    handle(req, res).catch((error) => send(res, 500, { message: String(error) }));
  });
  await new Promise<void>((resolve) => server.listen(fakeGitHub.port, resolve));
  return () => new Promise<void>((resolve) => server.close(() => resolve()));
}

/** Creates a repository the App's installation reaches. */
export async function createGitHubRepo(fullName: string): Promise<void> {
  await fetch(`${fakeGitHub.url}/__e2e/repos`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ full_name: fullName }),
  });
}

/** The labels the platform created on a repository. */
export async function gitHubLabels(fullName: string): Promise<string[]> {
  const response = await fetch(`${fakeGitHub.url}/repos/${fullName}/labels`);
  return (await response.json()).map((label: { name: string }) => label.name);
}
