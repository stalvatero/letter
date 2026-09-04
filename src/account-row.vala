public class Mail.AccountRow : Adw.ActionRow {
    public Account account { get; construct; }

    public AccountRow (Account account) {
        Object (account: account);
    }

    construct {
        this.use_markup = false;
        this.title = this.account.display_name;
        this.subtitle = this.account.subtitle;
        this.title_lines = 1;
        this.subtitle_lines = 1;
        this.activatable = true;

        if (this.account.has_mail)
            add_suffix (service_icon ("mail-unread-symbolic", _("Email enabled")));
        if (this.account.has_calendar)
            add_suffix (service_icon ("x-office-calendar-symbolic", _("Calendar enabled")));
        if (this.account.has_contacts)
            add_suffix (service_icon ("avatar-default-symbolic", _("Address book enabled")));
        if (!this.account.has_mail)
            add_css_class ("account-offline");
    }

    private static Gtk.Image service_icon (string name, string tooltip) {
        var icon = new Gtk.Image.from_icon_name (name) {
            tooltip_text = tooltip,
        };
        icon.add_css_class ("dim-label");
        return icon;
    }
}

public class Mail.FolderRow : Gtk.ListBoxRow {
    public Folder folder { get; construct; }
    public signal void context_pressed (double x, double y);
    public signal void expander_toggled ();

    private Gtk.Image expander;
    private Gtk.Label name_label;
    private Gtk.Label count_label;

    public FolderRow (Folder folder) {
        Object (folder: folder);
    }

    construct {
        this.activatable = true;
        add_css_class ("folder-row");

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            hexpand = true,
            valign = Gtk.Align.CENTER,
        };

        this.expander = new Gtk.Image.from_icon_name ("pan-end-symbolic") {
            pixel_size = 16,
            valign = Gtk.Align.CENTER,
        };
        this.expander.add_css_class ("folder-expander");
        this.expander.add_css_class ("dim-label");
        var expander_click = new Gtk.GestureClick ();
        expander_click.set_propagation_phase (Gtk.PropagationPhase.CAPTURE);
        expander_click.pressed.connect (() => {
            if (!this.folder.has_children)
                return;
            expander_toggled ();
            expander_click.set_state (Gtk.EventSequenceState.CLAIMED);
        });
        this.expander.add_controller (expander_click);
        box.append (this.expander);

        var icon = new Gtk.Image.from_icon_name (this.folder.icon_name);
        icon.add_css_class ("folder-icon");
        box.append (icon);

        this.name_label = new Gtk.Label (this.folder.name) {
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
        if (this.folder.indent > 0)
            box.margin_start = (int) this.folder.indent * 16;

        var click = new Gtk.GestureClick () {
            button = Gdk.BUTTON_SECONDARY,
        };
        click.pressed.connect ((n, x, y) => {
            context_pressed (x, y);
            click.set_state (Gtk.EventSequenceState.CLAIMED);
        });
        add_controller (click);

        update_expander (this.folder.has_children, true);
        update_unread ();
    }

    public void update_expander (bool has_children, bool expanded) {
        this.folder.has_children = has_children;
        this.expander.opacity = has_children ? 1 : 0;
        this.expander.can_target = has_children;
        this.expander.icon_name = expanded ? "pan-down-symbolic" : "pan-end-symbolic";
        this.expander.tooltip_text = has_children
            ? (expanded ? _("Collapse") : _("Expand"))
            : null;
    }

    public void update_unread () {
        if (this.folder.unread > 0)
            add_css_class ("unread");
        else
            remove_css_class ("unread");

        this.count_label.label = this.folder.badge_count.to_string ();
        this.count_label.visible = this.folder.badge_count > 0;
    }
}

public class Mail.MessageRow : Gtk.Box {
    public Conversation? conversation { get; private set; }
    public uint list_position { get; set; default = Gtk.INVALID_LIST_POSITION; }
    public signal void mark_read_clicked ();

    private Gtk.Box unread_indicator;
    private Gtk.Label from_label;
    private Gtk.Label date_label;
    private Gtk.Label subject_label;
    private Gtk.Label preview_label;
    private Gtk.Label folder_label;
    private Gtk.Label count_label;
    private Gtk.Image attachment_icon;
    private Gtk.Image bookmark_icon;
    private Gtk.Image important_icon;
    private ulong unread_id;
    private ulong flagged_id;
    private ulong important_id;

    private GenericArray<string>? highlight_tokens;

    public MessageRow () {
        Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 0);
    }

    construct {
        add_css_class ("message-row");
        hexpand = true;
        valign = Gtk.Align.CENTER;

        this.unread_indicator = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            valign = Gtk.Align.CENTER,
            vexpand = false,
            hexpand = false,
            can_focus = false,
        };
        this.unread_indicator.add_css_class ("unread-indicator");
        this.unread_indicator.set_size_request (2, 28);
        var mark_click = new Gtk.GestureClick ();
        mark_click.set_propagation_phase (Gtk.PropagationPhase.CAPTURE);
        mark_click.pressed.connect (() => {
            if (this.conversation == null || this.conversation.seen)
                return;
            mark_read_clicked ();
            mark_click.set_state (Gtk.EventSequenceState.CLAIMED);
        });
        this.unread_indicator.add_controller (mark_click);

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) {
            hexpand = true,
            valign = Gtk.Align.CENTER,
        };

        var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);

        this.from_label = new Gtk.Label ("") {
            hexpand = true,
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.END,
            use_markup = false,
        };
        this.from_label.add_css_class ("message-from");
        header.append (this.from_label);

        this.folder_label = new Gtk.Label ("") {
            use_markup = false,
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 18,
        };
        this.folder_label.add_css_class ("message-folder");
        this.folder_label.add_css_class ("dim-label");
        header.append (this.folder_label);

        this.count_label = new Gtk.Label ("") {
            use_markup = false,
        };
        this.count_label.add_css_class ("message-count");
        this.count_label.add_css_class ("numeric");
        header.append (this.count_label);

        this.attachment_icon = new Gtk.Image.from_icon_name ("mail-attachment-symbolic") {
            visible = false,
        };
        this.attachment_icon.add_css_class ("dim-label");
        header.append (this.attachment_icon);

        this.bookmark_icon = new Gtk.Image.from_icon_name ("user-bookmarks-symbolic") {
            visible = false,
            tooltip_text = _("Bookmarked"),
        };
        this.bookmark_icon.add_css_class ("bookmark-icon");
        header.append (this.bookmark_icon);

        this.important_icon = new Gtk.Image.from_icon_name ("mail-mark-important-symbolic") {
            visible = false,
            tooltip_text = _("Important"),
        };
        this.important_icon.add_css_class ("important-icon");
        header.append (this.important_icon);

        this.date_label = new Gtk.Label ("") {
            use_markup = false,
        };
        this.date_label.add_css_class ("message-date");
        this.date_label.add_css_class ("dim-label");
        this.date_label.add_css_class ("numeric");
        header.append (this.date_label);
        content.append (header);

        this.subject_label = new Gtk.Label ("") {
            hexpand = true,
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.END,
            use_markup = false,
        };
        this.subject_label.add_css_class ("message-subject");
        content.append (this.subject_label);

        this.preview_label = new Gtk.Label ("") {
            hexpand = true,
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.END,
            use_markup = false,
        };
        this.preview_label.add_css_class ("message-preview");
        this.preview_label.add_css_class ("dim-label");
        content.append (this.preview_label);
        append (this.unread_indicator);
        append (content);
    }

    public void bind (Conversation conversation, GenericArray<string>? highlights = null) {
        unbind ();
        this.highlight_tokens = highlights;
        this.conversation = conversation;
        apply_conversation ();
        this.unread_id = conversation.notify["unread"].connect (() => apply_conversation ());
        this.flagged_id = conversation.notify["flagged"].connect (() => apply_conversation ());
        this.important_id = conversation.notify["important"].connect (() => apply_conversation ());
    }

    public override void dispose () {
        unbind ();
        base.dispose ();
    }

    public void unbind () {
        var unread = this.unread_id;
        var flagged = this.flagged_id;
        var important = this.important_id;
        var conversation = this.conversation;
        this.unread_id = 0;
        this.flagged_id = 0;
        this.important_id = 0;
        this.conversation = null;
        if (unread != 0 && conversation != null && SignalHandler.is_connected (conversation, unread))
            conversation.disconnect (unread);
        if (flagged != 0 && conversation != null && SignalHandler.is_connected (conversation, flagged))
            conversation.disconnect (flagged);
        if (important != 0 && conversation != null && SignalHandler.is_connected (conversation, important))
            conversation.disconnect (important);
    }

    public void apply_seen (bool seen) {
        if (this.conversation == null)
            return;
        var latest = this.conversation.latest;
        if (latest != null && latest.seen != seen)
            latest.seen = seen;
        this.conversation.refresh ();
        apply_conversation ();
    }

    public void mark_seen () {
        apply_seen (true);
    }

    private void apply_conversation () {
        var conversation = this.conversation;
        if (conversation == null)
            return;

        var latest = conversation.latest;
        set_highlighted (this.from_label, conversation.participants);
        this.date_label.label = Utils.format_message_date (conversation.date);
        set_highlighted (this.subject_label, conversation.subject);
        this.attachment_icon.visible = conversation.has_attachment;
        this.bookmark_icon.visible = conversation.flagged;
        this.important_icon.visible = conversation.important;
        var folder_name = latest != null && latest.show_folder ? latest.folder_name : null;
        this.folder_label.label = folder_name ?? "";
        this.folder_label.visible = folder_name != null && folder_name.length > 0;
        var preview = conversation.preview;
        set_highlighted (this.preview_label, preview ?? "");
        this.preview_label.visible = preview != null && preview.length > 0;
        this.count_label.label = conversation.messages.length.to_string ();
        this.count_label.visible = conversation.messages.length > 1;
        this.unread_indicator.tooltip_text = conversation.seen ? null : _("Mark as read");
        if (conversation.seen)
            remove_css_class ("unread");
        else
            add_css_class ("unread");
    }

    private void set_highlighted (Gtk.Label label, string text) {
        label.label = text;
        label.attributes = Utils.search_highlight_attrs (text, this.highlight_tokens);
    }
}
