interface EmbedParams {
  shareId: string;
  showTitle: boolean;
  showDescription: boolean;
  showFileHeaders: boolean;
  showPoweredBy: boolean;
  theme: string;
  fragmentIndex?: number;
}

export const generateEmbedId = (params: EmbedParams): string => {
  const paramsString = `${params.shareId}-${params.showTitle}-${params.showDescription}-${params.showFileHeaders}-${params.showPoweredBy}-${params.fragmentIndex ?? 'all'}`;
  
  let hash = 0;
  for (let i = 0; i < paramsString.length; i++) {
    const char = paramsString.charCodeAt(i);
    hash = ((hash << 5) - hash) + char;
    hash = hash & hash;
  }
  
  const hashStr = Math.abs(hash).toString(16).padStart(16, '0').slice(0, 16);
  return hashStr;
};

/**
 * The origin of the page that embeds this iframe, so resize messages go only to it.
 * Uses location.ancestorOrigins (Chrome, Safari) and falls back to the referrer
 * (Firefox). Returns null when neither is known.
 */
export const embedParentOrigin = (
  win: Pick<Window, 'location'> = window,
  referrer: string = document.referrer
): string | null => {
  const ancestors = (win.location as Location & { ancestorOrigins?: DOMStringList }).ancestorOrigins;
  if (ancestors && ancestors.length > 0 && ancestors[0] && ancestors[0] !== 'null') {
    return ancestors[0];
  }
  if (referrer) {
    try {
      const origin = new URL(referrer).origin;
      if (origin && origin !== 'null') return origin;
    } catch {
      // not a URL
    }
  }
  return null;
};
