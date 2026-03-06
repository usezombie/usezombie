import { type ReactNode, useId } from "react";

type Props = {
  label?: string;
  green?: boolean;
  children: ReactNode;
};

export default function Terminal({ label, green, children }: Props) {
  const id = useId();
  const cls = ["z-terminal", green && "z-terminal--green"].filter(Boolean).join(" ");
  return (
    <pre className={cls} aria-label={label} aria-describedby={label ? undefined : id}>
      <code>{children}</code>
      {!label && <span id={id} className="sr-only">Code block</span>}
    </pre>
  );
}
