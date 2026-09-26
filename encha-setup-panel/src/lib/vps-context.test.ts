import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseDadosVps } from "./vps-context";

// Cobre a migração das chaves de dados_vps para inglês (Fase 0 de i18n —
// i18n/GLOSSARY.md). O parser precisa aceitar a chave nova E a antiga em
// português para sempre: dados_vps só é regravado numa instalação completa
// nova, então a frota já instalada mantém a chave em português
// indefinidamente (ver runOneShotJob/updater.ts — "Atualizar" nunca reescreve
// esse arquivo).

const NOVO = `[DADOS DA VPS]
Server Name: srv-novo
Internal Network: net-novo
SSL Email: novo@x.com
Portainer Link: https://portainer.novo.com
`;

const ANTIGO = `[DADOS DA VPS]
Nome do Servidor: srv-antigo
Rede interna: net-antigo
Email para SSL: antigo@x.com
Link do Portainer: https://portainer.antigo.com
`;

describe("parseDadosVps", () => {
  it("lê a chave nova em inglês (instalação a partir da Fase 0)", () => {
    expect(parseDadosVps(NOVO)).toEqual({
      nome_servidor: "srv-novo",
      nome_rede_interna: "net-novo",
      email_ssl: "novo@x.com",
      url_portainer: "portainer.novo.com",
    });
  });

  it("lê a chave antiga em português (frota já instalada)", () => {
    expect(parseDadosVps(ANTIGO)).toEqual({
      nome_servidor: "srv-antigo",
      nome_rede_interna: "net-antigo",
      email_ssl: "antigo@x.com",
      url_portainer: "portainer.antigo.com",
    });
  });

  it("remove o https:// da URL do Portainer em ambos os formatos", () => {
    expect(parseDadosVps(NOVO).url_portainer).not.toMatch(/^https?:\/\//);
    expect(parseDadosVps(ANTIGO).url_portainer).not.toMatch(/^https?:\/\//);
  });

  it("ignora linhas sem valor e linhas que não batem com nenhuma chave conhecida", () => {
    const conteudo = `[DADOS DA VPS]
Server Name:
Alguma Chave Desconhecida: valor qualquer
Internal Network: net-x
`;
    expect(parseDadosVps(conteudo)).toEqual({ nome_rede_interna: "net-x" });
  });

  it("string vazia não quebra e devolve objeto vazio", () => {
    expect(parseDadosVps("")).toEqual({});
  });
});

// protecaoSshInstalada (C8, plano de segurança / A2) — leitor do marcador
// não secreto do C10 (/root/dados_vps/seguranca, montado em VPS_CONTEXT_DIR).
// vps-context.ts lê VPS_CONTEXT_DIR no top-level (module scope, mesmo padrão
// de monitor.ts/MONITOR_BASE_URL) — cada teste reseta o registro de módulos
// e reimporta depois de ajustar o env, senão todos os testes deste describe
// dividiriam o mesmo CTX_DIR resolvido no primeiro import do arquivo.
describe("protecaoSshInstalada", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "vps-context-seguranca-"));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
    delete process.env.VPS_CONTEXT_DIR;
  });

  async function importVpsContext() {
    vi.resetModules();
    process.env.VPS_CONTEXT_DIR = dir;
    return import("./vps-context");
  }

  it("marcador ausente -> false, sem logar (caso normal: instalação anterior ao C10)", async () => {
    const aviso = vi.spyOn(console, "warn").mockImplementation(() => {});
    const { protecaoSshInstalada } = await importVpsContext();
    expect(protecaoSshInstalada()).toBe(false);
    expect(aviso).not.toHaveBeenCalled();
  });

  it("marcador presente com conteúdo -> true (só a existência importa)", async () => {
    writeFileSync(join(dir, "seguranca"), "fail2ban=ok");
    const { protecaoSshInstalada } = await importVpsContext();
    expect(protecaoSshInstalada()).toBe(true);
  });

  it("marcador presente vazio -> true (contrato: existir já basta, sem formato de conteúdo)", async () => {
    writeFileSync(join(dir, "seguranca"), "");
    const { protecaoSshInstalada } = await importVpsContext();
    expect(protecaoSshInstalada()).toBe(true);
  });

  it.skipIf(process.getuid?.() === 0)(
    "erro de leitura (sem permissão) -> false, loga no máximo 1x por processo",
    async () => {
      const caminho = join(dir, "seguranca");
      writeFileSync(caminho, "fail2ban=ok");
      chmodSync(caminho, 0o000);
      const aviso = vi.spyOn(console, "warn").mockImplementation(() => {});
      const { protecaoSshInstalada } = await importVpsContext();
      expect(protecaoSshInstalada()).toBe(false);
      expect(protecaoSshInstalada()).toBe(false); // segunda chamada não loga de novo
      expect(aviso).toHaveBeenCalledTimes(1);
      chmodSync(caminho, 0o644); // permite o rmSync do afterEach limpar o diretório
    }
  );
});
