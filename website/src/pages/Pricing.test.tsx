import { render, screen } from "@testing-library/react";
import { BrowserRouter } from "react-router-dom";
import userEvent from "@testing-library/user-event";
import { describe, it, expect } from "vitest";
import Pricing from "./Pricing";

function renderPricing() {
  return render(
    <BrowserRouter>
      <Pricing />
    </BrowserRouter>
  );
}

describe("Pricing", () => {
  it("renders the heading", () => {
    renderPricing();
    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent(/byok \+ compute billing/i);
  });

  it("renders the BYOK explanation", () => {
    renderPricing();
    expect(screen.getByText(/never resells model tokens/i)).toBeInTheDocument();
  });

  it("renders all 4 pricing tiers (Open Source, Hobby, Pro, Enterprise)", () => {
    renderPricing();
    expect(screen.getByText("Open Source")).toBeInTheDocument();
    expect(screen.getByText("Hobby")).toBeInTheDocument();
    expect(screen.getByText("Pro")).toBeInTheDocument();
    expect(screen.getByText("Enterprise")).toBeInTheDocument();
  });

  it("renders prices for each tier", () => {
    renderPricing();
    const freeTexts = screen.getAllByText("Free");
    expect(freeTexts.length).toBeGreaterThanOrEqual(1);
    expect(screen.getByText("$0")).toBeInTheDocument();
    expect(screen.getByText("$39/mo")).toBeInTheDocument();
    expect(screen.getByText("Contact")).toBeInTheDocument();
  });

  it("marks Pro tier as featured", () => {
    const { container } = renderPricing();
    const featured = container.querySelector(".card.featured");
    expect(featured).not.toBeNull();
    expect(featured!.textContent).toContain("Pro");
  });

  it("renders Hobby tier with default agents", () => {
    renderPricing();
    expect(screen.getByText(/3 default agents \(Scout, Echo, Warden\)/i)).toBeInTheDocument();
  });

  it("renders BYOK feature in each tier", () => {
    renderPricing();
    const byokItems = screen.getAllByText(/byok/i);
    expect(byokItems.length).toBeGreaterThanOrEqual(4);
  });

  it("renders Start free CTA for Hobby tier", () => {
    renderPricing();
    const startFree = screen.getAllByRole("link", { name: /start free/i });
    expect(startFree.length).toBeGreaterThanOrEqual(1);
  });

  it("renders View on GitHub CTA for Open Source tier", () => {
    renderPricing();
    expect(screen.getByRole("link", { name: /view on github/i })).toHaveAttribute(
      "href",
      "https://github.com/usezombie"
    );
  });

  it("renders Contact sales CTA for Enterprise", () => {
    renderPricing();
    expect(screen.getByRole("link", { name: /contact sales/i })).toHaveAttribute(
      "href",
      expect.stringContaining("mailto:")
    );
  });

  it("renders workspace activation fee note", () => {
    renderPricing();
    expect(screen.getByText(/one-time workspace activation: \$5/i)).toBeInTheDocument();
  });

  it("renders FAQ section", () => {
    renderPricing();
    expect(screen.getByText("What does BYOK mean?")).toBeInTheDocument();
  });

  it("FAQ accordion works", async () => {
    const user = userEvent.setup();
    renderPricing();

    await user.click(screen.getByText("What does BYOK mean?"));
    expect(screen.getByText(/Bring Your Own Keys/)).toBeInTheDocument();
  });

  it("renders bottom CTA block", () => {
    renderPricing();
    expect(screen.getByText(/not sure which plan/i)).toBeInTheDocument();
  });
});
