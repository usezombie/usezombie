import { render, screen } from "@testing-library/react";
import { BrowserRouter } from "react-router-dom";
import { describe, it, expect } from "vitest";
import Home from "./Home";

function renderHome(mode: "humans" | "agents" = "humans") {
  return render(
    <BrowserRouter>
      <Home mode={mode} />
    </BrowserRouter>
  );
}

describe("Home", () => {
  it("renders the hero headline", () => {
    renderHome();
    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent(/ship ai.generated prs/i);
  });

  it("renders the lead description", () => {
    renderHome();
    expect(screen.getByText(/spec queues into validated pull requests/i)).toBeInTheDocument();
  });

  it("shows human eyebrow in humans mode", () => {
    renderHome("humans");
    expect(screen.getByText(/for engineering teams/i)).toBeInTheDocument();
  });

  it("shows agent eyebrow in agents mode", () => {
    renderHome("agents");
    expect(screen.getByText(/agent delivery control plane/i)).toBeInTheDocument();
  });

  it("renders Start free CTAs", () => {
    renderHome();
    const ctas = screen.getAllByRole("link", { name: /start free/i });
    expect(ctas.length).toBeGreaterThanOrEqual(1);
    expect(ctas[0]).toHaveAttribute("href", "https://docs.usezombie.com/quickstart");
  });

  it("renders Book team pilot CTAs", () => {
    renderHome();
    const ctas = screen.getAllByRole("link", { name: /book team pilot/i });
    expect(ctas.length).toBeGreaterThanOrEqual(1);
    expect(ctas[0]).toHaveAttribute("href", expect.stringContaining("mailto:"));
  });

  it("renders the terminal quickstart command", () => {
    renderHome();
    expect(screen.getByLabelText(/quick start command/i)).toBeInTheDocument();
  });

  it("renders all 5 feature sections", () => {
    renderHome();
    expect(screen.getByText("Deterministic Lifecycle")).toBeInTheDocument();
    expect(screen.getByText("BYOK Trust Model")).toBeInTheDocument();
    expect(screen.getByText("Run Replay and Audit Trail")).toBeInTheDocument();
    expect(screen.getByText("Operational Controls")).toBeInTheDocument();
    expect(screen.getByText(/CLI-First, Agent-Ready/)).toBeInTheDocument();
  });

  it("renders the provider strip", () => {
    renderHome();
    expect(screen.getByText("Bring your own LLM keys")).toBeInTheDocument();
  });

  it("renders how it works section", () => {
    renderHome();
    expect(screen.getByText("Queue a spec")).toBeInTheDocument();
    expect(screen.getByText("Agent pipeline runs")).toBeInTheDocument();
    expect(screen.getByText("Validated PR opens")).toBeInTheDocument();
  });

  it("renders pricing preview", () => {
    renderHome();
    expect(screen.getByText("$0")).toBeInTheDocument();
    expect(screen.getByText("$39/mo")).toBeInTheDocument();
    expect(screen.getByText("$199/mo")).toBeInTheDocument();
    expect(screen.getByText("Contact")).toBeInTheDocument();
  });

  it("renders View full pricing link", () => {
    renderHome();
    expect(screen.getByRole("link", { name: /view full pricing/i })).toHaveAttribute("href", "/pricing");
  });

  it("renders CTA block", () => {
    renderHome();
    expect(screen.getByText(/ready to ship reliable prs/i)).toBeInTheDocument();
  });
});
