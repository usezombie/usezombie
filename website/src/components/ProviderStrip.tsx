const providers = [
  "Anthropic",
  "OpenAI",
  "Google",
  "Mistral",
  "Groq",
];

export default function ProviderStrip() {
  return (
    <div className="provider-strip">
      <span className="label">Bring your own LLM keys</span>
      <div className="providers">
        {providers.map((name) => (
          <span key={name} className="provider">{name}</span>
        ))}
      </div>
    </div>
  );
}
