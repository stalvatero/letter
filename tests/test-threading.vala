void main () {
    assert_count (independent_same_subject (), 2, "same subject is not a thread");
    assert_count (rfc_reply_chain (), 1, "In-Reply-To joins a thread");
    assert_count (shared_conversation_key (), 1, "Conversation-ID joins a thread");
    assert_count (shared_conversation_key_different_subject (), 2, "Conversation-ID keeps different subjects apart");
    assert_count (reply_all_changed_subject (), 2, "Reply-all with new subject starts a new conversation");
    assert_count (reply_after_changed_subject (), 2, "Replies to the new subject stay with that conversation");
    assert_count (message_id_different_subject (), 2, "Message-ID links keep different subjects apart");
    assert_count (glued_re_without_space (), 1, "Re: without space still matches the original subject");
    assert_count (unrelated_archive_extra (), 1, "extra with same subject stays out");
    assert_count (linked_sent_extra (), 1, "extra with shared Message-ID joins");
    assert_count (placeholder_sent_copy (), 1, "local send matches the Sent copy");
    assert_count (two_real_sends (), 2, "two real sent messages stay apart");
    assert_norm ("RDS Os 21 Deco lista pdv", "rds os 21 deco lista pdv");
    assert_norm ("Re:RDS Os 21 Deco lista pdv", "rds os 21 deco lista pdv");
    assert_norm ("R: Re:RDS Os 21 Deco lista pdv", "rds os 21 deco lista pdv");
}

GenericArray<Mail.Conversation> independent_same_subject () {
    var a = message ("inbox", "1", "HR notice", 11);
    var b = message ("inbox", "2", "HR notice", 22);
    return Mail.Conversation.group (primary (a, b), null);
}

GenericArray<Mail.Conversation> rfc_reply_chain () {
    var a = message ("inbox", "1", "Meeting", 11);
    var b = message ("inbox", "2", "Re: Meeting", 22);
    b.msgid_refs = { 11 };
    return Mail.Conversation.group (primary (a, b), null);
}

GenericArray<Mail.Conversation> shared_conversation_key () {
    var a = message ("inbox", "1", "Meeting", 11);
    var b = message ("inbox", "2", "Meeting", 22);
    a.conversation_key = "cid:abc";
    b.conversation_key = "cid:abc";
    return Mail.Conversation.group (primary (a, b), null);
}

GenericArray<Mail.Conversation> shared_conversation_key_different_subject () {
    var a = message ("inbox", "1", "Os 24 Docò lista pdv", 11);
    var b = message ("inbox", "2", "Os 22 Docò lista pdv", 22);
    a.conversation_key = "cid:abc";
    b.conversation_key = "cid:abc";
    return Mail.Conversation.group (primary (a, b), null);
}

GenericArray<Mail.Conversation> reply_all_changed_subject () {
    var a = message ("inbox", "1", "Meeting notes", 11);
    var b = message ("inbox", "2", "Budget proposal", 22);
    b.msgid_refs = { 11 };
    b.conversation_key = "cid:meeting";
    a.conversation_key = "cid:meeting";
    return Mail.Conversation.group (primary (a, b), null);
}

GenericArray<Mail.Conversation> reply_after_changed_subject () {
    var a = message ("inbox", "1", "Meeting notes", 11);
    var b = message ("inbox", "2", "Budget proposal", 22);
    var c = message ("inbox", "3", "Re: Budget proposal", 33);
    a.conversation_key = "cid:meeting";
    b.conversation_key = "cid:meeting";
    c.conversation_key = "cid:meeting";
    b.msgid_refs = { 11 };
    c.msgid_refs = { 22, 11 };
    var grouped = Mail.Conversation.group (primary (a, b, c), null);
    assert (grouped.length == 2);
    for (uint i = 0; i < grouped.length; i++) {
        if (Mail.Conversation.normalize_subject (grouped[i].subject) == "budget proposal")
            assert (grouped[i].messages.length == 2);
        else
            assert (grouped[i].messages.length == 1);
    }
    return grouped;
}

GenericArray<Mail.Conversation> message_id_different_subject () {
    var a = message ("inbox", "1", "Original topic", 11);
    var b = message ("inbox", "2", "Totally different", 22);
    b.msgid_refs = { 11 };
    return Mail.Conversation.group (primary (a, b), null);
}

GenericArray<Mail.Conversation> glued_re_without_space () {
    var a = message ("inbox", "1", "RDS Os 21 Deco lista pdv", 11);
    var b = message ("inbox", "2", "Re:RDS Os 21 Deco lista pdv", 22);
    var c = message ("inbox", "3", "R: Re:RDS Os 21 Deco lista pdv", 33);
    b.msgid_refs = { 11 };
    c.msgid_refs = { 22, 11 };
    return Mail.Conversation.group (primary (a, b, c), null);
}

GenericArray<Mail.Conversation> unrelated_archive_extra () {
    var a = message ("inbox", "1", "HR notice", 11);
    var extra = message ("archive", "9", "HR notice", 99);
    return Mail.Conversation.group (primary (a), extras (extra));
}

GenericArray<Mail.Conversation> linked_sent_extra () {
    var a = message ("inbox", "1", "Meeting", 11);
    var extra = message ("sent", "9", "Re: Meeting", 99);
    extra.outgoing = true;
    extra.msgid_refs = { 11 };
    var grouped = Mail.Conversation.group (primary (a), extras (extra));
    assert (grouped.length == 1);
    assert (grouped[0].messages.length == 2);
    return grouped;
}

GenericArray<Mail.Conversation> placeholder_sent_copy () {
    var placeholder = message ("sent", "local-sent-1", "Hello", 0);
    placeholder.outgoing = true;
    placeholder.local_only = true;
    placeholder.date = 1000;
    var sent = message ("sent", "real-1", "Hello", 55);
    sent.outgoing = true;
    sent.date = 1010;
    return Mail.Conversation.group (primary (placeholder, sent), null);
}

GenericArray<Mail.Conversation> two_real_sends () {
    var a = message ("sent", "1", "Hello", 11);
    a.outgoing = true;
    a.date = 1000;
    var b = message ("sent", "2", "Hello", 22);
    b.outgoing = true;
    b.date = 1010;
    return Mail.Conversation.group (primary (a, b), null);
}

Mail.Message message (string folder, string uid, string subject, uint64 hash) {
    return new Mail.Message () {
        uid = uid,
        subject = subject,
        from = "hr@example.com",
        to = "me@example.com",
        list_address = "hr@example.com",
        date = 1,
        seen = true,
        folder_name = folder,
        folder_full_name = folder,
        msgid_hash = hash,
        msgid_refs = {},
    };
}

GenericArray<Mail.Message> primary (Mail.Message a, Mail.Message? b = null, Mail.Message? c = null) {
    var messages = new GenericArray<Mail.Message> ();
    messages.add (a);
    if (b != null)
        messages.add (b);
    if (c != null)
        messages.add (c);
    return messages;
}

GenericArray<Mail.Message> extras (Mail.Message message) {
    var messages = new GenericArray<Mail.Message> ();
    messages.add (message);
    return messages;
}

void assert_count (GenericArray<Mail.Conversation> conversations, uint expected, string label) {
    if (conversations.length == expected)
        return;
    error ("%s: expected %u conversations, got %u", label, expected, conversations.length);
}

void assert_norm (string raw, string expected) {
    var got = Mail.Conversation.normalize_subject (raw);
    if (got == expected)
        return;
    error ("normalize_subject(%s): expected '%s', got '%s'", raw, expected, got);
}
