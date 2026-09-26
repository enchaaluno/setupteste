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
//
// Mas não em silêncio (auditoria C3): `_FILE` configurado e ilegível/vazio é
// erro de instalação (ex.: secret montado com dono/modo errado), e tratá-lo
// como "ausente" muda o comportamento do painel — sem a senha do admin local
// o login cai no passthrough do Portainer; sem a de serviço, 503. Então avisa
// no log, UMA vez por causa (getLocalAdmin roda a cada requisição), com o
// nome da variável, o caminho e o código do erro — nunca o conteúdo.
const avisados = new Set<string>();

function avisarUmaVez(nomeBase: string, caminho: string, motivo: string): void {
  const chave = `${nomeBase}\0${caminho}\0${motivo}`;
  if (avisados.has(chave)) return;
  avisados.add(chave);
  console.warn(
    `[segredo] ${nomeBase}_FILE=${caminho} definido mas ${motivo} — tratando ${nomeBase} como ausente`
  );
}

export function lerSegredo(nomeBase: string): string | undefined {
  const direto = process.env[nomeBase]?.trim();
  if (direto) return direto;

  const caminho = process.env[`${nomeBase}_FILE`];
  if (!caminho) return undefined;

  let conteudo: string;
  try {
    conteudo = readFileSync(caminho, "utf8").trim();
  } catch (e) {
    const code = (e as NodeJS.ErrnoException)?.code ?? "erro desconhecido";
    avisarUmaVez(nomeBase, caminho, `ilegível (${code})`);
    return undefined;
  }
  if (!conteudo) {
    avisarUmaVez(nomeBase, caminho, "vazio");
    return undefined;
  }
  return conteudo;
}
