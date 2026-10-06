/* ThreadIndex must return what the walk it replaces returns: the same
 * messages in the same order. walk () below is that walk, as
 * Window.related_thread_messages () does it over the folder lists. */
void main () {
    reply_in_sent ();
    cc_in_other_folder ();
    second_pass ();
    no_third_pass ();
    same_folder_and_uid ();
    hit_outside_walk ();
    random_lists ();
}

void reply_in_sent () {
    var hit = message ("INBOX", "1", 11);
    var reply = message ("Sent", "5", 12, { 11 });
    var other = message ("Sent", "6", 13);
    var lists = lists_of ({ hit }, { reply, other });
    assert_expand (lists, { hit }, { reply }, "your reply in Sent joins the thread");
}

void cc_in_other_folder () {
    var hit = message ("INBOX", "1", 11);
    hit.conversation_key = "cid:x";
    var cc = message ("Archive", "2", 0);
    cc.conversation_key = "cid:x";
    var lists = lists_of ({ hit }, { cc });
    assert_expand (lists, { hit }, { cc }, "a shared conversation key joins");
}

/* b only links to the hit through c, which comes after it in the walk. */
void second_pass () {
    var hit = message ("INBOX", "1", 11);
    var b = message ("Archive", "2", 22, { 33 });
    var c = message ("Sent", "3", 33, { 11 });
    var lists = lists_of ({ hit }, { b }, { c });
    assert_expand (lists, { hit }, { c, b }, "the second pass picks up what the first passed");
}

/* d → c → b → hit, each found only after the walk passed the next one. */
void no_third_pass () {
    var hit = message ("INBOX", "1", 11);
    var d = message ("Archive", "4", 44, { 33 });
    var c = message ("Archive", "3", 33, { 22 });
    var b = message ("Sent", "2", 22, { 11 });
    var lists = lists_of ({ hit }, { d, c }, { b });
    assert_expand (lists, { hit }, { b, c }, "two passes, not a full closure");
}

void same_folder_and_uid () {
    var hit = message ("INBOX", "1", 11);
    var twin = message ("INBOX", "1", 0, { 11 });
    var a = message ("Archive", "7", 0, { 11 });
    var b = message ("Archive", "7", 0, { 11 });
    var lists = lists_of ({ hit, twin }, { a, b });
    assert_expand (lists, { hit }, { a }, "folder and UID count once");
}

void hit_outside_walk () {
    var hit = message ("Search", "1", 11);
    var reply = message ("Sent", "5", 12, { 11 });
    var lists = lists_of ({ reply });
    assert_expand (lists, { hit }, { reply }, "hits not in the walk still find their threads");
}

void random_lists () {
    var random = new Rand.with_seed (7);
    for (int round = 0; round < 300; round++) {
        var lists = new GenericArray<GenericArray<Mail.Message>> ();
        var all = new GenericArray<Mail.Message> ();
        var folders = random.int_range (1, 6);
        var ids = random.int_range (2, 40);
        for (int f = 0; f < folders; f++) {
            var list = new GenericArray<Mail.Message> ();
            var count = random.int_range (0, 30);
            for (int i = 0; i < count; i++) {
                uint64[] refs = {};
                var nrefs = random.int_range (0, 3);
                for (int r = 0; r < nrefs; r++)
                    refs += (uint64) random.int_range (0, ids);
                var m = message (
                    "f%d".printf (random.int_range (0, folders)),
                    "%d".printf (random.int_range (0, 25)),
                    (uint64) random.int_range (0, ids),
                    refs
                );
                if (random.int_range (0, 4) == 0)
                    m.conversation_key = "cid:%d".printf (random.int_range (0, 5));
                else if (random.int_range (0, 6) == 0)
                    m.conversation_key = "";
                list.add (m);
                all.add (m);
            }
            /* The same list twice, as Gmail labels can show it. */
            lists.add (list);
            if (random.int_range (0, 8) == 0)
                lists.add (list);
        }
        var hits = new GenericArray<Mail.Message> ();
        for (uint i = 0; i < all.length; i++) {
            if (random.int_range (0, 10) == 0)
                hits.add (all[i]);
        }
        if (random.int_range (0, 3) == 0)
            hits.add (message ("f0", "99", (uint64) random.int_range (0, ids), { (uint64) random.int_range (0, ids) }));

        var index = new Mail.ThreadIndex (lists);
        assert_same (index.expand (hits), walk (lists, hits), "random lists, round %d".printf (round));
        /* The index is reused between lookups. */
        assert_same (index.expand (hits), walk (lists, hits), "random lists again, round %d".printf (round));
    }
}

GenericArray<Mail.Message> walk (GenericArray<GenericArray<Mail.Message>> lists, GenericArray<Mail.Message> hits) {
    var extras = new GenericArray<Mail.Message> ();
    var hashes = new HashTable<string, uint8> (str_hash, str_equal);
    var keys = new HashTable<string, uint8> (str_hash, str_equal);
    var skip = new HashTable<string, uint8> (str_hash, str_equal);
    for (uint i = 0; i < hits.length; i++) {
        remember (hits[i], hashes, keys);
        skip.set (Mail.ThreadIndex.flag_key (hits[i]), 1);
    }
    for (int pass = 0; pass < 2; pass++) {
        for (uint i = 0; i < lists.length; i++) {
            var list = lists[i];
            for (uint j = 0; j < list.length; j++) {
                var m = list[j];
                var id = Mail.ThreadIndex.flag_key (m);
                if (skip.contains (id))
                    continue;
                if (!shares (m, hashes, keys))
                    continue;
                skip.set (id, 1);
                extras.add (m);
                remember (m, hashes, keys);
            }
        }
    }
    return extras;
}

void remember (Mail.Message m, HashTable<string, uint8> hashes, HashTable<string, uint8> keys) {
    if (m.msgid_hash != 0)
        hashes.set (m.msgid_hash.to_string (), 1);
    var refs = m.msgid_refs;
    if (refs != null) {
        for (int i = 0; i < refs.length; i++) {
            if (refs[i] != 0)
                hashes.set (refs[i].to_string (), 1);
        }
    }
    if (m.conversation_key != null && m.conversation_key.length > 0)
        keys.set (m.conversation_key, 1);
}

bool shares (Mail.Message m, HashTable<string, uint8> hashes, HashTable<string, uint8> keys) {
    if (m.conversation_key != null && m.conversation_key.length > 0 && keys.contains (m.conversation_key))
        return true;
    if (m.msgid_hash != 0 && hashes.contains (m.msgid_hash.to_string ()))
        return true;
    var refs = m.msgid_refs;
    if (refs == null)
        return false;
    for (int i = 0; i < refs.length; i++) {
        if (refs[i] != 0 && hashes.contains (refs[i].to_string ()))
            return true;
    }
    return false;
}

Mail.Message message (string folder, string uid, uint64 hash, uint64[] refs = {}) {
    return new Mail.Message () {
        uid = uid,
        subject = "",
        folder_full_name = folder,
        msgid_hash = hash,
        msgid_refs = refs,
    };
}

GenericArray<GenericArray<Mail.Message>> lists_of (Mail.Message[] a, Mail.Message[]? b = null, Mail.Message[]? c = null) {
    var lists = new GenericArray<GenericArray<Mail.Message>> ();
    lists.add (array_of (a));
    if (b != null)
        lists.add (array_of (b));
    if (c != null)
        lists.add (array_of (c));
    return lists;
}

GenericArray<Mail.Message> array_of (Mail.Message[] messages) {
    var array = new GenericArray<Mail.Message> ();
    foreach (var m in messages)
        array.add (m);
    return array;
}

void assert_expand (
    GenericArray<GenericArray<Mail.Message>> lists,
    Mail.Message[] hits,
    Mail.Message[] expected,
    string label
) {
    var hit_list = array_of (hits);
    var expected_list = array_of (expected);
    assert_same (walk (lists, hit_list), expected_list, label + " (walk)");
    assert_same (new Mail.ThreadIndex (lists).expand (hit_list), expected_list, label);
}

void assert_same (GenericArray<Mail.Message> got, GenericArray<Mail.Message> expected, string label) {
    var same = got.length == expected.length;
    for (uint i = 0; same && i < got.length; i++)
        same = got[i] == expected[i];
    if (same)
        return;
    var text = new StringBuilder ();
    text.append_printf ("%s: got", label);
    for (uint i = 0; i < got.length; i++)
        text.append_printf (" %s", Mail.ThreadIndex.flag_key (got[i]).replace ("\n", "/"));
    text.append (", expected");
    for (uint i = 0; i < expected.length; i++)
        text.append_printf (" %s", Mail.ThreadIndex.flag_key (expected[i]).replace ("\n", "/"));
    error (text.str);
}
