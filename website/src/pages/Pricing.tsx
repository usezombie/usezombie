const tiers = [
  {
    name: "Free",
    price: "$0",
    points: ["1 workspace", "low concurrency", "community support"],
  },
  {
    name: "Pro",
    price: "$39/mo",
    points: ["5 workspaces", "priority queue", "advanced run replay"],
  },
  {
    name: "Team",
    price: "$199/mo",
    points: ["shared policies", "audit export", "team support"],
  },
  {
    name: "Enterprise",
    price: "Contact",
    points: ["dedicated isolation", "contract SLA", "deployment support"],
  },
];

export default function Pricing() {
  return (
    <section className="stack">
      <p className="eyebrow">pricing</p>
      <h1>BYOK + compute billing</h1>
      <p className="lead">
        UseZombie never resells model tokens. You bring provider keys, then pay for agent runtime and
        delivery reliability.
      </p>
      <div className="grid four">
        {tiers.map((tier) => (
          <article key={tier.name} className="card">
            <h2>{tier.name}</h2>
            <p className="price">{tier.price}</p>
            <ul>
              {tier.points.map((point) => (
                <li key={point}>{point}</li>
              ))}
            </ul>
          </article>
        ))}
      </div>
      <p className="fine">One-time workspace activation: $5.</p>
    </section>
  );
}
