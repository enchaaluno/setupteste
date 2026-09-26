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
    // Spy de console.warn de um teste não pode vazar a contagem para o
    // próximo (testes-setup.ts não restaura mocks sozinho).
    vi.restoreAllMocks();
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
  // Sem cache (decisão do C8): o marcador aparece com o painel já no ar
  // quando o operador roda `proteger-ssh` — e um cache (plausível, imitando
  // getVpsContext) faria o aviso nunca sumir sem reiniciar o container.
  // Mutante que este teste mata: memorizar o resultado entre chamadas.
  it("sem cache: marcador criado/removido com o painel no ar muda o resultado na chamada seguinte", async () => {
    const { protecaoSshInstalada } = await importVpsContext();
    const caminho = join(dir, "seguranca");
    expect(protecaoSshInstalada()).toBe(false);
    writeFileSync(caminho, "");
    expect(protecaoSshInstalada()).toBe(true);
    rmSync(caminho);
    expect(protecaoSshInstalada()).toBe(false);
  });

  // Mesma garantia do teste de chmod acima, mas sem depender de não ser root
  // (o chmod 000 não barra root e aquele teste é pulado) — o erro vem de um
  // node:fs simulado. 3 chamadas seguidas com EACCES: a flag é de módulo,
  // então só a primeira loga; mutante que isto mata: flag local à função.
  it("erro não-ENOENT simulado (EACCES) em 3 chamadas seguidas -> false nas 3, loga 1x só", async () => {
    vi.resetModules();
    process.env.VPS_CONTEXT_DIR = dir;
    vi.doMock("node:fs", async (importOriginal) => {
      const real = await importOriginal<typeof import("node:fs")>();
      return {
        ...real,
        readFileSync: vi.fn(() => {
          throw Object.assign(new Error("EACCES: permission denied"), { code: "EACCES" });
        }),
      };
    });
    const aviso = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      const { protecaoSshInstalada } = await import("./vps-context");
      expect(protecaoSshInstalada()).toBe(false);
      expect(protecaoSshInstalada()).toBe(false);
      expect(protecaoSshInstalada()).toBe(false);
      expect(aviso).toHaveBeenCalledTimes(1);
    } finally {
      vi.doUnmock("node:fs");
    }
  });
});
