public class Mail.SearchField : Gtk.Widget {
    public signal void query_changed ();
    public signal void activated ();
    public signal void stopped ();

    private Gtk.Box bar;
    private Gtk.Box flow;
    private Gtk.ScrolledWindow flow_scrolled;
    private Gtk.Text input;
    private Gtk.Button clear_button;
    private Gtk.Popover? suggest_popover;
    private Gtk.ScrolledWindow suggest_scrolled;
    private Gtk.ListBox suggest_list;
    private ContactStore? contacts;
    private GenericArray<Chip> chips = new GenericArray<Chip> ();
    /* -1 = typing in the input; otherwise the chip under keyboard focus. */
    private int selected_chip_index = -1;
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
                    icon = Utils.icon ("avatar-default-symbolic");
                    subtitle = _("Search sender");
                    break;
                case SearchFilterKind.TO:
                    icon = Utils.icon ("mail-replied-symbolic");
                    subtitle = _("Search recipients");
                    break;
                default:
                    icon = Utils.icon ("system-search-symbolic");
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
                hit.from_book ? Utils.icon ("avatar-default-symbolic") : Utils.icon ("document-open-recent-symbolic"),
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
        valign = Gtk.Align.CENTER;
        add_css_class ("search");

        this.bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4) {
            hexpand = true,
            vexpand = false,
            valign = Gtk.Align.CENTER,
        };
        this.bar.set_parent (this);

        var icon = new Gtk.Image.from_icon_name (Utils.icon ("system-search-symbolic")) {
            valign = Gtk.Align.CENTER,
            can_target = false,
        };
        icon.add_css_class ("dim-label");

        this.flow = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4) {
            hexpand = false,
            vexpand = false,
            valign = Gtk.Align.CENTER,
        };
        this.flow.add_css_class ("mail-search-flow");

        /* EXTERNAL: swipe / wheel scroll, never show a scrollbar (Apple Mail–like). */
        this.flow_scrolled = new Gtk.ScrolledWindow () {
            hexpand = true,
            vexpand = false,
            height_request = 24,
            min_content_width = 0,
            min_content_height = 24,
            max_content_height = 24,
            hscrollbar_policy = Gtk.PolicyType.EXTERNAL,
            vscrollbar_policy = Gtk.PolicyType.NEVER,
            overlay_scrolling = true,
            propagate_natural_width = false,
            propagate_natural_height = false,
            child = this.flow,
        };
        this.flow_scrolled.add_css_class ("mail-search-flow-scroll");

        /* Grow with typed text; overflow pans via EXTERNAL scroll, not a 6-char clip. */
        this.input = new Gtk.Text () {
            hexpand = false,
            hexpand_set = true,
            vexpand = false,
            valign = Gtk.Align.CENTER,
            width_chars = INPUT_WIDTH_CHARS,
            max_width_chars = 80,
            propagate_text_width = true,
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
            if (this.input.has_focus) {
                this.has_tooltip = false;
                return;
            }
            this.has_tooltip = this.tooltip_text != null && this.tooltip_text.length > 0;
            Timeout.add (200, () => {
                if (this.input.has_focus)
                    return Source.REMOVE;
                hide_suggest ();
                return Source.REMOVE;
            });
        });

        this.clear_button = new Gtk.Button.from_icon_name (Utils.icon ("edit-clear-symbolic")) {
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
        this.bar.append (this.flow_scrolled);
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
        clear_chip_selection ();
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
        submit_query ();
    }

    /* Enter runs search with the live draft. Only From:/To: suggestions become
     * chips — free “contains” text stays editable (Apple Mail–like). */
    private void submit_query () {
        if (suggest_is_open ()) {
            var row = this.suggest_list != null
                ? this.suggest_list.get_selected_row () as SuggestItem
                : null;
            if (row != null && row.is_operator
                && (row.kind == SearchFilterKind.FROM || row.kind == SearchFilterKind.TO)) {
                apply_suggest (row);
                return;
            }
        }
        hide_suggest ();
        if (!query ().is_empty)
            activated ();
    }

    private void on_input_text () {
        if (this.suppressing)
            return;

        clear_chip_selection ();
        sync_chrome ();
        queue_suggest ();
        query_changed ();
        scroll_input_into_view ();
    }

    private bool on_input_key (uint keyval, uint keycode, Gdk.ModifierType state) {
        var mods = state & Gtk.accelerator_get_default_mod_mask ();
        if (keyval == Gdk.Key.Escape) {
            if (suggest_is_open ()) {
                hide_suggest ();
                return true;
            }
            if (this.selected_chip_index >= 0) {
                clear_chip_selection ();
                this.input.grab_focus ();
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
        if (keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter) {
            /* Consume Enter so Gtk.Text.activate does not double-submit. */
            submit_query ();
            return true;
        }
        if (keyval == Gdk.Key.Tab && suggest_is_open () && (mods & Gdk.ModifierType.SHIFT_MASK) == 0) {
            apply_selected_suggest ();
            return true;
        }
        if (keyval == Gdk.Key.Left || keyval == Gdk.Key.KP_Left) {
            if (navigate_chips (-1))
                return true;
        }
        if (keyval == Gdk.Key.Right || keyval == Gdk.Key.KP_Right) {
            if (navigate_chips (1))
                return true;
        }
        if ((keyval == Gdk.Key.BackSpace || keyval == Gdk.Key.Delete || keyval == Gdk.Key.KP_Delete)
            && this.chips.length > 0) {
            if (this.selected_chip_index >= 0) {
                remove_selected_chip ();
                return true;
            }
            if (this.input.text.length == 0) {
                remove_chip_at (this.chips.length - 1, true);
                return true;
            }
        }
        return false;
    }

    private bool navigate_chips (int delta) {
        if (this.chips.length == 0)
            return false;

        if (this.selected_chip_index >= 0) {
            var next = this.selected_chip_index + delta;
            if (next < 0)
                return true;
            if (next >= (int) this.chips.length) {
                clear_chip_selection ();
                this.input.grab_focus ();
                ((Gtk.Editable) this.input).set_position (0);
                return true;
            }
            select_chip_at ((uint) next);
            return true;
        }

        /* From the input: Left at the caret start jumps onto the last chip. */
        if (delta < 0 && ((Gtk.Editable) this.input).cursor_position == 0) {
            select_chip_at (this.chips.length - 1);
            return true;
        }
        return false;
    }

    private void clear_chip_selection () {
        if (this.selected_chip_index >= 0 && this.selected_chip_index < (int) this.chips.length)
            this.chips[this.selected_chip_index].widget.remove_css_class ("selected");
        this.selected_chip_index = -1;
    }

    private void select_chip_at (uint index) {
        if (index >= this.chips.length)
            return;
        clear_chip_selection ();
        this.selected_chip_index = (int) index;
        this.chips[index].widget.add_css_class ("selected");
        ensure_chip_visible (index);
    }

    private void ensure_chip_visible (uint index) {
        if (index >= this.chips.length)
            return;
        var holder = this.chips[index].holder;
        Graphene.Rect bounds;
        if (!holder.compute_bounds (this.flow, out bounds))
            return;
        var adj = this.flow_scrolled.hadjustment;
        var start = bounds.origin.x;
        var end = start + bounds.size.width;
        if (start < adj.value)
            adj.value = start;
        else if (end > adj.value + adj.page_size)
            adj.value = end - adj.page_size;
    }

    private void remove_selected_chip () {
        if (this.selected_chip_index < 0 || this.selected_chip_index >= (int) this.chips.length)
            return;
        var index = (uint) this.selected_chip_index;
        var next = index;
        clear_chip_selection ();
        remove_chip_at (index, false);
        if (this.chips.length == 0) {
            this.input.grab_focus ();
        } else if (next < this.chips.length) {
            select_chip_at (next);
        } else {
            select_chip_at (this.chips.length - 1);
        }
        query_changed ();
        emit_chip_search ();
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
        /* Insert before the trailing input so chips stay left-aligned. */
        this.flow.insert_child_after (chip.holder, this.input.get_prev_sibling ());
        this.chips.add (chip);
        Idle.add (() => {
            /* Keep the left edge of the chip row visible — do not jump past it. */
            this.flow_scrolled.hadjustment.value = 0;
            return Source.REMOVE;
        });
        if (notify)
            query_changed ();
        sync_chrome ();
    }

    private void scroll_input_into_view () {
        Idle.add (() => {
            Graphene.Rect bounds;
            if (!this.input.compute_bounds (this.flow, out bounds))
                return Source.REMOVE;
            var adj = this.flow_scrolled.hadjustment;
            var start = bounds.origin.x;
            var end = start + bounds.size.width;
            if (end > adj.value + adj.page_size)
                adj.value = end - adj.page_size;
            else if (start < adj.value)
                adj.value = start;
            return Source.REMOVE;
        });
    }

    private Gtk.Widget make_chip_widget (SearchClause clause) {
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 2) {
            hexpand = false,
            vexpand = false,
            valign = Gtk.Align.CENTER,
            halign = Gtk.Align.START,
        };
        box.add_css_class ("search-chip");

        /* Full text; the chip row scrolls horizontally when space is tight. */
        var label = new Gtk.Label (SearchQuery.chip_label (clause)) {
            ellipsize = Pango.EllipsizeMode.NONE,
            single_line_mode = true,
            use_markup = false,
            valign = Gtk.Align.CENTER,
            hexpand = false,
        };
        var close = new Gtk.Button.from_icon_name (Utils.icon ("window-close-symbolic")) {
            valign = Gtk.Align.CENTER,
            can_focus = false,
            focusable = false,
            has_frame = false,
            tooltip_text = _("Remove"),
        };
        close.add_css_class ("flat");
        close.add_css_class ("search-chip-close");
        close.add_css_class ("dim-label");
        close.clicked.connect (() => {
            for (uint i = 0; i < this.chips.length; i++) {
                if (this.chips[i].clause == clause || this.chips[i].widget == box) {
                    if (this.selected_chip_index == (int) i)
                        clear_chip_selection ();
                    else if (this.selected_chip_index > (int) i)
                        this.selected_chip_index--;
                    remove_chip_at (i, true);
                    break;
                }
            }
        });
        var click = new Gtk.GestureClick ();
        click.pressed.connect (() => {
            for (uint i = 0; i < this.chips.length; i++) {
                if (this.chips[i].widget == box) {
                    select_chip_at (i);
                    this.input.grab_focus ();
                    break;
                }
            }
        });
        box.add_controller (click);
        box.append (label);
        box.append (close);
        return box;
    }

    private void remove_chip_at (uint index, bool notify) {
        if (index >= this.chips.length)
            return;
        if (this.selected_chip_index == (int) index)
            this.selected_chip_index = -1;
        else if (this.selected_chip_index > (int) index)
            this.selected_chip_index--;
        var chip = this.chips[index];
        this.flow.remove (chip.holder);
        this.chips.remove_index (index);
        sync_chrome ();
        if (notify) {
            this.input.grab_focus ();
            query_changed ();
            emit_chip_search ();
        }
    }

    private void emit_chip_search () {
        if (query ().is_empty)
            return;
        activated ();
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

        var stripped = this.input.text.strip ();
        if (stripped.length == 0)
            return;

        if (SearchQuery.has_filter_operators (this.input.text)) {
            var parsed = SearchQuery.parse (this.input.text);
            if (parsed.clauses.length == 0)
                return;
            var clause = parsed.clauses[parsed.clauses.length - 1];
            kind = clause.kind;
            needle = clause.display;
            prefixed = clause.kind != SearchFilterKind.TEXT;
            return;
        }

        kind = SearchFilterKind.TEXT;
        needle = stripped;
        prefixed = false;
    }

    private void fill_suggest (SearchFilterKind kind, string needle, bool prefixed) {
        ensure_suggest ();

        GenericArray<ContactHit>? hits = null;
        uint contact_n = 0;
        if (this.contacts != null && needle.length >= 2) {
            hits = this.contacts.search_collected (needle, 8);
            contact_n = hits.length;
        }

        /* From:/To: only for a single token — multi-word drafts are contains. */
        var party_ok = !prefixed && !contains_space (needle);
        var extra = prefixed ? 0 : (party_ok ? 3 : 1);
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
            if (party_ok) {
                this.suggest_list.append (new SuggestItem.operator (SearchFilterKind.FROM, needle));
                this.suggest_list.append (new SuggestItem.operator (SearchFilterKind.TO, needle));
            }
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
        /* Anchor to the whole search field so the menu sits under the chrome,
         * not mid-text / mid-chip. */
        this.suggest_popover.set_pointing_to ({
            0,
            0,
            int.max (1, get_width ()),
            int.max (1, get_height ()),
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
        this.suggest_popover.set_offset (0, 2);
        this.suggest_popover.set_parent (this);
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
        /* Contains: never chip — just search the draft text. */
        if (item.is_operator && item.kind == SearchFilterKind.TEXT) {
            if (!query ().is_empty)
                activated ();
            return;
        }

        if (item.is_operator) {
            this.suppressing = true;
            this.input.text = "";
            this.suppressing = false;
        } else {
            drop_last_token ();
        }

        /* From:/To: (and contacts as From) become chips. */
        var kind = item.is_operator
            ? item.kind
            : (item.kind != SearchFilterKind.TEXT ? item.kind : SearchFilterKind.FROM);
        add_chip (new SearchClause () {
            kind = kind,
            display = item.display,
            folded = item.folded,
        }, true);
        this.input.grab_focus ();
        emit_chip_search ();
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

    private static bool contains_space (string text) {
        unichar c;
        int i = 0;
        while (i < text.length) {
            text.get_next_char (ref i, out c);
            if (c.isspace ())
                return true;
        }
        return false;
    }

    private static SearchClause copy_clause (SearchClause clause) {
        return new SearchClause () {
            kind = clause.kind,
            folded = clause.folded,
            display = clause.display,
        };
    }
}
