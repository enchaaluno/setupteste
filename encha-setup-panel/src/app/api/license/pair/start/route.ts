import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { requireSessionToken } from "@/lib/auth/require-token";
import { verifyCsrf, verifyOrigin, getClientIp } from "@/lib/csrf";
import { checkRateLimit } from "@/lib/security/rate-limit";
import { getStack } from "@/lib/stacks/registry";
import { getOrCreateMachineId, pareamentoAtivo, criarPareamento, falharPareamento } from "@/lib/pairing-store";
import { pairStart, PairingError } from "@/lib/license-pairing";
import { fetchLatestRelease, ReleaseInfoError } from "@/lib/release-info";
import { logAudit } from "@/lib/audit";
import { resolveLocale } from "@/lib/locale";
import { apiError, unauthenticatedResponse } from "@/lib/api-error";

// novo=true: "Gerar outro código" — o usuário pediu explicitamente uma sessão
// nova, então uma sessão 'aberto' existente é descartada em vez de retomada.
const bodySchema = z.object({ stackId: z.string().min(1).max(60), novo: z.boolean().optional() });

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
  apphostname_ausente: {
    pt: "Stack sem appHostname configurado — bug de configuração",
    en: "Stack has no appHostname configured — configuration bug",
    es: "El stack no tiene appHostname configurado — error de configuración",
  },
  pareamento_falhou: {
    pt: "Não foi possível iniciar o pareamento",
    en: "Could not start pairing",
    es: "No fue posible iniciar el emparejamiento",
  },
} satisfies Record<string, Record<import("@/lib/locale-shared").Locale, string>>;

const RATE_LIMIT_MSG = {
  pt: (s: number) => `Muitas tentativas — aguarde ${s}s`,
  en: (s: number) => `Too many attempts — wait ${s}s`,
  es: (s: number) => `Demasiados intentos — espere ${s}s`,
};

// Abre (ou RETOMA) a sessão de pareamento self-service de licença de uma
// stack. Nunca devolve fingerprint/machine_id/session_id do Console pro
// browser — só um pairing_id opaco, que as demais rotas /api/license/pair/*
// resolvem server-side. Ver license-pairing.ts para o protocolo e
// pairing-store.ts para a persistência.
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
  const { stackId, novo } = parsed.data;

  const def = getStack(stackId);
  if (!def?.pairing) return apiError(ERROS, "stack_sem_pareamento", locale, 404);
  if (!def.appHostname) {
    return apiError(ERROS, "apphostname_ausente", locale, 500);
  }

  const ip = getClientIp(req);
  // Espelha MAX_POR_FINGERPRINT_HORA=5 do Console (pair/start/route.ts) —
  // falhar aqui ANTES de gastar uma das 5 tentativas por fingerprint que o
  // Console impõe é o que faz a mensagem de erro ser "aguarde" em vez de
  // um pareamento que nasce e já não tem chance de confirmar.
  const rl = checkRateLimit(`license.pair.start:${ip}:${stackId}`, 5, 15 * 60_000);
  if (!rl.allowed) {
    return NextResponse.json(
      { error: "muitas_tentativas", message: RATE_LIMIT_MSG[locale](Math.ceil(rl.resetMs / 1000)) },
      { status: 429 }
    );
  }

  // Retomada: reabrir o wizard não deve abrir uma SEGUNDA sessão (cada uma
  // consome 1 das 5 tentativas/hora por fingerprint no Console) — devolve a
  // que já está aberta/confirmada, com os MESMOS campos de exibição da
  // resposta original (wa_link/wa_qr_svg/etc. persistidos em criarPareamento
  // exatamente pra isto — nem o Console nem o poll os reenviam depois).
  let existente = pareamentoAtivo(stackId);
  // "Gerar outro código": descarta só uma sessão ainda 'aberto'. Uma
  // 'confirmado' já carrega a chave emitida (chave_encrypted) esperando o
  // install consumir — descartá-la perderia a licença; nesse caso a
  // retomada abaixo continua valendo.
  if (novo && existente?.status === "aberto") {
    falharPareamento(existente.id);
    existente = null;
  }
  if (existente) {
    return NextResponse.json({
      pairingId: existente.id,
      status: existente.status,
      codigo: existente.codigo_exibicao,
      codigoExibicao: existente.codigo_exibicao,
      numeroExibicao: existente.numero_exibicao,
      waLink: existente.wa_link,
      waQrSvg: existente.wa_qr_svg,
      expiraEm: existente.expires_at,
      signupUrl: existente.signup_url,
      retomado: true,
    });
  }

  const { machineId, fingerprint, legacy } = getOrCreateMachineId(stackId, def.appHostname);
  if (legacy) {
    // Instalação anterior a este mecanismo — pareamento mudaria o
    // fingerprint de uma licença possivelmente já ativada. Não abre sessão;
    // o wizard deve cair no fallback de colar a chave manualmente.
    return NextResponse.json(
      { error: "instalacao_legado", legacy: true },
      { status: 409 }
    );
  }

  try {
    const release = await fetchLatestRelease(
      def.pairing.consoleBaseUrl,
      def.id === "enchat" ? "enchat" : def.id, // versao_app é só telemetria no Console — nome da stack basta
      def.pairing.edicao,
      "stable"
    ).catch(() => null); // versao_app é informativo — não bloqueia o pareamento se o /api/version falhar

    const result = await pairStart(def.pairing.consoleBaseUrl, {
      fingerprint,
      versaoApp: release?.version ?? "desconhecida",
      edicao: def.pairing.edicao,
      nomeInstalacao: session.user,
    });

    const row = criarPareamento({
      stackId,
      machineId,
      fingerprint,
      consoleSessionId: result.sessionId,
      codigoExibicao: result.codigoExibicao ?? result.codigo,
      expiresAt: result.expiraEm,
      waLink: result.waLink,
      waQrSvg: result.waQrSvg,
      numeroExibicao: result.numeroExibicao,
      signupUrl: result.signupUrl,
    });

    logAudit({
      user: session.user,
      ip,
      action: "license.pair.start",
      target: stackId,
      result: "ok",
      meta: { pairing_id: row.id }, // nunca session_id/fingerprint/código
    });

    return NextResponse.json({
      pairingId: row.id,
      status: "aberto",
      codigo: result.codigo,
      codigoExibicao: result.codigoExibicao,
      numeroExibicao: result.numeroExibicao,
      waLink: result.waLink,
      waQrSvg: result.waQrSvg,
      expiraEm: result.expiraEm,
      signupUrl: result.signupUrl,
      numeroOficialExibicao: result.numeroOficialExibicao,
      waLinkOficial: result.waLinkOficial,
    });
  } catch (e) {
    const meta: Record<string, unknown> = { error: e instanceof Error ? e.message : "Erro desconhecido" };
    let httpStatus = 502;
    if (e instanceof PairingError) {
      meta.reason = e.reason;
      if (e.httpStatus !== undefined) meta.httpStatus = e.httpStatus;
      if (e.serverDetail !== undefined) meta.serverDetail = e.serverDetail;
      httpStatus = e.reason === "rate_limited" ? 429 : e.reason === "recusado" ? 409 : 502;
    } else if (e instanceof ReleaseInfoError) {
      meta.reason = e.reason;
    }
    logAudit({ user: session.user, ip, action: "license.pair.start.fail", target: stackId, result: "error", meta });
    // e.message de PairingError vem de license-pairing.ts (fora do escopo
    // desta migração) — só o fallback abaixo, hardcoded aqui, é traduzido.
    return NextResponse.json(
      {
        error: e instanceof PairingError ? e.message : ERROS.pareamento_falhou[locale],
        reason: e instanceof PairingError ? e.reason : undefined,
      },
      { status: httpStatus }
    );
  }
}
