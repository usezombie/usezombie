import { render, screen } from "@testing-library/react";
import { BrowserRouter } from "react-router-dom";
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
    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent(/start free\. upgrade when you need stronger control\./i);
  });

  it("renders roadmap proof points", () => {
    renderPricing();
    expect(screen.getByText(/run quality scoring and failure analysis/i)).toBeInTheDocument();
    expect(screen.getByText(/sandbox governance and team controls/i)).toBeInTheDocument();
  });

  it("renders Hobby and Scale tiers", () => {
    renderPricing();
    expect(screen.getByRole("heading", { level: 2, name: "Hobby" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { level: 2, name: "Scale" })).toBeInTheDocument();
  });

  it("renders Start free CTA for Hobby", () => {
    renderPricing();
    expect(screen.getByRole("link", { name: /start free/i })).toHaveAttribute(
      "href",
      "https://app.dev.usezombie.com",
    );
  });

  it("shows Free and direct-upgrade availability in the card chrome", () => {
    renderPricing();
    expect(screen.getByText("Free")).toBeInTheDocument();
    expect(screen.getByText("Upgrade when ready")).toBeInTheDocument();
  });

  it("renders Scale upgrade copy and CTA", () => {
    renderPricing();
    expect(screen.getByRole("link", { name: /upgrade in app/i })).toHaveAttribute(
      "href",
      "https://app.dev.usezombie.com",
    );
    expect(screen.getByText(/operator-visible upgrade path after free credit exhaustion/i)).toBeInTheDocument();
    expect(screen.getByText(/workspace subscription id/i)).toBeInTheDocument();
  });

  it("renders move-up guidance copy", () => {
    renderPricing();
    expect(screen.getByText(/start on hobby/i)).toBeInTheDocument();
  });

  it("renders FAQ section", () => {
    renderPricing();
    expect(screen.getByText("What does BYOK mean?")).toBeInTheDocument();
  });
});
