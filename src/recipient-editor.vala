public class Mail.RecipientEditor : Adw.PreferencesRow {
    public signal void recipients_changed ();

    private Adw.WrapBox flow;
    private Gtk.Text input;
    private Gtk.Button book_button;
    private Gtk.Spinner suggest_spinner;
    private Gtk.Popover? suggest_popover;
    private Gtk.ScrolledWindow suggest_scrolled;
    private Gtk.ListBox suggest_list;
    private ContactStore? contacts;
    private GenericArray<Chip> chips = new GenericArray<Chip> ();
    private Chip? selected_chip;
    private bool finishing_edit;
    private static RecipientEditor? drag_origin;
    private static Chip? drag_chip;
    private uint suggest_source;
    private uint suggest_generation;
    private string suggest_shown_key = "";
    private bool searching;
    private const uint SUGGEST_MIN_CHARS = 3;
    private const uint SUGGEST_IDLE_MS = 300;
    private const int SUGGEST_ROW_HEIGHT = 52;
    private const int SUGGEST_CHROME = 12;
    private const int SUGGEST_MAX_HEIGHT = 260;
    private const int SUGGEST_MIN_WIDTH = 280;
    private const int SUGGEST_MAX_WIDTH = 380;
    private const int INPUT_WIDTH_CHARS = 4;

    private class Chip {
        public Recipient recipient;
        public Gtk.Widget widget;
        public Gtk.Box holder;
    }

    private class SuggestRow : Gtk.ListBoxRow {
        public ContactHit hit;

        public SuggestRow (ContactHit hit) {
            this.hit = hit;
            this.activatable = true;

            var title_text = hit.name.length > 0 && hit.name.down () != hit.email.down ()
                ? hit.name
                : hit.email;
            var subtitle_text = title_text != hit.email
                ? hit.email
                : (hit.from_book ? _("Address book") : _("Recent recipient"));

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
            box.add_css_class ("compose-suggest-row");
            box.append (new Gtk.Image.from_icon_name (
                hit.from_book ? "avatar-default-symbolic" : "document-open-recent-symbolic"
            ) {
                valign = Gtk.Align.CENTER,
            });
            box.append (texts);
            this.child = box;
            this.can_focus = false;
            this.focusable = false;
            this.focus_on_click = false;
        }
    }

    public RecipientEditor (string caption, string? initial = null) {
        Object (activatable: false);

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            margin_start = 12,
            margin_end = 12,
            margin_top = 4,
            margin_bottom = 4,
        };

        var label = new Gtk.Label (caption) {
            xalign = 0,
            yalign = 0.5f,
            width_chars = 3,
            valign = Gtk.Align.CENTER,
            use_markup = false,
        };
        label.add_css_class ("dim-label");
        label.add_css_class ("caption");

        this.flow = new Adw.WrapBox () {
            hexpand = true,
            vexpand = false,
            valign = Gtk.Align.CENTER,
            halign = Gtk.Align.FILL,
            child_spacing = 6,
            line_spacing = 2,
            justify = Adw.JustifyMode.NONE,
            line_homogeneous = false,
            wrap_policy = Adw.WrapPolicy.NATURAL,
        };
        this.flow.add_css_class ("compose-recipient-flow");

        this.input = new Gtk.Text () {
            hexpand = true,
            hexpand_set = true,
            width_chars = INPUT_WIDTH_CHARS,
            max_width_chars = INPUT_WIDTH_CHARS,
            propagate_text_width = false,
            input_purpose = Gtk.InputPurpose.EMAIL,
        };
        this.input.add_css_class ("compose-recipient-input");
        this.input.activate.connect (on_input_activate);
        this.input.notify["text"].connect (on_input_text);
        var input_keys = new Gtk.EventControllerKey ();
        input_keys.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        input_keys.key_pressed.connect (on_input_key);
        this.input.add_controller (input_keys);
        var tab = new Gtk.ShortcutController () {
            scope = Gtk.ShortcutScope.LOCAL,
        };
        tab.add_shortcut (new Gtk.Shortcut (
            new Gtk.KeyvalTrigger (Gdk.Key.Tab, 0),
            new Gtk.CallbackAction ((widget, args) => {
                if (!suggest_is_open ())
                    return false;
                apply_selected_suggest ();
                return true;
            })
        ));
        this.input.add_controller (tab);
        this.input.notify["has-focus"].connect (() => {
            if (this.input.has_focus)
                return;
            Timeout.add (200, () => {
                if (this.input.has_focus)
                    return Source.REMOVE;
                var window = get_root () as Gtk.Window;
                var focus = window != null ? window.get_focus () : null;
                if (focus != null && (focus == this || focus.is_ancestor (this)))
                    return Source.REMOVE;
                hide_suggest ();
                commit_input ();
                return Source.REMOVE;
            });
        });

        this.book_button = new Gtk.Button.from_icon_name ("x-office-address-book-symbolic") {
            valign = Gtk.Align.CENTER,
            tooltip_text = _("Address book"),
        };
        this.book_button.add_css_class ("flat");
        this.book_button.add_css_class ("compose-address-book");
        this.book_button.visible = false;
        this.book_button.clicked.connect (open_picker);

        this.suggest_spinner = new Gtk.Spinner () {
            width_request = 16,
            height_request = 16,
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER,
            tooltip_text = _("Searching"),
            visible = false,
            can_target = false,
        };
        this.suggest_spinner.add_css_class ("compose-suggest-spinner");

        var book_slot = new Gtk.Overlay () {
            valign = Gtk.Align.CENTER,
            vexpand = false,
        };
        book_slot.child = this.book_button;
        book_slot.add_overlay (this.suggest_spinner);

        this.flow.append (this.input);
        box.append (label);
        box.append (this.flow);
        box.append (book_slot);
        this.child = box;

        var label_click = new Gtk.GestureClick ();
        label_click.released.connect (() => this.input.grab_focus ());
        label.add_controller (label_click);

        var keys = new Gtk.EventControllerKey ();
        keys.key_pressed.connect (on_row_key);
        add_controller (keys);
        add_recipient_drop_target ();

        if (initial != null && initial.strip ().length > 0)
            set_recipients (Utils.parse_recipient_list (initial));
    }

    public override bool grab_focus () {
        return this.input.grab_focus ();
    }

    public string text {
        owned get {
            return Utils.format_recipient_list (recipients ());
        }
    }

    public bool is_empty {
        get {
            return this.chips.length == 0 && this.input.text.strip ().length == 0;
        }
    }

    public GenericArray<Recipient> recipients () {
        var listed = new GenericArray<Recipient> ();
        for (uint i = 0; i < this.chips.length; i++)
            listed.add (this.chips[i].recipient);
        return listed;
    }

    public void set_recipients (GenericArray<Recipient> recipients) {
        while (this.chips.length > 0)
            remove_chip (this.chips[this.chips.length - 1], false);
        for (uint i = 0; i < recipients.length; i++)
            add_chip (recipients[i], false);
        recipients_changed ();
    }

    public void bind_contacts (ContactStore? store) {
        this.contacts = store;
        this.book_button.visible = store != null;
        store?.warm ();
    }

    public void add_recipient (Recipient recipient) {
        var email = Utils.sanitize_recipient_text (recipient.email).down ();
        if (email.length == 0 || !email.contains ("@"))
            return;
        for (uint i = 0; i < this.chips.length; i++) {
            if (Utils.sanitize_recipient_text (this.chips[i].recipient.email).down () == email)
                return;
        }
        add_chip (recipient, true);
    }

    public void commit_pending () {
        commit_input ();
    }

    private void add_chip (Recipient recipient, bool notify) {
        var chip = new Chip ();
        chip.recipient = recipient;
        chip.widget = make_chip_widget (recipient);
        chip.holder = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) {
            hexpand = false,
            hexpand_set = true,
            vexpand = false,
            halign = Gtk.Align.START,
            valign = Gtk.Align.CENTER,
        };
        chip.holder.add_css_class ("compose-recipient-holder");
        chip.holder.append (chip.widget);
        Gtk.Widget? after = this.chips.length > 0 ? this.chips[this.chips.length - 1].holder : null;
        this.flow.insert_child_after (chip.holder, after);
        this.chips.add (chip);
        wire_chip (chip);

        if (notify)
            recipients_changed ();
    }

    private void wire_chip (Chip chip) {
        var click = new Gtk.GestureClick ();
        click.set_propagation_phase (Gtk.PropagationPhase.CAPTURE);
        click.pressed.connect ((n_press, x, y) => {
            if (n_press >= 2) {
                start_edit (chip);
                click.set_state (Gtk.EventSequenceState.CLAIMED);
            } else {
                select_chip (chip);
            }
        });
        chip.widget.add_controller (click);

        var drag = new Gtk.DragSource () {
            actions = Gdk.DragAction.MOVE,
        };
        drag.prepare.connect ((x, y) => {
            if (chip.widget is Gtk.Editable)
                return null;
            drag_origin = this;
            drag_chip = chip;
            return new Gdk.ContentProvider.for_value (chip.recipient);
        });
        drag.drag_begin.connect ((gdk_drag) => {
            select_chip (chip);
            chip.widget.add_css_class ("dragging");
            chip.widget.cursor = new Gdk.Cursor.from_name ("grabbing", null);
            var hot_x = (int) (chip.widget.get_width () / 2.0);
            var hot_y = (int) (chip.widget.get_height () / 2.0);
            drag.set_icon (new Gtk.WidgetPaintable (chip.widget), hot_x, hot_y);
        });
        drag.drag_end.connect ((gdk_drag, delete_data) => {
            chip.widget.remove_css_class ("dragging");
            chip.widget.cursor = new Gdk.Cursor.from_name ("grab", null);
            if (delete_data)
                remove_chip (chip, true);
            if (drag_chip == chip) {
                drag_origin = null;
                drag_chip = null;
            }
        });
        drag.drag_cancel.connect ((gdk_drag, reason) => {
            chip.widget.remove_css_class ("dragging");
            chip.widget.cursor = new Gdk.Cursor.from_name ("grab", null);
            if (drag_chip == chip) {
                drag_origin = null;
                drag_chip = null;
            }
            return false;
        });
        chip.widget.add_controller (drag);

        var keys = new Gtk.EventControllerKey ();
        keys.key_pressed.connect ((keyval) => {
            if (keyval == Gdk.Key.Delete || keyval == Gdk.Key.KP_Delete || keyval == Gdk.Key.BackSpace) {
                remove_chip (chip, true);
                return true;
            }
            return false;
        });
        chip.widget.add_controller (keys);
    }

    private static Gtk.Widget make_chip_widget (Recipient recipient) {
        var label = new Gtk.Label (recipient.chip_label) {
            ellipsize = Pango.EllipsizeMode.END,
            wrap = false,
            hexpand = false,
            hexpand_set = true,
            single_line_mode = true,
            use_markup = false,
        };
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) {
            valign = Gtk.Align.CENTER,
            hexpand = false,
            vexpand = false,
            tooltip_text = recipient.tooltip,
            focusable = true,
            focus_on_click = true,
        };
        box.add_css_class ("recipient-chip");
        box.cursor = new Gdk.Cursor.from_name ("grab", null);
        box.append (label);
        return box;
    }

    private void select_chip (Chip chip) {
        if (this.selected_chip != null && this.selected_chip != chip)
            this.selected_chip.widget.remove_css_class ("selected");
        this.selected_chip = chip;
        chip.widget.add_css_class ("selected");
        chip.widget.grab_focus ();
    }

    private void start_edit (Chip chip) {
        chip.holder.remove (chip.widget);
        var entry = new Gtk.Entry () {
            text = Utils.format_recipient (chip.recipient),
            has_frame = false,
            hexpand = false,
        };
        entry.add_css_class ("compose-recipient-edit");
        entry.has_frame = false;
        chip.widget = entry;
        chip.holder.append (entry);
        entry.grab_focus ();
        entry.select_region (0, -1);
        entry.activate.connect (() => finish_edit (chip, entry));
        var focus = new Gtk.EventControllerFocus ();
        focus.leave.connect (() => finish_edit (chip, entry));
        entry.add_controller (focus);
    }

    private void finish_edit (Chip chip, Gtk.Entry entry) {
        if (this.finishing_edit)
            return;
        this.finishing_edit = true;

        var parsed = Utils.parse_recipient_list (entry.text);
        if (parsed.length == 0) {
            this.finishing_edit = false;
            remove_chip (chip, true);
            return;
        }

        chip.holder.remove (entry);
        chip.recipient = parsed[0];
        chip.widget = make_chip_widget (chip.recipient);
        chip.holder.append (chip.widget);
        wire_chip (chip);

        for (uint i = 1; i < parsed.length; i++)
            add_chip (parsed[i], false);

        this.finishing_edit = false;
        this.selected_chip = null;
        recipients_changed ();
    }

    private void remove_chip (Chip chip, bool notify) {
        for (uint i = 0; i < this.chips.length; i++) {
            if (this.chips[i] != chip)
                continue;
            this.flow.remove (chip.holder);
            this.chips.remove_index (i);
            break;
        }

        if (this.selected_chip == chip)
            this.selected_chip = null;
        if (notify)
            recipients_changed ();
        this.input.grab_focus ();
    }

    private void on_input_activate () {
        if (suggest_is_open ())
            apply_selected_suggest ();
        else
            commit_input ();
    }

    private void commit_input () {
        var raw = this.input.text.strip ();
        if (raw.length == 0)
            return;

        var parsed = Utils.parse_recipient_list (raw);
        if (parsed.length == 0)
            return;

        this.input.text = "";
        hide_suggest ();
        for (uint i = 0; i < parsed.length; i++)
            add_chip (parsed[i], false);
        recipients_changed ();
    }

    private void on_input_text () {
        maybe_commit_separator ();
        queue_suggest ();
    }

    private bool suggest_is_open () {
        return this.suggest_popover != null && this.suggest_popover.visible;
    }

    private static bool suggest_needle_ready (string needle) {
        return needle.length >= SUGGEST_MIN_CHARS || needle.contains ("@");
    }

    private void queue_suggest (bool immediate = false) {
        if (this.suggest_source != 0) {
            Source.remove (this.suggest_source);
            this.suggest_source = 0;
        }

        var needle = this.input.text.strip ();
        if (this.contacts == null || !suggest_needle_ready (needle)) {
            hide_suggest ();
            return;
        }

        this.suggest_generation++;
        fill_suggest (this.contacts.search_collected (needle, 12));
        set_searching (true);

        if (immediate) {
            refresh_suggest.begin (needle);
            return;
        }

        this.suggest_source = Timeout.add (SUGGEST_IDLE_MS, () => {
            this.suggest_source = 0;
            refresh_suggest.begin (this.input.text.strip ());
            return Source.REMOVE;
        });
    }

    private async void refresh_suggest (string needle) {
        if (this.contacts == null || !suggest_needle_ready (needle)) {
            set_searching (false);
            return;
        }
        var generation = ++this.suggest_generation;
        var hits = yield this.contacts.search (needle, 12, null, false);
        if (generation != this.suggest_generation || this.input.text.strip () != needle)
            return;

        set_searching (false);
        fill_suggest (hits);
    }

    private void fill_suggest (GenericArray<ContactHit> hits) {
        ensure_suggest ();

        var emails = new StringBuilder ();
        var shown = 0;
        var rows = new GenericArray<ContactHit> ();
        for (uint i = 0; i < hits.length; i++) {
            if (recipient_already_added (hits[i].email))
                continue;
            rows.add (hits[i]);
            emails.append (hits[i].email.down ());
            emails.append_c (';');
            shown++;
        }

        if (shown == 0) {
            if (!this.searching) {
                this.suggest_shown_key = "";
                this.suggest_popover.popdown ();
            }
            return;
        }

        var key = emails.str;
        if (key == this.suggest_shown_key && this.suggest_popover.visible)
            return;

        this.suggest_shown_key = key;
        this.suggest_list.remove_all ();
        for (uint i = 0; i < rows.length; i++)
            this.suggest_list.append (new SuggestRow (rows[i]));

        this.suggest_list.select_row (this.suggest_list.get_row_at_index (0));
        size_suggest (shown);
        point_suggest ();
        if (!this.suggest_popover.visible)
            this.suggest_popover.popup ();
        keep_entry_focus ();
    }

    private void size_suggest (uint shown) {
        var width = this.flow.get_width ();
        if (width < SUGGEST_MIN_WIDTH)
            width = SUGGEST_MIN_WIDTH;
        if (width > SUGGEST_MAX_WIDTH)
            width = SUGGEST_MAX_WIDTH;

        var height = (int) shown * SUGGEST_ROW_HEIGHT + SUGGEST_CHROME;
        var scroll = height > SUGGEST_MAX_HEIGHT;
        if (scroll)
            height = SUGGEST_MAX_HEIGHT;

        set_scrolled_content_size (this.suggest_scrolled, width, height);
        this.suggest_scrolled.vscrollbar_policy = scroll
            ? Gtk.PolicyType.AUTOMATIC
            : Gtk.PolicyType.NEVER;
        this.suggest_popover.width_request = width;
        this.suggest_popover.height_request = height;
        point_suggest ();
    }

    private void point_suggest () {
        if (this.suggest_popover == null)
            return;

        var rect = Gdk.Rectangle () {
            x = 0,
            y = 0,
            width = 1,
            height = int.max (1, this.input.get_height ()),
        };
        Graphene.Rect strong;
        Graphene.Rect weak;
        this.input.compute_cursor_extents (0, out strong, out weak);
        if (strong.size.height > 0.5f) {
            rect.x = (int) strong.origin.x;
            rect.y = (int) strong.origin.y;
            rect.width = 1;
            rect.height = int.max (1, (int) strong.size.height);
        }
        this.suggest_popover.set_pointing_to (rect);
    }

    private static void set_scrolled_content_size (Gtk.ScrolledWindow scrolled, int width, int height) {
        if (scrolled.max_content_width < 0 || width > scrolled.max_content_width)
            scrolled.max_content_width = width;
        scrolled.min_content_width = width;
        scrolled.max_content_width = width;

        if (scrolled.max_content_height < 0 || height > scrolled.max_content_height)
            scrolled.max_content_height = height;
        scrolled.min_content_height = height;
        scrolled.max_content_height = height;
    }

    private bool recipient_already_added (string email) {
        var needle = Utils.sanitize_recipient_text (email).down ();
        for (uint i = 0; i < this.chips.length; i++) {
            if (Utils.sanitize_recipient_text (this.chips[i].recipient.email).down () == needle)
                return true;
        }
        return false;
    }

    private void keep_entry_focus () {
        if (!this.input.has_focus)
            this.input.grab_focus_without_selecting ();
    }

    private void set_searching (bool on) {
        if (this.searching == on)
            return;
        this.searching = on;
        if (on) {
            this.book_button.opacity = 0;
            this.suggest_spinner.visible = true;
            this.suggest_spinner.start ();
        } else {
            this.suggest_spinner.stop ();
            this.suggest_spinner.visible = false;
            this.book_button.opacity = 1;
        }
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

        var popover_keys = new Gtk.EventControllerKey ();
        popover_keys.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        popover_keys.key_pressed.connect (on_popover_key);
        ((Gtk.Widget) this.suggest_popover).add_controller (popover_keys);
    }

    private bool on_popover_key (uint keyval, uint keycode, Gdk.ModifierType state) {
        if (on_input_key (keyval, keycode, state))
            return true;
        if ((state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.SUPER_MASK)) != 0)
            return false;
        if (keyval == Gdk.Key.BackSpace) {
            var pos = this.input.cursor_position;
            if (pos > 0)
                this.input.delete_text (pos - 1, pos);
            else if (this.chips.length > 0)
                remove_chip (this.chips[this.chips.length - 1], true);
            keep_entry_focus ();
            return true;
        }
        var unicode = Gdk.keyval_to_unicode (keyval);
        if (unicode == 0 || unicode < 32)
            return false;
        unichar c = (unichar) unicode;
        var str = c.to_string ();
        int pos = this.input.cursor_position;
        this.input.insert_text (str, str.length, ref pos);
        this.input.set_position (pos);
        keep_entry_focus ();
        return true;
    }

    private void hide_suggest () {
        this.suggest_generation++;
        if (this.suggest_source != 0) {
            Source.remove (this.suggest_source);
            this.suggest_source = 0;
        }
        set_searching (false);
        this.suggest_shown_key = "";
        this.suggest_popover?.popdown ();
    }

    private void on_suggest_activated (Gtk.ListBoxRow row) {
        var suggest = row as SuggestRow;
        if (suggest == null)
            return;
        this.input.text = "";
        hide_suggest ();
        add_recipient (suggest.hit.to_recipient ());
        this.input.grab_focus ();
    }

    private void apply_selected_suggest () {
        if (!suggest_is_open ())
            return;
        var row = this.suggest_list.get_selected_row ()
            ?? this.suggest_list.get_row_at_index (0);
        if (row != null)
            on_suggest_activated (row);
    }

    private void open_picker () {
        if (this.contacts == null)
            return;
        var dialog = new ContactPickerDialog (this.contacts);
        dialog.contact_chosen.connect ((recipient) => add_recipient (recipient));
        dialog.present (get_root () as Gtk.Widget);
    }

    private void maybe_commit_separator () {
        var raw = this.input.text;
        if (!has_complete_unquoted_separator (raw))
            return;

        var cleaned = raw.replace (";", ",");
        if (cleaned.has_suffix (","))
            cleaned = cleaned.substring (0, cleaned.length - 1);
        this.input.text = cleaned;
        commit_input ();
    }

    private static bool has_complete_unquoted_separator (string raw) {
        var in_quotes = false;
        for (int i = 0; i < raw.length; i++) {
            var c = raw[i];
            if (c == '"') {
                in_quotes = !in_quotes;
                continue;
            }
            if (in_quotes || (c != ',' && c != ';'))
                continue;

            var left = raw.substring (0, i).strip ();
            return left.contains ("@") || left.contains (">");
        }
        return false;
    }

    private bool on_input_key (uint keyval, uint keycode, Gdk.ModifierType state) {
        var mods = state & Gtk.accelerator_get_default_mod_mask ();
        if (keyval == Gdk.Key.Escape && suggest_is_open ()) {
            hide_suggest ();
            return true;
        }
        if (keyval == Gdk.Key.Down || keyval == Gdk.Key.KP_Down) {
            if (suggest_is_open ()) {
                move_suggest (1);
                return true;
            }
            queue_suggest (true);
            return suggest_needle_ready (this.input.text.strip ());
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
            remove_chip (this.chips[this.chips.length - 1], true);
            return true;
        }

        return false;
    }

    private void move_suggest (int delta) {
        var current = this.suggest_list.get_selected_row ();
        int index = current != null ? current.get_index () : -1;
        var next = this.suggest_list.get_row_at_index (index + delta);
        if (next == null)
            return;

        this.suggest_list.select_row (next);
        var adj = this.suggest_scrolled.get_vadjustment ();
        var y = (double) next.get_index () * SUGGEST_ROW_HEIGHT;
        var bottom = y + SUGGEST_ROW_HEIGHT;
        if (y < adj.value)
            adj.value = y;
        else if (bottom > adj.value + adj.page_size)
            adj.value = bottom - adj.page_size;
        keep_entry_focus ();
    }

    private bool on_row_key (uint keyval, uint keycode, Gdk.ModifierType state) {
        if (this.input.has_focus)
            return false;
        if (this.selected_chip == null)
            return false;
        if (keyval == Gdk.Key.Delete || keyval == Gdk.Key.KP_Delete || keyval == Gdk.Key.BackSpace) {
            remove_chip (this.selected_chip, true);
            return true;
        }
        return false;
    }

    private void add_recipient_drop_target () {
        var target = new Gtk.DropTarget (typeof (Recipient), Gdk.DragAction.MOVE);
        target.enter.connect ((x, y) => {
            if (drag_origin == this)
                return 0;
            add_css_class ("compose-recipient-drop");
            return Gdk.DragAction.MOVE;
        });
        target.leave.connect (() => {
            remove_css_class ("compose-recipient-drop");
        });
        target.drop.connect ((value, x, y) => {
            remove_css_class ("compose-recipient-drop");
            if (drag_origin == this)
                return false;
            var recipient = value.get_object () as Recipient;
            if (recipient == null)
                return false;
            add_recipient (recipient);
            return true;
        });
        add_controller (target);
    }
}
