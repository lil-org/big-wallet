import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// Force an invalid test-only secret so an inherited production value is never
// imported into the test runtime. Handler tests inject their own key material.
process.env.ALCHEMY_JWT_PRIVATE_KEY = "test-only-unused";
process.env.ALCHEMY_JWT_REQUEST_PROOF_KEY =
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: {
        configPath: "./wrangler.jsonc",
      },
    }),
  ],
});
