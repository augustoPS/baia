import * as React from "react";

export interface GroupedRow {
  id?: string;
  label: React.ReactNode;
  description?: React.ReactNode;
  /** Trailing control — Switch, PopUpButton, Button, Stepper. */
  control?: React.ReactNode;
}

/**
 * Settings-style grouped rows: label left, control right, hairlines between.
 * @startingPoint section="Surfaces" subtitle="Settings rows with trailing controls" viewport="700x260"
 */
export interface GroupedSectionProps extends React.HTMLAttributes<HTMLElement> {
  title?: React.ReactNode;
  footnote?: React.ReactNode;
  rows?: GroupedRow[];
  children?: React.ReactNode;
}

export function GroupedSection(props: GroupedSectionProps): JSX.Element;
