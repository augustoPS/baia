import * as React from "react";

export interface TabItem { id: string; label: React.ReactNode; dirty?: boolean }

/** Document/window tab strip; the active tab lifts as a glass knob. */
export interface TabsProps extends React.HTMLAttributes<HTMLDivElement> {
  tabs?: TabItem[];
  value?: string;
  onChange?: (id: string) => void;
  onClose?: (id: string) => void;
  onNew?: () => void;
}

export function Tabs(props: TabsProps): JSX.Element;
