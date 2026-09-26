import { createHash, timingSafeEqual } from "node:crypto";
import { lerSegredo } from "../security/segredo";

// Admin local do painel, lido do ambiente do container (variáveis editáveis
// no Portainer — ver docker-stack.yaml). Quando ausente, o painel opera no
// modo legado de "passthrough": login = credenciais do Portainer, sem
// usuário próprio (ver src/app/api/auth/route.ts e require-token.ts).
//
// A senha passa por `lerSegredo` (C3, M3): aceita tanto a env direta
// (`PANEL_ADMIN_PASSWORD`/`PORTAINER_PASSWORD`) quanto um Docker secret via
// `<NOME>_FILE` — o usuário nunca é segredo, então `PANEL_ADMIN_USER` e
// `PORTAINER_USER` continuam só via env direta.

export type LocalAdmin = { user: string; password: string };

export function getLocalAdmin(): LocalAdmin | null {
  const user = process.env.PANEL_ADMIN_USER?.trim();
  const password = lerSegredo("PANEL_ADMIN_PASSWORD");
  if (!user || !password) return null;
  return { user, password };
}

export function hasServiceCredentials(): boolean {
  return Boolean(process.env.PORTAINER_USER?.trim() && lerSegredo("PORTAINER_PASSWORD"));
}

// Compara usuário e senha em tempo constante e sem short-circuit — os dois
// são sempre avaliados, mesmo quando o usuário já está errado, para não
// vazar via timing se foi o usuário ou a senha que não bateu.
function timingSafeStringEqual(a: string, b: string): boolean {
  const ha = createHash("sha256").update(a, "utf8").digest();
  const hb = createHash("sha256").update(b, "utf8").digest();
  return timingSafeEqual(ha, hb);
}

export function verifyLocalAdmin(username: string, password: string): boolean {
  const admin = getLocalAdmin();
  if (!admin) return false;
  const okUser = timingSafeStringEqual(username, admin.user);
  const okPass = timingSafeStringEqual(password, admin.password);
  return okUser && okPass;
}
