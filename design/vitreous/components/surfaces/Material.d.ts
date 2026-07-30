import * as React from "react";

/**
 * The primitive every glass surface is built from: translucent fill + lensed
 * blur + bright top rim + dark bottom rim, with optional specular sheen and
 * refraction highlight. Pick the material by role, not by look.
 * @startingPoint section="Surfaces" subtitle="Eight materials, four elevations" viewport="700x300"
 */
export interface MaterialProps extends React.HTMLAttributes<HTMLElement> {
  material?: "ultraThin" | "thin" | "regular" | "thick" | "chrome" | "sidebar" | "menu" | "hud";
  /** CSS length or radius token. */
  radius?: string;
  pad?: number | string;
  elevation?: "none" | "control" | "raised" | "popover" | "sheet" | "window";
  sheen?: boolean;
  refract?: boolean;
  rim?: "strong" | "soft" | "none";
  /** Animated specular sweep — only visible under [data-motion="high"]. */
  sweep?: boolean;
  as?: keyof JSX.IntrinsicElements;
  children?: React.ReactNode;
}

export function Material(props: MaterialProps): JSX.Element;
