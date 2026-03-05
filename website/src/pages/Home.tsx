type Props = {
  mode: "humans" | "agents";
};

export default function Home({ mode }: Props) {
  return (
    <section className="stack">
      <p className="eyebrow">{mode === "humans" ? "human-operator mode" : "agent-first mode"}</p>
      <h1>Ship AI-generated PRs with deterministic policy and replay.</h1>
      <p className="lead">
        UseZombie turns specs into validated pull requests with transition audits, artifact trails, and
        retry-safe delivery.
      </p>
      <div className="cta-row">
        <a className="cta" href="https://docs.usezombie.com">
          View docs
        </a>
        <a className="cta ghost" href="/agents">
          Agent bootstrap
        </a>
      </div>

      <div className="grid two">
        <article className="card">
          <h2>Deterministic lifecycle</h2>
          <p>spec → plan → patch → verify → PR → notify</p>
        </article>
        <article className="card">
          <h2>BYOK trust model</h2>
          <p>Customers bring model keys. UseZombie bills compute time, not token markup.</p>
        </article>
        <article className="card">
          <h2>Operational controls</h2>
          <p>Pause workspaces, inspect transitions, and replay failed attempts with full auditability.</p>
        </article>
        <article className="card">
          <h2>Launch surface</h2>
          <p>CLI-first on v1 with machine-readable onboarding at usezombie.sh.</p>
        </article>
      </div>
    </section>
  );
}
