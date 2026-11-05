import { expect, type Locator } from "@playwright/test";

/**
 * Picks a project in one of the forms that start work (task, job, proposal).
 * Each option reads "<name> · <runner>:<directory>" (a disabled one,
 * "<name> (<reason>)"); picks the enabled one named `name`, waiting for it to
 * be listed.
 */
export async function selectProject(select: Locator, name: string): Promise<void> {
  let value: string | undefined;

  await expect
    .poll(
      async () => {
        const options = await select.evaluate((el: HTMLSelectElement) =>
          Array.from(el.options).map((o) => ({ label: o.text, value: o.value, disabled: o.disabled })),
        );
        value = options.find((o) => !o.disabled && o.label.startsWith(`${name} · `))?.value;
        return value;
      },
      { message: `project ${name} among the options` },
    )
    .toBeTruthy();

  await select.selectOption(value!);
}
