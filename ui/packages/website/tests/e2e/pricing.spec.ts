import { test, expect } from "@playwright/test";

test.describe("Pricing page", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/pricing");
  });

  test("renders pricing heading", async ({ page }) => {
    await expect(page.getByRole("heading", { level: 1 })).toContainText("Hobby and Scale plans");
  });

  test("renders Hobby and Scale tiers", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "Hobby", exact: true, level: 2 })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Scale", exact: true, level: 2 })).toBeVisible();
  });

  test("Scale tier has featured styling", async ({ page }) => {
    const teamCard = page.locator(".card.featured");
    await expect(teamCard).toBeVisible();
    await expect(teamCard).toContainText("Scale");
  });

  test("Hobby tier lists free runtime window", async ({ page }) => {
    await expect(page.getByText(/1 free runtime hour per day/i)).toBeVisible();
  });

  test("renders workspace activation fee note", async ({ page }) => {
    await expect(page.getByText(/one-time workspace activation/i)).toBeVisible();
  });

  test("FAQ accordion: first item opens on click", async ({ page }) => {
    const trigger = page.getByTestId("faq-trigger-0");
    await expect(trigger).toBeVisible();
    await expect(page.getByTestId("faq-answer-0")).not.toBeVisible();
    await trigger.click();
    await expect(page.getByTestId("faq-answer-0")).toBeVisible();
  });

  test("FAQ accordion: closes on second click", async ({ page }) => {
    const trigger = page.getByTestId("faq-trigger-0");
    await trigger.click();
    await expect(page.getByTestId("faq-answer-0")).toBeVisible();
    await trigger.click();
    await expect(page.getByTestId("faq-answer-0")).not.toBeVisible();
  });

  test("FAQ accordion: only one item open at a time", async ({ page }) => {
    await page.getByTestId("faq-trigger-0").click();
    await expect(page.getByTestId("faq-answer-0")).toBeVisible();
    await page.getByTestId("faq-trigger-1").click();
    await expect(page.getByTestId("faq-answer-1")).toBeVisible();
    await expect(page.getByTestId("faq-answer-0")).not.toBeVisible();
  });

  test("Start free CTA links to docs", async ({ page }) => {
    const cta = page.getByRole("link", { name: /start free/i }).first();
    await expect(cta).toHaveAttribute("href", "https://docs.usezombie.com/quickstart");
  });

  test("Scale waitlist CTA is a mailto link", async ({ page }) => {
    const cta = page.getByRole("link", { name: /join waitlist/i });
    await expect(cta).toHaveAttribute("href", /Scale%20Waitlist/);
  });

  test("footer renders on pricing page", async ({ page }) => {
    await expect(page.getByRole("contentinfo")).toBeVisible();
  });
});
