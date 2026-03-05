export default function Footer() {
  return (
    <footer className="site-footer">
      <div className="footer-grid">
        <div className="footer-brand">
          <span className="brand">usezombie</span>
          <p>Agent delivery control plane. Specs in, validated PRs out.</p>
        </div>

        <div className="footer-col">
          <h4>Product</h4>
          <ul>
            <li><a href="/">Features</a></li>
            <li><a href="/pricing">Pricing</a></li>
            <li><a href="https://docs.usezombie.com">Docs</a></li>
            <li><a href="/agents">Agent Surface</a></li>
          </ul>
        </div>

        <div className="footer-col">
          <h4>Community</h4>
          <ul>
            <li><a href="https://github.com/usezombie" target="_blank" rel="noopener noreferrer">GitHub</a></li>
            <li><a href="https://discord.gg/usezombie" target="_blank" rel="noopener noreferrer">Discord</a></li>
          </ul>
        </div>

        <div className="footer-col">
          <h4>Legal</h4>
          <ul>
            <li><a href="/privacy">Privacy</a></li>
            <li><a href="/terms">Terms</a></li>
          </ul>
        </div>
      </div>

      <div className="footer-bottom">
        <span>&copy; {new Date().getFullYear()} UseZombie. All rights reserved.</span>
        <span>BYOK &middot; Compute billing &middot; CLI-first</span>
      </div>
    </footer>
  );
}
