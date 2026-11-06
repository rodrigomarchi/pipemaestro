/**
 * Sends a webhook delivery to the platform the way Forgejo does: the JSON
 * body signed with the connection's secret (HMAC-SHA256 in plain hex, in
 * `X-Forgejo-Signature`), the event in `X-Forgejo-Event-Type` and the
 * delivery's id in `X-Forgejo-Delivery`. Black-box: it only crosses HTTP.
 */
import type { APIRequestContext } from "@playwright/test";
import crypto from "node:crypto";

export async function sendForgejoWebhook(
  request: APIRequestContext,
  delivery: { url: string; secret: string; event: string; id: string; payload: unknown },
) {
  const body = JSON.stringify(delivery.payload);
  const signature = crypto.createHmac("sha256", delivery.secret).update(body).digest("hex");

  return request.post(delivery.url, {
    data: body,
    headers: {
      "content-type": "application/json",
      "x-forgejo-event": delivery.event === "issue_label" ? "issues" : delivery.event,
      "x-forgejo-event-type": delivery.event,
      "x-forgejo-delivery": delivery.id,
      "x-forgejo-signature": signature,
    },
  });
}

/** An `issue_label` payload of an issue of `repo` with `labels`. */
export function issueLabelPayload(repo: string, issue: { number: number; title: string; body: string; labels: string[] }, baseUrl: string) {
  return {
    action: "label_updated",
    number: issue.number,
    repository: { full_name: repo },
    sender: { login: "ana" },
    issue: {
      number: issue.number,
      title: issue.title,
      body: issue.body,
      state: "open",
      html_url: `${baseUrl}/${repo}/issues/${issue.number}`,
      user: { login: "ana" },
      labels: issue.labels.map((name) => ({ name })),
      updated_at: new Date().toISOString(),
      pull_request: null,
    },
  };
}
