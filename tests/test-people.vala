void main () {
    var account = new Mail.Account () {
        email = "me@example.org",
    };

    var incoming = message ("Ada Lovelace", "ada@example.org", "Me", "me@example.org,bob@example.org", false);
    var sent = message ("Me", "me@example.org", "Ada Lovelace, Bob", "ada@example.org,bob@example.org", true);
    var from_other_client = message ("Me", "me@example.org", "Bob", "bob@example.org", false);
    /* A header cache from before the People view: names only. */
    var old_cache = message ("Ada Lovelace", null, "Me", null, false);
    var old_sent = message ("Me", null, "Ada Lovelace", null, true);

    var index = new Mail.PeopleIndex (account);
    index.learn (incoming);
    index.learn (old_cache);

    assert_people (index.counterparts (incoming), { "ada@example.org" }, "incoming mail belongs to its sender, not to Cc");
    assert_people (index.counterparts (sent), { "ada@example.org", "bob@example.org" }, "sent mail belongs to each recipient");
    assert_people (index.counterparts (from_other_client), { "bob@example.org" }, "mail from your own address counts as sent");
    assert_people (index.counterparts (old_cache), { "ada@example.org" }, "names from old caches map to learned addresses");
    assert_people (index.counterparts (old_sent), { "ada@example.org" }, "recipient names from old caches map too");

    var unknown = message ("Grace Hopper", null, "Me", null, false);
    assert_people (index.counterparts (unknown), { "name:grace hopper" }, "unknown names keep a name key");
    assert (Mail.PeopleIndex.name_from_key ("name:grace hopper") == "grace hopper");
    assert (Mail.PeopleIndex.name_from_key ("ada@example.org") == null);

    assert (index.involves (sent, "bob@example.org"));
    assert (!index.involves (incoming, "bob@example.org"));

    assert (Mail.PeopleIndex.name_for (incoming, false) == "Ada Lovelace");
    assert (Mail.PeopleIndex.name_for (sent, true) == null);
    assert (Mail.PeopleIndex.name_for (from_other_client, true) == "Bob");
}

Mail.Message message (string from, string? from_address, string to, string? recipients, bool outgoing) {
    return new Mail.Message () {
        uid = "1",
        subject = "Hello",
        from = from,
        to = to,
        from_address = from_address,
        recipient_addresses = recipients,
        outgoing = outgoing,
    };
}

void assert_people (GenericArray<string> actual, string[] expected, string what) {
    var ok = actual.length == expected.length;
    for (uint i = 0; ok && i < actual.length; i++)
        ok = actual[i] == expected[i];
    if (!ok) {
        var got = new StringBuilder ();
        for (uint i = 0; i < actual.length; i++)
            got.append ((i > 0 ? ", " : "") + actual[i]);
        error ("%s: got [%s], expected [%s]", what, got.str, string.joinv (", ", expected));
    }
}
