import * as React from "react";

/** Continuous value with an accent-filled track and a white knob. */
export interface SliderProps extends React.HTMLAttributes<HTMLDivElement> {
  value?: number;
  min?: number;
  max?: number;
  step?: number;
  onChange?: (value: number) => void;
  /** Number of tick marks drawn under the track (0 = none). */
  ticks?: number;
  label?: React.ReactNode;
  valueLabel?: React.ReactNode;
}

export function Slider(props: SliderProps): JSX.Element;
