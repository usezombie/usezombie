import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import HowItWorks from "./HowItWorks";

describe("HowItWorks", () => {
  it("renders the section heading", () => {
    render(<HowItWorks />);
    expect(screen.getByRole("heading", { level: 2, name: /specs in/i })).toBeInTheDocument();
  });

  it("renders the eyebrow", () => {
    render(<HowItWorks />);
    expect(screen.getByText("How it works")).toBeInTheDocument();
  });

  it("renders all three steps", () => {
    render(<HowItWorks />);
    expect(screen.getByText("Queue a spec")).toBeInTheDocument();
    expect(screen.getByText("Agent pipeline runs")).toBeInTheDocument();
    expect(screen.getByText("Validated PR opens")).toBeInTheDocument();
  });

  it("renders step descriptions", () => {
    render(<HowItWorks />);
    expect(screen.getByText(/PENDING_\*\.md/)).toBeInTheDocument();
    expect(screen.getByText(/Echo plans, Scout patches/)).toBeInTheDocument();
    expect(screen.getByText(/verified pull request/)).toBeInTheDocument();
  });
});
