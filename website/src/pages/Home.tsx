import FeatureSection from "../components/FeatureSection";
import ProviderStrip from "../components/ProviderStrip";
import HowItWorks from "../components/HowItWorks";
import CTABlock from "../components/CTABlock";

const features = [
  {
    number: "01",
    title: "Deterministic Lifecycle",
    description:
      "Every spec follows a strict state machine: SPEC_QUEUED, RUN_PLANNED, PATCH_IN_PROGRESS, VERIFICATION_IN_PROGRESS, PR_PREPARED, PR_OPENED, NOTIFIED, DONE. No ambiguity, no silent failures. Each transition is recorded with reason codes and timestamps.",
  },
  {
    number: "02",
    title: "BYOK Trust Model",
    description:
      "You bring your own LLM API keys from Anthropic, OpenAI, Google, or any provider. UseZombie never touches your tokens and never marks them up. You pay your provider directly. We bill only for agent compute time.",
  },
  {
    number: "03",
    title: "Run Replay and Audit Trail",
    description:
      "Every run produces artifacts: plan.json, implementation.md, validation.md, defect reports, and a run summary. Inspect any transition, see why a patch was retried, and replay failed attempts with full context.",
  },
  {
    number: "04",
    title: "Operational Controls",
    description:
      "Pause workspaces, enforce policies by command class (safe, sensitive, critical), and lock down destructive operations. Encrypted vault secrets, subprocess timeouts, and Git hook disabling keep your repos safe.",
  },
  {
    number: "05",
    title: "CLI-First, Agent-Ready",
    description:
      "Launch with npx zombiectl. Machine-readable onboarding at usezombie.sh with OpenAPI spec, agent manifests, and skill.md. Built for both human operators and autonomous agents from day one.",
  },
];

const pricingPreview = [
  { name: "Free", price: "$0", point: "1 workspace, low concurrency" },
  { name: "Pro", price: "$39/mo", point: "5 workspaces, priority queue" },
  { name: "Team", price: "$199/mo", point: "Shared policies, audit export" },
  { name: "Enterprise", price: "Contact", point: "Dedicated isolation, SLA" },
];

type Props = {
  mode: "humans" | "agents";
};

export default function Home({ mode }: Props) {
  return (
    <section className="stack">
      {/* Hero */}
      <p className="eyebrow">
        {mode === "humans" ? "for engineering teams" : "agent delivery control plane"}
      </p>
      <h1>Ship AI&#8209;generated PRs with policy, replay, and reliability.</h1>
      <p className="lead">
        UseZombie turns spec queues into validated pull requests. Deterministic lifecycle, transition
        audits, artifact trails, and retry-safe delivery — for teams that need their agent output to
        actually ship.
      </p>
      <div className="cta-row">
        <a className="cta" href="https://docs.usezombie.com/quickstart">
          Start free
        </a>
        <a className="cta ghost" href="mailto:team@usezombie.com?subject=Team%20Pilot">
          Book team pilot
        </a>
      </div>

      <pre className="terminal" aria-label="Quick start command">
        <code>npx zombiectl login &amp;&amp; zombiectl workspace add https://github.com/your-org/your-repo</code>
      </pre>

      {/* BYOK Provider strip */}
      <ProviderStrip />

      {/* Features */}
      <div className="section-gap">
        <p className="eyebrow">Features</p>
        <h2>What UseZombie handles for you</h2>
      </div>
      {features.map((f) => (
        <FeatureSection key={f.number} number={f.number} title={f.title} description={f.description} />
      ))}

      {/* How it works */}
      <HowItWorks />

      {/* Pricing preview */}
      <div className="section-gap">
        <p className="eyebrow">Pricing</p>
        <h2>BYOK + compute billing</h2>
        <p className="lead">No token markup. Pay for agent runtime only.</p>
        <div className="grid four">
          {pricingPreview.map((tier) => (
            <article key={tier.name} className="card">
              <h3>{tier.name}</h3>
              <p className="price">{tier.price}</p>
              <p>{tier.point}</p>
            </article>
          ))}
        </div>
        <div className="cta-row" style={{ marginTop: "1rem" }}>
          <a className="cta ghost" href="/pricing">
            View full pricing
          </a>
        </div>
      </div>

      {/* CTA block */}
      <CTABlock />
    </section>
  );
}
