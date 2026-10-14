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
    assert_people (index.counterparts (old_cache), { "ada@example.org" }, "names from old caches map to the address seen with them");
    assert_people (index.counterparts (old_sent), { "ada@example.org" }, "recipient names from old caches map too");

    var unknown = message ("Grace Hopper", null, "Me", null, false);
    assert_people (index.counterparts (unknown), { "name:grace hopper" }, "mail without an address still has a person");
    assert (index.name_for (unknown, "name:grace hopper", false) == "Grace Hopper");

    /* A name seen on several addresses is nobody's alone. */
    index.learn (message ("Mario Nardiello", "mario@example.org", "Me", "me@example.org", false));
    index.learn (message ("Mario Nardiello", "team@example.org", "Me", "me@example.org", false));
    var old_mario = message ("Mario Nardiello", null, "Me", null, false);
    assert_people (index.counterparts (old_mario), { "name:mario nardiello" }, "a shared name maps to no address");

    check_own_addresses ();
    check_contacts ();
    check_names ();
    check_people_model ();
    check_unbound_row_is_freed ();
}

/* Your aliases and the addresses you sent from are you, not people. */
void check_own_addresses () {
    var account = new Mail.Account () {
        email = "me@example.org",
    };
    var index = new Mail.PeopleIndex (account, { "alias@example.org" });
    index.learn (message ("Me", "old@example.net", "Ada Lovelace", "ada@example.org", true));

    var to_old = message ("Me", "alias@example.org", "Me", "old@example.net,ada@example.org", false);
    assert (index.is_outgoing (to_old));
    assert_people (index.counterparts (to_old), { "ada@example.org" }, "mail between your own addresses has no person of you");
    var from_old = message ("Me", "old@example.net", "Bob", "bob@example.org", false);
    assert_people (index.counterparts (from_old), { "bob@example.org" }, "an address you sent from counts as yours");
}

/* One contact is one person, whichever of its addresses the mail used;
 * the same name on another address is still someone else. */
void check_contacts () {
    var account = new Mail.Account () {
        email = "me@example.org",
    };
    var index = new Mail.PeopleIndex (account, {}, new TwoAddressBook ());
    var work = message ("Ada Lovelace", "ada@example.org", "Me", "me@example.org", false);
    var home = message ("Ada L.", "ada@home.example", "Me", "me@example.org", false);
    var namesake = message ("Ada Lovelace", "ada@other.example", "Me", "me@example.org", false);
    var both = message ("Me", "me@example.org", "Ada", "ada@example.org,ada@home.example", true);
    assert_people (index.counterparts (work), { "ada@example.org" }, "a contact's address is its person");
    assert_people (index.counterparts (home), { "ada@example.org" }, "a contact's other address is the same person");
    assert_people (index.counterparts (namesake), { "ada@other.example" }, "a name alone does not join a contact");
    assert_people (index.counterparts (both), { "ada@example.org" }, "mail to two addresses of one contact counts once");
    assert (index.name_for (home, "ada@example.org", false) == "Ada L.");

    var from_old = message ("Me", "me@old.example", "Bob", "bob@example.org", false);
    assert (index.is_outgoing (from_old));
    assert_people (index.counterparts (from_old), { "bob@example.org" }, "your own contact's addresses are yours");
}

/* Names come only from mail tied to the address, and a shared address
 * whose mail carries several people's names shows the address. */
void check_names () {
    var index = new Mail.PeopleIndex (new Mail.Account () { email = "me@example.org" });
    var incoming = message ("Ada Lovelace", "ada@example.org", "Me", "me@example.org", false);
    assert (index.name_for (incoming, "ada@example.org", false) == "Ada Lovelace");
    assert (index.name_for (incoming, "team@example.org", false) == null);

    /* You wrote to Mario with a group on Cc: the group is not Mario. */
    var with_cc = message ("Me", "me@example.org", "Mario Nardiello", "mario@example.org,team@example.org", true);
    assert (index.name_for (with_cc, "team@example.org", true) == null);
    assert (index.name_for (with_cc, "mario@example.org", true) == null);
    var alone = message ("Me", "me@example.org", "Mario Nardiello", "mario@example.org", true);
    assert (index.name_for (alone, "mario@example.org", true) == "Mario Nardiello");

    var relayed = message ("Mario Nardiello via Team", "team@example.org", "Me", "me@example.org", false);
    assert (index.name_for (relayed, "team@example.org", false) == null);
    var surname_first = message ("Nardiello, Mario", "mario@example.org", "Me", "me@example.org", false);
    assert (index.name_for (surname_first, "mario@example.org", false) == "Nardiello, Mario");

    var mario = new Mail.Person ("mario@example.org", new Mail.Folder ());
    mario.begin_update ();
    mario.offer_name ("Mario", 1, false);
    mario.offer_name ("Nardiello, Mario", 2, true);
    mario.offer_name ("Mario Nardiello", 3, true);
    mario.offer_name ("Mario N.", 4, false);
    mario.commit_update ();
    assert_name (mario, "Mario Nardiello", "the newest of one person's own names wins over yours");

    var team = new Mail.Person ("team@example.org", new Mail.Folder ());
    team.begin_update ();
    team.offer_name ("Mario Nardiello", 1, true);
    team.offer_name ("Grace Hopper", 2, true);
    team.offer_name ("Mario Nardiello", 3, true);
    team.offer_name ("Team", 4, false);
    team.commit_update ();
    assert_name (team, "team@example.org", "an address many people write from shows the address");

    var quiet = new Mail.Person ("noreply@example.org", new Mail.Folder ());
    quiet.begin_update ();
    quiet.commit_update ();
    assert_name (quiet, "noreply@example.org", "no name shows the whole address");
}

void assert_name (Mail.Person person, string expected, string what) {
    if (person.display_name != expected)
        error ("%s: got \"%s\", expected \"%s\"", what, person.display_name, expected);
}

class NoPhotos : Object, Mail.ContactSource {
    public Gdk.Texture? photo_for (string email) {
        return null;
    }

    public string? contact_key_for (string email) {
        return null;
    }
}

/* An address book with Ada under two addresses, and you under an old one. */
class TwoAddressBook : Object, Mail.ContactSource {
    public Gdk.Texture? photo_for (string email) {
        return null;
    }

    public string? contact_key_for (string email) {
        switch (email) {
            case "ada@example.org":
            case "ada@home.example":
                return "ada@example.org";
            case "me@example.org":
            case "me@old.example":
                return "me@example.org";
            default:
                return null;
        }
    }
}

class RowWatch : Object {
    public bool finalized;

    public void on_finalized (Object row) {
        this.finalized = true;
    }

    public void on_changed (uint position, uint removed, uint added) {
        this.changes++;
    }

    public void on_notify (Object object, ParamSpec pspec) {
        this.notifies++;
    }

    public uint changes;
    public uint notifies;
}

Mail.Person person (Mail.PeopleModel model, string address, string name, int64 latest) {
    var known = model.lookup (address);
    var result = known ?? new Mail.Person (address, new Mail.Folder () {
        full_name = Mail.Folder.PERSON_PREFIX + address,
    });
    result.begin_update ();
    result.pending_name = name;
    result.pending_latest = latest;
    return result;
}

HashTable<string, Mail.Person> people (Mail.Person[] list) {
    var result = new HashTable<string, Mail.Person> (str_hash, str_equal);
    foreach (var item in list)
        result.set (item.address, item);
    return result;
}

void assert_order (Mail.PeopleModel model, string[] expected, string what) {
    var model_items = model.selection.model;
    var got = new StringBuilder ();
    for (uint i = 0; i < model_items.get_n_items (); i++) {
        var item = (Mail.Person) model_items.get_item (i);
        got.append ((i > 0 ? ", " : "") + (item.is_all ? "all" : item.address));
    }
    var want = string.joinv (", ", expected);
    if (got.str != want)
        error ("%s: got [%s], expected [%s]", what, got.str, want);
}

/* The sidebar model: All People on top, then the most recent people, and a
 * rebuild that changes nothing touches nothing. */
void check_people_model () {
    var model = new Mail.PeopleModel ();
    model.ensure_all (new Mail.Folder () {
        name = "All People",
        full_name = Mail.Folder.PEOPLE_PATH,
    });
    model.update (people ({
        person (model, "ada@example.org", "Ada", 1),
        person (model, "bob@example.org", "Bob", 3),
        person (model, "cy@example.org", "", 2),
    }));
    assert_order (model, { "all", "bob@example.org", "cy@example.org", "ada@example.org" }, "newest first, All People on top");
    assert (model.lookup ("cy@example.org").display_name == "cy@example.org");

    var watch = new RowWatch ();
    model.selection.items_changed.connect (watch.on_changed);
    var ada = model.lookup ("ada@example.org");
    ada.notify.connect (watch.on_notify);
    model.update (people ({
        person (model, "ada@example.org", "Ada", 1),
        person (model, "bob@example.org", "Bob", 3),
        person (model, "cy@example.org", "", 2),
    }));
    if (watch.changes != 0 || watch.notifies != 0)
        error ("an unchanged rebuild changed the list %u times and notified %u times", watch.changes, watch.notifies);

    model.update (people ({
        person (model, "ada@example.org", "Ada Lovelace", 5),
        person (model, "bob@example.org", "Bob", 3),
    }));
    assert_order (model, { "all", "ada@example.org", "bob@example.org" }, "newer mail moves up, people without mail leave");
    assert (watch.notifies > 0);
    assert (model.size == 2);
    assert (model.lookup ("cy@example.org") == null);

    var bob = model.lookup ("bob@example.org");
    model.select (bob);
    assert (model.selection.selected == 2);
    model.set_filter_text ("  LOVE ");
    assert_order (model, { "all", "ada@example.org" }, "the filter matches names, ignoring case and spaces");
    model.select (bob);
    assert (model.selection.selected == Gtk.INVALID_LIST_POSITION);
    model.set_filter_text ("bob@");
    assert_order (model, { "all", "bob@example.org" }, "the filter matches addresses");
    model.set_filter_text ("");
    assert_order (model, { "all", "ada@example.org", "bob@example.org" }, "an empty filter shows everyone");

    model.select (model.all);
    assert (model.selection.selected == 0);
    model.clear ();
    assert (model.selection.model.get_n_items () == 0);
    assert (model.all == null);
}

/* Rows are recycled; once unbound, a row must not be kept alive by the
 * person or folder it showed. */
void check_unbound_row_is_freed () {
    if (!Gtk.init_check ()) {
        print ("people: no display, row lifetime not checked\n");
        return;
    }

    var folder = new Mail.Folder () {
        name = "Ada Lovelace",
        full_name = Mail.Folder.PERSON_PREFIX + "ada@example.org",
    };
    var ada = new Mail.Person ("ada@example.org", folder);
    var photos = new NoPhotos ();
    var watch = new RowWatch ();
    var row = new Mail.PersonRow (photos);
    row.weak_ref (watch.on_finalized);
    row.bind (ada);
    ada.name = "Ada";
    folder.unread = 2;
    photos.contacts_changed ();
    row.unbind ();
    row = null;
    if (!watch.finalized)
        error ("an unbound person row is never freed");
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
