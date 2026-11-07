/**
 * A Forgejo in memory for the suite, the git host the control plane talks to
 * when a spec connects an integration (`PipeMaestro.Integrations.Forgejo`).
 *
 * `global-setup.ts` starts it on `fakeForgejo.port` and the returned teardown
 * stops it. Specs run in other processes, so they reach it only over HTTP, as
 * the platform does:
 *
 *   - the API under `/api/v1` and OAuth under `/login/oauth`, the parts the
 *     platform uses, signed in with `fakeForgejo.token` (the bot
 *     `pipemaestro-bot`) or a token the OAuth flow handed out;
 *   - `/__e2e/*`, for the specs: create a repository or an issue, set what
 *     the repository's CI reports (`POST /__e2e/ci`), and read what the
 *     platform did (`GET /__e2e/state?repo=owner/name`).
 *
 * A pull request's head is the last commit the platform set a status on (the
 * fake knows no git), and it always merges cleanly.
 *
 * The authorize page answers at once with a code, as if the person clicked
 * "authorize". Specs create repositories with unique names, so they share
 * the fake without resetting it.
 */
import http from "node:http";

export const fakeForgejo = {
  port: Number(process.env.E2E_FORGEJO_PORT || 4013),
  get url() {
    return `http://localhost:${this.port}`;
  },
  token: "e2e-bot-token",
};

type Json = Record<string, any>;

interface Repo {
  id: number;
  fullName: string;
  labels: Json[];
  hooks: Json[];
  issues: Map<number, Json>;
  comments: Json[];
  reactions: Json[];
  statuses: Json[];
  pulls: Json[];
  /** What the repository's CI (`ci/test`) reports on every commit, if anything. */
  ci: string | null;
}

const repos = new Map<string, Repo>();
const tokens = new Map<string, Json>([[fakeForgejo.token, { login: "pipemaestro-bot", id: 7 }]]);
const refreshTokens = new Map<string, boolean>();
let nextId = 1000;

function repoOf(fullName: string): Repo {
  let repo = repos.get(fullName);
  if (!repo) {
    repo = { id: nextId++, fullName, labels: [], hooks: [], issues: new Map(), comments: [], reactions: [], statuses: [], pulls: [], ci: null };
    repos.set(fullName, repo);
  }
  return repo;
}

function repoJson(repo: Repo): Json {
  return { id: repo.id, full_name: repo.fullName, default_branch: "main", html_url: `${fakeForgejo.url}/${repo.fullName}` };
}

function send(res: http.ServerResponse, status: number, body?: unknown, headers: Json = {}) {
  res.writeHead(status, { "content-type": "application/json", ...headers });
  res.end(body === undefined ? "" : JSON.stringify(body));
}

async function readBody(req: http.IncomingMessage): Promise<Json> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  const text = Buffer.concat(chunks).toString();
  if (!text) return {};
  if ((req.headers["content-type"] || "").includes("application/x-www-form-urlencoded")) {
    return Object.fromEntries(new URLSearchParams(text));
  }
  return JSON.parse(text);
}

function page<T>(items: T[], query: URLSearchParams): { slice: T[]; headers: Json } {
  const limit = Number(query.get("limit") || 30);
  const n = Number(query.get("page") || 1);
  return { slice: items.slice((n - 1) * limit, n * limit), headers: { "x-total-count": String(items.length) } };
}

function issueJson(repo: Repo, issue: Json): Json {
  return {
    id: 5000 + issue.number,
    number: issue.number,
    title: issue.title || `Issue ${issue.number}`,
    body: issue.body || "",
    state: issue.state || "open",
    html_url: `${fakeForgejo.url}/${repo.fullName}/issues/${issue.number}`,
    user: { login: issue.author || "ana" },
    labels: (issue.labels || []).map((name: string) => ({ name })),
    pull_request: null,
    updated_at: issue.updated_at || new Date().toISOString(),
  };
}

async function handle(req: http.IncomingMessage, res: http.ServerResponse) {
  const url = new URL(req.url || "/", fakeForgejo.url);
  const parts = url.pathname.split("/").filter(Boolean).map(decodeURIComponent);
  const method = req.method || "GET";
  const body = await readBody(req);

  // The specs' side door.
  if (parts[0] === "__e2e") {
    if (method === "POST" && parts[1] === "repos") return send(res, 201, repoJson(repoOf(body.full_name)));
    if (method === "POST" && parts[1] === "issues") {
      const repo = repoOf(body.repo);
      repo.issues.set(body.number, { ...body });
      return send(res, 201, issueJson(repo, body));
    }
    if (method === "POST" && parts[1] === "ci") {
      repoOf(body.repo).ci = body.state;
      return send(res, 200, { ci: body.state });
    }
    if (method === "GET" && parts[1] === "state") {
      const repo = repoOf(url.searchParams.get("repo") || "");
      return send(res, 200, {
        labels: repo.labels,
        hooks: repo.hooks,
        issues: [...repo.issues.values()].map((issue) => issueJson(repo, issue)),
        comments: repo.comments,
        reactions: repo.reactions,
        statuses: repo.statuses,
        pulls: repo.pulls,
      });
    }
  }

  // OAuth: authorizing answers at once; the token endpoint hands out tokens.
  if (parts[0] === "login" && parts[1] === "oauth") {
    if (parts[2] === "authorize") {
      const back = new URL(url.searchParams.get("redirect_uri") || "");
      back.searchParams.set("code", "e2e-code");
      back.searchParams.set("state", url.searchParams.get("state") || "");
      res.writeHead(302, { location: back.toString() });
      return res.end();
    }
    if (parts[2] === "access_token") {
      const valid =
        (body.grant_type === "authorization_code" && body.code === "e2e-code" && body.code_verifier) ||
        (body.grant_type === "refresh_token" && refreshTokens.get(body.refresh_token));
      if (!valid) return send(res, 400, { error: "invalid_grant" });
      if (body.refresh_token) refreshTokens.set(body.refresh_token, false);
      const n = nextId++;
      tokens.set(`access-${n}`, { login: "ana-forgejo", id: 8 });
      refreshTokens.set(`refresh-${n}`, true);
      return send(res, 200, { access_token: `access-${n}`, refresh_token: `refresh-${n}`, expires_in: 3600 });
    }
  }

  if (parts[0] !== "api" || parts[1] !== "v1") return send(res, 404, { message: "not found" });
  const auth = (req.headers.authorization || "").replace(/^(token|Bearer) /, "");
  const me = tokens.get(auth);
  if (!me) return send(res, 401, { message: "token is required" });

  const api = parts.slice(2);
  if (method === "GET" && api.join("/") === "version") return send(res, 200, { version: "17.0.1+gitea-1.22.0" });
  if (method === "GET" && api.join("/") === "user") return send(res, 200, me);
  if (method === "GET" && api.join("/") === "repos/search") {
    const q = url.searchParams.get("q") || "";
    const all = [...repos.values()].filter((repo) => repo.fullName.includes(q)).map(repoJson);
    const { slice, headers } = page(all, url.searchParams);
    return send(res, 200, { ok: true, data: slice }, headers);
  }

  if (api[0] !== "repos" || api.length < 3) return send(res, 404, { message: "not found" });
  const repo = repos.get(`${api[1]}/${api[2]}`);
  if (!repo) return send(res, 404, { message: "repo not found" });
  const rest = api.slice(3);
  const route = `${method} ${rest.map((part) => (/^\d+$/.test(part) ? ":n" : part)).join("/")}`;
  const n = Number(rest.find((part) => /^\d+$/.test(part)));

  // The latest status of each context on a commit, the CI's included.
  if (method === "GET" && rest[0] === "commits" && rest[2] === "status") {
    const sha = rest[1];
    const latest = new Map<string, Json>();
    for (const status of repo.statuses.filter((candidate) => candidate.sha === sha)) latest.set(status.context, status);
    if (repo.ci) latest.set("ci/test", { sha, context: "ci/test", state: repo.ci, description: `ci/test: ${repo.ci}` });
    const statuses = [...latest.values()].map((status) => ({ ...status, status: status.state }));
    return send(res, 200, { sha, statuses });
  }

  switch (route) {
    case "GET ":
      return send(res, 200, repoJson(repo));
    case "GET collaborators/" + rest[1] + "/permission":
      return send(res, 200, { permission: rest[1] === "estranho" ? "none" : "write" });
    case "GET labels": {
      const { slice, headers } = page(repo.labels, url.searchParams);
      return send(res, 200, slice, headers);
    }
    case "POST labels": {
      const label = { ...body, id: nextId++ };
      repo.labels.push(label);
      return send(res, 201, label);
    }
    case "POST hooks": {
      const hook = { ...body, id: nextId++ };
      repo.hooks.push(hook);
      return send(res, 201, hook);
    }
    case "PATCH hooks/:n":
      repo.hooks = repo.hooks.map((hook) => (hook.id === n ? { ...hook, ...body } : hook));
      return send(res, 200, { id: n });
    case "DELETE hooks/:n":
      repo.hooks = repo.hooks.filter((hook) => hook.id !== n);
      return send(res, 204);
    case "GET issues": {
      const since = url.searchParams.get("since");
      const wanted = (url.searchParams.get("labels") || "").split(",").filter(Boolean);
      const all = [...repo.issues.values()]
        .map((issue) => issueJson(repo, issue))
        .filter((issue) => issue.state === "open" && (!since || issue.updated_at >= since))
        .filter((issue) => wanted.length === 0 || issue.labels.some((label: Json) => wanted.includes(label.name)));
      const { slice, headers } = page(all, url.searchParams);
      return send(res, 200, slice, headers);
    }
    case "GET issues/:n": {
      const issue = repo.issues.get(n);
      return issue ? send(res, 200, issueJson(repo, issue)) : send(res, 404, { message: "issue not found" });
    }
    case "POST issues/:n/comments": {
      const comment = { id: nextId++, issue: n, body: body.body };
      repo.comments.push(comment);
      return send(res, 201, comment);
    }
    case "PATCH issues/comments/:n":
      repo.comments = repo.comments.map((comment) => (comment.id === n ? { ...comment, body: body.body } : comment));
      return send(res, 200, { id: n, body: body.body });
    case "POST issues/:n/reactions":
      repo.reactions.push({ target: "issue", id: n, content: body.content });
      return send(res, 201, { content: body.content });
    case "POST issues/comments/:n/reactions":
      repo.reactions.push({ target: "comment", id: n, content: body.content });
      return send(res, 201, { content: body.content });
    case "POST issues/:n/labels": {
      const issue = repo.issues.get(n);
      if (!issue) return send(res, 404, { message: "issue not found" });
      issue.labels = [...new Set([...(issue.labels || []), ...body.labels])];
      issue.updated_at = new Date().toISOString();
      return send(res, 200, issue.labels.map((name: string) => ({ name })));
    }
    case "POST statuses/" + rest[1]: {
      repo.statuses.push({ ...body, sha: rest[1] });
      return send(res, 201, body);
    }
    case "GET pulls": {
      const { slice, headers } = page(repo.pulls.filter((pull) => pull.state === "open"), url.searchParams);
      return send(res, 200, slice, headers);
    }
    case "POST pulls": {
      const number = repo.pulls.length + 1;
      const pull = {
        number,
        state: "open",
        title: body.title,
        body: body.body,
        head: { ref: body.head },
        base: { ref: body.base },
        html_url: `${fakeForgejo.url}/${repo.fullName}/pulls/${number}`,
      };
      repo.pulls.push(pull);
      return send(res, 201, pull);
    }
    case "GET pulls/:n": {
      const pull = repo.pulls.find((candidate) => candidate.number === n);
      if (!pull) return send(res, 404, { message: "pull not found" });
      const head = repo.statuses.at(-1)?.sha;
      return send(res, 200, { mergeable: true, merged: false, ...pull, head: { ...pull.head, sha: head } });
    }
    case "POST pulls/:n/merge": {
      const pull = repo.pulls.find((candidate) => candidate.number === n);
      if (!pull) return send(res, 404, { message: "pull not found" });
      Object.assign(pull, { merged: true, state: "closed", merge: body });
      return send(res, 200, {});
    }
    case "PATCH pulls/:n": {
      const pull = repo.pulls.find((candidate) => candidate.number === n);
      if (!pull) return send(res, 404, { message: "pull not found" });
      if (body.title !== undefined) pull.title = body.title;
      if (body.body !== undefined) pull.body = body.body;
      return send(res, 200, pull);
    }
  }

  // Removing a label: DELETE issues/:n/labels/<name>.
  if (method === "DELETE" && rest[0] === "issues" && rest[2] === "labels") {
    const issue = repo.issues.get(Number(rest[1]));
    if (issue) issue.labels = (issue.labels || []).filter((name: string) => name !== rest[3]);
    return send(res, 204);
  }

  return send(res, 404, { message: "not found" });
}

/** Starts the fake; resolves to a function that stops it. */
export async function startFakeForgejo(): Promise<() => Promise<void>> {
  const server = http.createServer((req, res) => {
    handle(req, res).catch((error) => send(res, 500, { message: String(error) }));
  });
  await new Promise<void>((resolve) => server.listen(fakeForgejo.port, resolve));
  return () => new Promise<void>((resolve) => server.close(() => resolve()));
}

/** What the platform did to a repository of the fake. */
export async function forgejoState(fullName: string): Promise<Json> {
  const response = await fetch(`${fakeForgejo.url}/__e2e/state?repo=${encodeURIComponent(fullName)}`);
  return response.json();
}

/** Creates a repository on the fake. */
export async function createForgejoRepo(fullName: string): Promise<void> {
  await fetch(`${fakeForgejo.url}/__e2e/repos`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ full_name: fullName }),
  });
}

/** Creates an issue on the fake. */
export async function createForgejoIssue(issue: { repo: string; number: number; title: string; body?: string; labels?: string[] }): Promise<void> {
  await fetch(`${fakeForgejo.url}/__e2e/issues`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(issue),
  });
}

/** Sets what the repository's CI (`ci/test`) reports on every commit: "pending", "success", "failure", or null for no CI. */
export async function setForgejoCi(repo: string, state: string | null): Promise<void> {
  await fetch(`${fakeForgejo.url}/__e2e/ci`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ repo, state }),
  });
}
