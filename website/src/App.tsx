import { useEffect, useState } from "react";
import { Link, NavLink, Route, Routes } from "react-router-dom";
import Home from "./pages/Home";
import Pricing from "./pages/Pricing";
import Agents from "./pages/Agents";

type Mode = "humans" | "agents";

const MODE_KEY = "usezombie_mode";

export default function App() {
  const [mode, setMode] = useState<Mode>(() => {
    const saved = localStorage.getItem(MODE_KEY);
    return saved === "agents" ? "agents" : "humans";
  });

  useEffect(() => {
    localStorage.setItem(MODE_KEY, mode);
  }, [mode]);

  return (
    <div className="site-shell">
      <header className="site-header">
        <div className="brand-wrap">
          <Link className="brand" to="/">
            usezombie
          </Link>
          <span className="badge">agent delivery control plane</span>
        </div>

        <div className="mode-switch" role="tablist" aria-label="Mode switch">
          <button
            type="button"
            className={mode === "humans" ? "mode-btn active" : "mode-btn"}
            onClick={() => setMode("humans")}
          >
            Humans
          </button>
          <button
            type="button"
            className={mode === "agents" ? "mode-btn active" : "mode-btn"}
            onClick={() => setMode("agents")}
          >
            Agents
          </button>
        </div>

        <nav className="site-nav" aria-label="Primary">
          <NavLink to="/">Home</NavLink>
          <NavLink to="/pricing">Pricing</NavLink>
          <NavLink to="/agents">Agents</NavLink>
        </nav>
      </header>

      <main className="site-main">
        <Routes>
          <Route path="/" element={<Home mode={mode} />} />
          <Route path="/pricing" element={<Pricing />} />
          <Route path="/agents" element={<Agents />} />
        </Routes>
      </main>
    </div>
  );
}
