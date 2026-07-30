import * as React from "react";

export interface InspectorSection { title?: React.ReactNode; content?: React.ReactNode }

/** Trailing utility pane with optional tab strip and caps-labelled sections. */
export interface InspectorProps extends React.HTMLAttributes<HTMLElement> {
  tabs?: Array<string | { id: string; label: React.ReactNode }>;
  tab?: string;
  onTab?: (id: string) => void;
  sections?: InspectorSection[];
  width?: string;
  children?: React.ReactNode;
}

export function Inspector(props: InspectorProps): JSX.Element;
