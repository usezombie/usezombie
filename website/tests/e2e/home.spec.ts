import { test, expect } from "@playwright/test";

test.describe("Home page", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
  });

  test("renders hero heading", async ({ page }) => {
    await expect(page.getByRole("heading", { level: 1 })).toContainText("Ship AI");
  });

  test("renders hero CTAs", async ({ page }) => {
    await expect(page.getByRole("link", { name: /start free/i }).first()).toBeVisible();
    await expect(page.getByRole("link", { name: /book team pilot/i }).first()).toBeVisible();
  });

  test("renders bootstrap terminal command", async ({ page }) => {
    await expect(page.getByLabel(/quick start command/i)).toBeVisible();
    await expect(page.getByLabel(/quick start command/i)).toContainText("npx zombiectl login");
  });

  test("renders BYOK provider strip", async ({ page }) => {
    await expect(page.getByText("Bring your own LLM keys")).toBeVisible();
    // Target the exact span elements in the provider strip, not text-within-paragraphs
    const strip = page.locator(".provider-strip");
    await expect(strip.getByText("Anthropic", { exact: true })).toBeVisible();
    await expect(strip.getByText("OpenAI", { exact: true })).toBeVisible();
  });

  test("renders all 5 feature sections", async ({ page }) => {
    // Target the feature headings (h3) specifically
    await expect(page.getByRole("heading", { name: "Deterministic Lifecycle" })).toBeVisible();
    await expect(page.getByRole("heading", { name: "BYOK Trust Model" })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Run Replay and Audit Trail" })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Operational Controls" })).toBeVisible();
    await expect(page.getByRole("heading", { name: "CLI-First, Agent-Ready" })).toBeVisible();
  });

  test("renders how it works steps", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "Queue a spec" })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Agent pipeline runs" })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Validated PR opens" })).toBeVisible();
  });

  test("renders pricing preview cards", async ({ page }) => {
    await expect(page.getByText("$0")).toBeVisible();
    await expect(page.getByText("$39/mo")).toBeVisible();
    await expect(page.getByText("$199/mo")).toBeVisible();
  });

  test("View full pricing link navigates to /pricing", async ({ page }) => {
    await page.getByRole("link", { name: /view full pricing/i }).click();
    await expect(page).toHaveURL(/\/pricing/);
  });

  test("footer is present", async ({ page }) => {
    await expect(page.getByRole("contentinfo")).toBeVisible();
    const footer = page.getByRole("contentinfo");
    await expect(footer.getByRole("link", { name: "GitHub" })).toBeVisible();
    await expect(footer.getByRole("link", { name: "Discord" })).toBeVisible();
  });
});
