import * as React from "react";

export interface PaletteItem { id: string; label: React.ReactNode; detail?: React.ReactNode; shortcut?: React.ReactNode }
export interface PaletteGroup { label?: React.ReactNode; items: PaletteItem[] }

/**
 * Spotlight-style floating search palette on the HUD material.
 * @startingPoint section="Chrome" subtitle="Spotlight-style command palette" viewport="700x420"
 */
export interface CommandPaletteProps extends React.HTMLAttributes<HTMLDivElement> {
  open?: boolean;
  query?: string;
  onQuery?: (value: string) => void;
  groups?: PaletteGroup[];
  selected?: string;
  onSelect?: (id: string) => void;
  footer?: React.ReactNode;
  width?: number | string;
}

export function CommandPalette(props: CommandPaletteProps): JSX.Element | null;
