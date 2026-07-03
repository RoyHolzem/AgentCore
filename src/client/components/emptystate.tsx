'use client';

import styles from '../styles/emptystate.module.css';

export function EmptyState() {
  return (
    <div className={styles.container}>
      <div className={styles.logoBig}>
        <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z" />
        </svg>
      </div>
      <h2 className={styles.title}>AgentCore</h2>
      <p className={styles.subtitle}>Your AI workspace, powered by Bedrock.</p>
      <div className={styles.hints}>
        <div className={styles.hint}>What can you do?</div>
        <div className={styles.hint}>Run a shell command</div>
        <div className={styles.hint}>Read a file</div>
      </div>
    </div>
  );
}
