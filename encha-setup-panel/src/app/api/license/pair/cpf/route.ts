import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { requireSessionToken } from "@/lib/auth/require-token";
import { verifyCsrf, verifyOrigin, getClientIp } from "@/lib/csrf";
import { checkRateLimit } from "@/lib/security/rate-limit";
import { getStack } from "@/lib/stacks/registry";
import { buscarPareamento, falharPareamento } from "@/lib/pairing-store";
import { pairCpf, PairingError } from "@/lib/license-pairing";
import { logAudit } from "@/lib/audit";
import { resolveLocale } from "@/lib/locale";
import { apiError, unauthenticatedResponse } from "@/lib/api-error";

const bodySchema = z.object({
  stackId: z.string().min(1).max(60),
  pairingId: z.string().regex(/^[0-9a-f]{32}$/),
  cpf: z.string().min(11).max(14),
});

const ERROS = {
  origem_invalida: { pt: "Origem inválida", en: "Invalid origin", es: "Origen inválido" },
  csrf_invalido: { pt: "CSRF inválido", en: "Invalid CSRF token", es: "CSRF inválido" },
  payload_invalido: { pt: "Payload inválido", en: "Invalid payload", es: "Payload inválido" },
  cpf_invalido_formato: {
    pt: "Informe um CPF válido (11 dígitos)",
    en: "Enter a valid CPF (11 digits)",
    es: "Ingrese un CPF válido (11 dígitos)",
  },
  stack_sem_pareamento: {
    pt: "Stack sem pareamento de licença",
    en: "Stack has no license pairing",
    es: "El stack no tiene emparejamiento de licencia",
  },
  sessao_nao_encontrada: { pt: "Sessão não encontrada", en: "Session not found", es: "Sesión no encontrada" },
  // Console devolveu 404/410: a sessão de pareamento não existe mais lá
  // (expirou ou foi apagada). Distinto de "cpf não confere" — o cliente
  // troca o card por "expirado / gere outro código" em vez de deixar o
  // usuário retentar o CPF contra uma sessão morta.
  sessao_expirada: {
    pt: "A sessão de pareamento expirou — gere um novo código",
    en: "The pairing session expired — generate a new code",
    es: "La sesión de emparejamiento expiró — genere un nuevo código",
  },
  nao_confirmou_cpf: {
    pt: "Não foi possível confirmar com este CPF — confira os dados e tente de novo",
    en: "Could not confirm with this CPF — check the details and try again",
    es: "No fue posible confirmar con este CPF — revise los datos e intente de nuevo",
  },
} satisfies Record<string, Record<import("@/lib/locale-shared").Locale, string>>;

const RATE_LIMIT_MSG = {
  pt: (s: number) => `Muitas tentativas — aguarde ${s}s`,
  en: (s: number) => `Too many attempts — wait ${s}s`,
  es: (s: number) => `Demasiados intentos — espere ${s}s`,
};

// Informa o CPF depois do telefone já confirmado por WhatsApp (protocolo
// "aguardando_cpf" — ver pair/poll). O CPF em si NUNCA é persistido aqui
// nem em audit — só repassado ao Console. cpf_nao_confere/aguardando_
// credencial (Fase 2, 2 tentativas) SÃO revelados de propósito — ver o
// catch abaixo; os demais motivos continuam genéricos (anti-oráculo).
export async function POST(req: NextRequest) {
  const locale = await resolveLocale();
  if (!verifyOrigin(req)) return apiError(ERROS, "origem_invalida", locale, 403);
  if (!(await verifyCsrf(req))) return apiError(ERROS, "csrf_invalido", locale, 403);

  const auth = await requireSessionToken();
  if (!auth) return unauthenticatedResponse(locale);
  const { session } = auth;

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return apiError(ERROS, "payload_invalido", locale, 400);
  }
  const parsed = bodySchema.safeParse(body);
  if (!parsed.success) return apiError(ERROS, "cpf_invalido_formato", locale, 400);
  const { stackId, pairingId, cpf } = parsed.data;

  const def = getStack(stackId);
  if (!def?.pairing) return apiError(ERROS, "stack_sem_pareamento", locale, 404);

  const ip = getClientIp(req);
  // Espelha o teto de 3 tentativas de CPF POR SESSÃO que o Console já impõe
  // (excesso_tentativas_cpf) — este aqui é só uma segunda camada por IP,
  // pra não deixar um único IP disparar CPFs contra várias sessões abertas.
  const rl = checkRateLimit(`license.pair.cpf:${ip}`, 5, 10 * 60_000);
  if (!rl.allowed) {
    return NextResponse.json(
      { error: "muitas_tentativas", message: RATE_LIMIT_MSG[locale](Math.ceil(rl.resetMs / 1000)) },
      { status: 429 }
    );
  }

  const row = buscarPareamento(pairingId);
  if (!row || row.stack_id !== stackId) return apiError(ERROS, "sessao_nao_encontrada", locale, 404);

  try {
    await pairCpf(def.pairing.consoleBaseUrl, { sessionId: row.console_session_id ?? "", fingerprint: row.fingerprint, cpf });
    return NextResponse.json({ ok: true });
  } catch (e) {
    const meta: Record<string, unknown> = { error: e instanceof Error ? e.message : "Erro desconhecido", pairing_id: pairingId }; // nunca o CPF
    let httpStatus = 502;
    let motivoConsole: string | undefined;
    let tentativasRestantes: number | undefined;
    if (e instanceof PairingError) {
      meta.reason = e.reason;
      if (e.httpStatus !== undefined) meta.httpStatus = e.httpStatus;
      httpStatus = e.reason === "recusado" ? 409 : e.reason === "rate_limited" ? 429 : 502;
      motivoConsole = (e.body?.error as string | undefined) ?? e.serverDetail;
      if (typeof e.body?.tentativas_restantes === "number") tentativasRestantes = e.body.tentativas_restantes;
    }
    logAudit({ user: session.user, ip, action: "license.pair.cpf.fail", target: stackId, result: "error", meta });

    // Sessão inexistente/expirada no Console: terminal. Libera o slot local
    // (senão "Gerar outro código" retoma a mesma sessão morta) e NÃO cai no
    // "nao_confirmou_cpf" abaixo, que fingia ser um erro de CPF.
    if (e instanceof PairingError && e.reason === "not_found") {
      falharPareamento(pairingId);
      return apiError(ERROS, "sessao_expirada", locale, 410);
    }

    // cpf_nao_confere/aguardando_credencial (Fase 2) SÃO revelados — quem
    // chega aqui já provou posse de um WhatsApp cadastrado, então só
    // descobre algo sobre a PRÓPRIA conta, nunca de terceiros.
    if (motivoConsole === "cpf_nao_confere" || motivoConsole === "aguardando_credencial") {
      return NextResponse.json(
        { ok: false, error: motivoConsole, tentativas_restantes: tentativasRestantes },
        { status: httpStatus }
      );
    }
    return apiError(ERROS, "nao_confirmou_cpf", locale, httpStatus);
  }
}
