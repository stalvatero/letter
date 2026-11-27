/**
 * Preferences UI to review/remove compose “recent” addresses that are not
 * already in an address book (EDS / Graph contacts).
 */
public class Mail.CollectedAddressesDialog : Adw.Dialog {
    private ContactStore store;
    private Gtk.ListBox list;
    private Adw.StatusPage empty;
    private Gtk.Stack stack;
    private Gtk.SearchEntry search;
    private Gtk.Spinner spinner;
    private uint filter_source;
    private uint reload_generation;

    public CollectedAddressesDialog (ContactStore store) {
        Object (
            title: _("Recent addresses"),
            content_width: 460,
            content_height: 520
        );
        this.store = store;

        this.search = new Gtk.SearchEntry () {
            hexpand = true,
            placeholder_text = _("Filter addresses"),
        };
        this.search.search_changed.connect (queue_reload);

        this.spinner = new Gtk.Spinner () {
            spinning = true,
            visible = false,
        };

        var header = new Adw.HeaderBar ();
        header.set_title_widget (this.search);
        header.pack_end (this.spinner);

        this.list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.NONE,
            hexpand = true,
            vexpand = true,
        };
        this.list.add_css_class ("navigation-sidebar");

        var scrolled = new Gtk.ScrolledWindow () {
            hexpand = true,
            vexpand = true,
            child = this.list,
        };

        this.empty = new Adw.StatusPage () {
            icon_name = Utils.icon ("document-open-recent-symbolic"),
            title = _("No recent addresses"),
            description = _("Only addresses that are not already in your address books appear here. Letter gathers them from mail you send."),
        };

        var loading = new Adw.StatusPage () {
            icon_name = Utils.icon ("content-loading-symbolic"),
            title = _("Comparing with address books…"),
            description = _("Removing addresses that already exist in your contacts or organization directory (GAL)."),
        };

        this.stack = new Gtk.Stack ();
        this.stack.add_named (scrolled, "list");
        this.stack.add_named (this.empty, "empty");
        this.stack.add_named (loading, "loading");

        var view = new Adw.ToolbarView () {
            content = this.stack,
        };
        view.add_top_bar (header);
        this.child = view;

        Idle.add (() => {
            refresh_and_reload.begin ();
            this.search.grab_focus ();
            return Source.REMOVE;
        });
    }

    private void queue_reload () {
        if (this.filter_source != 0)
            Source.remove (this.filter_source);
        this.filter_source = Timeout.add (120, () => {
            this.filter_source = 0;
            fill_list ();
            return Source.REMOVE;
        });
    }

    private async void refresh_and_reload () {
        var generation = ++this.reload_generation;
        this.spinner.visible = true;
        this.spinner.spinning = true;
        this.stack.visible_child_name = "loading";
        try {
            yield this.store.refresh_book_email_index (null);
        } catch (Error e) {
            warning ("Collected addresses refresh: %s", e.message);
        }
        if (generation != this.reload_generation)
            return;
        this.spinner.visible = false;
        this.spinner.spinning = false;
        fill_list ();
    }

    private void fill_list () {
        var needle = this.search.text.strip ().down ();
        this.list.remove_all ();
        var hits = this.store.list_collected ();
        uint shown = 0;
        for (uint i = 0; i < hits.length; i++) {
            var hit = hits[i];
            if (needle.length > 0) {
                var name = (hit.name ?? "").down ();
                var email = (hit.email ?? "").down ();
                if (!name.contains (needle) && !email.contains (needle))
                    continue;
            }
            this.list.append (build_row (hit));
            shown++;
        }
        if (shown == 0 && needle.length == 0)
            this.stack.visible_child_name = "empty";
        else
            this.stack.visible_child_name = "list";
    }

    private Gtk.ListBoxRow build_row (ContactHit hit) {
        var row = new Gtk.ListBoxRow () {
            activatable = false,
        };
        var title_text = hit.name.length > 0 && hit.name.down () != hit.email.down ()
            ? hit.name
            : hit.email;
        var subtitle_text = title_text != hit.email
            ? hit.email
            : _("Recent recipient");

        var title = new Gtk.Label (title_text) {
            xalign = 0,
            hexpand = true,
            ellipsize = Pango.EllipsizeMode.END,
        };
        var subtitle = new Gtk.Label (subtitle_text) {
            xalign = 0,
            hexpand = true,
            ellipsize = Pango.EllipsizeMode.END,
        };
        subtitle.add_css_class ("dim-label");
        subtitle.add_css_class ("caption");

        var texts = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            hexpand = true,
            valign = Gtk.Align.CENTER,
        };
        texts.append (title);
        texts.append (subtitle);

        var email = hit.email;
        var remove = new Gtk.Button.from_icon_name (Utils.icon ("user-trash-symbolic")) {
            valign = Gtk.Align.CENTER,
            tooltip_text = _("Remove from suggestions"),
        };
        remove.add_css_class ("flat");
        remove.clicked.connect (() => {
            this.store.forget_collected (email);
            fill_list ();
        });

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10) {
            hexpand = true,
            valign = Gtk.Align.CENTER,
            margin_top = 6,
            margin_bottom = 6,
            margin_start = 12,
            margin_end = 8,
        };
        box.append (new Gtk.Image.from_icon_name (Utils.icon ("document-open-recent-symbolic")) {
            valign = Gtk.Align.CENTER,
        });
        box.append (texts);
        box.append (remove);
        row.child = box;
        return row;
    }
}
