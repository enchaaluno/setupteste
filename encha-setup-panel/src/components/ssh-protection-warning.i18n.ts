import type { Locale } from "@/lib/locale-shared";

export type SshProtectionWarningText = {
  message: string;
  copy: string;
  copied: string;
};

export const sshProtectionWarningText: Record<Locale, SshProtectionWarningText> = {
  pt: {
    message:
      "O SSH desta VPS não tem proteção contra tentativas de força bruta (fail2ban). Rode o comando abaixo para ativar:",
    copy: "Copiar",
    copied: "Copiado!",
  },
  en: {
    message:
      "This VPS's SSH has no brute-force protection (fail2ban). Run the command below to enable it:",
    copy: "Copy",
    copied: "Copied!",
  },
  es: {
    message:
      "El SSH de esta VPS no tiene protección contra intentos de fuerza bruta (fail2ban). Ejecute el siguiente comando para activarla:",
    copy: "Copiar",
    copied: "¡Copiado!",
  },
};
