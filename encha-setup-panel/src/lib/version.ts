// Versão do Encha Setup Panel — bakeada na imagem no momento do build.
// Mantenha em sincronia com `package.json` e com `ENCHA_VERSION` em main.sh/secondary.sh.
// O fluxo de publicação está documentado no CLAUDE.md.
export const APP_VERSION = "0.2.13";

/**
 * Compara duas versões semver (X.Y.Z, com sufixo de pré-release opcional ignorado).
 * Retorna >0 se a > b, <0 se a < b, 0 se iguais.
 * Tolerante a entradas malformadas: segmentos não-numéricos viram 0.
 */
export function compareSemver(a: string, b: string): number {
  const parse = (v: string) =>
    v
      .split("-")[0] // descarta sufixo de pré-release (ex: -beta.1)
      .split(".")
      .map((n) => parseInt(n, 10) || 0);
  const pa = parse(a);
  const pb = parse(b);
  const len = Math.max(pa.length, pb.length);
  for (let i = 0; i < len; i++) {
    const diff = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (diff !== 0) return diff;
  }
  return 0;
}
