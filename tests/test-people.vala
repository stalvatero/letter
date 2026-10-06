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

    assert (Mail.PeopleIndex.name_for (incoming, false) == "Ada Lovelace");
    assert (Mail.PeopleIndex.name_for (sent, true) == null);
    assert (Mail.PeopleIndex.name_for (from_other_client, true) == "Bob");

    check_removed_row_is_freed ();
}

class RowWatch : Object {
    public bool finalized;

    public void on_finalized (Object row) {
        this.finalized = true;
    }

    public void on_context_pressed (Mail.PersonRow row, double x, double y) {
    }
}

/* People who no longer have mail leave the list. A row that is still alive
 * once it is out of the list is memory that never comes back. */
void check_removed_row_is_freed () {
    if (!Gtk.init_check ()) {
        print ("people: no display, row lifetime not checked\n");
        return;
    }

    var folder = new Mail.Folder () {
        name = "Ada Lovelace",
        full_name = Mail.Folder.PERSON_PREFIX + "ada@example.org",
    };
    var list = new Gtk.ListBox ();
    var watch = new RowWatch ();
    var row = new Mail.PersonRow (new Mail.Person ("ada@example.org", folder));
    row.weak_ref (watch.on_finalized);
    row.context_pressed.connect (watch.on_context_pressed);
    list.append (row);
    list.remove (row);
    row = null;
    if (!watch.finalized)
        error ("a person row removed from the list is never freed");
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
