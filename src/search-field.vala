public class Mail.SearchField : Gtk.Widget {
    public signal void query_changed ();
    public signal void stopped ();

    private Gtk.Box bar;
    private Adw.WrapBox flow;
    private Gtk.Text input;
    private Gtk.Button clear_button;
    private Gtk.Popover? suggest_popover;
    private Gtk.ScrolledWindow suggest_scrolled;
    private Gtk.ListBox suggest_list;
    private ContactStore? contacts;
    private GenericArray<Chip> chips = new GenericArray<Chip> ();
    private uint suggest_source;
    private string suggest_shown_key = "";
    private string placeholder = _("Search");
    private bool suppressing;

    private const int SUGGEST_ROW_HEIGHT = 44;
    private const int SUGGEST_CHROME = 8;
    private const int SUGGEST_MAX_HEIGHT = 240;
    private const int SUGGEST_MIN_WIDTH = 240;
    private const int SUGGEST_MAX_WIDTH = 360;
    private const int INPUT_WIDTH_CHARS = 6;

    private class NoBaselineLayout : Gtk.LayoutManager {
        public override Gtk.SizeRequestMode get_request_mode (Gtk.Widget widget) {
            var child = widget.get_first_child ();
            return child != null ? child.get_request_mode () : Gtk.SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure (
            Gtk.Widget widget,
            Gtk.Orientation orientation,
            int for_size,
            out int minimum,
            out int natural,
            out int minimum_baseline,
            out int natural_baseline
        ) {
            var child = widget.get_first_child ();
            if (child == null) {
                minimum = 0;
                natural = 0;
                minimum_baseline = -1;
                natural_baseline = -1;
                return;
            }
            int ignored_min;
            int ignored_nat;
            child.measure (
                orientation,
                for_size,
                out minimum,
                out natural,
                out ignored_min,
                out ignored_nat
            );
            minimum_baseline = -1;
            natural_baseline = -1;
        }

        public override void allocate (Gtk.Widget widget, int width, int height, int baseline) {
            var child = widget.get_first_child ();
            child?.allocate (width, height, -1, null);
        }
    }

    private class Chip {
        public SearchClause clause;
        public Gtk.Widget widget;
        public Gtk.Box holder;
    }

    private class SuggestItem : Gtk.ListBoxRow {
        public SearchFilterKind kind;
        public string display;
        public string folded;
        public bool is_operator;

        public SuggestItem.operator (SearchFilterKind kind, string needle) {
            this.kind = kind;
            this.display = needle;
            this.folded = needle.casefold ();
            this.is_operator = true;
            string icon;
            string subtitle;
            switch (kind) {
                case SearchFilterKind.FROM:
                    icon = "avatar-default-symbolic";
                    subtitle = _("Search sender");
                    break;
                case SearchFilterKind.TO:
                    icon = "mail-replied-symbolic";
                    subtitle = _("Search recipients");
                    break;
                default:
                    icon = "system-search-symbolic";
                    subtitle = _("Search everywhere");
                    break;
            }
            build (icon, SearchQuery.kind_suggestion (kind, needle), subtitle);
        }

        public SuggestItem.contact (ContactHit hit) {
            this.kind = SearchFilterKind.TEXT;
            this.display = hit.name.length > 0 ? hit.name : hit.email;
            this.folded = (hit.email.length > 0 ? hit.email : hit.name).casefold ();
            this.is_operator = false;
            var title = this.display;
            var subtitle = title != hit.email && hit.email.length > 0
                ? hit.email
                : (hit.from_book ? _("Address book") : _("Recent recipient"));
            build (
                hit.from_book ? "avatar-default-symbolic" : "document-open-recent-symbolic",
                title,
                subtitle
            );
        }

        private void build (string icon, string title_text, string subtitle_text) {
            this.activatable = true;
            this.can_focus = false;
            this.focusable = false;
            this.focus_on_click = false;

            var title = new Gtk.Label (title_text) {
                xalign = 0,
                hexpand = true,
                ellipsize = Pango.EllipsizeMode.END,
                single_line_mode = true,
                wrap = false,
                use_markup = false,
            };
            var subtitle = new Gtk.Label (subtitle_text) {
                xalign = 0,
                hexpand = true,
                ellipsize = Pango.EllipsizeMode.END,
                single_line_mode = true,
                wrap = false,
                use_markup = false,
            };
            subtitle.add_css_class ("dim-label");
            subtitle.add_css_class ("caption");

            var texts = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
                hexpand = true,
                valign = Gtk.Align.CENTER,
            };
            texts.append (title);
            texts.append (subtitle);

            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10) {
                hexpand = true,
                valign = Gtk.Align.CENTER,
            };
            box.add_css_class ("search-suggest-row");
            box.append (new Gtk.Image.from_icon_name (icon) {
                valign = Gtk.Align.CENTER,
            });
            box.append (texts);
            this.child = box;
        }
    }

    static construct {
        set_layout_manager_type (typeof (NoBaselineLayout));
        set_css_name ("entry");
    }

    construct {
        hexpand = false;
        vexpand = false;
        valign = Gtk.Align.FILL;
        add_css_class ("search");
        add_css_class ("mail-search-field");

        this.bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4) {
            hexpand = true,
            vexpand = true,
            valign = Gtk.Align.FILL,
        };
        this.bar.set_parent (this);

        var icon = new Gtk.Image.from_icon_name ("system-search-symbolic") {
            valign = Gtk.Align.CENTER,
            can_target = false,
        };
        icon.add_css_class ("dim-label");

        this.flow = new Adw.WrapBox () {
            hexpand = true,
            vexpand = false,
            valign = Gtk.Align.CENTER,
            halign = Gtk.Align.FILL,
            child_spacing = 4,
            line_spacing = 2,
            justify = Adw.JustifyMode.NONE,
            line_homogeneous = false,
            wrap_policy = Adw.WrapPolicy.NATURAL,
        };
        this.flow.add_css_class ("mail-search-flow");

        this.input = new Gtk.Text () {
            hexpand = true,
            hexpand_set = true,
            vexpand = false,
            valign = Gtk.Align.CENTER,
            width_chars = INPUT_WIDTH_CHARS,
            max_width_chars = INPUT_WIDTH_CHARS,
            propagate_text_width = false,
            placeholder_text = this.placeholder,
        };
        this.input.add_css_class ("mail-search-input");
        this.input.activate.connect (on_activate);
        this.input.notify["text"].connect (on_input_text);
        var input_keys = new Gtk.EventControllerKey ();
        input_keys.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        input_keys.key_pressed.connect (on_input_key);
        this.input.add_controller (input_keys);
        this.input.notify["has-focus"].connect (() => {
            if (this.input.has_focus)
                return;
            Timeout.add (200, () => {
                if (this.input.has_focus)
                    return Source.REMOVE;
                hide_suggest ();
                return Source.REMOVE;
            });
        });

        this.clear_button = new Gtk.Button.from_icon_name ("edit-clear-symbolic") {
            valign = Gtk.Align.CENTER,
            tooltip_text = _("Clear search"),
            can_focus = false,
            focusable = false,
            visible = false,
        };
        this.clear_button.add_css_class ("flat");
        this.clear_button.add_css_class ("mail-search-clear");
        this.clear_button.clicked.connect (on_clear_clicked);

        this.flow.append (this.input);
        this.bar.append (icon);
        this.bar.append (this.flow);
        this.bar.append (this.clear_button);

        var click = new Gtk.GestureClick ();
        click.released.connect (() => {
            this.input.grab_focus ();
        });
        add_controller (click);
        sync_chrome ();
    }

    public override void dispose () {
        this.bar?.unparent ();
        this.bar = null;
        base.dispose ();
    }

    public string placeholder_text {
        get {
            return this.placeholder;
        }
        set {
            this.placeholder = value ?? "";
            sync_chrome ();
        }
    }

    public override bool grab_focus () {
        return this.input.grab_focus ();
    }

    public void bind_contacts (ContactStore? store) {
        this.contacts = store;
        store?.warm ();
    }

    public SearchQuery query () {
        var query = new SearchQuery ();
        for (uint i = 0; i < this.chips.length; i++)
            query.add_clause (copy_clause (this.chips[i].clause));
        return query.merge_text (this.input.text);
    }

    public void clear () {
        this.suppressing = true;
        hide_suggest ();
        while (this.chips.length > 0)
            remove_chip_at (this.chips.length - 1, false);
        this.input.text = "";
        this.suppressing = false;
        sync_chrome ();
    }

    private void on_clear_clicked () {
        clear ();
        this.input.grab_focus ();
        query_changed ();
    }

    private void on_activate () {
        if (suggest_is_open ()) {
            apply_selected_suggest ();
            return;
        }
        commit_operators (true);
        hide_suggest ();
    }

    private void on_input_text () {
        if (this.suppressing)
            return;

        if (ends_with_space (this.input.text))
            commit_operators (false);

        sync_chrome ();
        queue_suggest ();
        query_changed ();
    }

    private bool on_input_key (uint keyval, uint keycode, Gdk.ModifierType state) {
        var mods = state & Gtk.accelerator_get_default_mod_mask ();
        if (keyval == Gdk.Key.Escape) {
            if (suggest_is_open ()) {
                hide_suggest ();
                return true;
            }
            clear ();
            stopped ();
            return true;
        }
        if (keyval == Gdk.Key.Down || keyval == Gdk.Key.KP_Down) {
            if (suggest_is_open ()) {
                move_suggest (1);
                return true;
            }
            queue_suggest (true);
            return true;
        }
        if ((keyval == Gdk.Key.Up || keyval == Gdk.Key.KP_Up) && suggest_is_open ()) {
            move_suggest (-1);
            return true;
        }
        if ((keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter) && suggest_is_open ()) {
            apply_selected_suggest ();
            return true;
        }
        if (keyval == Gdk.Key.Tab && suggest_is_open () && (mods & Gdk.ModifierType.SHIFT_MASK) == 0) {
            apply_selected_suggest ();
            return true;
        }
        if ((keyval == Gdk.Key.BackSpace || keyval == Gdk.Key.Delete || keyval == Gdk.Key.KP_Delete)
            && this.input.text.length == 0 && this.chips.length > 0) {
            remove_chip_at (this.chips.length - 1, true);
            return true;
        }
        return false;
    }

    private void commit_operators (bool force) {
        if (!force && !ends_with_space (this.input.text))
            return;

        var parsed = SearchQuery.parse (this.input.text);
        if (parsed.is_empty)
            return;

        for (uint i = 0; i < parsed.clauses.length; i++)
            add_chip (parsed.clauses[i], false);

        SearchFilterKind incomplete;
        var leftover = SearchQuery.incomplete_prefix (this.input.text, out incomplete)
            ? last_live_prefix (this.input.text)
            : "";

        hide_suggest ();
        this.suppressing = true;
        this.input.text = leftover;
        this.suppressing = false;
        sync_chrome ();
        query_changed ();
    }

    private void add_chip (SearchClause clause, bool notify) {
        if (clause.folded.length == 0)
            return;

        var chip = new Chip ();
        chip.clause = copy_clause (clause);
        chip.widget = make_chip_widget (chip.clause);
        chip.holder = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) {
            hexpand = false,
            vexpand = false,
            valign = Gtk.Align.CENTER,
        };
        chip.holder.append (chip.widget);
        Gtk.Widget? after = this.chips.length > 0 ? this.chips[this.chips.length - 1].holder : null;
        this.flow.insert_child_after (chip.holder, after);
        this.chips.add (chip);
        if (notify)
            query_changed ();
        sync_chrome ();
    }

    private Gtk.Widget make_chip_widget (SearchClause clause) {
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 2) {
            valign = Gtk.Align.CENTER,
        };
        box.add_css_class ("search-chip");

        var label = new Gtk.Label (SearchQuery.chip_label (clause)) {
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 16,
            single_line_mode = true,
            use_markup = false,
        };
        var close = new Gtk.Button.from_icon_name ("window-close-symbolic") {
            valign = Gtk.Align.CENTER,
            can_focus = false,
            focusable = false,
            tooltip_text = _("Remove"),
        };
        close.add_css_class ("flat");
        close.add_css_class ("search-chip-close");
        close.clicked.connect (() => {
            for (uint i = 0; i < this.chips.length; i++) {
                if (this.chips[i].clause == clause || this.chips[i].widget == box) {
                    remove_chip_at (i, true);
                    break;
                }
            }
        });
        box.append (label);
        box.append (close);
        return box;
    }

    private void remove_chip_at (uint index, bool notify) {
        if (index >= this.chips.length)
            return;
        var chip = this.chips[index];
        this.flow.remove (chip.holder);
        this.chips.remove_index (index);
        sync_chrome ();
        if (notify) {
            this.input.grab_focus ();
            query_changed ();
        }
    }

    private void queue_suggest (bool immediate = false) {
        if (this.suggest_source != 0) {
            Source.remove (this.suggest_source);
            this.suggest_source = 0;
        }

        SearchFilterKind kind;
        string needle;
        bool prefixed;
        current_edit (out kind, out needle, out prefixed);
        if (needle.length == 0) {
            hide_suggest ();
            return;
        }

        if (immediate) {
            fill_suggest (kind, needle, prefixed);
            return;
        }

        this.suggest_source = Timeout.add (160, () => {
            this.suggest_source = 0;
            SearchFilterKind live_kind;
            string live_needle;
            bool live_prefixed;
            current_edit (out live_kind, out live_needle, out live_prefixed);
            if (live_needle.length == 0) {
                hide_suggest ();
                return Source.REMOVE;
            }
            fill_suggest (live_kind, live_needle, live_prefixed);
            return Source.REMOVE;
        });
    }

    private void current_edit (out SearchFilterKind kind, out string needle, out bool prefixed) {
        kind = SearchFilterKind.TEXT;
        needle = "";
        prefixed = false;

        if (SearchQuery.incomplete_prefix (this.input.text, out kind)) {
            prefixed = true;
            return;
        }

        var parsed = SearchQuery.parse (this.input.text);
        if (parsed.clauses.length == 0)
            return;

        var clause = parsed.clauses[parsed.clauses.length - 1];
        kind = clause.kind;
        needle = clause.display;
        prefixed = clause.kind != SearchFilterKind.TEXT;
    }

    private void fill_suggest (SearchFilterKind kind, string needle, bool prefixed) {
        ensure_suggest ();

        GenericArray<ContactHit>? hits = null;
        uint contact_n = 0;
        if (this.contacts != null && needle.length >= 2) {
            hits = this.contacts.search_collected (needle, 8);
            contact_n = hits.length;
        }

        var extra = prefixed ? 0 : 3;
        if (extra == 0 && contact_n == 0) {
            hide_suggest ();
            return;
        }

        var key = "%d:%s:%u:%u".printf ((int) kind, needle.casefold (), extra, contact_n);
        if (key == this.suggest_shown_key && this.suggest_popover.visible)
            return;

        this.suggest_list.remove_all ();
        if (extra > 0) {
            this.suggest_list.append (new SuggestItem.operator (SearchFilterKind.TEXT, needle));
            this.suggest_list.append (new SuggestItem.operator (SearchFilterKind.FROM, needle));
            this.suggest_list.append (new SuggestItem.operator (SearchFilterKind.TO, needle));
        }

        if (hits != null) {
            for (uint i = 0; i < hits.length; i++) {
                var item = new SuggestItem.contact (hits[i]);
                if (prefixed)
                    item.kind = kind;
                this.suggest_list.append (item);
            }
        }

        var first = this.suggest_list.get_row_at_index (0);
        if (first == null) {
            hide_suggest ();
            return;
        }

        this.suggest_shown_key = key;
        this.suggest_list.select_row (first);
        size_suggest ((uint) extra + contact_n);
        if (!this.suggest_popover.visible)
            this.suggest_popover.popup ();
        keep_entry_focus ();
    }

    private void size_suggest (uint shown) {
        var width = get_width ();
        if (width < SUGGEST_MIN_WIDTH)
            width = SUGGEST_MIN_WIDTH;
        if (width > SUGGEST_MAX_WIDTH)
            width = SUGGEST_MAX_WIDTH;

        var height = (int) shown * SUGGEST_ROW_HEIGHT + SUGGEST_CHROME;
        var scroll = height > SUGGEST_MAX_HEIGHT;
        if (scroll)
            height = SUGGEST_MAX_HEIGHT;

        this.suggest_scrolled.min_content_width = width;
        this.suggest_scrolled.max_content_width = width;
        this.suggest_scrolled.min_content_height = height;
        this.suggest_scrolled.max_content_height = height;
        this.suggest_scrolled.vscrollbar_policy = scroll
            ? Gtk.PolicyType.AUTOMATIC
            : Gtk.PolicyType.NEVER;
        this.suggest_popover.width_request = width;
        this.suggest_popover.set_pointing_to ({
            0,
            0,
            int.max (1, this.input.get_width ()),
            int.max (1, this.input.get_height ()),
        });
    }

    private void ensure_suggest () {
        if (this.suggest_popover != null)
            return;

        this.suggest_list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.SINGLE,
            hexpand = true,
            vexpand = false,
            valign = Gtk.Align.START,
            can_focus = false,
            focusable = false,
            focus_on_click = false,
        };
        this.suggest_list.add_css_class ("compose-suggest-list");
        this.suggest_list.row_activated.connect (on_suggest_activated);

        this.suggest_scrolled = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            vscrollbar_policy = Gtk.PolicyType.NEVER,
            propagate_natural_width = true,
            propagate_natural_height = true,
            hexpand = true,
            can_focus = false,
            focusable = false,
            child = this.suggest_list,
        };

        this.suggest_popover = new Gtk.Popover () {
            autohide = false,
            has_arrow = false,
            can_focus = false,
            focusable = false,
            position = Gtk.PositionType.BOTTOM,
            child = this.suggest_scrolled,
        };
        this.suggest_popover.add_css_class ("compose-suggest-popover");
        this.suggest_popover.set_parent (this.input);
    }

    private void on_suggest_activated (Gtk.ListBoxRow row) {
        var item = row as SuggestItem;
        if (item == null)
            return;
        apply_suggest (item);
    }

    private void apply_selected_suggest () {
        var row = this.suggest_list != null ? this.suggest_list.get_selected_row () : null;
        var item = row as SuggestItem;
        if (item == null)
            return;
        apply_suggest (item);
    }

    private void apply_suggest (SuggestItem item) {
        hide_suggest ();
        drop_last_token ();
        add_chip (new SearchClause () {
            kind = item.is_operator || item.kind != SearchFilterKind.TEXT
                ? item.kind
                : SearchFilterKind.TEXT,
            display = item.display,
            folded = item.folded,
        }, true);
        this.input.grab_focus ();
    }

    private void drop_last_token () {
        var text = this.input.text;
        int i = text.length;
        unichar c;
        while (i > 0) {
            var prev = i;
            text.get_prev_char (ref prev, out c);
            if (!c.isspace ())
                break;
            i = prev;
        }
        while (i > 0) {
            var prev = i;
            text.get_prev_char (ref prev, out c);
            if (c.isspace ())
                break;
            i = prev;
        }
        this.suppressing = true;
        this.input.text = text.substring (0, i);
        this.suppressing = false;
    }

    private void move_suggest (int delta) {
        if (this.suggest_list == null)
            return;
        var current = this.suggest_list.get_selected_row ();
        int index = current != null ? current.get_index () : -1;
        var next = this.suggest_list.get_row_at_index (index + delta);
        if (next == null)
            return;
        this.suggest_list.select_row (next);
        next.grab_focus ();
        keep_entry_focus ();
    }

    private bool suggest_is_open () {
        return this.suggest_popover != null && this.suggest_popover.visible;
    }

    private void hide_suggest () {
        if (this.suggest_source != 0) {
            Source.remove (this.suggest_source);
            this.suggest_source = 0;
        }
        this.suggest_shown_key = "";
        this.suggest_popover?.popdown ();
    }

    private void keep_entry_focus () {
        if (!this.input.has_focus)
            this.input.grab_focus_without_selecting ();
    }

    private void sync_chrome () {
        this.input.placeholder_text = this.chips.length == 0 ? this.placeholder : "";
        this.clear_button.visible = this.chips.length > 0 || this.input.text.length > 0;
    }

    private static string last_live_prefix (string text) {
        var token = text.strip ();
        var space = token.last_index_of_char (' ');
        if (space >= 0)
            token = token.substring (space + 1).strip ();
        return token;
    }

    private static bool ends_with_space (string text) {
        if (text.length == 0)
            return false;
        unichar c;
        var i = text.length;
        text.get_prev_char (ref i, out c);
        return c.isspace ();
    }

    private static SearchClause copy_clause (SearchClause clause) {
        return new SearchClause () {
            kind = clause.kind,
            folded = clause.folded,
            display = clause.display,
        };
    }
}
