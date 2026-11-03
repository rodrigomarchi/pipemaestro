/**
 * The operator every backoffice spec signs in as.
 *
 * It is the one record the suite does not create through the browser: without
 * an operator nobody can reach the backoffice. `global-setup.ts` creates it the
 * way production does, through `ClaudeControlPlane.Release.create_operator/3`.
 * Everything else - workspaces, users, other operators - each spec creates
 * itself through the UI.
 */
export const bootstrapOperator = {
  email: process.env.E2E_OPERATOR_EMAIL || "operador@e2e.test",
  name: "Operador E2E",
  password: process.env.E2E_OPERATOR_PASSWORD || "senha-e2e-operador",
};

/** A password that passes the product's rules, for users the specs create. */
export const userPassword = "senha-e2e-usuario";

/** A suffix that keeps names, e-mails and slugs unique across runs. */
export function uniqueSuffix(): string {
  return `${Date.now().toString(36)}${Math.floor(Math.random() * 1296).toString(36)}`;
}
