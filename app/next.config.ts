import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  experimental: {
    // React 19 concurrent features
    reactCompiler: false,
  },
};

export default nextConfig;
