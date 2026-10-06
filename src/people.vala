/* People view: mail grouped by the people it was exchanged with, across all
 * folders of an account. Incoming mail belongs to its sender, mail you sent
 * belongs to each of its recipients. Being on Cc of someone else's mail does
 * not put it in your contact's view. */

public class Mail.Person : Object {
    public Folder folder { get; construct; }
    public string address { get; construct; }
    public string name { get; set; default = ""; }
    public int64 latest { get; set; }

    public Person (string address, Folder folder) {
        Object (address: address, folder: folder);
    }

    public bool has_email {
        get {
            return this.address.contains ("@");
        }
    }

    public string display_name {
        owned get {
            if (this.name.length > 0)
                return this.name;
            var at = this.address.index_of_char ('@');
            return at > 0 ? this.address.substring (0, at) : this.address;
        }
    }

    /* Collation key of the display name, made once per rebuild rather than
     * on every comparison of the sorted list. */
    private string sort_key = "";

    public void update_sort_key () {
        this.sort_key = this.display_name.collate_key ();
    }

    /* Most recent mail first, then by name. */
    public static int compare (Person a, Person b) {
        if (a.latest != b.latest)
            return a.latest < b.latest ? 1 : -1;
        return strcmp (a.sort_key, b.sort_key);
    }

    public bool matches (string needle) {
        if (needle.length == 0)
            return true;
        return this.name.down ().contains (needle) || this.address.contains (needle);
    }
}

public class Mail.PeopleIndex : Object {
    /* Mail without stored addresses (header caches from before the People
     * view) is keyed by display name until its folder is written again. */
    private const string NAME_PREFIX = "name:";

    private HashTable<string, uint8> own = new HashTable<string, uint8> (str_hash, str_equal);
    private HashTable<string, string> address_by_name = new HashTable<string, string> (str_hash, str_equal);

    public PeopleIndex (Account account) {
        if (account.email != null && account.email.length > 0)
            this.own.set (account.email.down (), 1);
    }

    public bool is_outgoing (Message message) {
        if (message.outgoing)
            return true;
        return message.from_address != null && this.own.contains (message.from_address);
    }

    /* Learn which address goes with which name, so mail from older caches
     * lands on the same person as mail with stored addresses. */
    public void learn (Message message) {
        if (message.from_address == null || message.from_address.length == 0)
            return;
        if (message.from == null || message.from.length == 0 || message.from.contains ("@"))
            return;
        var name = message.from.down ();
        if (!this.address_by_name.contains (name))
            this.address_by_name.set (name, message.from_address);
    }

    public GenericArray<string> counterparts (Message message) {
        var result = new GenericArray<string> ();
        if (is_outgoing (message)) {
            if (message.recipient_addresses != null && message.recipient_addresses.length > 0) {
                foreach (var address in message.recipient_addresses.split (",")) {
                    if (address.length > 0 && !this.own.contains (address))
                        add_unique (result, address);
                }
            } else if (message.to != null) {
                foreach (var name in message.to.split (", "))
                    add_unique (result, key_for_name (name));
            }
            return result;
        }

        if (message.from_address != null && message.from_address.length > 0)
            add_unique (result, message.from_address);
        else if (message.from != null && message.from.length > 0)
            add_unique (result, key_for_name (message.from));
        return result;
    }

    /* A name for a person, from the mail they sent, or from mail sent only
     * to them. */
    public static string? name_for (Message message, bool outgoing) {
        if (!outgoing) {
            var from = message.from ?? "";
            return from.length > 0 && !from.contains ("@") ? from : null;
        }
        var to = message.to ?? "";
        if (to.length == 0 || to.contains (", ") || to.contains ("@"))
            return null;
        return to;
    }

    private string key_for_name (string raw) {
        var name = raw.strip ();
        var lower = name.down ();
        if (lower.contains ("@") && !lower.contains (" "))
            return lower;
        var known = this.address_by_name.get (lower);
        if (known != null)
            return known;
        return NAME_PREFIX + lower;
    }

    public static string? name_from_key (string address) {
        return address.has_prefix (NAME_PREFIX) ? address.substring (NAME_PREFIX.length) : null;
    }

    private static void add_unique (GenericArray<string> list, string value) {
        for (uint i = 0; i < list.length; i++) {
            if (list[i] == value)
                return;
        }
        list.add (value);
    }
}

public class Mail.PersonRow : Gtk.ListBoxRow {
    public Person? person { get; construct; }
    public Folder folder { get; construct; }
    public signal void context_pressed (double x, double y);

    private Adw.Avatar avatar;
    private Gtk.Label name_label;
    private Gtk.Label count_label;
    private Gtk.GestureClick secondary_click;

    public PersonRow (Person person) {
        Object (person: person, folder: person.folder);
    }

    /* The entry above all people that shows every conversation. */
    public PersonRow.all (Folder folder) {
        Object (person: null, folder: folder);
    }

    construct {
        this.activatable = true;
        add_css_class ("folder-row");
        add_css_class ("person-row");

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            hexpand = true,
            valign = Gtk.Align.CENTER,
        };

        if (this.person != null) {
            this.avatar = new Adw.Avatar (24, null, true);
            box.append (this.avatar);
        } else {
            var icon = new Gtk.Image.from_icon_name (this.folder.icon_name) {
                pixel_size = 16,
                width_request = 24,
            };
            icon.add_css_class ("folder-icon");
            box.append (icon);
        }

        this.name_label = new Gtk.Label ("") {
            hexpand = true,
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.END,
            use_markup = false,
        };
        this.name_label.add_css_class ("folder-name");
        box.append (this.name_label);

        this.count_label = new Gtk.Label ("") {
            use_markup = false,
        };
        this.count_label.add_css_class ("folder-count");
        this.count_label.add_css_class ("numeric");
        box.append (this.count_label);

        this.child = box;

        /* A method handler, not a lambda: a closure holding the gesture and
         * the row would keep every replaced row alive. */
        this.secondary_click = new Gtk.GestureClick () {
            button = Gdk.BUTTON_SECONDARY,
        };
        this.secondary_click.pressed.connect (on_secondary_pressed);
        add_controller (this.secondary_click);

        update ();
    }

    private void on_secondary_pressed (int n_press, double x, double y) {
        context_pressed (x, y);
        this.secondary_click.set_state (Gtk.EventSequenceState.CLAIMED);
    }

    public void update () {
        if (this.person != null) {
            this.name_label.label = this.person.display_name;
            this.avatar.text = this.person.display_name;
            this.tooltip_text = this.person.has_email ? this.person.address : null;
        } else {
            this.name_label.label = this.folder.name;
        }

        if (this.folder.unread > 0)
            add_css_class ("unread");
        else
            remove_css_class ("unread");
        this.count_label.label = this.folder.unread.to_string ();
        this.count_label.visible = this.folder.unread > 0;
    }
}
