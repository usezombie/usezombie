import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import ProviderStrip from "./ProviderStrip";

describe("ProviderStrip", () => {
  it("renders the BYOK label", () => {
    render(<ProviderStrip />);
    expect(screen.getByText("Bring your own LLM keys")).toBeInTheDocument();
  });

  it("renders all provider names", () => {
    render(<ProviderStrip />);
    expect(screen.getByText("Anthropic")).toBeInTheDocument();
    expect(screen.getByText("OpenAI")).toBeInTheDocument();
    expect(screen.getByText("Google")).toBeInTheDocument();
    expect(screen.getByText("Mistral")).toBeInTheDocument();
    expect(screen.getByText("Groq")).toBeInTheDocument();
  });
});
