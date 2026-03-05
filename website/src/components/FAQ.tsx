import { useState } from "react";

const items = [
  {
    q: "What does BYOK mean?",
    a: "Bring Your Own Keys. You provide your own LLM API keys (Anthropic, OpenAI, Google, etc.). UseZombie never resells model tokens or marks them up. You pay your provider directly for token usage.",
  },
  {
    q: "What am I actually paying for?",
    a: "Compute billing: per agent-second of wall-clock time that workers (Echo, Scout, Warden) run. Plus a one-time $5 workspace activation fee. That's it.",
  },
  {
    q: "Can I try it before committing?",
    a: "Yes. The Free tier gives you 1 workspace with low concurrency. No credit card required. Upgrade when you need more workspaces or priority queue access.",
  },
  {
    q: "What happens to my code?",
    a: "UseZombie operates on your Git repos via branch-based state. Code stays in your repositories. Artifacts and run transitions are stored with full audit trails you can export.",
  },
  {
    q: "Which Git providers are supported?",
    a: "GitHub is fully supported in v1. GitLab and Bitbucket support are on the roadmap.",
  },
  {
    q: "Is there an SLA?",
    a: "Enterprise tier includes contractual SLAs with dedicated isolation. Free, Pro, and Team tiers operate on best-effort with high availability targets.",
  },
];

export default function FAQ() {
  const [openIndex, setOpenIndex] = useState<number | null>(null);

  return (
    <div className="section-gap">
      <p className="eyebrow">FAQ</p>
      <h2>Common questions</h2>
      <div style={{ maxWidth: "640px" }}>
        {items.map((item, i) => (
          <div key={i} className={`faq-item${openIndex === i ? " open" : ""}`} data-testid={`faq-item-${i}`}>
            <button
              type="button"
              className="faq-trigger"
              onClick={() => setOpenIndex(openIndex === i ? null : i)}
              aria-expanded={openIndex === i}
              data-testid={`faq-trigger-${i}`}
            >
              {item.q}
              <span className="chevron" aria-hidden="true">&#9662;</span>
            </button>
            {openIndex === i && (
              <div className="faq-answer" data-testid={`faq-answer-${i}`}>{item.a}</div>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}
