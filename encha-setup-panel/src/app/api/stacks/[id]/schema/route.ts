import { NextResponse } from "next/server";
import { readSession } from "@/lib/session";
import { getStack } from "@/lib/stacks/registry";
import { stackDescription, stackFieldText } from "@/lib/stacks/i18n-resolve";
import { resolveLocale } from "@/lib/locale";
import { apiError, unauthenticatedResponse } from "@/lib/api-error";

const ERROS = {
  stack_desconhecida: { pt: "Stack desconhecida", en: "Unknown stack", es: "Stack desconocida" },
} satisfies Record<string, Record<import("@/lib/locale-shared").Locale, string>>;

export async function GET(_req: Request, ctx: { params: Promise<{ id: string }> }) {
  const locale = await resolveLocale();
  const session = await readSession();
  if (!session) return unauthenticatedResponse(locale);

  const { id } = await ctx.params;
  const def = getStack(id);
  if (!def) return apiError(ERROS, "stack_desconhecida", locale, 404);

  return NextResponse.json({
    id: def.id,
    name: def.name,
    // Fase 3 de i18n (i18n/GLOSSARY.md): description/fields chegam já
    // resolvidos no locale da requisição — o cliente nunca vê `i18n`, só o
    // texto final (mesmo padrão de apiError: resolução sempre no servidor).
    description: stackDescription(def, locale),
    fields: def.fields.map((f) => ({ ...f, ...stackFieldText(def, f, locale) })),
    // Só o subconjunto que a UI precisa pra saber quais campos do form o
    // componente de pareamento preenche — consoleBaseUrl/edicao ficam só no
    // servidor (installer.ts e as rotas /api/license/pair/*), o browser
    // nunca fala direto com o Console. O `group` NÃO vai: o wizard posiciona
    // o card pelo grupo (já traduzido) do targetField; mandar o nome cru em
    // pt aqui era o que fazia o card sumir em EN/ES.
    pairing: def.pairing
      ? { targetField: def.pairing.targetField, sessionField: def.pairing.sessionField }
      : null,
    // emailActivation (Ciclo 20b) NÃO é mais exposto aqui: desde o Ciclo D
    // o e-mail é só mais um campo comum de `fields` (kind:"email"), sem
    // componente dedicado no wizard — nenhuma metadata extra é necessária
    // pro browser.
  });
}
