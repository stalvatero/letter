public class Mail.SignatureEditorDialog : Adw.Dialog {
    public signal void saved (MailSignature signature);

    private Adw.EntryRow name_row;
    private ComposeHtmlView editor;
    private Gtk.Button save_button;
    private string? original_name;
    private bool ready;

    public SignatureEditorDialog (MailSignature? existing) {
        Object (
            content_width: 680,
            content_height: 560,
            follows_content_size: false
        );
        this.title = existing == null ? _("New Signature") : _("Edit Signature");
        this.original_name = existing != null ? existing.name : null;

        this.save_button = new Gtk.Button.with_label (_("Save")) {
            sensitive = false,
        };
        this.save_button.add_css_class ("suggested-action");
        this.save_button.add_css_class ("pill");
        this.save_button.clicked.connect (() => save.begin ());

        var header = new Adw.HeaderBar ();
        header.pack_end (this.save_button);

        this.name_row = new Adw.EntryRow () {
            title = _("Name"),
            text = existing != null ? existing.name : "",
        };
        this.name_row.notify["text"].connect (update_save);

        var name_group = new Adw.PreferencesGroup ();
        name_group.add (this.name_row);

        var initial = existing != null && existing.html.length > 0
            ? existing.html_body ()
            : "<p><br></p>";
        this.editor = new ComposeHtmlView (null, false, true, false, "", initial);
        this.editor.add_css_class ("compose-signature-editor");
        this.editor.height_request = 280;
        this.editor.ready.connect (() => {
            this.ready = true;
            update_save ();
        });

        var toolbar = new FormatToolbar (this.editor);
        toolbar.insert_image.connect (() => prompt_image.begin ());

        var editor_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            hexpand = true,
            vexpand = true,
        };
        editor_box.add_css_class ("card");
        editor_box.append (toolbar);
        editor_box.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
        editor_box.append (this.editor);

        var hint = new Gtk.Label (
            _("The signature is added after two blank lines and a -- mark, before any quoted reply.")
        ) {
            wrap = true,
            xalign = 0,
            hexpand = true,
        };
        hint.add_css_class ("caption");
        hint.add_css_class ("dim-label");

        var page = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) {
            margin_start = 16,
            margin_end = 16,
            margin_top = 12,
            margin_bottom = 16,
            hexpand = true,
            vexpand = true,
        };
        page.append (name_group);
        page.append (editor_box);
        page.append (hint);

        var toolbar_view = new Adw.ToolbarView () {
            content = page,
        };
        toolbar_view.add_top_bar (header);
        child = toolbar_view;
    }

    private void update_save () {
        this.save_button.sensitive = this.ready && this.name_row.text.strip ().length > 0;
    }

    private async void save () {
        var name = this.name_row.text.strip ();
        if (name.length == 0)
            return;
        string html = "";
        try {
            html = yield this.editor.get_editor_html ();
        } catch (Error e) {
            warning ("Could not read signature: %s", e.message);
            return;
        }
        if (is_blank_html (html))
            html = "";
        if (html.length == 0)
            return;

        saved (new MailSignature (name, html));
        close ();
    }

    private static bool is_blank_html (string html) {
        var text = html.strip ().down ().replace (" ", "");
        return text.length == 0
            || text == "<br>"
            || text == "<br/>"
            || text == "<p><br></p>"
            || text == "<p></p>"
            || text == "<div><br></div>";
    }

    private async void prompt_image () {
        yield ComposeExtras.prompt_insert_image (this, this.editor);
    }
}

public class Mail.SignatureListPage : Adw.NavigationPage {
    private Account account;
    private SignatureStore store;
    private Adw.PreferencesGroup group;
    private GenericArray<Adw.ActionRow> rows = new GenericArray<Adw.ActionRow> ();

    public SignatureListPage (Account account, SignatureStore store) {
        Object (title: _("Signatures"));
        this.account = account;
        this.store = store;

        var header = new Adw.HeaderBar ();
        var add = new Gtk.Button.from_icon_name ("list-add-symbolic") {
            tooltip_text = _("Add Signature"),
        };
        add.add_css_class ("flat");
        add.clicked.connect (add_signature);
        header.pack_end (add);

        this.group = new Adw.PreferencesGroup () {
            title = account.display_name,
            description = _("Each account has its own signatures. Star the one that should be added to new messages. You can still pick another signature while writing."),
        };

        var clamp = new Adw.Clamp () {
            child = this.group,
            maximum_size = 680,
            tightening_threshold = 480,
            margin_start = 16,
            margin_end = 16,
            margin_top = 16,
            margin_bottom = 16,
        };

        var toolbar = new Adw.ToolbarView () {
            content = clamp,
        };
        toolbar.add_top_bar (header);
        child = toolbar;
        refresh ();
    }

    private void refresh () {
        for (uint i = 0; i < this.rows.length; i++)
            this.group.remove (this.rows[i]);
        this.rows = new GenericArray<Adw.ActionRow> ();

        var listed = this.store.list (this.account.signature_key);
        if (listed.length == 0) {
            var empty = new Adw.ActionRow () {
                title = _("No signatures yet"),
                subtitle = _("Add a signature to use it when writing messages from this account."),
                sensitive = false,
            };
            this.group.add (empty);
            this.rows.add (empty);
            return;
        }

        var selected = this.store.default_name (this.account.signature_key);
        for (uint i = 0; i < listed.length; i++) {
            var signature = listed[i];
            var is_default = selected == signature.name;
            var row = new Adw.ActionRow () {
                title = signature.name,
                activatable = true,
            };
            var star = new Gtk.Button () {
                valign = Gtk.Align.CENTER,
                icon_name = is_default ? "starred-symbolic" : "non-starred-symbolic",
                tooltip_text = is_default
                    ? _("Default for new messages. Click to stop using it automatically.")
                    : _("Use as the default for new messages from this account"),
                focus_on_click = false,
            };
            star.add_css_class ("flat");
            star.add_css_class ("circular");
            if (is_default)
                star.add_css_class ("accent");
            var captured = signature;
            star.clicked.connect (() => toggle_default (captured.name));
            row.add_prefix (star);

            var edit = new Gtk.Button.with_label (_("Edit")) {
                valign = Gtk.Align.CENTER,
            };
            edit.add_css_class ("flat");
            var trash = new Gtk.Button.from_icon_name ("user-trash-symbolic") {
                valign = Gtk.Align.CENTER,
                tooltip_text = _("Delete"),
            };
            trash.add_css_class ("flat");
            row.activated.connect (() => edit_signature (captured));
            edit.clicked.connect (() => edit_signature (captured));
            trash.clicked.connect (() => confirm_delete.begin (captured));
            row.add_suffix (edit);
            row.add_suffix (trash);
            this.group.add (row);
            this.rows.add (row);
        }
    }

    private void toggle_default (string name) {
        var key = this.account.signature_key;
        if (this.store.default_name (key) == name)
            this.store.set_default_name (key, "");
        else
            this.store.set_default_name (key, name);
        refresh ();
    }

    private void add_signature () {
        open_editor (null);
    }

    private void edit_signature (MailSignature signature) {
        open_editor (signature);
    }

    private void open_editor (MailSignature? existing) {
        var dialog = new SignatureEditorDialog (existing);
        var old_name = existing != null ? existing.name : null;
        dialog.saved.connect ((signature) => {
            this.store.upsert (this.account.signature_key, signature, old_name);
            refresh ();
        });
        dialog.present (this);
    }

    private async void confirm_delete (MailSignature signature) {
        var dialog = new Adw.AlertDialog (
            _("Delete “%s”?").printf (signature.name),
            _("This signature will no longer be available when writing messages from this account.")
        );
        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("delete", _("Delete"));
        dialog.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.default_response = "cancel";
        dialog.close_response = "cancel";
        var response = yield dialog.choose (this, null);
        if (response != "delete")
            return;
        this.store.remove (this.account.signature_key, signature.name);
        refresh ();
    }
}
