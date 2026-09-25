// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { InstallWizard } from "./install-wizard";
import { installWizardText } from "./install-wizard.i18n";
import { licensePairingText } from "./license-pairing.i18n";
import { LocaleProvider } from "@/components/locale-provider";
import type { Locale } from "@/lib/locale-shared";

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

// Pareamento de licença: sessão morta não pode prender o usuário, e "Instalar"
// sem licença não pode chegar a virar um "Falha na instalação" genérico.
// Componente real (InstallWizard + LicensePairing), fetch falso por rota.

const PAIRING_ID = "a".repeat(32);
const CAMPOS_ENCHAT = [{ name: "chave_licenca", label: "Chave", kind: "text", optional: true }];
const STACK_COM_PAREAMENTO = {
  id: "enchat",
  name: "EnchaT Grátis",
  description: "teste",
  fields: CAMPOS_ENCHAT,
  pairing: { targetField: "chave_licenca", sessionField: "licenca_pareamento_id" },
};

type Chamada = { path: string; body: Record<string, unknown> };

function stubPareamento(respostas: Record<string, () => Record<string, unknown>>): Chamada[] {
  const chamadas: Chamada[] = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (url: string, init?: RequestInit) => {
      const path = String(url).replace("/api/license/", "");
      chamadas.push({ path, body: JSON.parse(String(init?.body ?? "{}")) });
      const fabrica = respostas[path];
      const corpo = fabrica ? fabrica() : {};
      return new Response(JSON.stringify(corpo), { status: 200, headers: { "content-type": "application/json" } });
    })
  );
  return chamadas;
}

function renderComPareamento() {
  return render(
    <InstallWizard
      stack={STACK_COM_PAREAMENTO}
      open
      onClose={() => {}}
      csrfToken="csrf"
      swarmCtx={{ networkName: "rede", serverName: "vps", email: "" }}
    />
  );
}

const sessaoAberta = (codigo: string) => () => ({
  status: "aberto",
  pairingId: PAIRING_ID,
  codigo,
  codigoExibicao: codigo,
  numeroExibicao: "(61) 90000-0000",
  expiraEm: Math.floor(Date.now() / 1000) + 900,
});

describe("InstallWizard — Instalar só com licença", () => {
  it("com o pareamento pendente e sem chave, o botão fica desabilitado e explica por quê", async () => {
    stubPareamento({ "pair/start": sessaoAberta("ENCHAT-AAAAAA"), "pair/poll": () => ({ status: "aguardando" }) });
    renderComPareamento();

    await screen.findByText("ENCHAT-AAAAAA");
    expect(screen.getByRole("button", { name: installWizardText.pt.instalar })).toBeDisabled();
    expect(screen.getByText(installWizardText.pt.concluaLicencaParaInstalar)).toBeInTheDocument();
  });

  it("habilita quando o usuário cola uma chave à mão", async () => {
    stubPareamento({ "pair/start": sessaoAberta("ENCHAT-AAAAAA"), "pair/poll": () => ({ status: "aguardando" }) });
    const user = userEvent.setup();
    renderComPareamento();
    await screen.findByText("ENCHAT-AAAAAA");

    await user.type(screen.getByRole("textbox"), "CHAVE-EXISTENTE-123");

    expect(screen.getByRole("button", { name: installWizardText.pt.instalar })).toBeEnabled();
    expect(screen.queryByText(installWizardText.pt.concluaLicencaParaInstalar)).not.toBeInTheDocument();
  });

  it("habilita quando o pareamento já está confirmado (retomada)", async () => {
    stubPareamento({
      "pair/start": () => ({ status: "confirmado", pairingId: PAIRING_ID }),
      "pair/poll": () => ({ status: "confirmado" }),
    });
    renderComPareamento();

    await waitFor(() => expect(screen.getByRole("button", { name: installWizardText.pt.instalar })).toBeEnabled());
  });

  it("stack SEM pareamento não é afetada (botão sempre habilitado)", () => {
    vi.stubGlobal("fetch", vi.fn());
    render(
      <InstallWizard
        stack={{ id: "x", name: "X", description: "t", fields: [] }}
        open
        onClose={() => {}}
        csrfToken="csrf"
        swarmCtx={{ networkName: "rede", serverName: "vps", email: "" }}
      />
    );
    expect(screen.getByRole("button", { name: installWizardText.pt.instalar })).toBeEnabled();
  });
});

describe("LicensePairing — sessão morta e 'Gerar outro código'", () => {
  it("'Gerar outro código' pede sessão NOVA (novo:true) e mostra o código novo; a abertura inicial não pede", async () => {
    let n = 0;
    const chamadas = stubPareamento({
      "pair/start": () => sessaoAberta(n++ === 0 ? "ENCHAT-VELHO1" : "ENCHAT-NOVO22")(),
      "pair/poll": () => ({ status: "aguardando" }),
    });
    const user = userEvent.setup();
    renderComPareamento();
    await screen.findByText("ENCHAT-VELHO1");

    await user.click(screen.getByRole("button", { name: licensePairingText.pt.gerarOutroCodigo }));

    await screen.findByText("ENCHAT-NOVO22");
    const starts = chamadas.filter((c) => c.path === "pair/start");
    expect(starts).toHaveLength(2);
    expect(starts[0].body.novo).toBeUndefined();
    expect(starts[1].body.novo).toBe(true);
  });

  it("poll 'expirado' troca o QR morto pela mensagem de expirado, com botão de novo código", async () => {
    stubPareamento({ "pair/start": sessaoAberta("ENCHAT-MORTO1"), "pair/poll": () => ({ status: "expirado" }) });
    renderComPareamento();

    await screen.findByText(licensePairingText.pt.expiradoMensagem, undefined, { timeout: 5000 });
    expect(screen.queryByText("ENCHAT-MORTO1")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: licensePairingText.pt.gerarOutroCodigo })).toBeInTheDocument();
  }, 10000);
});

// O servidor traduz o `group` dos campos por idioma ("Licença" -> "License" /
// "Licencia"), mas o pareamento sempre saiu com o grupo em pt. O wizard
// comparava os dois nomes, então em EN/ES o card de pareamento nunca aparecia
// (e "Instalar" ficava bloqueado esperando um pareamento invisível).

const GRUPOS_POR_IDIOMA: Record<Locale, { dominios: string; licenca: string }> = {
  pt: { dominios: "Domínios", licenca: "Licença" },
  en: { dominios: "Domains", licenca: "License" },
  es: { dominios: "Dominios", licenca: "Licencia" },
};

function stackTraduzida(locale: Locale, alvoPareamento = "chave_licenca") {
  const g = GRUPOS_POR_IDIOMA[locale];
  return {
    id: "enchat",
    name: "EnchaT Grátis",
    description: "teste",
    fields: [
      { name: "url_enchat", label: "Domínio", kind: "text", group: g.dominios },
      { name: "chave_licenca", label: "Chave", kind: "text", optional: true, group: g.licenca },
    ],
    // Payload como o servidor antigo mandava: pairing.group SEMPRE em pt.
    pairing: { targetField: alvoPareamento, sessionField: "licenca_pareamento_id", group: "Licença" },
  };
}

function renderNoIdioma(locale: Locale, stack: ReturnType<typeof stackTraduzida>) {
  return render(
    <LocaleProvider initialLocale={locale}>
      <InstallWizard
        stack={stack}
        open
        onClose={() => {}}
        csrfToken="csrf"
        swarmCtx={{ networkName: "rede", serverName: "vps", email: "" }}
      />
    </LocaleProvider>
  );
}

describe("InstallWizard — card de pareamento em qualquer idioma", () => {
  it.each(["pt", "en", "es"] as const)("%s: o card aparece e o pair/start é chamado", async (locale) => {
    const chamadas = stubPareamento({
      "pair/start": sessaoAberta("ENCHAT-IDIOMA1"),
      "pair/poll": () => ({ status: "aguardando" }),
    });
    renderNoIdioma(locale, stackTraduzida(locale));

    await screen.findByText("ENCHAT-IDIOMA1");
    expect(chamadas.some((c) => c.path === "pair/start")).toBe(true);
  });

  it.each(["en", "es"] as const)("%s: o card fica no grupo da licença, não no dos domínios", async (locale) => {
    stubPareamento({ "pair/start": sessaoAberta("ENCHAT-IDIOMA2"), "pair/poll": () => ({ status: "aguardando" }) });
    renderNoIdioma(locale, stackTraduzida(locale));

    const codigo = await screen.findByText("ENCHAT-IDIOMA2");
    const tituloLicenca = screen.getByText(GRUPOS_POR_IDIOMA[locale].licenca);
    const tituloDominios = screen.getByText(GRUPOS_POR_IDIOMA[locale].dominios);
    // O card vem DEPOIS do título do grupo da licença e ANTES do grupo seguinte/campos dele.
    expect(tituloLicenca.compareDocumentPosition(codigo) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(tituloDominios.compareDocumentPosition(codigo) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(tituloLicenca.parentElement!.contains(codigo)).toBe(true);
    expect(tituloDominios.parentElement!.contains(codigo)).toBe(false);
  });

  it("targetField que não existe nos campos: o card não some (cai no primeiro grupo)", async () => {
    stubPareamento({ "pair/start": sessaoAberta("ENCHAT-FALLBK"), "pair/poll": () => ({ status: "aguardando" }) });
    renderNoIdioma("en", stackTraduzida("en", "campo_inexistente"));

    const codigo = await screen.findByText("ENCHAT-FALLBK");
    expect(screen.getByText(GRUPOS_POR_IDIOMA.en.dominios).parentElement!.contains(codigo)).toBe(true);
  });
});
