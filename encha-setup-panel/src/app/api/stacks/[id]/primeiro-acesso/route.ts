import { NextRequest, NextResponse } from "next/server";
import { readSession } from "@/lib/session";
import { getClientIp } from "@/lib/csrf";
import { checkRateLimit } from "@/lib/security/rate-limit";
import { getStack } from "@/lib/stacks/registry";
import { lerLinkPrimeiroAcesso, appPrecisaSetup } from "@/lib/primeiro-acesso";
import { logAudit } from "@/lib/audit";
import { resolveLocale } from "@/lib/locale";
import { apiError, unauthenticatedResponse } from "@/lib/api-error";

const ERROS = {
  stack_desconhecida: { pt: "Stack desconhecida", en: "Unknown stack", es: "Stack desconocida" },
  muitas_tentativas: {
    pt: "Muitas consultas — aguarde um instante",
    en: "Too many requests — wait a moment",
    es: "Demasiadas consultas — espere un momento",
  },
} satisfies Record<string, Record<import("@/lib/locale-shared").Locale, string>>;

// Link de primeiro acesso (?setup=) da stack, enquanto o app ainda não tem
// administrador. Só para a sessão logada do painel; o token nunca vai para
// log, audit nem cache (Cache-Control: no-store).
//
//   { disponivel: false }  — painel sem o material (instalação de fora / antiga)
//   { jaCriado: true }     — o app já tem administrador; não há mais link
//   { setupUrl }           — link pronto para copiar/abrir
export async function GET(req: NextRequest, ctx: { params: Promise<{ id: string }> }) {
  const locale = await resolveLocale();
  const session = await readSession();
  if (!session) return unauthenticatedResponse(locale);

  const { id } = await ctx.params;
  const def = getStack(id);
  if (!def?.postInstall?.setupUrl) return apiError(ERROS, "stack_desconhecida", locale, 404);

  const ip = getClientIp(req);
  const rl = checkRateLimit(`stack.primeiro_acesso:${session.user}:${id}`, 30, 60_000);
  if (!rl.allowed) return apiError(ERROS, "muitas_tentativas", locale, 429);

  const noStore = { "Cache-Control": "no-store" };

  const info = await lerLinkPrimeiroAcesso(id);
  if (!info) return NextResponse.json({ disponivel: false }, { headers: noStore });

  const precisa = await appPrecisaSetup(info.dominio);
  if (precisa === false) {
    logAudit({ user: session.user, ip, action: "stack.primeiro_acesso", target: id, result: "ok", meta: { ja_criado: true } });
    return NextResponse.json({ jaCriado: true }, { headers: noStore });
  }

  logAudit({
    user: session.user,
    ip,
    action: "stack.primeiro_acesso",
    target: id,
    result: "ok",
    meta: { ja_criado: false, app_respondeu: precisa === true },
  });
  return NextResponse.json({ setupUrl: info.setupUrl }, { headers: noStore });
}
