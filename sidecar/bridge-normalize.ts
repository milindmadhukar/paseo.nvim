import { need, type Request } from "./bridge-io.ts";

/**
 * Images carried with a prompt.
 *
 * The daemon takes BARE base64 plus a mimeType beside it, not a data URL --
 * and a data URL is exactly what anything else that handles images hands you,
 * so one is unwrapped here rather than at every call site.
 *
 * Returns undefined for "no images", so the caller can leave the field off the
 * request entirely: an empty array is still an array on the wire.
 */
export function pictures(
  req: Request,
): Array<{ data: string; mimeType: string }> | undefined {
  const given = req.images;
  if (!Array.isArray(given) || given.length === 0) return undefined;
  return given.map((image: any, index: number) => {
    const data = String(need(image?.data, `images[${index}].data`));
    const url = /^data:([^;,]+);base64,(.*)$/s.exec(data);
    if (url) return { data: url[2]!, mimeType: url[1]! };
    return {
      data,
      mimeType: String(need(image?.mimeType, `images[${index}].mimeType`)),
    };
  });
}

/**
 * A permission request with buttons GUARANTEED to exist.
 *
 * `actions` is optional in the protocol, and a provider that omits it means
 * plain allow/deny. Synthesising them here rather than in Lua keeps the dialog
 * to one code path -- it renders `request.actions` and never asks whether they
 * are real.
 *
 * The synthetic ones are MARKED, because their ids are ours, not the
 * provider's. Sending an invented `selectedActionId` back is rejected, so
 * `agent.respondToPermission` strips it when the flag is set.
 */
export function withFallbackActions(request: any): any {
  if (Array.isArray(request?.actions) && request.actions.length > 0)
    return request;
  return {
    ...request,
    actions: [
      {
        id: "__allow",
        label: "Allow",
        behavior: "allow",
        variant: "primary",
        synthetic: true,
      },
      {
        id: "__deny",
        label: "Deny",
        behavior: "deny",
        variant: "secondary",
        synthetic: true,
      },
    ],
  };
}

/**
 * A turn's (or a session's) stats, as `{ label, value, tone }` -- values come
 * formatted by the provider ("12.3s", "$0.04") and are drawn as they are.
 * Nil for none, so the Lua side draws nothing rather than an empty line.
 */
export function describeMetrics(
  metrics: any,
): { label: string; value: string; tone: string | null }[] | null {
  if (!Array.isArray(metrics) || metrics.length === 0) return null;
  const out = metrics
    .filter((m: any) => m && m.label != null && m.value != null)
    .map((m: any) => ({
      label: String(m.label),
      value: String(m.value),
      tone: m.tone && m.tone !== "default" ? String(m.tone) : null,
    }));
  return out.length > 0 ? out : null;
}
