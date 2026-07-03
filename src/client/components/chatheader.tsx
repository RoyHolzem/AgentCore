'use client';

import styles from '../styles/chatheader.module.css';

export function ChatHeader() {
  return (
    <header className={styles.header}>
      <div className={styles.brand}>
        <div className={styles.logo}>
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
            <path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z" />
          </svg>
        </div>
        <span className={styles.name}>AgentCore</span>
        <span className={styles.badge}>v2</span>
      </div>
      <div className={styles.pill}>
        <span className={styles.dot} />
        Online
      </div>
    </header>
  );
}
