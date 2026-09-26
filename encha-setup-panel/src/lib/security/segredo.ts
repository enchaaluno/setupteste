import { readFileSync } from "node:fs";

// Resolvedor único de segredo configurável por env var direta OU por Docker
// secret (arquivo apontado por `<NOME>_FILE`, montado pelo instalador — ver
// plano de segurança, M3). Usado hoje por `PANEL_ADMIN_PASSWORD`
// (src/lib/auth/local-admin.ts) e `PORTAINER_PASSWORD`
// (src/lib/auth/local-admin.ts e src/lib/portainer.ts `authenticateService`)
// — fica aqui, fora de `auth/`, porque `portainer.ts` também precisa dele e
// não deveria importar de `auth/` para isso.
//
// Regra: a env direta, quando não-vazia (depois de `.trim()`), SEMPRE vence
// sobre o arquivo. Esse é o caminho de recuperação que a instrução "Esqueceu
// a senha" (main.sh) usa — o cliente edita a env no Portainer, e isso precisa
// continuar funcionando mesmo depois de uma instalação migrada para secret.
// Sem a env direta, cai para `<NOME>_FILE`; erro de leitura (arquivo ausente,
// sem permissão, etc.) nunca deve derrubar o processo — resolve para
// `undefined`, como se o segredo simplesmente não estivesse configurado.
export function lerSegredo(nomeBase: string): string | undefined {
  const direto = process.env[nomeBase]?.trim();
  if (direto) return direto;

  const caminho = process.env[`${nomeBase}_FILE`];
  if (!caminho) return undefined;

  try {
    const conteudo = readFileSync(caminho, "utf8").trim();
    return conteudo || undefined;
  } catch {
    return undefined;
  }
}
