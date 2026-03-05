const steps = [
  {
    title: "Queue a spec",
    description: "Push a PENDING_*.md file to your repo or call the API. UseZombie picks it up automatically.",
  },
  {
    title: "Agent pipeline runs",
    description: "Echo plans, Scout patches, Warden validates. Every transition is recorded with reason codes and artifacts.",
  },
  {
    title: "Validated PR opens",
    description: "A verified pull request lands in your repo with full audit trail, retry history, and artifact links.",
  },
];

export default function HowItWorks() {
  return (
    <div className="section-gap">
      <p className="eyebrow">How it works</p>
      <h2>Specs in. Validated PRs out.</h2>
      <div className="how-steps">
        {steps.map((step) => (
          <div key={step.title} className="how-step">
            <h3>{step.title}</h3>
            <p>{step.description}</p>
          </div>
        ))}
      </div>
    </div>
  );
}
