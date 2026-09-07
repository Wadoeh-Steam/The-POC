// Short pairing code generation/normalization — replaces the UUID token +
// Universal Link pairing mechanism. Excludes I/O (confusable with 1/0 and
// each other).
const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ";

export function generatePairingCode(): string {
  let code = "";
  for (let i = 0; i < 6; i++) {
    code += CODE_ALPHABET[Math.floor(Math.random() * CODE_ALPHABET.length)];
  }
  return code;
}

export function formatPairingCodeForDisplay(code: string): string {
  return `${code.slice(0, 3)}-${code.slice(3)}`;
}

// Accepts input with or without the dash, any case.
export function normalizePairingCode(input: string): string {
  return input.replace(/[^A-Za-z0-9]/g, "").toUpperCase();
}
