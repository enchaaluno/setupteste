import { getDb } from "./db";

export type AuditAction =
  | "login.success"
  | "login.fail"
  | "logout"
  | "stack.install"
  | "stack.install.fail"
  | "stack.remove"
  | "stack.remove.fail"
  | "stack.update"
  | "stack.update.fail"
  | "terms.accept"
  | "banner.click"
  | "panel.update"
  | "panel.update.fail"
  | "host.scripts.update"
  | "host.scripts.update.fail"
  | "registry.auth"
  | "registry.auth.fail"
  | "release.resolve"
  | "release.resolve.fail"
  // Pareamento self-service de licença (ver license-pairing.ts). Nunca a
  // chave nem PII (nome/CPF/celular) no `meta` — só identificadores opacos
  // (pairing_id) e causas estruturadas (reason/httpStatus).
  | "license.pair.start"
  | "license.pair.start.fail"
  | "license.pair.poll.fail"
  | "license.pair.confirm"
  | "license.pair.cpf.fail"
  | "license.pair.choose.fail"
  | "license.pair.migrar"
  | "license.pair.migrar.fail"
  | "license.pair.credencial"
  | "license.pair.credencial.fail"
  | "license.pair.trocar-telefone"
  | "license.pair.trocar-telefone.fail"
  | "license.signup"
  | "license.signup.fail"
  // Ativação síncrona por e-mail do Tracker (ver tracker-ativacao.ts, Ciclo
  // 20b). Nunca a chave nem o e-mail no `meta` — só o stackId e a causa
  // estruturada (reason) no caminho de falha.
  | "license.tracker.ativar"
  | "license.tracker.ativar.fail"
  // Sistema de tickets de suporte (ver suporte.ts). Nunca o texto do ticket
  // nem nome de anexo no `meta` — só ticket_id e causas estruturadas.
  | "suporte.abrir"
  | "suporte.abrir.fail"
  | "suporte.anexo"
  | "suporte.anexo.fail"
  // Consulta do link de primeiro acesso (?setup=) de uma stack instalada.
  // Nunca o token nem o link no `meta` — só se o link foi entregue ou se o
  // administrador já existia.
  | "stack.primeiro_acesso";

export type AuditEntry = {
  user: string;
  ip: string;
  action: AuditAction;
  target?: string;
  result: "ok" | "error";
  meta?: Record<string, unknown>;
};

export function logAudit(entry: AuditEntry): void {
  const db = getDb();
  db.prepare(
    "INSERT INTO audit_log (ts, user, ip, action, target, result, meta) VALUES (?, ?, ?, ?, ?, ?, ?)"
  ).run(
    Date.now(),
    entry.user,
    entry.ip,
    entry.action,
    entry.target ?? null,
    entry.result,
    entry.meta ? JSON.stringify(entry.meta) : null
  );
}

export type AuditRow = {
  id: number;
  ts: number;
  user: string;
  ip: string;
  action: string;
  target: string | null;
  result: string;
  meta: string | null;
};

export function listAudit(limit = 200, offset = 0): AuditRow[] {
  const db = getDb();
  return db
    .prepare("SELECT * FROM audit_log ORDER BY ts DESC LIMIT ? OFFSET ?")
    .all(limit, offset) as AuditRow[];
}
