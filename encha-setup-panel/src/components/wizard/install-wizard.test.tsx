// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { InstallWizard } from "./install-wizard";
import { installWizardText } from "./install-wizard.i18n";

// C7 (S10 do plano de segurança do EnchaT) — o card de sucesso mostra o
// link de primeiro acesso (setupUrl) com botão de copiar e a nota de uso
// único. Componente real, fetch falso devolvendo o mesmo shape de
// POST /api/stacks.

vi.mock("next/navigation", () => ({ useRouter: () => ({ refresh: () => {} }) }));

const SETUP_URL = "https://crm.exemplo.com/?setup=TOKEN-DE-TESTE-0123456789abcdef";

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

async function instalarAteSucesso(resposta: Record<string, unknown>) {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => new Response(JSON.stringify(resposta), { status: 200, headers: { "content-type": "application/json" } }))
  );
  const user = userEvent.setup();
  render(
    <InstallWizard
      stack={{ id: "enchat", name: "EnchaT Grátis", description: "teste", fields: [] }}
      open
      onClose={() => {}}
      csrfToken="csrf"
      swarmCtx={{ networkName: "rede", serverName: "vps", email: "" }}
    />
  );
  await user.click(screen.getByRole("button", { name: installWizardText.pt.instalar }));
  await screen.findByText(installWizardText.pt.stackImplantada);
  return user;
}

describe("InstallWizard — link de primeiro acesso", () => {
  it("mostra o setupUrl, a nota de uso único, e o botão copia exatamente o link", async () => {
    const user = await instalarAteSucesso({
      ok: true,
      accessUrl: "https://crm.exemplo.com",
      setupUrl: SETUP_URL,
      notes: [],
      revealSecrets: [],
    });
    const writeText = vi.spyOn(navigator.clipboard, "writeText").mockResolvedValue(undefined);

    expect(screen.getByText(installWizardText.pt.linkPrimeiroAcesso)).toBeInTheDocument();
    expect(screen.getByText(installWizardText.pt.linkPrimeiroAcessoNota)).toBeInTheDocument();
    const campo = screen.getByDisplayValue(SETUP_URL);
    expect(campo).toHaveAttribute("readonly");

    const bloco = campo.closest("div")!.parentElement!;
    await user.click(bloco.querySelector("button")!);
    await waitFor(() => expect(writeText).toHaveBeenCalledWith(SETUP_URL));
  });

  it("sem setupUrl (stack que não tem link de setup) o bloco não aparece", async () => {
    await instalarAteSucesso({ ok: true, accessUrl: "https://x.exemplo.com", notes: [], revealSecrets: [] });
    expect(screen.queryByText(installWizardText.pt.linkPrimeiroAcesso)).not.toBeInTheDocument();
  });

  it("os três idiomas têm o rótulo e a nota preenchidos (e diferentes entre si)", () => {
    const rotulos = (["pt", "en", "es"] as const).map((l) => installWizardText[l].linkPrimeiroAcesso);
    const notas = (["pt", "en", "es"] as const).map((l) => installWizardText[l].linkPrimeiroAcessoNota);
    expect(new Set(rotulos).size).toBe(3);
    expect(new Set(notas).size).toBe(3);
  });
});
