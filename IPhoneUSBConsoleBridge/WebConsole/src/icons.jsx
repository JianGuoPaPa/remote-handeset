function Icon({ children, size = 20, className = '' }) {
  return (
    <svg
      aria-hidden="true"
      className={className}
      fill="none"
      height={size}
      viewBox="0 0 24 24"
      width={size}
    >
      {children}
    </svg>
  );
}

export function LockIcon(props) {
  return <Icon {...props}><rect x="5" y="10" width="14" height="10" rx="2" stroke="currentColor" strokeWidth="1.7"/><path d="M8.5 10V7.4a3.5 3.5 0 0 1 7 0V10" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round"/></Icon>;
}

export function HomeIcon(props) {
  return <Icon {...props}><path d="m3.5 11 8.5-7 8.5 7" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"/><path d="M5.5 10v9.5h13V10M9.5 19.5v-6h5v6" stroke="currentColor" strokeWidth="1.7" strokeLinejoin="round"/></Icon>;
}

export function FullscreenIcon(props) {
  return <Icon {...props}><path d="M8.5 4H4v4.5M15.5 4H20v4.5M8.5 20H4v-4.5M15.5 20H20v-4.5" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"/></Icon>;
}

export function PulseIcon(props) {
  return <Icon {...props}><path d="M3.5 12h3l2-5 3.4 10 2.6-7 1.7 2H21" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"/></Icon>;
}

export function ClockIcon(props) {
  return <Icon {...props}><circle cx="12" cy="12" r="8.5" stroke="currentColor" strokeWidth="1.7"/><path d="M12 7.5v5l3 1.8" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round"/></Icon>;
}

export function ShieldIcon(props) {
  return <Icon {...props}><path d="M12 3.2 19 6v5.3c0 4.5-2.7 7.5-7 9.5-4.3-2-7-5-7-9.5V6l7-2.8Z" stroke="currentColor" strokeWidth="1.7" strokeLinejoin="round"/><path d="m8.8 12 2 2 4.4-4.6" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"/></Icon>;
}

export function SpeakerIcon(props) {
  return <Icon {...props}><path d="M4 9.2v5.6h3.3l4.2 3.3V5.9L7.3 9.2H4Z" stroke="currentColor" strokeWidth="1.7" strokeLinejoin="round"/><path d="M15 9.1a4 4 0 0 1 0 5.8M17.8 6.6a7.4 7.4 0 0 1 0 10.8" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round"/></Icon>;
}

export function MicrophoneIcon(props) {
  return <Icon {...props}><rect x="8.2" y="3.5" width="7.6" height="11.3" rx="3.8" stroke="currentColor" strokeWidth="1.7"/><path d="M5.8 11.5a6.2 6.2 0 0 0 12.4 0M12 17.7v3M8.8 20.7h6.4" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round"/></Icon>;
}
