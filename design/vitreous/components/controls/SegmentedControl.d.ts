import * as React from "react";

export interface Segment { id: string; label: React.ReactNode }

/** Inline single-choice picker; the selected segment lifts as a glass knob. */
export interface SegmentedControlProps extends React.HTMLAttributes<HTMLDivElement> {
  items?: Array<string | Segment>;
  value?: string;
  onChange?: (id: string) => void;
  size?: "small" | "regular" | "large";
  fullWidth?: boolean;
}

export function SegmentedControl(props: SegmentedControlProps): JSX.Element;
