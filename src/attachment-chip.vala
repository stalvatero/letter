public class Mail.AttachmentChip : Gtk.Box {
    public Attachment attachment { get; construct; }
    public bool removable { get; construct; }

    public signal void removed ();

    public AttachmentChip (Attachment attachment, bool removable = false) {
        Object (
            orientation: Gtk.Orientation.HORIZONTAL,
            spacing: 0,
            hexpand: false,
            hexpand_set: true,
            vexpand: false,
            valign: Gtk.Align.CENTER,
            attachment: attachment,
            removable: removable
        );
    }

    construct {
        if (this.removable)
            add_css_class ("compose-attachment");

        var open_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            hexpand = false,
        };
        open_box.append (new Gtk.Image.from_icon_name (
            this.attachment.is_message ? "mail-unread-symbolic" : "mail-attachment-symbolic"
        ));
        var label = new Gtk.Label (this.attachment.filename) {
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 40,
            wrap = false,
            hexpand = false,
            single_line_mode = true,
            use_markup = false,
        };
        open_box.append (label);
        var size = new Gtk.Label (this.attachment.size_label) {
            wrap = false,
            hexpand = false,
            single_line_mode = true,
            use_markup = false,
        };
        size.add_css_class ("dim-label");
        size.add_css_class ("caption");
        size.add_css_class ("numeric");
        open_box.append (size);

        var preview = new Gtk.Button.from_icon_name ("view-reveal-symbolic") {
            tooltip_text = _("Preview"),
            valign = Gtk.Align.CENTER,
        };
        preview.add_css_class ("flat");
        preview.add_css_class ("circular");
        var save = new Gtk.Button.from_icon_name ("folder-download-symbolic") {
            tooltip_text = _("Save"),
            valign = Gtk.Align.CENTER,
        };
        save.add_css_class ("flat");
        save.add_css_class ("circular");

        var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
        actions.add_css_class ("attachment-actions");
        actions.append (preview);
        actions.append (save);

        var popover = new Gtk.Popover () {
            autohide = true,
            has_arrow = true,
            position = Gtk.PositionType.BOTTOM,
            child = actions,
        };
        preview.clicked.connect (() => {
            popover.popdown ();
            preview_attachment.begin ();
        });
        save.clicked.connect (() => {
            popover.popdown ();
            save_attachment.begin ();
        });

        var open_button = new Gtk.MenuButton () {
            child = open_box,
            popover = popover,
            always_show_arrow = false,
            has_frame = false,
            hexpand = false,
            tooltip_text = _("Preview or save “%s”").printf (this.attachment.filename),
        };
        open_button.add_css_class ("flat");
        open_button.add_css_class (this.removable ? "compose-attachment-open" : "attachment-chip");
        append (open_button);

        if (!this.removable)
            return;

        var remove = new Gtk.Button.from_icon_name ("window-close-symbolic") {
            tooltip_text = _("Remove “%s”").printf (this.attachment.filename),
            valign = Gtk.Align.CENTER,
        };
        remove.add_css_class ("flat");
        remove.add_css_class ("compose-attachment-remove");
        remove.clicked.connect (() => {
            popover.popdown ();
            removed ();
        });
        append (remove);
    }

    private async void preview_attachment () {
        try {
            var file = Utils.ensure_attachment_file (this.attachment);
            yield Utils.open_or_preview_file (file, get_root () as Gtk.Window, false);
        } catch (Error e) {
            show_error (e.message);
        }
    }

    private async void save_attachment () {
        try {
            yield Utils.save_attachment (this.attachment, get_root () as Gtk.Window);
        } catch (Error e) {
            if (e is IOError.CANCELLED || e is Gtk.DialogError.DISMISSED)
                return;
            show_error (e.message);
        }
    }

    private void show_error (string message) {
        Gtk.Widget? widget = this;
        while (widget != null) {
            var overlay = widget as Adw.ToastOverlay;
            if (overlay != null) {
                overlay.add_toast (new Adw.Toast (message) {
                    timeout = 4,
                });
                return;
            }
            widget = widget.parent;
        }
        warning ("%s", message);
    }
}
