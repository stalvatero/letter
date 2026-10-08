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

    /* Names seen for this address while a rebuild gathers. A name the
     * person sent from this address wins over one you addressed them by;
     * names that cannot be the same person (a shared or group address)
     * leave the address shown instead. */
    private NameChoice from_them = new NameChoice ();
    private NameChoice from_you = new NameChoice ();

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
            return this.name.length > 0 ? this.name : this.address;
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
        this.from_them.reset ();
        this.from_you.reset ();
    }

    /* Offers a name for this address, from mail they sent from it or from
     * mail you sent to it alone. */
    public void offer_name (string name, int64 date, bool sent_by_them) {
        (sent_by_them ? this.from_them : this.from_you).offer (name, date);
        if (this.from_them.offered)
            this.pending_name = this.from_them.result;
        else
            this.pending_name = this.from_you.result;
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

/* The name to show for one address. The newest name wins while all names
 * seen could be the same person ("Ada Lovelace", "Lovelace, Ada", "Ada");
 * names that cannot be, as on a group or shared address that many people
 * write from, give no name at all. */
private class Mail.NameChoice {
    public bool offered;
    public string result = "";
    private int64 date;
    private bool mixed;
    private string[] words = {};

    public void reset () {
        this.offered = false;
        this.result = "";
        this.date = 0;
        this.mixed = false;
        this.words = {};
    }

    public void offer (string name, int64 date) {
        /* Most mail repeats the name already chosen. */
        if (this.offered && !this.mixed && name == this.result) {
            if (date > this.date)
                this.date = date;
            return;
        }
        var words = name_words (name);
        if (words.length == 0)
            return;
        if (!this.offered) {
            this.offered = true;
            this.words = words;
            this.date = date;
            this.result = name;
            return;
        }
        if (this.mixed)
            return;
        if (!contains_all (this.words, words) && !contains_all (words, this.words)) {
            this.mixed = true;
            this.result = "";
            return;
        }
        if (words.length > this.words.length)
            this.words = words;
        if (date >= this.date) {
            this.date = date;
            this.result = name;
        }
    }

    private static string[] name_words (string name) {
        string[] words = {};
        var word = new StringBuilder ();
        unichar c;
        for (int i = 0; name.get_next_char (ref i, out c);) {
            if (c.isalnum ()) {
                word.append_unichar (c.tolower ());
            } else if (word.len > 0) {
                words += word.str;
                word.truncate ();
            }
        }
        if (word.len > 0)
            words += word.str;
        return words;
    }

    private static bool contains_all (string[] words, string[] wanted) {
        foreach (var word in wanted) {
            if (!(word in words))
                return false;
        }
        return true;
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
    /* Mail without stored addresses (header caches that are not written
     * again yet) is keyed by display name. */
    private const string NAME_PREFIX = "name:";

    private HashTable<string, uint8> own = new HashTable<string, uint8> (str_hash, str_equal);
    /* The one address each sender name was seen with; "" once it was seen
     * with several, as on group and shared addresses. */
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

    /* Learn which address goes with which name, so mail without stored
     * addresses lands on that person, unless the name is not theirs alone. */
    public void learn (Message message) {
        if (message.from_address == null || message.from_address.length == 0)
            return;
        if (message.from == null || message.from.length == 0 || message.from.contains ("@"))
            return;
        var name = message.from.strip ().down ();
        var known = this.address_by_name.get (name);
        if (known == null)
            this.address_by_name.set (name, message.from_address);
        else if (known != message.from_address)
            this.address_by_name.set (name, "");
    }

    /* People are their addresses; every message belongs to someone. Mail
     * without stored addresses goes to the one address its name was seen
     * with, or to a person of that name alone. */
    public GenericArray<string> counterparts (Message message) {
        var result = new GenericArray<string> ();
        if (is_outgoing (message)) {
            if (message.recipient_addresses != null && message.recipient_addresses.length > 0) {
                foreach (var address in message.recipient_addresses.split (",")) {
                    if (address.length > 0 && !this.own.contains (address))
                        add_unique (result, address);
                }
            } else if (message.to != null) {
                foreach (var name in message.to.split (", ")) {
                    if (name.strip ().length > 0)
                        add_unique (result, key_for_name (name));
                }
            }
            return result;
        }

        if (message.from_address != null && message.from_address.length > 0)
            add_unique (result, message.from_address);
        else if (message.from != null && message.from.length > 0)
            add_unique (result, key_for_name (message.from));
        return result;
    }

    private string key_for_name (string raw) {
        var lower = raw.strip ().down ();
        if (lower.contains ("@") && !lower.contains (" "))
            return lower;
        var known = this.address_by_name.get (lower);
        if (known != null && known.length > 0)
            return known;
        return NAME_PREFIX + lower;
    }

    public static string? name_from_key (string address) {
        return address.has_prefix (NAME_PREFIX) ? address.substring (NAME_PREFIX.length) : null;
    }

    /* The name a message gives the person at address, if it gives one for
     * certain: the sender's own name on mail from that address, or the
     * name you wrote to them by when they were the only recipient. Names
     * relayed for someone else ("Ada via Team") belong to no address. */
    public static string? name_for (Message message, string address, bool outgoing) {
        string name;
        if (outgoing) {
            if (message.recipient_addresses != null && message.recipient_addresses.length > 0
                ? message.recipient_addresses != address
                : name_key (message.to) != address)
                return null;
            name = message.to ?? "";
        } else {
            if (message.from_address != null && message.from_address.length > 0
                ? message.from_address != address
                : name_key (message.from) != address)
                return null;
            name = message.from ?? "";
        }
        name = name.strip ();
        if (name.length == 0 || name.contains ("@"))
            return null;
        var folded = name.down ();
        if (folded.contains (" via ") || folded.contains (" on behalf of "))
            return null;
        return name;
    }

    private static string name_key (string? name) {
        return NAME_PREFIX + (name ?? "").strip ().down ();
    }

    private static void add_unique (GenericArray<string> list, string value) {
        for (uint i = 0; i < list.length; i++) {
            if (list[i] == value)
                return;
        }
        list.add (value);
    }
}

/* Where People rows find a photo for an address: the address book. */
public interface Mail.PhotoSource : Object {
    public signal void photos_changed ();

    public abstract Gdk.Texture? photo_for (string email);
}

/* A row of the People sidebar. Rows are recycled by the list view: bind
 * hooks a row up to a person, unbind lets go of it again, so no person or
 * folder keeps a row it no longer shows alive. */
public class Mail.PersonRow : Gtk.Box {
    public Person? person { get; private set; }
    public PhotoSource? contacts { get; construct; }

    private Adw.Avatar avatar;
    private Gtk.Image icon;
    private Gtk.Label name_label;
    private Gtk.Label address_label;
    private Gtk.Label count_label;
    private ulong name_handler;
    private ulong unread_handler;
    private ulong photos_handler;

    public PersonRow (PhotoSource? contacts = null) {
        Object (contacts: contacts);
    }

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
        this.address_label = new Gtk.Label ("") {
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.MIDDLE,
            use_markup = false,
            visible = false,
        };
        this.address_label.add_css_class ("caption");
        this.address_label.add_css_class ("dim-label");
        var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            hexpand = true,
            valign = Gtk.Align.CENTER,
        };
        labels.append (this.name_label);
        labels.append (this.address_label);
        append (labels);

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
        if (this.contacts != null)
            this.photos_handler = this.contacts.photos_changed.connect (update_photo);
        update_name ();
        update_photo ();
        update_unread ();
    }

    public void unbind () {
        if (this.person == null)
            return;
        SignalHandler.disconnect (this.person, this.name_handler);
        SignalHandler.disconnect (this.person.folder, this.unread_handler);
        if (this.photos_handler != 0)
            SignalHandler.disconnect (this.contacts, this.photos_handler);
        this.name_handler = 0;
        this.unread_handler = 0;
        this.photos_handler = 0;
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
        /* The address under the name says which address the row is; a row
         * without a name already shows it as the name. */
        this.address_label.label = this.person.address;
        this.address_label.visible = this.person.name.length > 0 && this.person.has_email;
        if (!this.person.is_all)
            this.avatar.text = name;
        this.tooltip_text = this.person.has_email ? this.person.address : null;
    }

    private void update_photo () {
        if (this.person.is_all)
            return;
        this.avatar.custom_image = this.contacts != null && this.person.has_email
            ? this.contacts.photo_for (this.person.address)
            : null;
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
