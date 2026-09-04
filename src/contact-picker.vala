public class Mail.ContactPickerDialog : Adw.Dialog {
    public signal void contact_chosen (Recipient recipient);

    private ContactStore store;
    private Gtk.SearchEntry search;
    private Gtk.ListBox list;
    private Adw.StatusPage empty;
    private Gtk.Stack stack;
    private uint search_source;
    private uint search_generation;

    public ContactPickerDialog (ContactStore store) {
        Object (
            title: _("Address Book"),
            content_width: 420,
            content_height: 520
        );
        this.store = store;

        this.search = new Gtk.SearchEntry () {
            hexpand = true,
            placeholder_text = _("Search contacts"),
        };
        this.search.search_changed.connect (queue_search);

        var header = new Adw.HeaderBar ();
        header.set_title_widget (this.search);

        this.list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.SINGLE,
            hexpand = true,
            vexpand = true,
        };
        this.list.add_css_class ("navigation-sidebar");
        this.list.row_activated.connect (on_row_activated);

        var scrolled = new Gtk.ScrolledWindow () {
            hexpand = true,
            vexpand = true,
            child = this.list,
        };

        this.empty = new Adw.StatusPage () {
            icon_name = "x-office-address-book-symbolic",
            title = _("No Contacts"),
            description = _("Type a name or email to search the address book."),
        };

        this.stack = new Gtk.Stack ();
        this.stack.add_named (scrolled, "list");
        this.stack.add_named (this.empty, "empty");

        var view = new Adw.ToolbarView () {
            content = this.stack,
        };
        view.add_top_bar (header);
        this.child = view;

        Idle.add (() => {
            this.search.grab_focus ();
            run_search.begin ("");
            return Source.REMOVE;
        });
    }

    private void queue_search () {
        if (this.search_source != 0)
            Source.remove (this.search_source);
        this.search_source = Timeout.add (150, () => {
            this.search_source = 0;
            run_search.begin (this.search.text);
            return Source.REMOVE;
        });
    }

    private async void run_search (string needle) {
        var generation = ++this.search_generation;
        var hits = yield this.store.search (needle, 80, null);
        if (generation != this.search_generation)
            return;

        this.list.remove_all ();

        for (uint i = 0; i < hits.length; i++)
            this.list.append (new ContactPickRow (hits[i]));

        if (hits.length == 0) {
            this.empty.title = needle.strip ().length > 0 ? _("No Matching Contacts") : _("No Contacts");
            this.empty.description = needle.strip ().length > 0
                ? _("Try a different name or email address.")
                : _("Type a name or email to search the address book.");
            this.stack.visible_child_name = "empty";
        } else {
            this.stack.visible_child_name = "list";
        }
    }

    private void on_row_activated (Gtk.ListBoxRow row) {
        var pick = row as ContactPickRow;
        if (pick == null)
            return;
        this.contact_chosen (pick.hit.to_recipient ());
    }
}

private class Mail.ContactPickRow : Adw.ActionRow {
    public ContactHit hit;

    public ContactPickRow (ContactHit hit) {
        var title = hit.name.length > 0 && hit.name.down () != hit.email.down ()
            ? hit.name
            : hit.email;
        var subtitle = title != hit.email
            ? hit.email
            : (hit.from_book ? _("Address book") : _("Recent recipient"));
        Object (
            title: title,
            subtitle: subtitle,
            activatable: true,
            use_markup: false
        );
        this.hit = hit;
        add_prefix (new Gtk.Image.from_icon_name (
            hit.from_book ? "avatar-default-symbolic" : "document-open-recent-symbolic"
        ));
        if (!hit.from_book)
            tooltip_text = _("Recent recipient");
    }
}
