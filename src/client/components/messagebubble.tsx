'use client';

import { memo } from 'react';
import type { ChatMessage } from '../lib/stream';
import styles from '../styles/messagebubble.module.css';

interface Props {
  message: ChatMessage;
}

function MessageBubbleBase({ message }: Props) {
  if (message.role === 'user') {
    return (
      <div className={`${styles.row} ${styles.rowUser}`}>
        <div className={`${styles.bubble} ${styles.bubbleUser}`}>
          {message.content}
        </div>
      </div>
    );
  }

  return (
    <div className={styles.row}>
      <div className={`${styles.bubble} ${message.isError ? styles.bubbleError : styles.bubbleAssistant}`}>
        {message.content}
      </div>
    </div>
  );
}

export const MessageBubble = memo(MessageBubbleBase);
