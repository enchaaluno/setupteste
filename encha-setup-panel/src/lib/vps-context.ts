import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

export type VpsContext = {
  nome_servidor: string;
  nome_rede_interna: string;
  email_ssl: string;
  url_portainer: string;
};

const CTX_DIR = process.env.VPS_CONTEXT_DIR ?? "/app/vps-context";
const FALLBACK: VpsContext = {
  nome_servidor: process.env.VPS_SERVER ?? "encha",
  nome_rede_interna: process.env.VPS_NETWORK ?? "enchanet",
  email_ssl: process.env.VPS_SSL_EMAIL ?? "",
  url_portainer: process.env.VPS_PORTAINER_URL ?? "",
};

let cached: VpsContext | null = null;

// Exportada para teste direto (função pura) — mesmo padrão de
// containerSpecToServiceSpec/taskOutcome em portainer.ts.
export function parseDadosVps(content: string): Partial<VpsContext> {
  const out: Partial<VpsContext> = {};
  const lines = content.split(/\r?\n/);
  for (const line of lines) {
    const m = line.match(/^\s*([^:]+):\s*(.+?)\s*$/);
    if (!m) continue;
    const key = m[1].trim().toLowerCase();
    const value = m[2].trim();
    if (!value) continue;
    // Aceita a chave nova em inglês (instalações a partir da Fase 0 de i18n)
    // e a antiga em português (frota já instalada — dados_vps só é regravado
    // numa instalação completa nova, nunca por "Atualizar", então essas
    // instalações mantêm a chave antiga para sempre). Ver i18n/GLOSSARY.md.
    if (key.includes("nome do servidor") || key === "servidor" || key.includes("server name")) {
      out.nome_servidor = value;
    } else if (key.includes("rede interna") || key === "rede" || key.includes("internal network")) {
      out.nome_rede_interna = value;
    } else if ((key.includes("email") && key.includes("ssl")) || key.includes("ssl email")) {
      out.email_ssl = value;
    } else if (key.includes("link do portainer") || key.includes("portainer link") || key.includes("portainer")) {
      out.url_portainer = value.replace(/^https?:\/\//, "");
    }
  }
  return out;
}

export function getVpsContext(): VpsContext {
  if (cached) return cached;

  const merged: VpsContext = { ...FALLBACK };
  const dadosVpsPath = join(CTX_DIR, "dados_vps");

  if (existsSync(dadosVpsPath)) {
    try {
      const content = readFileSync(dadosVpsPath, "utf8");
      const parsed = parseDadosVps(content);
      Object.assign(merged, parsed);
    } catch (e) {
      console.warn("[vps-context] erro lendo dados_vps:", e);
    }
  }

  cached = merged;
  return merged;
}

export function resetVpsContextCache(): void {
  cached = null;
}

// Marcador não secreto do C10 (plano de segurança, achado A2): gravado em
// /root/dados_vps/seguranca (modo 644) por instalar_protecao_ssh no
// secondary.sh SÓ quando o fail2ban foi instalado/configurado com sucesso —
// mesmo mount de CTX_DIR que dados_vps/encha_locale já usam. CONTRATO para o
// C10 seguir: só a EXISTÊNCIA do arquivo importa, não o conteúdo — o C10 pode
// gravar "fail2ban=ok", uma linha qualquer ou deixar vazio, tanto faz; não
// crie aqui nenhuma dependência de formato/conteúdo específico sem atualizar
// este comentário e o teste correspondente.
//
// Ao contrário de getVpsContext() (que cacheia para sempre — dados_vps só é
// escrito numa instalação nova), este marcador pode aparecer numa VPS já em
// produção, com o painel já rodando, quando o operador roda
// `proteger-ssh`/instalar_protecao_ssh manualmente depois do C10 existir —
// então NÃO cacheamos o resultado entre chamadas, senão o aviso nunca some
// sem reiniciar o container do painel.
//
// readFileSync (não existsSync) para poder diferenciar ausência (ENOENT — o
// caso comum hoje, nenhuma instalação rodou o C10 ainda; nunca loga) de um
// erro de leitura de verdade (permissão etc. — anômalo; loga no máximo 1x
// por processo, mesmo padrão de avisarUmaVez em lib/security/segredo.ts).
let avisadoErroProtecaoSsh = false;

export function protecaoSshInstalada(): boolean {
  const caminho = join(CTX_DIR, "seguranca");
  try {
    readFileSync(caminho);
    return true;
  } catch (e) {
    const code = (e as NodeJS.ErrnoException)?.code;
    if (code !== "ENOENT" && !avisadoErroProtecaoSsh) {
      avisadoErroProtecaoSsh = true;
      console.warn(`[vps-context] erro lendo marcador de segurança (${caminho}):`, e);
    }
    return false;
  }
}
