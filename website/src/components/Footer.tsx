import { Link } from "react-router-dom";

const DISCORD_URL = "https://discord.gg/H9hH2nqQjh";

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
            <li><Link to="/">Features</Link></li>
            <li><Link to="/pricing">Pricing</Link></li>
            <li><a href="https://docs.usezombie.com" target="_blank" rel="noopener noreferrer">Docs</a></li>
            <li><Link to="/agents">Agents</Link></li>
          </ul>
        </div>

        <div className="footer-col">
          <h4>Community</h4>
          <ul>
            <li><a href="https://github.com/usezombie" target="_blank" rel="noopener noreferrer">GitHub</a></li>
            <li><a href={DISCORD_URL} target="_blank" rel="noopener noreferrer">Discord</a></li>
          </ul>
        </div>

        <div className="footer-col">
          <h4>Legal</h4>
          <ul>
            <li><Link to="/privacy">Privacy</Link></li>
            <li><Link to="/terms">Terms</Link></li>
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
