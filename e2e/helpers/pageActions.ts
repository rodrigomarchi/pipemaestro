import { expect, type Locator, type Page } from "@playwright/test";

/**
 * A page's actions in the top bar. One action is a button of its own; two or
 * more fold into the "Ações" menu (`page-actions-trigger`). Either way each
 * keeps its `data-testid`, so a spec names the action and this opens the menu
 * first when there is one.
 */
export async function clickPageAction(page: Page, testid: string) {
  await (await pageAction(page, testid)).click();
}

/** The action, reachable: the menu is opened when the page has one. */
export async function pageAction(page: Page, testid: string): Promise<Locator> {
  await expect(page.getByTestId("page-actions")).toBeVisible();
  const action = page.getByTestId(testid);
  const trigger = page.getByTestId("page-actions-trigger");
  if ((await trigger.count()) > 0 && !(await action.isVisible())) {
    await trigger.click();
  }
  await expect(action).toBeVisible();
  return action;
}
