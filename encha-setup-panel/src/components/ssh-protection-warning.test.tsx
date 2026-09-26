// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import {
  COMANDO_PROTEGER_SSH,
  SshProtectionWarning,
  deveExibirAvisoProtecaoSsh,
} from "./ssh-protection-warning";
import { sshProtectionWarningText } from "./ssh-protection-warning.i18n";

// C8 (plano de segurança, achado A2) — aviso de fail2ban ausente. Mutação
// do auditor a matar: inverter deveExibirAvisoProtecaoSsh (mostrar quando
// protegido, escondido quando não).

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe("deveExibirAvisoProtecaoSsh", () => {
  it("false (marcador ausente) -> mostra", () => {
    expect(deveExibirAvisoProtecaoSsh(false)).toBe(true);
  });

  it("true (marcador presente) -> não mostra", () => {
    expect(deveExibirAvisoProtecaoSsh(true)).toBe(false);
  });

  it("null (ainda carregando /api/vps-context) -> não mostra", () => {
    expect(deveExibirAvisoProtecaoSsh(null)).toBe(false);
  });
});

describe("<SshProtectionWarning>", () => {
  it("protecaoInstalada=false: mostra a mensagem e o comando", () => {
    render(<SshProtectionWarning protecaoInstalada={false} />);
    expect(screen.getByText(sshProtectionWarningText.pt.message)).toBeInTheDocument();
    expect(screen.getByText(COMANDO_PROTEGER_SSH)).toBeInTheDocument();
  });

  it("protecaoInstalada=true: não renderiza nada", () => {
    const { container } = render(<SshProtectionWarning protecaoInstalada={true} />);
    expect(container).toBeEmptyDOMElement();
  });

  it("protecaoInstalada=null (ainda carregando): não renderiza nada", () => {
    const { container } = render(<SshProtectionWarning protecaoInstalada={null} />);
    expect(container).toBeEmptyDOMElement();
  });

  it("botão de copiar copia exatamente o comando", async () => {
    const user = userEvent.setup();
    render(<SshProtectionWarning protecaoInstalada={false} />);
    const writeText = vi.spyOn(navigator.clipboard, "writeText").mockResolvedValue(undefined);
    await user.click(screen.getByRole("button", { name: new RegExp(sshProtectionWarningText.pt.copy) }));
    expect(writeText).toHaveBeenCalledWith(COMANDO_PROTEGER_SSH);
    expect(await screen.findByText(sshProtectionWarningText.pt.copied)).toBeInTheDocument();
  });

  // Auditoria C8: o botão não pode dizer "Copiado!" quando a cópia falhou
  // (permissão negada) nem estourar quando navigator.clipboard não existe
  // (painel por http://IP, fora de contexto seguro).
  it("writeText rejeitado: não mostra 'Copiado!'", async () => {
    const user = userEvent.setup();
    render(<SshProtectionWarning protecaoInstalada={false} />);
    vi.spyOn(navigator.clipboard, "writeText").mockRejectedValue(new Error("NotAllowedError"));
    await user.click(screen.getByRole("button", { name: new RegExp(sshProtectionWarningText.pt.copy) }));
    await new Promise((r) => setTimeout(r, 0));
    expect(screen.queryByText(sshProtectionWarningText.pt.copied)).not.toBeInTheDocument();
    expect(screen.getByText(COMANDO_PROTEGER_SSH)).toBeInTheDocument();
  });

  it("sem navigator.clipboard (contexto inseguro): clicar não quebra nem mostra 'Copiado!'", async () => {
    const user = userEvent.setup();
    render(<SshProtectionWarning protecaoInstalada={false} />);
    vi.stubGlobal("navigator", { ...navigator, clipboard: undefined });
    await user.click(screen.getByRole("button", { name: new RegExp(sshProtectionWarningText.pt.copy) }));
    expect(screen.queryByText(sshProtectionWarningText.pt.copied)).not.toBeInTheDocument();
    expect(screen.getByText(COMANDO_PROTEGER_SSH)).toBeInTheDocument();
  });
});
