import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { describe, it, expect, beforeEach } from "vitest";
import App from "./App";

const storage: Record<string, string> = {};
const mockLocalStorage = {
  getItem: (key: string) => storage[key] ?? null,
  setItem: (key: string, value: string) => { storage[key] = value; },
  removeItem: (key: string) => { delete storage[key]; },
  clear: () => { for (const k in storage) delete storage[k]; },
  get length() { return Object.keys(storage).length; },
  key: (i: number) => Object.keys(storage)[i] ?? null,
};

Object.defineProperty(globalThis, "localStorage", { value: mockLocalStorage, writable: true });

function renderApp(initialRoute = "/") {
  return render(
    <MemoryRouter initialEntries={[initialRoute]}>
      <App />
    </MemoryRouter>
  );
}

describe("App", () => {
  beforeEach(() => {
    mockLocalStorage.clear();
  });

  it("renders the brand name in header and footer", () => {
    renderApp();
    const brands = screen.getAllByText("usezombie");
    expect(brands.length).toBeGreaterThanOrEqual(2);
  });

  it("renders the badge", () => {
    renderApp();
    expect(screen.getByText("agent delivery control plane")).toBeInTheDocument();
  });

  it("renders the mode switch", () => {
    renderApp();
    expect(screen.getByRole("tablist", { name: /mode switch/i })).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: "Humans" })).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: "Agents" })).toBeInTheDocument();
  });

  it("defaults to humans mode", () => {
    renderApp();
    expect(screen.getByRole("tab", { name: "Humans" })).toHaveAttribute("aria-selected", "true");
    expect(screen.getByRole("tab", { name: "Agents" })).toHaveAttribute("aria-selected", "false");
  });

  it("switches to agents mode on click", async () => {
    const user = userEvent.setup();
    renderApp();

    await user.click(screen.getByRole("tab", { name: "Agents" }));
    expect(screen.getByRole("tab", { name: "Agents" })).toHaveAttribute("aria-selected", "true");
  });

  it("persists mode to localStorage", async () => {
    const user = userEvent.setup();
    renderApp();

    await user.click(screen.getByRole("tab", { name: "Agents" }));
    expect(mockLocalStorage.getItem("usezombie_mode")).toBe("agents");
  });

  it("reads saved mode from localStorage on mount", () => {
    mockLocalStorage.setItem("usezombie_mode", "agents");
    renderApp();
    // App reads localStorage in useState initializer, so it should pick up agents.
    // The mode-btn for Agents should have the active class.
    const agentsTab = screen.getByRole("tab", { name: "Agents" });
    expect(agentsTab).toHaveClass("active");
  });

  it("renders primary navigation in header", () => {
    renderApp();
    const nav = screen.getByRole("navigation", { name: /primary/i });
    expect(within(nav).getByRole("link", { name: "Home" })).toBeInTheDocument();
    expect(within(nav).getByRole("link", { name: "Pricing" })).toBeInTheDocument();
    expect(within(nav).getByRole("link", { name: "Agents" })).toBeInTheDocument();
    expect(within(nav).getByRole("link", { name: "Docs" })).toHaveAttribute(
      "href",
      "https://docs.usezombie.com"
    );
  });

  it("renders home page by default", () => {
    renderApp("/");
    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent(/ship ai/i);
  });

  it("renders pricing page at /pricing", () => {
    renderApp("/pricing");
    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent(/byok/i);
  });

  it("renders agents page at /agents", () => {
    renderApp("/agents");
    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent(/autonomous agents/i);
  });

  it("renders footer on all routes", () => {
    renderApp("/");
    expect(screen.getByRole("contentinfo")).toBeInTheDocument();
  });
});
