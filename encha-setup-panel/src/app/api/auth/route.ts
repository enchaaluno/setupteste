import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { authenticate, getServiceToken, PortainerError } from "@/lib/portainer";
import { createSession, setCsrfCookie, destroySession } from "@/lib/session";
import { getLocalAdmin, hasServiceCredentials, verifyLocalAdmin } from "@/lib/auth/local-admin";
import { dispararGarantiaAposLoginLegado } from "@/lib/guard-runtime";
import { logAudit } from "@/lib/audit";
import { checkRateLimit } from "@/lib/security/rate-limit";
import { getClientIp, verifyOrigin, verifyCsrf } from "@/lib/csrf";
import { newCsrfToken } from "@/lib/csrf";
import { resolveLocale } from "@/lib/locale";
import { apiError } from "@/lib/api-error";

const loginSchema = z.object({
  username: z.string().min(1).max(80),
  password: z.string().min(1).max(200),
});

// "muitas_tentativas_login" carrega um placeholder "{s}" (segundos até
// liberar de novo) — apiError() não faz interpolação, então essa mensagem é
// montada à mão logo abaixo (ver comentário no POST).
const ERROS = {
  origem_invalida: { pt: "Origem inválida", en: "Invalid origin", es: "Origen inválido" },
  csrf_invalido: { pt: "CSRF inválido", en: "Invalid CSRF token", es: "Token CSRF inválido" },
  muitas_tentativas_login: {
    pt: "Muitas tentativas. Tente novamente em {s}s",
    en: "Too many attempts. Try again in {s}s",
    es: "Demasiados intentos. Vuelve a intentarlo en {s}s",
  },
  payload_invalido: { pt: "Payload inválido", en: "Invalid payload", es: "Payload inválido" },
  credenciais_invalidas: { pt: "Credenciais inválidas", en: "Invalid credentials", es: "Credenciales inválidas" },
  configuracao_incompleta: {
    pt: "Configuração incompleta no servidor. Contate o administrador.",
    en: "Incomplete server configuration. Contact the administrator.",
    es: "Configuración incompleta en el servidor. Contacte al administrador.",
  },
  usuario_senha_incorretos: {
    pt: "Usuário ou senha incorretos",
    en: "Incorrect username or password",
    es: "Usuario o contraseña incorrectos",
  },
  falha_conexao_portainer_servico: {
    pt: "Falha ao conectar no Portainer com as credenciais de serviço",
    en: "Failed to connect to Portainer with the service credentials",
    es: "No se pudo conectar a Portainer con las credenciales de servicio",
  },
  falha_conexao_portainer: {
    pt: "Falha ao conectar no Portainer",
    en: "Failed to connect to Portainer",
    es: "No se pudo conectar a Portainer",
  },
} satisfies Record<string, Record<import("@/lib/locale-shared").Locale, string>>;

export async function POST(req: NextRequest) {
  const locale = await resolveLocale();

  if (!verifyOrigin(req)) {
    return apiError(ERROS, "origem_invalida", locale, 403);
  }

  const ip = getClientIp(req);
  const rl = checkRateLimit(`login:${ip}`, 5, 15 * 60 * 1000);
  if (!rl.allowed) {
    const segundos = Math.ceil(rl.resetMs / 1000);
    const template = ERROS.muitas_tentativas_login[locale] ?? ERROS.muitas_tentativas_login.pt;
    return NextResponse.json(
      { error: "muitas_tentativas_login", message: template.replace("{s}", String(segundos)) },
      { status: 429 }
    );
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return apiError(ERROS, "payload_invalido", locale, 400);
  }

  const parsed = loginSchema.safeParse(body);
  if (!parsed.success) {
    return apiError(ERROS, "credenciais_invalidas", locale, 400);
  }

  const { username, password } = parsed.data;
  const exp = Date.now() + 8 * 60 * 60 * 1000;
  const localAdmin = getLocalAdmin();

  // Modo local: o painel tem admin próprio (PANEL_ADMIN_USER/PASSWORD no
  // env). O login não fala com o Portainer diretamente — a conta de serviço
  // (PORTAINER_USER/PASSWORD) é quem se autentica lá, sob demanda.
  if (localAdmin) {
    if (!hasServiceCredentials()) {
      console.error("[auth] PANEL_ADMIN_USER definido mas credenciais de serviço do Portainer ausentes");
      return apiError(ERROS, "configuracao_incompleta", locale, 503);
    }
    if (!verifyLocalAdmin(username, password)) {
      logAudit({ user: username, ip, action: "login.fail", result: "error", meta: { mode: "local" } });
      return apiError(ERROS, "usuario_senha_incorretos", locale, 401);
    }
    try {
      // Falha cedo se as credenciais de serviço estiverem erradas, em vez de
      // deixar o operador "logado" e só descobrir no primeiro /api/stacks.
      await getServiceToken();
    } catch (e) {
      console.error("[auth] falha ao autenticar credenciais de serviço do Portainer:", e);
      logAudit({ user: username, ip, action: "login.fail", result: "error", meta: { mode: "local", serviceAuth: true } });
      return apiError(ERROS, "falha_conexao_portainer_servico", locale, 502);
    }
    await createSession({ user: username, exp, mode: "local" });
    await setCsrfCookie(newCsrfToken());
    logAudit({ user: username, ip, action: "login.success", result: "ok", meta: { mode: "local" } });
    return NextResponse.json({ ok: true });
  }

  // Modo legado: sem admin próprio, o login é um proxy direto para o
  // Portainer (comportamento anterior a esta mudança, mantido para não
  // travar instalações já existentes — ver requireSessionToken). É também
  // o único lugar (fora de instrumentation.ts, que não tem credencial de
  // serviço nessa instalação) onde o encha-guard tem chance de ser
  // garantido — fire-and-forget, nunca atrasa nem faz a resposta de login
  // "falhar" por causa disso (ciclo C6 do plano de segurança).
  try {
    const jwt = await authenticate(username, password);
    await createSession({ user: username, jwt, exp, mode: "portainer" });
    await setCsrfCookie(newCsrfToken());
    logAudit({ user: username, ip, action: "login.success", result: "ok", meta: { mode: "portainer" } });
    dispararGarantiaAposLoginLegado(jwt);
    return NextResponse.json({ ok: true });
  } catch (e) {
    console.error("[auth] erro no login:", e);
    const status = e instanceof PortainerError ? e.status : 500;
    logAudit({
      user: username,
      ip,
      action: "login.fail",
      result: "error",
      meta: { status, mode: "portainer" },
    });
    const invalido = status === 401 || status === 422;
    return apiError(ERROS, invalido ? "usuario_senha_incorretos" : "falha_conexao_portainer", locale, invalido ? 401 : 502);
  }
}

export async function DELETE(req: NextRequest) {
  const locale = await resolveLocale();
  if (!verifyOrigin(req)) return apiError(ERROS, "origem_invalida", locale, 403);
  if (!(await verifyCsrf(req))) return apiError(ERROS, "csrf_invalido", locale, 403);
  await destroySession();
  return NextResponse.json({ ok: true });
}
