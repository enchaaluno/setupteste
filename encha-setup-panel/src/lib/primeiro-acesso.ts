import { getDb } from "./db";
import { getStack } from "./stacks/registry";

// Link de primeiro acesso (?setup=) de uma stack instalada pelo painel.
//
// O token de setup é gerado no install (enchat_setup_token, ver enchat.ts) e
// o app só o aceita enquanto não existe nenhum usuário. O painel já guarda os
// segredos gerados cifrados em stack_secrets (installer.ts, saveStackSecrets),
// mas o link só era mostrado uma vez, no card de sucesso — quem fechava o card
// ou clicava em "Abrir EnchaT" (endereço sem token) ficava sem como criar o
// Super Admin. Aqui o link é remontado do MESMO material, com o MESMO
// postInstall.setupUrl da definição da stack — nunca uma segunda cópia da regra.

type GeneratedSecret = { name?: unknown; value?: unknown };

export type LinkPrimeiroAcesso = { setupUrl: string; dominio: string };

// Mesma normalização de installer.ts (nome da stack no Portainer/stack_secrets).
function nomeDaStack(stackId: string): string {
  return stackId.replace(/-/g, "_");
}

// null = esta stack não tem link de primeiro acesso, ou o painel não tem o
// material (instalação feita fora do painel, antes deste mecanismo, ou que
// nunca chegou a gravar segredos). Nunca lança: o chamador só mostra ou
// esconde o card.
export async function lerLinkPrimeiroAcesso(stackId: string): Promise<LinkPrimeiroAcesso | null> {
  const def = getStack(stackId);
  const montar = def?.postInstall?.setupUrl;
  if (!montar) return null;

  const row = getDb()
    .prepare("SELECT encrypted_envs FROM stack_secrets WHERE stack_name = ?")
    .get(nomeDaStack(stackId)) as { encrypted_envs: string } | undefined;
  if (!row) return null;

  try {
    const { decryptSecret } = await import("./crypto");
    const parsed = JSON.parse(decryptSecret(row.encrypted_envs)) as {
      values?: Record<string, unknown>;
      generated?: GeneratedSecret[];
    };
    const secrets: Record<string, string> = {};
    for (const g of parsed.generated ?? []) {
      if (g && typeof g.name === "string" && typeof g.value === "string") secrets[g.name] = g.value;
    }
    if (!secrets.enchat_setup_token || !parsed.values) return null;

    const setupUrl = montar(parsed.values, secrets);
    const dominio = new URL(setupUrl).host;
    return { setupUrl, dominio };
  } catch {
    return null;
  }
}

// O app diz sozinho se ainda precisa do primeiro admin (GET /api/setup/status,
// público, devolve {precisa_setup}). true = ainda precisa; false = o admin já
// existe e o token foi apagado no app (o link não serve mais); null = não deu
// para saber (app subindo/fora do ar) — o chamador mostra o link mesmo assim:
// é inofensivo se o admin já existir, e some o motivo do usuário ficar preso.
export async function appPrecisaSetup(
  dominio: string,
  fetchImpl: typeof fetch = fetch
): Promise<boolean | null> {
  try {
    const res = await fetchImpl(`https://${dominio}/api/setup/status`, {
      cache: "no-store",
      redirect: "error",
      signal: AbortSignal.timeout(4000),
    });
    if (!res.ok) return null;
    const corpo = (await res.json()) as { precisa_setup?: unknown };
    return typeof corpo.precisa_setup === "boolean" ? corpo.precisa_setup : null;
  } catch {
    return null;
  }
}
