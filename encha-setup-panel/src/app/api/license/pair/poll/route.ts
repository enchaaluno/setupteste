import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { requireSessionToken } from "@/lib/auth/require-token";
import { verifyCsrf, verifyOrigin, getClientIp } from "@/lib/csrf";
import { checkRateLimit } from "@/lib/security/rate-limit";
import { getStack } from "@/lib/stacks/registry";
import { buscarPareamento, confirmarPareamento, falharPareamento } from "@/lib/pairing-store";
import { pairPoll, PairingError } from "@/lib/license-pairing";
import { logAudit } from "@/lib/audit";
import { resolveLocale } from "@/lib/locale";
import { apiError, unauthenticatedResponse } from "@/lib/api-error";

const bodySchema = z.object({ stackId: z.string().min(1).max(60), pairingId: z.string().regex(/^[0-9a-f]{32}$/) });

const ERROS = {
  origem_invalida: { pt: "Origem inválida", en: "Invalid origin", es: "Origen inválido" },
  csrf_invalido: { pt: "CSRF inválido", en: "Invalid CSRF token", es: "CSRF inválido" },
  payload_invalido: { pt: "Payload inválido", en: "Invalid payload", es: "Payload inválido" },
  corpo_invalido: { pt: "Inválido", en: "Invalid request", es: "Solicitud inválida" },
  stack_sem_pareamento: {
    pt: "Stack sem pareamento de licença",
    en: "Stack has no license pairing",
    es: "El stack no tiene emparejamiento de licencia",
  },
  sessao_nao_encontrada: { pt: "Sessão não encontrada", en: "Session not found", es: "Sesión no encontrada" },
} satisfies Record<string, Record<import("@/lib/locale-shared").Locale, string>>;

// Poll de ~3s da sessão de pareamento — mesmo padrão do app Go
// (ConsultarPareamento) e do painel.py standalone. Nunca devolve a CHAVE de
// licença ao browser: no status "confirmado" ela é cifrada e guardada
// server-side (pairing-store.ts); o browser só recebe a confirmação de que
// pode seguir para o install.
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
  if (!parsed.success) return apiError(ERROS, "corpo_invalido", locale, 400);
  const { stackId, pairingId } = parsed.data;

  const def = getStack(stackId);
  if (!def?.pairing) return apiError(ERROS, "stack_sem_pareamento", locale, 404);

  const ip = getClientIp(req);
  // Espelha MAX_POLLS=400 (~20min a 3s) do Console — teto generoso, só para
  // um poll travado em loop não martelar sem limite.
  const rl = checkRateLimit(`license.pair.poll:${pairingId}`, 30, 60_000);
  if (!rl.allowed) return NextResponse.json({ status: "aguardando" }); // não expõe rate limit ao poll — só "continue esperando"

  const row = buscarPareamento(pairingId);
  if (!row || row.stack_id !== stackId) {
    return apiError(ERROS, "sessao_nao_encontrada", locale, 404);
  }
  if (row.status === "consumido") return NextResponse.json({ status: "consumido" });
  if (row.status === "falhou") return NextResponse.json({ status: "recusado" });
  if (row.status === "confirmado") return NextResponse.json({ status: "confirmado" }); // já confirmado antes — idempotente, não repete a chamada ao Console

  try {
    const result = await pairPoll(def.pairing.consoleBaseUrl, {
      sessionId: row.console_session_id ?? "",
      fingerprint: row.fingerprint,
      edicao: def.pairing.edicao,
    });

    switch (result.status) {
      case "confirmado":
        confirmarPareamento(pairingId, result.chave, result.plano);
        logAudit({
          user: session.user,
          ip,
          action: "license.pair.confirm",
          target: stackId,
          result: "ok",
          meta: { pairing_id: pairingId }, // nunca a chave, nunca cliente/plano (PII/comercial)
        });
        return NextResponse.json({ status: "confirmado", cliente: result.cliente, plano: result.plano });
      case "expirado":
      case "recusado":
        falharPareamento(pairingId);
        return NextResponse.json(
          result.status === "recusado"
            ? { status: "recusado", motivo: result.motivo, instalacaoAtual: result.instalacaoAtual }
            : { status: "expirado" }
        );
      case "aguardando_cpf":
        return NextResponse.json({ status: "aguardando_cpf", remetenteMascarado: result.remetenteMascarado });
      case "escolha_pendente":
        return NextResponse.json({ status: "escolha_pendente", licencas: result.licencas, escolhaExpiraEm: result.escolhaExpiraEm });
      case "consumido":
        return NextResponse.json({ status: "consumido" });
      default:
        return NextResponse.json({ status: "aguardando", expiraEm: result.expiraEm, aviso: result.aviso, avisoRemetente: result.avisoRemetente });
    }
  } catch (e) {
    const meta: Record<string, unknown> = { error: e instanceof Error ? e.message : "Erro desconhecido", pairing_id: pairingId };
    if (e instanceof PairingError) {
      meta.reason = e.reason;
      if (e.httpStatus !== undefined) meta.httpStatus = e.httpStatus;
      if (e.serverDetail !== undefined) meta.serverDetail = e.serverDetail;
    }
    logAudit({ user: session.user, ip, action: "license.pair.poll.fail", target: stackId, result: "error", meta });
    // 404/410 do Console = a sessão não existe mais lá (expirou, foi
    // apagada). Isso é terminal, ao contrário de um erro de rede: sem marcar
    // 'falhou', a linha local ficava 'aberto' pra sempre — o poll martelava
    // uma sessão morta e "Gerar outro código" (pair/start) retomava o mesmo
    // código, já que pareamentoAtivo() ainda o via como ativo.
    if (e instanceof PairingError && e.reason === "not_found") {
      falharPareamento(pairingId);
      return NextResponse.json({ status: "expirado" });
    }
    // Erro de transporte no poll NÃO falha a sessão (ela pode se recuperar
    // no próximo poll, igual ao app Go) — devolve "aguardando" em vez de
    // matar o pareamento por uma falha transitória de rede.
    return NextResponse.json({ status: "aguardando" });
  }
}
