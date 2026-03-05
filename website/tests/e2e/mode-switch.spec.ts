import { test, expect } from "@playwright/test";

test.describe("Humans/Agents mode switch", () => {
  test("defaults to Humans mode", async ({ page }) => {
    await page.goto("/");
    const humansBtn = page.getByTestId("mode-humans");
    await expect(humansBtn).toHaveAttribute("aria-selected", "true");
    await expect(humansBtn).toHaveClass(/active/);
  });

  test("switches to Agents mode on click", async ({ page }) => {
    await page.goto("/");
    await page.getByTestId("mode-agents").click();
    await expect(page.getByTestId("mode-agents")).toHaveAttribute("aria-selected", "true");
    await expect(page.getByTestId("mode-humans")).toHaveAttribute("aria-selected", "false");
  });

  test("persists Agents mode to localStorage", async ({ page }) => {
    await page.goto("/");
    await page.getByTestId("mode-agents").click();

    const stored = await page.evaluate(() => localStorage.getItem("usezombie_mode"));
    expect(stored).toBe("agents");
  });

  test("restores mode from localStorage on reload", async ({ page }) => {
    await page.goto("/");
    // Set agents mode in localStorage
    await page.evaluate(() => localStorage.setItem("usezombie_mode", "agents"));
    await page.reload();

    await expect(page.getByTestId("mode-agents")).toHaveClass(/active/);
  });

  test("eyebrow text changes with mode", async ({ page }) => {
    await page.goto("/");
    await expect(page.getByText("for engineering teams")).toBeVisible();

    await page.getByTestId("mode-agents").click();
    await expect(page.getByText("agent delivery control plane").first()).toBeVisible();
  });

  test("mode switch is keyboard navigable", async ({ page }) => {
    await page.goto("/");
    await page.getByTestId("mode-humans").focus();
    await expect(page.getByTestId("mode-humans")).toBeFocused();

    await page.keyboard.press("Tab");
    await expect(page.getByTestId("mode-agents")).toBeFocused();
  });
});
