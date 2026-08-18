/**
 * M4-4. Balanced-brace JSON extraction from free text.
 *
 * Ollama's structured-output `format` should produce clean JSON on its own,
 * but "should" is not "always" for a local model, and docs/05's fallback
 * ladder step 2 exists for exactly the case where it doesn't: the model
 * wraps the object in prose, or a markdown code fence, or both. This finds
 * the first balanced `{...}` region and parses it -- nothing fancier, and
 * deliberately not an attempt to find the "best" JSON object if there are
 * several, just the first one, matching the documented fallback step.
 */

export function extractBalancedJson(text: string): unknown | null {
  const start = text.indexOf("{");
  if (start === -1) {
    return null;
  }

  let depth = 0;
  let inString = false;
  let escaped = false;

  for (let i = start; i < text.length; i += 1) {
    const ch = text[i];

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch === "\\") {
        escaped = true;
      } else if (ch === '"') {
        inString = false;
      }
      continue;
    }

    if (ch === '"') {
      inString = true;
      continue;
    }
    if (ch === "{") {
      depth += 1;
    } else if (ch === "}") {
      depth -= 1;
      if (depth === 0) {
        const candidate = text.slice(start, i + 1);
        try {
          return JSON.parse(candidate);
        } catch {
          return null;
        }
      }
    }
  }

  // Ran off the end without the depth returning to zero -- unbalanced.
  return null;
}
