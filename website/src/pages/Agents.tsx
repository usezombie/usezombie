const jsonLd = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: "UseZombie",
  applicationCategory: "DeveloperApplication",
  url: "https://usezombie.sh/agents",
  sameAs: [
    "https://usezombie.sh/openapi.json",
    "https://usezombie.sh/agent-manifest.json",
    "https://usezombie.sh/skill.md"
  ]
};

export default function Agents() {
  return (
    <section className="stack">
      <p className="eyebrow">agent surface</p>
      <h1>This page is for autonomous agents.</h1>
      <p className="lead">
        Use <code>/openapi.json</code> as canonical contract. Docs are secondary.
      </p>

      <pre className="terminal" aria-label="Bootstrap command">
        <code>npx zombiectl login && npx zombiectl workspace add https://github.com/indykish/terraform-provider-e2e</code>
      </pre>

      <div className="grid two">
        <article className="card">
          <h2>Machine contracts</h2>
          <ul>
            <li><a href="/skill.md">/skill.md</a></li>
            <li><a href="/openapi.json">/openapi.json</a></li>
            <li><a href="/agent-manifest.json">/agent-manifest.json</a></li>
            <li><a href="/llms.txt">/llms.txt</a></li>
            <li><a href="/heartbeat">/heartbeat</a></li>
          </ul>
        </article>
        <article className="card">
          <h2>Safety limits</h2>
          <ul>
            <li>Workspace-scoped idempotency.</li>
            <li>CAS transitions with audit trail.</li>
            <li>Encrypted vault secrets via BYTEA columns.</li>
            <li>Git hook disable + subprocess timeouts.</li>
          </ul>
        </article>
      </div>

      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }} />
    </section>
  );
}
