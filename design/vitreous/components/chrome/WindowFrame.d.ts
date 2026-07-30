import * as React from "react";

/**
 * App window: rounded 11px corners, traffic lights, unified titlebar/toolbar on the
 * chrome material, optional sidebar (its titlebar segment is transparent to the
 * sidebar), optional inspector, tab strip and status bar.
 * @startingPoint section="Chrome" subtitle="Full window with sidebar, toolbar, status bar" viewport="900x560"
 */
export interface WindowFrameProps extends React.HTMLAttributes<HTMLDivElement> {
  title?: React.ReactNode;
  subtitle?: React.ReactNode;
  /** Toolbar content — usually <Toolbar>. */
  toolbar?: React.ReactNode;
  sidebar?: React.ReactNode;
  sidebarWidth?: string;
  inspector?: React.ReactNode;
  tabs?: React.ReactNode;
  statusBar?: React.ReactNode;
  /** Renders the window as background/unfocused. */
  inactive?: boolean;
  radius?: string;
  children?: React.ReactNode;
}

export function WindowFrame(props: WindowFrameProps): JSX.Element;
