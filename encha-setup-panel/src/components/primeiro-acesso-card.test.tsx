// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { PrimeiroAcessoCard } from "./primeiro-acesso-card";
import { installWizardText } from "./wizard/install-wizard.i18n";

const LINK = "https://crm.exemplo.com/?setup=TOKEN-DE-TESTE-0123456789abcdef";

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

function respostaDaRota(corpo: unknown, ok = true) {
  const f = vi.fn(async () => new Response(JSON.stringify(corpo), { status: ok ? 200 : 502 }));
  vi.stubGlobal("fetch", f);
  return f;
}

describe("PrimeiroAcessoCard", () => {
  it("mostra o link, o botão de copiar copia exatamente o link e o de abrir aponta para ele", async () => {
    const f = respostaDaRota({ setupUrl: LINK });
    const user = userEvent.setup();
    render(<PrimeiroAcessoCard stackId="enchat" />);

    const campo = await screen.findByDisplayValue(LINK);
    expect(campo).toHaveAttribute("readonly");
    expect(f).toHaveBeenCalledWith("/api/stacks/enchat/primeiro-acesso", { cache: "no-store" });
    expect(screen.getByRole("link", { name: installWizardText.pt.abrirPrimeiroAcesso })).toHaveAttribute("href", LINK);

    const writeText = vi.spyOn(navigator.clipboard, "writeText").mockResolvedValue(undefined);
    await user.click(screen.getByRole("button", { name: installWizardText.pt.copiar }));
    expect(writeText).toHaveBeenCalledWith(LINK);
  });

  it.each([
    ["admin já criado", { jaCriado: true }, true],
    ["painel sem o material", { disponivel: false }, true],
    ["rota com erro", { error: "x" }, false],
  ])("%s: o card não aparece", async (_nome, corpo, ok) => {
    const f = respostaDaRota(corpo, ok);
    render(<PrimeiroAcessoCard stackId="enchat" />);

    await waitFor(() => expect(f).toHaveBeenCalled());
    await new Promise((r) => setTimeout(r, 50));
    expect(screen.queryByText(installWizardText.pt.linkPrimeiroAcesso)).not.toBeInTheDocument();
  });

  it("sem rede: o card não aparece e nada estoura", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("offline"); }));
    render(<PrimeiroAcessoCard stackId="enchat" />);
    await new Promise((r) => setTimeout(r, 50));
    expect(screen.queryByText(installWizardText.pt.linkPrimeiroAcesso)).not.toBeInTheDocument();
  });
});
