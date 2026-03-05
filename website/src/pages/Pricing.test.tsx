import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, it, expect } from "vitest";
import Pricing from "./Pricing";

describe("Pricing", () => {
  it("renders the heading", () => {
    render(<Pricing />);
    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent(/byok \+ compute billing/i);
  });

  it("renders the BYOK explanation", () => {
    render(<Pricing />);
    expect(screen.getByText(/never resells model tokens/i)).toBeInTheDocument();
  });

  it("renders all 4 pricing tiers", () => {
    render(<Pricing />);
    expect(screen.getByText("Free")).toBeInTheDocument();
    expect(screen.getByText("Pro")).toBeInTheDocument();
    expect(screen.getByText("Team")).toBeInTheDocument();
    expect(screen.getByText("Enterprise")).toBeInTheDocument();
  });

  it("renders prices for each tier", () => {
    render(<Pricing />);
    expect(screen.getByText("$0")).toBeInTheDocument();
    expect(screen.getByText("$39/mo")).toBeInTheDocument();
    expect(screen.getByText("$199/mo")).toBeInTheDocument();
    expect(screen.getByText("Contact")).toBeInTheDocument();
  });

  it("marks Pro tier as featured", () => {
    const { container } = render(<Pricing />);
    const featured = container.querySelector(".card.featured");
    expect(featured).not.toBeNull();
    expect(featured!.textContent).toContain("Pro");
  });

  it("renders BYOK feature in each tier", () => {
    render(<Pricing />);
    const byokItems = screen.getAllByText(/byok/i);
    expect(byokItems.length).toBeGreaterThanOrEqual(4);
  });

  it("renders Start free CTA for Free tier", () => {
    render(<Pricing />);
    const startFree = screen.getAllByRole("link", { name: /start free/i });
    expect(startFree.length).toBeGreaterThanOrEqual(1);
  });

  it("renders Contact sales CTA for Enterprise", () => {
    render(<Pricing />);
    expect(screen.getByRole("link", { name: /contact sales/i })).toHaveAttribute(
      "href",
      expect.stringContaining("mailto:")
    );
  });

  it("renders workspace activation fee note", () => {
    render(<Pricing />);
    expect(screen.getByText(/one-time workspace activation: \$5/i)).toBeInTheDocument();
  });

  it("renders FAQ section", () => {
    render(<Pricing />);
    expect(screen.getByText("What does BYOK mean?")).toBeInTheDocument();
  });

  it("FAQ accordion works", async () => {
    const user = userEvent.setup();
    render(<Pricing />);

    await user.click(screen.getByText("What does BYOK mean?"));
    expect(screen.getByText(/Bring Your Own Keys/)).toBeInTheDocument();
  });

  it("renders bottom CTA block", () => {
    render(<Pricing />);
    expect(screen.getByText(/not sure which plan/i)).toBeInTheDocument();
  });
});
