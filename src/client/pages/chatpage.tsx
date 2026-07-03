'use client';

import { useChat } from '../hooks/usechat';
import { ChatHeader } from '../components/chatheader';
import { MessageBubble } from '../components/messagebubble';
import { TypingIndicator } from '../components/typingindicator';
import { ChatInput } from '../components/chatinput';
import { EmptyState } from '../components/emptystate';
import shellStyles from '../styles/chatapp.module.css';

export default function ChatPage() {
  const { messages, loading, send, scrollRef } = useChat();

  const isEmpty = messages.length === 0;
  const showTyping = loading &&
    messages.length > 0 &&
    messages[messages.length - 1].content === '';

  return (
    <div className={shellStyles.shell}>
      <ChatHeader />

      <div className={shellStyles.messages}>
        {isEmpty && <EmptyState />}
        {messages.map((msg, i) => (
          <MessageBubble key={i} message={msg} />
        ))}
        {showTyping && <TypingIndicator />}
        <div ref={scrollRef} />
      </div>

      <div className={shellStyles.inputZone}>
        <ChatInput onSend={send} disabled={loading} />
      </div>
    </div>
  );
}
