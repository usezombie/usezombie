import FAQ from "../components/FAQ";
import { Button } from "../design-system";

const tiers = [
  {
    name: "Open Source",
    price: "Free",
    featured: false,
    points: [
      "Self-host on your infra",
      "Unlimited workspaces",
      "Full pipeline access",
      "Community support",
      "BYOK — bring your own keys",
    ],
  },
  {
    name: "Hobby",
    price: "$0",
    featured: false,
    points: [
      "1 workspace",
      "3 default agents (Scout, Echo, Warden)",
      "Low concurrency",
      "Basic run replay",
      "Community support",
      "BYOK — bring your own keys",
    ],
  },
  {
    name: "Pro",
    price: "$39/mo",
    featured: true,
    points: [
      "5 workspaces",
      "Unlimited agents + harness",
      "Priority queue",
      "Advanced run replay",
      "Artifact export",
      "Email support",
      "BYOK — bring your own keys",
    ],
  },
  {
    name: "Enterprise",
    price: "Contact",
    featured: false,
    points: [
      "Dedicated isolation",
      "Contractual SLA",
      "Deployment support",
      "Compliance features",
      "Custom integrations",
      "BYOK — bring your own keys",
    ],
  },
];

export default function Pricing() {
  return (
    <section className="stack">
      <p className="eyebrow">pricing</p>
      <h1>BYOK + compute billing</h1>
      <p className="lead">
        UseZombie never resells model tokens. You bring your own LLM API keys from any provider and
        pay them directly. We charge only for agent compute time — per second of wall-clock time that
        workers (Echo, Scout, Warden) run your pipeline.
      </p>

      <div className="grid four">
        {tiers.map((tier) => (
          <article key={tier.name} className={`card${tier.featured ? " featured" : ""}`}>
            <h2>{tier.name}</h2>
            <p className="price">{tier.price}</p>
            <ul>
              {tier.points.map((point) => (
                <li key={point}>{point}</li>
              ))}
            </ul>
            {tier.name === "Enterprise" ? (
              <Button variant="ghost" to="mailto:team@usezombie.com?subject=Enterprise" style={{ marginTop: "0.75rem" }}>
                Contact sales
              </Button>
            ) : tier.name === "Open Source" ? (
              <Button variant="ghost" to="https://github.com/usezombie" external style={{ marginTop: "0.75rem" }}>
                View on GitHub
              </Button>
            ) : (
              <Button to="https://docs.usezombie.com/quickstart" style={{ marginTop: "0.75rem" }}>
                {tier.name === "Hobby" ? "Start free" : "Start trial"}
              </Button>
            )}
          </article>
        ))}
      </div>

      <p className="fine">One-time workspace activation: $5. All plans include BYOK — you pay your LLM provider directly for tokens.</p>

      <FAQ />

      <div className="cta-block">
        <h2>Not sure which plan?</h2>
        <p>Start free with a single workspace. Upgrade when you need more capacity or team features.</p>
        <div className="cta-row">
          <a className="cta" href="https://docs.usezombie.com/quickstart">
            Start free
          </a>
          <a className="cta ghost" href="mailto:team@usezombie.com?subject=Team%20Pilot">
            Book team pilot
          </a>
        </div>
      </div>
    </section>
  );
}
