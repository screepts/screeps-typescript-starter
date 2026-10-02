import { defineConfig } from "vitest/config"

export default defineConfig({
  resolve: {
    tsconfigPaths: true,
  },
  test: {
    // using node -test for integration tests as xxscreeps is loader conflicts with Vitest
    exclude: ['**/node_modules/**', '**/.git/**', "test/integration/**/"],
  },
})
