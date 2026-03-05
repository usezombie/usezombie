import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import Agents from "./Agents";

describe("Agents", () => {
  it("renders the agent-first heading", () => {
    render(<Agents />);
    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent(/autonomous agents/i);
  });

  it("renders the canonical contract note", () => {
    render(<Agents />);
    expect(screen.getByText(/canonical contract/i)).toBeInTheDocument();
  });

  it("renders bootstrap commands", () => {
    render(<Agents />);
    expect(screen.getByLabelText(/bootstrap commands/i)).toBeInTheDocument();
    expect(screen.getByText(/curl -s https:\/\/usezombie\.sh\/skill\.md/)).toBeInTheDocument();
  });

  it("renders machine contracts table", () => {
    render(<Agents />);
    expect(screen.getByText("Machine Contracts")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "/openapi.json" })).toHaveAttribute("href", "/openapi.json");
    expect(screen.getByRole("link", { name: "/agent-manifest.json" })).toHaveAttribute("href", "/agent-manifest.json");
    expect(screen.getByRole("link", { name: "/skill.md" })).toHaveAttribute("href", "/skill.md");
    expect(screen.getByRole("link", { name: "/llms.txt" })).toHaveAttribute("href", "/llms.txt");
    expect(screen.getByRole("link", { name: "/heartbeat" })).toHaveAttribute("href", "/heartbeat");
  });

  it("renders API operations table", () => {
    render(<Agents />);
    expect(screen.getByText("API Operations")).toBeInTheDocument();
    expect(screen.getByText("Start run")).toBeInTheDocument();
    expect(screen.getByText("Get run")).toBeInTheDocument();
    expect(screen.getByText("Retry run")).toBeInTheDocument();
    expect(screen.getByText("Pause workspace")).toBeInTheDocument();
    expect(screen.getByText("List specs")).toBeInTheDocument();
    expect(screen.getByText("Sync specs")).toBeInTheDocument();
  });

  it("renders HTTP methods", () => {
    render(<Agents />);
    const posts = screen.getAllByText("POST");
    const gets = screen.getAllByText("GET");
    expect(posts.length).toBeGreaterThanOrEqual(3);
    expect(gets.length).toBeGreaterThanOrEqual(2);
  });

  it("renders webhook example", () => {
    render(<Agents />);
    expect(screen.getByText("Webhook Callback Example")).toBeInTheDocument();
    expect(screen.getByText(/run\.completed/)).toBeInTheDocument();
  });

  it("renders safety limits cards", () => {
    render(<Agents />);
    expect(screen.getByText("Idempotency")).toBeInTheDocument();
    expect(screen.getByText("Audit Trail")).toBeInTheDocument();
    expect(screen.getByText("Secret Management")).toBeInTheDocument();
    expect(screen.getByText("Policy Enforcement")).toBeInTheDocument();
  });

  it("renders JSON-LD script", () => {
    const { container } = render(<Agents />);
    const script = container.querySelector('script[type="application/ld+json"]');
    expect(script).not.toBeNull();
    const data = JSON.parse(script!.textContent!);
    expect(data["@type"]).toBe("SoftwareApplication");
    expect(data.name).toBe("UseZombie");
  });

  it("uses agent-surface class for terminal aesthetic", () => {
    const { container } = render(<Agents />);
    expect(container.querySelector(".agent-surface")).not.toBeNull();
  });

  it("renders scanline overlay", () => {
    const { container } = render(<Agents />);
    const scanline = container.querySelector(".scanline");
    expect(scanline).not.toBeNull();
    expect(scanline).toHaveAttribute("aria-hidden", "true");
  });
});
