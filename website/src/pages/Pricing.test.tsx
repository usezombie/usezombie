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
    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent(/hobby and scale plans/i);
  });

  it("renders the BYOK explanation", () => {
    renderPricing();
    expect(screen.getByText(/never resells model tokens/i)).toBeInTheDocument();
  });

  it("renders Hobby and Scale tiers", () => {
    renderPricing();
    expect(screen.getByText("Hobby")).toBeInTheDocument();
    expect(screen.getByText("Scale")).toBeInTheDocument();
  });

  it("renders prices for each tier", () => {
    renderPricing();
    expect(screen.getByText("$0")).toBeInTheDocument();
    expect(screen.getByText("Coming soon")).toBeInTheDocument();
  });

  it("marks Scale tier as featured", () => {
    const { container } = renderPricing();
    const featured = container.querySelector(".card.featured");
    expect(featured).not.toBeNull();
    expect(featured!.textContent).toContain("Scale");
  });

  it("renders Hobby tier with free runtime window", () => {
    renderPricing();
    expect(screen.getByText(/1 free runtime hour per day/i)).toBeInTheDocument();
  });

  it("renders BYOK/BYOM feature language", () => {
    renderPricing();
    const byokItems = screen.getAllByText(/byok\/byom/i);
    expect(byokItems.length).toBeGreaterThanOrEqual(2);
  });

  it("renders Start free CTA for Hobby tier", () => {
    renderPricing();
    const startFree = screen.getAllByRole("link", { name: /start free/i });
    expect(startFree.length).toBeGreaterThanOrEqual(1);
  });

  it("renders waitlist CTA for Scale", () => {
    renderPricing();
    expect(screen.getByRole("link", { name: /join waitlist/i })).toHaveAttribute(
      "href",
      expect.stringContaining("Scale%20Waitlist")
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
