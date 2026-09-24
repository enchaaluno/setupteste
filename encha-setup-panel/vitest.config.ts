import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import path from "node:path";

// Ciclo 20: primeiro test runner deste repositório — antes só havia `tsc
// --noEmit`. Ambiente padrão "node": todos os testes são lógica de
// servidor (fingerprint, geração de YAML, validação de diretórios,
// orquestração de installStack), sem DOM. Teste de componente declara
// `// @vitest-environment jsdom` no topo do próprio arquivo (hoje só
// install-wizard.test.tsx, do link de primeiro acesso do EnchaT).
export default defineConfig({
  plugins: [react()],
  resolve: {
    // Mesmo mapeamento de tsconfig.json (paths."@/*") — o Next.js resolve
    // isso sozinho no build real, mas o Vite (por baixo do vitest) precisa
    // do alias explícito.
    alias: { "@": path.resolve(__dirname, "./src") },
  },
  test: {
    environment: "node",
    include: ["src/**/*.test.{ts,tsx}"],
    setupFiles: ["./src/testes-setup.ts"],
  },
});
