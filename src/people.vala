/* People view: mail grouped by the people it was exchanged with, across all
 * folders of an account. Incoming mail belongs to its sender, mail you sent
 * belongs to each of its recipients. Being on Cc of someone else's mail does
 * not put it in your contact's view. */

public class Mail.Person : Object {
    public Folder folder { get; construct; }
    public string address { get; construct; }
    public int64 latest { get; set; }

    /* The entry above all people that shows every conversation. */
    public bool is_all { get; construct; }

    /* Set only when it really changed: bound rows follow its notify. */
    private string _name = "";
    private string folded_name = "";
    [CCode (notify = false)]
    public string name {
        get {
            return this._name;
        }
        set {
            if (this._name == value)
                return;
            this._name = value;
            this.folded_name = value.down ();
            notify_property ("name");
        }
    }

    /* What a rebuild gathers before it touches the person, so a regroup
     * that ends with the same name and date notifies nobody. */
    public string pending_name = "";
    public int64 pending_latest;

    public Person (string address, Folder folder) {
        Object (address: address, folder: folder, is_all: false);
    }

    public Person.all (Folder folder) {
        Object (address: "", folder: folder, is_all: true);
    }

    public bool has_email {
        get {
            return this.address.contains ("@");
        }
    }

    public string display_name {
        owned get {
            if (this.is_all)
                return this.folder.name;
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

    public void begin_update () {
        this.pending_name = "";
        this.pending_latest = 0;
    }

    /* Applies what a rebuild gathered. Returns whether the person's place
     * in the sorted list may have moved. */
    public bool commit_update () {
        var name = this.pending_name.length > 0
            ? this.pending_name
            : PeopleIndex.name_from_key (this.address) ?? "";
        var moved = false;
        if (name != this.name) {
            this.name = name;
            var old_key = this.sort_key;
            update_sort_key ();
            moved = old_key != this.sort_key;
        } else if (this.sort_key.length == 0) {
            update_sort_key ();
        }
        if (this.pending_latest != this.latest) {
            this.latest = this.pending_latest;
            moved = true;
        }
        if (this.folder.name != this.display_name)
            this.folder.name = this.display_name;
        return moved;
    }

    /* Most recent mail first, then by name. */
    public static int compare (Person a, Person b) {
        if (a.latest != b.latest)
            return a.latest < b.latest ? 1 : -1;
        return strcmp (a.sort_key, b.sort_key);
    }

    /* The needle is already stripped and lower case. */
    public bool matches (string needle) {
        if (needle.length == 0)
            return true;
        return this.folded_name.contains (needle) || this.address.contains (needle);
    }
}

/* The People sidebar's items: the All People entry on top, then the people,
 * filtered and sorted. Only the rows on screen exist; they follow each
 * person's notify instead of being refreshed one by one. */
public class Mail.PeopleModel : Object {
    public Gtk.SingleSelection selection { get; private set; }
    public Person? all { get; private set; }

    private ListStore all_store = new ListStore (typeof (Person));
    private ListStore people_store = new ListStore (typeof (Person));
    private HashTable<string, Person> by_address = new HashTable<string, Person> (str_hash, str_equal);
    private Gtk.CustomFilter filter;
    private Gtk.CustomSorter sorter;
    private string needle = "";

    construct {
        this.filter = new Gtk.CustomFilter (filter_person);
        this.sorter = new Gtk.CustomSorter ((a, b) => Person.compare ((Person) a, (Person) b));
        var filtered = new Gtk.FilterListModel (this.people_store, this.filter);
        var sorted = new Gtk.SortListModel (filtered, this.sorter);
        var parts = new ListStore (typeof (ListModel));
        parts.append (this.all_store);
        parts.append (sorted);
        this.selection = new Gtk.SingleSelection (new Gtk.FlattenListModel (parts)) {
            autoselect = false,
            can_unselect = true,
        };
    }

    private bool filter_person (Object item) {
        return ((Person) item).matches (this.needle);
    }

    public uint size {
        get {
            return this.by_address.size ();
        }
    }

    public Person? lookup (string address) {
        return this.by_address.get (address);
    }

    public Person ensure_all (Folder folder) {
        if (this.all == null) {
            this.all = new Person.all (folder);
            this.all_store.append (this.all);
        }
        return this.all;
    }

    /* Filters on what was typed; the needle is made once per change, not
     * once per person. */
    public void set_filter_text (string text) {
        var next = text.strip ().down ();
        if (next == this.needle)
            return;
        var change = Gtk.FilterChange.DIFFERENT;
        if (next.contains (this.needle))
            change = Gtk.FilterChange.MORE_STRICT;
        else if (this.needle.contains (next))
            change = Gtk.FilterChange.LESS_STRICT;
        this.needle = next;
        this.filter.changed (change);
    }

    /* Makes the list hold exactly the people in present, whose pending
     * name and date a rebuild has gathered. People already listed are
     * updated in place; the list is sorted again only when an order key
     * moved. */
    public void update (HashTable<string, Person> present) {
        uint i = this.people_store.get_n_items ();
        while (i > 0) {
            if (present.contains (((Person) this.people_store.get_item (i - 1)).address)) {
                i--;
                continue;
            }
            var end = i;
            while (i > 0 && !present.contains (((Person) this.people_store.get_item (i - 1)).address))
                i--;
            for (uint j = i; j < end; j++)
                this.by_address.remove (((Person) this.people_store.get_item (j)).address);
            this.people_store.splice (i, end - i, new Object[0]);
        }

        var moved = false;
        var renamed = false;
        var added = new GenericArray<Object> ();
        foreach (var person in present.get_values ()) {
            var old_name = person.name;
            var known = this.by_address.contains (person.address);
            if (person.commit_update () && known)
                moved = true;
            if (known) {
                renamed |= old_name != person.name;
            } else {
                this.by_address.set (person.address, person);
                added.add (person);
            }
        }
        if (renamed && this.needle.length > 0)
            this.filter.changed (Gtk.FilterChange.DIFFERENT);
        if (moved)
            this.sorter.changed (Gtk.SorterChange.DIFFERENT);
        if (added.length > 0)
            this.people_store.splice (this.people_store.get_n_items (), 0, added.data);
    }

    /* Where the person is in the list, or INVALID_LIST_POSITION when the
     * filter hides them. */
    public uint position_of (Person person) {
        var model = this.selection.model;
        var n = model.get_n_items ();
        for (uint i = 0; i < n; i++) {
            if (model.get_item (i) == person)
                return i;
        }
        return Gtk.INVALID_LIST_POSITION;
    }

    /* Selects the person without moving the view; null clears it. */
    public void select (Person? person) {
        if (person == null) {
            this.selection.unselect_all ();
            return;
        }
        if (this.selection.selected_item == person)
            return;
        var position = position_of (person);
        if (position == Gtk.INVALID_LIST_POSITION)
            this.selection.unselect_all ();
        else
            this.selection.selected = position;
    }

    public void clear () {
        this.people_store.remove_all ();
        this.all_store.remove_all ();
        this.by_address.remove_all ();
        this.all = null;
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

/* A row of the People sidebar. Rows are recycled by the list view: bind
 * hooks a row up to a person, unbind lets go of it again, so no person or
 * folder keeps a row it no longer shows alive. */
public class Mail.PersonRow : Gtk.Box {
    public Person? person { get; private set; }

    private Adw.Avatar avatar;
    private Gtk.Image icon;
    private Gtk.Label name_label;
    private Gtk.Label count_label;
    private ulong name_handler;
    private ulong unread_handler;

    construct {
        this.orientation = Gtk.Orientation.HORIZONTAL;
        this.spacing = 8;
        this.hexpand = true;
        this.valign = Gtk.Align.CENTER;
        add_css_class ("folder-row");
        add_css_class ("person-row");

        this.avatar = new Adw.Avatar (24, null, true);
        append (this.avatar);
        this.icon = new Gtk.Image () {
            pixel_size = 16,
            width_request = 24,
            visible = false,
        };
        this.icon.add_css_class ("folder-icon");
        append (this.icon);

        this.name_label = new Gtk.Label ("") {
            hexpand = true,
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.END,
            use_markup = false,
        };
        this.name_label.add_css_class ("folder-name");
        append (this.name_label);

        this.count_label = new Gtk.Label ("") {
            use_markup = false,
        };
        this.count_label.add_css_class ("folder-count");
        this.count_label.add_css_class ("numeric");
        append (this.count_label);
    }

    public void bind (Person person) {
        unbind ();
        this.person = person;
        this.avatar.visible = !person.is_all;
        this.icon.visible = person.is_all;
        if (person.is_all)
            this.icon.icon_name = person.folder.icon_name;
        /* Methods, disconnected in unbind: a closure holding the row would
         * keep it alive as long as the person. */
        this.name_handler = person.notify["name"].connect (on_name_changed);
        this.unread_handler = person.folder.notify["unread"].connect (on_unread_changed);
        update_name ();
        update_unread ();
    }

    public void unbind () {
        if (this.person == null)
            return;
        SignalHandler.disconnect (this.person, this.name_handler);
        SignalHandler.disconnect (this.person.folder, this.unread_handler);
        this.name_handler = 0;
        this.unread_handler = 0;
        this.person = null;
    }

    private void on_name_changed (Object object, ParamSpec pspec) {
        update_name ();
    }

    private void on_unread_changed (Object object, ParamSpec pspec) {
        update_unread ();
    }

    private void update_name () {
        var name = this.person.display_name;
        this.name_label.label = name;
        if (!this.person.is_all)
            this.avatar.text = name;
        this.tooltip_text = this.person.has_email ? this.person.address : null;
    }

    private void update_unread () {
        var unread = this.person.folder.unread;
        if (unread > 0)
            add_css_class ("unread");
        else
            remove_css_class ("unread");
        this.count_label.label = unread.to_string ();
        this.count_label.visible = unread > 0;
    }
}
