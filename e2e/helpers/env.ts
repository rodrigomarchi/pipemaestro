/**
 * The operator every backoffice spec signs in as.
 *
 * It is the one record the suite does not create through the browser: without
 * an operator nobody can reach the backoffice. `global-setup.ts` creates it the
 * way production does, through `PipeMaestro.Release.create_operator/3`.
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

/**
 * The versions the suite pins (`CP_VERSION`): the server is built as
 * `controlPlane`; a runner started with `outdatedRunner` is an older release,
 * so its pages show it as outdated.
 */
export const versions = {
  controlPlane: "2026-11-04.02",
  outdatedRunner: "2026-11-04.01",
};

/** A suffix that keeps names, e-mails and slugs unique across runs. */
export function uniqueSuffix(): string {
  return `${Date.now().toString(36)}${Math.floor(Math.random() * 1296).toString(36)}`;
}
