import { render, screen } from "@testing-library/react";
import { BrowserRouter } from "react-router-dom";
import { describe, it, expect } from "vitest";
import Footer from "./Footer";

function renderFooter() {
  return render(
    <BrowserRouter>
      <Footer />
    </BrowserRouter>
  );
}

describe("Footer", () => {
  it("renders the brand name", () => {
    renderFooter();
    expect(screen.getByText("usezombie")).toBeInTheDocument();
  });

  it("renders the tagline", () => {
    renderFooter();
    expect(screen.getByText(/agent delivery control plane/i)).toBeInTheDocument();
  });

  it("renders Product column with links", () => {
    renderFooter();
    expect(screen.getByText("Product")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Features" })).toHaveAttribute("href", "/");
    expect(screen.getByRole("link", { name: "Pricing" })).toHaveAttribute("href", "/pricing");
    expect(screen.getByRole("link", { name: "Docs" })).toHaveAttribute("href", "https://docs.usezombie.com");
    expect(screen.getByRole("link", { name: "Agent Surface" })).toHaveAttribute("href", "/agents");
  });

  it("renders Community column with external links", () => {
    renderFooter();
    expect(screen.getByText("Community")).toBeInTheDocument();
    const github = screen.getByRole("link", { name: "GitHub" });
    expect(github).toHaveAttribute("href", "https://github.com/usezombie");
    expect(github).toHaveAttribute("target", "_blank");
    expect(github).toHaveAttribute("rel", "noopener noreferrer");

    const discord = screen.getByRole("link", { name: "Discord" });
    expect(discord).toHaveAttribute("target", "_blank");
  });

  it("renders Legal column", () => {
    renderFooter();
    expect(screen.getByText("Legal")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Privacy" })).toHaveAttribute("href", "/privacy");
    expect(screen.getByRole("link", { name: "Terms" })).toHaveAttribute("href", "/terms");
  });

  it("renders copyright with current year", () => {
    renderFooter();
    const year = new Date().getFullYear().toString();
    expect(screen.getByText(new RegExp(year))).toBeInTheDocument();
  });

  it("renders the BYOK tagline in footer bottom", () => {
    renderFooter();
    expect(screen.getByText(/BYOK/)).toBeInTheDocument();
  });
});
