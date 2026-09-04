public class Mail.ComposeWindow : Adw.ApplicationWindow {
    private const int64 MAX_ATTACHMENT_BYTES = 50 * 1024 * 1024;

    private Settings settings;
    private MailSession session;
    private SignatureStore signature_store;
    private GenericArray<Account> accounts = new GenericArray<Account> ();
    private Gtk.DropDown? from_drop;
    private RecipientEditor to_row;
    private RecipientEditor cc_row;
    private RecipientEditor bcc_row;
    private Adw.EntryRow subject_row;
    private ComposeHtmlView body_view;
    private Gtk.Button send_button;
    private Adw.WrapBox attachments_box;
    private Gtk.DropDown signature_drop;
    private Adw.ToastOverlay toast_overlay;
    private GenericArray<Attachment> attachments = new GenericArray<Attachment> ();
    private GenericArray<MailSignature> signatures = new GenericArray<MailSignature> ();
    private GenericArray<string> font_families = new GenericArray<string> ();
    private HashTable<string, uint8> recent_drops = new HashTable<string, uint8> (str_hash, str_equal);
    private bool force_close;
    private bool prompting;
    private bool sending;
    private bool rebuilding_signatures;
    private bool toolbar_live;
    private bool focus_to_field;
    private bool skip_initial_signature;
    private bool body_mutated;
    private bool attachment_offer_done;
    private GenericSet<string> original_participants = new GenericSet<string> (str_hash, str_equal);
    private uint signature_index;
    private string initial_to;
    private string initial_cc;
    private string initial_bcc;
    private string initial_subject;
    private string initial_body;
    private uint initial_attachment_count;
    private MessageContent? reply_of;
    private MessageContent? thread_of;

    public ComposeWindow (
        Gtk.Application app,
        MailSession session,
        AccountStore store,
        Account? selected,
        string? to = null,
        string? cc = null,
        string? subject = null,
        MessageContent? quoted = null,
        bool forward_quote = false,
        string? bcc = null,
        bool resend = false
    ) {
        var settings = new Settings (Config.APP_ID);
        Object (
            application: app,
            title: _("New Message"),
            default_width: settings.get_int ("compose-width").clamp (480, 4000),
            default_height: settings.get_int ("compose-height").clamp (360, 4000)
        );

        this.settings = settings;
        this.signature_store = new SignatureStore (settings);
        this.signature_store.migrate_if_needed (store);
        this.session = session;
        this.reply_of = (!forward_quote && !resend) ? quoted : null;
        this.thread_of = !resend ? quoted : null;
        this.focus_to_field = quoted == null || forward_quote;
        this.skip_initial_signature = resend;
        resizable = true;
        width_request = 480;
        height_request = 360;

        if (Config.PROFILE == "development")
            add_css_class ("devel");

        this.send_button = new Gtk.Button.with_label (_("Send")) {
            sensitive = false,
        };
        this.send_button.add_css_class ("suggested-action");
        this.send_button.add_css_class ("pill");
        this.send_button.add_css_class ("compose-send");
        this.send_button.clicked.connect (() => send.begin ());

        var header = new Adw.HeaderBar ();
        header.pack_start (header_icon ("document-save-symbolic", _("Save Draft"), () => save_draft_now.begin ()));
        header.pack_start (header_icon ("document-print-symbolic", _("Print"), () => print_message ()));
        header.pack_start (this.send_button);

        var from_model = new Gtk.StringList (null);
        uint selected_index = 0;
        for (uint i = 0; i < store.items.get_n_items (); i++) {
            var account = (Account) store.items.get_item (i);
            if (!Utils.is_sendable (account))
                continue;

            if (selected != null && (account.uid == selected.uid || account.source_uid == selected.source_uid))
                selected_index = this.accounts.length;

            this.accounts.add (account);
            var identity = session.get_identity (account);
            var label = identity != null
                ? "%s <%s>".printf (identity.name, identity.address)
                : account.display_name;
            from_model.append (label);
        }

        this.to_row = new RecipientEditor (_("To"), to);
        this.cc_row = new RecipientEditor (_("Cc"), cc);
        this.bcc_row = new RecipientEditor (_("Bcc"), bcc);
        var mail_app = app as Application;
        if (mail_app != null) {
            this.to_row.bind_contacts (mail_app.contacts);
            this.cc_row.bind_contacts (mail_app.contacts);
            this.bcc_row.bind_contacts (mail_app.contacts);
        }
        this.bcc_row.visible = bcc != null && bcc.strip ().length > 0;
        this.subject_row = new Adw.EntryRow () {
            title = _("Subject"),
        };
        this.to_row.recipients_changed.connect (update_send_sensitive);
        this.to_row.recipients_changed.connect (on_compose_recipients_changed);
        this.cc_row.recipients_changed.connect (on_compose_recipients_changed);
        this.bcc_row.recipients_changed.connect (on_compose_recipients_changed);
        remember_original_participants ();
        this.initial_to = this.to_row.text;
        this.initial_cc = this.cc_row.text;
        this.initial_bcc = this.bcc_row.text;
        this.initial_subject = subject ?? "";
        this.initial_attachment_count = 0;

        this.signature_drop = new Gtk.DropDown (null, null) {
            valign = Gtk.Align.CENTER,
            vexpand = false,
            tooltip_text = _("Signature"),
        };
        this.signature_drop.add_css_class ("compose-from-signature");
        this.signature_drop.factory = ellipsize_string_factory ();
        this.signature_drop.notify["selected"].connect (on_signature_selected);

        var fields = new Adw.PreferencesGroup () {
            hexpand = true,
        };
        fields.add (build_from_row (from_model, selected_index));
        fields.add (this.to_row);
        fields.add (this.cc_row);
        fields.add (this.bcc_row);
        fields.add (this.subject_row);
        reload_signature_model ();
        this.settings.changed["account-signatures"].connect (() => {
            reload_signature_model ();
            if (this.toolbar_live)
                apply_selected_signature.begin ();
        });

        var clamp = new Adw.Clamp () {
            child = fields,
            maximum_size = 4000,
            tightening_threshold = 400,
            hexpand = true,
            margin_top = 12,
            margin_start = 12,
            margin_end = 12,
            margin_bottom = 8,
        };

        var initial_signature = "";
        if (!this.skip_initial_signature
            && this.signature_index > 0
            && this.signature_index <= this.signatures.length)
            initial_signature = this.signatures[this.signature_index - 1].compose_html ();

        this.body_view = new ComposeHtmlView (
            quoted,
            forward_quote,
            !this.focus_to_field,
            resend,
            initial_signature
        );
        this.body_view.files_dropped.connect ((files) => handle_dropped_files.begin (files));
        this.initial_body = "";
        this.body_view.ready.connect (() => {
            if (this.skip_initial_signature) {
                this.rebuilding_signatures = true;
                this.signature_drop.selected = 0;
                this.signature_index = 0;
                this.rebuilding_signatures = false;
            }
            finish_compose_ready ();
        });

        if (subject != null && subject.length > 0)
            this.subject_row.text = subject;
        skip_toolbar_on_tab (this.subject_row);

        this.attachments_box = new Adw.WrapBox () {
            visible = false,
            hexpand = true,
            vexpand = false,
            child_spacing = 8,
            line_spacing = 6,
            justify = Adw.JustifyMode.NONE,
            wrap_policy = Adw.WrapPolicy.NATURAL,
            margin_start = 12,
            margin_end = 12,
            margin_top = 8,
            margin_bottom = 4,
        };
        this.attachments_box.add_css_class ("compose-attachments");

        if ((forward_quote || resend) && quoted != null)
            add_attachments_from (quoted);

        this.initial_attachment_count = this.attachments.length;

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        box.append (clamp);
        box.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
        var format_bar = build_toolbar ();
        exclude_from_tab_chain (format_bar);
        format_bar.realize.connect (() => exclude_from_tab_chain (format_bar));
        exclude_from_tab_chain (this.attachments_box);
        box.append (format_bar);
        box.append (this.attachments_box);
        box.append (this.body_view);

        var toolbar = new Adw.ToolbarView () {
            content = box,
        };
        toolbar.add_top_bar (header);

        this.toast_overlay = new Adw.ToastOverlay () {
            child = toolbar,
        };
        this.content = this.toast_overlay;
        add_file_drop_target (this);

        close_request.connect (on_close_request);
        update_send_sensitive ();
    }

    private delegate void HeaderClicked ();

    private Gtk.Button header_icon (string icon, string tooltip, HeaderClicked clicked) {
        var button = new Gtk.Button.from_icon_name (icon) {
            tooltip_text = tooltip,
        };
        button.add_css_class ("flat");
        button.add_css_class ("message-action-button");
        button.clicked.connect (() => clicked ());
        return button;
    }

    public async bool offer_close () {
        persist_size ();
        if (this.force_close)
            return true;
        if (this.prompting) {
            present_for_attention ();
            return false;
        }

        this.prompting = true;
        var body = this.initial_body;
        try {
            body = yield this.body_view.get_plain ();
        } catch (Error e) {
        }

        if (!is_dirty_headers () && !this.body_mutated && body == this.initial_body) {
            this.force_close = true;
            this.prompting = false;
            close ();
            return true;
        }

        present_for_attention ();
        yield prompt_close ();
        return this.force_close;
    }

    public void present_for_attention () {
        present ();
    }

    private Account? selected_account () {
        if (this.from_drop != null) {
            var index = this.from_drop.selected;
            if (index == Gtk.INVALID_LIST_POSITION || index >= this.accounts.length)
                return null;

            return this.accounts[index];
        }

        return this.accounts.length > 0 ? this.accounts[0] : null;
    }

    private void update_send_sensitive () {
        this.send_button.sensitive = selected_account () != null && !this.to_row.is_empty;
    }

    private void remember_original_participants () {
        if (this.reply_of == null)
            return;

        add_participant_email (this.reply_of.from_email);
        add_participant_email (Utils.email_from_header (this.reply_of.from));
        add_participant_recipients (this.reply_of.to_recipients);
        add_participant_recipients (this.reply_of.cc_recipients);
        add_participant_recipients (this.reply_of.bcc_recipients);
        add_participant_recipients (Utils.parse_recipient_list (this.reply_of.to));
        add_participant_recipients (Utils.parse_recipient_list (this.reply_of.cc));
        add_participant_recipients (Utils.parse_recipient_list (this.reply_of.bcc));
    }

    private void add_participant_recipients (GenericArray<Recipient>? recipients) {
        if (recipients == null)
            return;
        for (uint i = 0; i < recipients.length; i++)
            add_participant_email (recipients[i].email);
    }

    private void add_participant_email (string? raw) {
        var email = Utils.sanitize_recipient_text (raw).down ();
        if (email.contains ("@"))
            this.original_participants.add (email);
    }

    private void on_compose_recipients_changed () {
        maybe_offer_original_attachments.begin ();
    }

    private bool reply_has_original_attachments () {
        return this.reply_of != null
            && this.reply_of.attachments != null
            && this.reply_of.attachments.length > 0;
    }

    private bool compose_has_new_recipient () {
        return row_has_new_recipient (this.to_row)
            || row_has_new_recipient (this.cc_row)
            || row_has_new_recipient (this.bcc_row);
    }

    private bool row_has_new_recipient (RecipientEditor row) {
        var recipients = row.recipients ();
        for (uint i = 0; i < recipients.length; i++) {
            var email = Utils.sanitize_recipient_text (recipients[i].email).down ();
            if (email.contains ("@") && !this.original_participants.contains (email))
                return true;
        }
        return false;
    }

    private bool already_has_attachment (Attachment source) {
        var name = source.filename ?? "";
        var size = source.data != null ? source.data.get_size () : 0;
        for (uint i = 0; i < this.attachments.length; i++) {
            var listed = this.attachments[i];
            if ((listed.filename ?? "") != name)
                continue;
            var listed_size = listed.data != null ? listed.data.get_size () : 0;
            if (listed_size == size)
                return true;
        }
        return false;
    }

    private bool missing_original_attachments () {
        if (!reply_has_original_attachments ())
            return false;
        for (uint i = 0; i < this.reply_of.attachments.length; i++) {
            if (!already_has_attachment (this.reply_of.attachments[i]))
                return true;
        }
        return false;
    }

    private async void maybe_offer_original_attachments () {
        if (this.attachment_offer_done || this.prompting)
            return;
        if (!reply_has_original_attachments () || !missing_original_attachments ())
            return;
        if (!compose_has_new_recipient ())
            return;

        this.attachment_offer_done = true;
        this.prompting = true;
        var count = this.reply_of.attachments.length;
        var dialog = new Adw.AlertDialog (
            _("Include original attachments?"),
            ngettext (
                "You added someone who did not receive the original message. Attach the file from that message?",
                "You added someone who did not receive the original message. Attach the files from that message?",
                count
            )
        );
        dialog.add_response ("skip", _("Don't Attach"));
        dialog.add_response ("attach", _("Attach"));
        dialog.set_response_appearance ("attach", Adw.ResponseAppearance.SUGGESTED);
        dialog.default_response = "attach";
        dialog.close_response = "skip";

        var response = yield dialog.choose (this, null);
        this.prompting = false;
        if (response == "attach")
            add_attachments_from (this.reply_of);
    }

    private void add_attachments_from (MessageContent content) {
        if (content.attachments == null)
            return;

        var added = false;
        for (uint i = 0; i < content.attachments.length; i++) {
            var source = content.attachments[i];
            if (already_has_attachment (source))
                continue;
            this.attachments.add (new Attachment () {
                filename = source.filename,
                mime_type = source.mime_type,
                data = source.data,
                file = source.file,
            });
            added = true;
        }
        if (added)
            refresh_attachment_chips ();
    }

    private void focus_initial_field () {
        if (this.focus_to_field)
            this.to_row.grab_focus ();
        else
            this.body_view.grab_focus ();
    }

    private void finish_compose_ready () {
        this.toolbar_live = true;
        focus_initial_field ();
        this.body_view.get_plain.begin ((p, pres) => {
            try {
                this.initial_body = this.body_view.get_plain.end (pres);
            } catch (Error e) {
                this.initial_body = "";
            }
        });
        if (this.focus_to_field) {
            Idle.add (() => {
                this.to_row.grab_focus ();
                return Source.REMOVE;
            });
        }
    }

    private bool is_dirty_headers () {
        return this.to_row.text != this.initial_to
            || this.cc_row.text != this.initial_cc
            || this.bcc_row.text != this.initial_bcc
            || this.subject_row.text != this.initial_subject
            || this.attachments.length != this.initial_attachment_count;
    }

    private void persist_size () {
        if (maximized)
            return;

        this.settings.set_int ("compose-width", get_width ().clamp (480, 4000));
        this.settings.set_int ("compose-height", get_height ().clamp (360, 4000));
    }

    private bool on_close_request () {
        persist_size ();
        if (this.force_close)
            return false;

        if (this.prompting) {
            present_for_attention ();
            return true;
        }
        offer_close.begin ();
        return true;
    }

    private async void prompt_close () {
        this.prompting = true;
        present_for_attention ();
        var dialog = new Adw.AlertDialog (
            _("Save this message as a draft?"),
            _("It will be stored in Drafts so you can finish it later.")
        );
        dialog.add_response ("discard", _("Discard"));
        dialog.add_response ("cancel", _("Keep Editing"));
        dialog.add_response ("save", _("Save Draft"));
        dialog.set_response_appearance ("discard", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_response_appearance ("save", Adw.ResponseAppearance.SUGGESTED);
        dialog.default_response = "save";
        dialog.close_response = "cancel";

        var response = yield dialog.choose (this, null);
        this.prompting = false;

        if (response == "save") {
            try {
                yield save_draft ();
                this.force_close = true;
                close ();
            } catch (Error e) {
                this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                    timeout = 5,
                });
            }
        } else if (response == "discard") {
            this.force_close = true;
            close ();
        }
    }

    private async void save_draft () throws Error {
        var account = selected_account ();
        if (account == null) {
            throw new IOError.FAILED (_("This account has no sending identity."));
        }

        this.to_row.commit_pending ();
        this.cc_row.commit_pending ();
        this.bcc_row.commit_pending ();
        string plain;
        string html;
        yield this.body_view.get_bodies (out plain, out html);
        yield this.session.save_draft (
            account,
            this.to_row.text,
            this.cc_row.text,
            this.subject_row.text,
            plain,
            html,
            this.bcc_row.text,
            this.attachments,
            this.thread_of
        );
        yield remember_clean_state ();
    }

    private async void remember_clean_state () {
        this.initial_to = this.to_row.text;
        this.initial_cc = this.cc_row.text;
        this.initial_bcc = this.bcc_row.text;
        this.initial_subject = this.subject_row.text;
        this.initial_attachment_count = this.attachments.length;
        try {
            this.initial_body = yield this.body_view.get_plain ();
        } catch (Error e) {
        }
    }

    private async void save_draft_now () {
        try {
            yield save_draft ();
            this.toast_overlay.add_toast (new Adw.Toast (_("Saved to Drafts")) {
                timeout = 3,
            });
        } catch (Error e) {
            this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                timeout = 5,
            });
        }
    }

    private void print_message () {
        this.body_view.print (this);
    }

    private async void send () {
        var account = selected_account ();
        if (account == null || this.sending)
            return;

        this.sending = true;
        this.to_row.commit_pending ();
        this.cc_row.commit_pending ();
        this.bcc_row.commit_pending ();
        this.send_button.sensitive = false;
        Idle.add (send.callback);
        yield;

        string plain;
        string html;
        try {
            yield this.body_view.get_bodies (out plain, out html);
        } catch (Error body_error) {
            this.sending = false;
            this.send_button.sensitive = true;
            this.toast_overlay.add_toast (new Adw.Toast (body_error.message) {
                timeout = 5,
            });
            return;
        }

        var to = this.to_row.text;
        var cc = this.cc_row.text;
        var bcc = this.bcc_row.text;
        var subject = this.subject_row.text;
        var attachments = this.attachments;
        var thread_of = this.thread_of;
        var to_recipients = this.to_row.recipients ();
        var cc_recipients = this.cc_row.recipients ();
        var session = this.session;
        var app = get_application () as Application;

        try {
            session.ensure_can_send (account, to, cc, bcc);
        } catch (Error valid_error) {
            this.sending = false;
            this.send_button.sensitive = true;
            this.toast_overlay.add_toast (new Adw.Toast (Utils.friendly_send_error (valid_error)) {
                timeout = 5,
            });
            return;
        }

        this.force_close = true;
        persist_size ();
        close ();

        try {
            yield session.send_message (
                account,
                to,
                cc,
                subject,
                plain,
                html,
                bcc,
                attachments,
                thread_of
            );
            app?.contacts.remember_recipients (to_recipients);
            app?.contacts.remember_recipients (cc_recipients);
        } catch (Error e) {
            var message = Utils.friendly_send_error (e);
            try {
                yield session.save_draft (
                    account,
                    to,
                    cc,
                    subject,
                    plain,
                    html,
                    bcc,
                    attachments,
                    thread_of
                );
                app?.show_mail_toast (
                    "%s %s".printf (message, _("The message was saved to Drafts."))
                );
            } catch (Error save_error) {
                app?.show_mail_toast (message);
            }
        }
    }

    private Gtk.Widget build_toolbar () {
        var bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            hexpand = true,
            vexpand = false,
            valign = Gtk.Align.CENTER,
        };
        bar.add_css_class ("compose-toolbar");

        var font_drop = build_font_drop ();
        font_drop.add_css_class ("compose-font-drop");
        font_drop.valign = Gtk.Align.CENTER;
        font_drop.vexpand = false;
        font_drop.tooltip_text = _("Font");
        font_drop.enable_search = true;
        font_drop.notify["selected"].connect (() => {
            if (!this.toolbar_live)
                return;
            var index = font_drop.selected;
            if (index < this.font_families.length)
                this.body_view.apply_font (this.font_families[index]);
        });

        var size_drop = new Gtk.DropDown.from_strings ({
            _("Small"),
            _("Normal"),
            _("Large"),
            _("Huge"),
        });
        size_drop.add_css_class ("compose-size-drop");
        size_drop.selected = 1;
        size_drop.valign = Gtk.Align.CENTER;
        size_drop.vexpand = false;
        size_drop.tooltip_text = _("Font size");
        size_drop.notify["selected"].connect (() => {
            if (!this.toolbar_live)
                return;
            string[] sizes = { "2", "3", "4", "6" };
            var index = size_drop.selected;
            if (index < sizes.length)
                this.body_view.apply_size (sizes[index]);
        });

        bar.append (font_drop);
        bar.append (size_drop);

        var formats = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4) {
            hexpand = true,
            vexpand = false,
            valign = Gtk.Align.CENTER,
        };
        formats.append (command_button ("format-text-bold-symbolic", _("Bold"), "Bold"));
        formats.append (command_button ("format-text-italic-symbolic", _("Italic"), "Italic"));
        formats.append (command_button ("format-text-underline-symbolic", _("Underline"), "Underline"));
        formats.append (command_button ("format-text-strikethrough-symbolic", _("Strikethrough"), "Strikethrough"));
        formats.append (color_menu_button (false));
        formats.append (color_menu_button (true));
        formats.append (command_button (
            "view-list-bullet-symbolic",
            _("Bullet list (Tab indents, Shift+Tab outdents)"),
            "InsertUnorderedList"
        ));
        formats.append (command_button (
            "view-list-ordered-symbolic",
            _("Numbered list (Tab indents, Shift+Tab outdents)"),
            "InsertOrderedList"
        ));
        formats.append (command_button ("format-indent-less-symbolic", _("Decrease Indent"), "Outdent"));
        formats.append (command_button ("format-indent-more-symbolic", _("Increase Indent"), "Indent"));
        formats.append (emoji_button ());
        formats.append (icon_action_button ("image-x-generic-symbolic", _("Insert Image"), () => prompt_insert_image.begin ()));
        bar.append (formats);

        var attach = new Gtk.Button.from_icon_name ("mail-attachment-symbolic") {
            valign = Gtk.Align.CENTER,
            tooltip_text = _("Attach file"),
        };
        attach.add_css_class ("flat");
        attach.clicked.connect (() => attach_files.begin ());
        bar.append (attach);

        var bcc = new Gtk.ToggleButton () {
            label = _("Bcc"),
            valign = Gtk.Align.CENTER,
            tooltip_text = _("Show Bcc"),
            active = this.bcc_row.visible,
        };
        bcc.add_css_class ("flat");
        bcc.toggled.connect (() => {
            this.bcc_row.visible = bcc.active;
            if (bcc.active)
                this.bcc_row.grab_focus ();
        });
        bar.append (bcc);

        return bar;
    }

    private Gtk.Widget build_from_row (Gtk.StringList from_model, uint selected_index) {
        var row = new Adw.PreferencesRow () {
            activatable = false,
        };
        row.add_css_class ("compose-from-row");

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            margin_start = 12,
            margin_end = 12,
            margin_top = 6,
            margin_bottom = 6,
            hexpand = true,
            valign = Gtk.Align.CENTER,
        };

        var from_label = new Gtk.Label (_("From")) {
            xalign = 0,
            width_chars = 3,
            valign = Gtk.Align.CENTER,
            use_markup = false,
        };
        from_label.add_css_class ("dim-label");
        from_label.add_css_class ("caption");

        Gtk.Widget identity;
        if (this.accounts.length > 1) {
            this.from_drop = new Gtk.DropDown (from_model, null) {
                hexpand = true,
                halign = Gtk.Align.FILL,
                valign = Gtk.Align.CENTER,
                vexpand = false,
                selected = selected_index,
                tooltip_text = _("From"),
                enable_search = this.accounts.length > 6,
            };
            this.from_drop.add_css_class ("compose-from-identity");
            this.from_drop.factory = ellipsize_string_factory ();
            this.from_drop.notify["selected"].connect (update_send_sensitive);
            this.from_drop.notify["selected"].connect (on_from_account_changed);
            identity = this.from_drop;
        } else {
            var text = from_model.get_n_items () > 0 ? from_model.get_string (0) : "";
            var identity_label = new Gtk.Label (text) {
                xalign = 0,
                hexpand = true,
                ellipsize = Pango.EllipsizeMode.END,
                single_line_mode = true,
                selectable = false,
                valign = Gtk.Align.CENTER,
                tooltip_text = text,
            };
            identity_label.add_css_class ("compose-from-identity");
            identity = identity_label;
        }

        var signature_label = new Gtk.Label (_("Signature")) {
            xalign = 0,
            valign = Gtk.Align.CENTER,
            use_markup = false,
        };
        signature_label.add_css_class ("dim-label");
        signature_label.add_css_class ("caption");

        this.signature_drop.hexpand = false;
        this.signature_drop.halign = Gtk.Align.FILL;
        this.signature_drop.width_request = 180;

        var identity_side = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            hexpand = true,
            halign = Gtk.Align.FILL,
            valign = Gtk.Align.CENTER,
        };
        identity_side.append (from_label);
        identity_side.append (identity);

        var signature_side = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            hexpand = false,
            halign = Gtk.Align.END,
            valign = Gtk.Align.CENTER,
        };
        signature_side.append (signature_label);
        signature_side.append (this.signature_drop);

        var split = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            hexpand = true,
            valign = Gtk.Align.CENTER,
        };
        split.append (identity_side);
        split.append (signature_side);
        box.append (split);

        row.child = box;
        return row;
    }

    private static Gtk.ListItemFactory ellipsize_string_factory () {
        var factory = new Gtk.SignalListItemFactory ();
        factory.setup.connect ((item) => {
            var list_item = (Gtk.ListItem) item;
            list_item.child = new Gtk.Label ("") {
                xalign = 0,
                hexpand = true,
                ellipsize = Pango.EllipsizeMode.END,
                single_line_mode = true,
            };
        });
        factory.bind.connect ((item) => {
            var list_item = (Gtk.ListItem) item;
            var label = (Gtk.Label) list_item.child;
            var value = list_item.item as Gtk.StringObject;
            label.label = value != null ? value.string : "";
        });
        return factory;
    }

    private Gtk.Button command_button (string icon, string tooltip, string command) {
        return icon_action_button (icon, tooltip, () => this.body_view.apply_command (command));
    }

    private Gtk.Button icon_action_button (string icon, string tooltip, owned FormatToolbar.VoidFunc action) {
        var button = new Gtk.Button.from_icon_name (icon) {
            valign = Gtk.Align.CENTER,
            tooltip_text = tooltip,
            focus_on_click = false,
        };
        button.add_css_class ("flat");
        button.clicked.connect (() => action ());
        return button;
    }

    private Gtk.Widget emoji_button () {
        var chooser = new Gtk.EmojiChooser ();
        var button = new Gtk.MenuButton () {
            valign = Gtk.Align.CENTER,
            tooltip_text = _("Insert Emoji"),
            icon_name = "face-smile-symbolic",
            popover = chooser,
            always_show_arrow = false,
            direction = Gtk.ArrowType.DOWN,
            focus_on_click = false,
        };
        button.add_css_class ("flat");
        button.add_css_class ("compose-format-menu");
        chooser.emoji_picked.connect ((text) => this.body_view.insert_text (text));
        return button;
    }

    private Gtk.Widget color_menu_button (bool highlight) {
        var popover = new Gtk.Popover ();
        popover.add_css_class ("compose-color-popover");
        var button = new Gtk.MenuButton () {
            valign = Gtk.Align.CENTER,
            tooltip_text = highlight ? _("Highlight") : _("Text Color"),
            popover = popover,
            always_show_arrow = false,
            direction = Gtk.ArrowType.DOWN,
            focus_on_click = false,
        };
        button.add_css_class ("flat");
        button.add_css_class ("compose-format-menu");
        if (highlight) {
            var glyph = new Gtk.Label ("A");
            glyph.add_css_class ("compose-highlight-glyph");
            button.child = glyph;
        } else {
            button.icon_name = "color-select-symbolic";
        }

        popover.child = build_color_palette (highlight, popover);
        return button;
    }

    private Gtk.Widget build_color_palette (bool highlight, Gtk.Popover popover) {
        var grid = new Gtk.Grid () {
            column_spacing = 6,
            row_spacing = 6,
            margin_start = 8,
            margin_end = 8,
            margin_top = 8,
            margin_bottom = 8,
        };

        var none = palette_icon_button (
            highlight ? _("No Highlight") : _("Default Color"),
            "edit-clear-symbolic"
        );
        none.clicked.connect (() => {
            popover.popdown ();
            if (highlight)
                this.body_view.apply_highlight ("");
            else
                this.body_view.apply_color ("");
        });
        grid.attach (none, 0, 0, 1, 1);

        string[] colors;
        string[] names;
        if (highlight) {
            colors = { "#f8e45c", "#8ff0a4", "#99c1f1", "#dc8add", "#ffbe6f", "#ffffff" };
            names = { _("Yellow"), _("Green"), _("Blue"), _("Pink"), _("Orange"), _("White") };
        } else {
            colors = {
                "#1c1c1c", "#5e5c64", "#c01c28", "#e66100", "#e5a50a",
                "#26a269", "#1c71d8", "#813d9c", "#ffffff"
            };
            names = {
                _("Black"), _("Gray"), _("Red"), _("Orange"), _("Gold"),
                _("Green"), _("Blue"), _("Purple"), _("White")
            };
        }

        for (int i = 0; i < colors.length; i++) {
            var swatch = color_swatch (colors[i], names[i]);
            connect_palette_color (swatch, popover, highlight, colors[i]);
            var slot = i + 1;
            grid.attach (swatch, slot % 5, slot / 5, 1, 1);
        }

        var custom = palette_icon_button (_("Custom Color…"), "color-select-symbolic");
        custom.clicked.connect (() => {
            popover.popdown ();
            pick_custom_color.begin (highlight);
        });
        var custom_slot = colors.length + 1;
        grid.attach (custom, custom_slot % 5, custom_slot / 5, 1, 1);
        return grid;
    }

    private void connect_palette_color (Gtk.Button swatch, Gtk.Popover popover, bool highlight, string hex) {
        swatch.clicked.connect (() => {
            popover.popdown ();
            if (highlight)
                this.body_view.apply_highlight (hex);
            else
                this.body_view.apply_color (hex);
        });
    }

    private static Gtk.Button palette_icon_button (string tooltip, string icon) {
        var button = new Gtk.Button.from_icon_name (icon) {
            tooltip_text = tooltip,
            width_request = 28,
            height_request = 28,
            focus_on_click = false,
            valign = Gtk.Align.CENTER,
            halign = Gtk.Align.CENTER,
        };
        button.add_css_class ("flat");
        button.add_css_class ("compose-color-swatch");
        return button;
    }

    private static Gtk.Button color_swatch (string hex, string tooltip) {
        var button = new Gtk.Button () {
            tooltip_text = tooltip,
            width_request = 28,
            height_request = 28,
            focus_on_click = false,
            valign = Gtk.Align.CENTER,
            halign = Gtk.Align.CENTER,
        };
        button.add_css_class ("compose-color-swatch");
        button.add_css_class ("c-%s".printf (hex.substring (1).down ()));
        return button;
    }

    private async void pick_custom_color (bool highlight) {
        var dialog = new Gtk.ColorDialog () {
            title = highlight ? _("Highlight") : _("Text Color"),
            modal = true,
            with_alpha = false,
        };
        try {
            var rgba = yield dialog.choose_rgba (this, null, null);
            if (rgba == null)
                return;
            var hex = "#%02x%02x%02x".printf (
                (uint) (rgba.red * 255.0 + 0.5),
                (uint) (rgba.green * 255.0 + 0.5),
                (uint) (rgba.blue * 255.0 + 0.5)
            );
            if (highlight)
                this.body_view.apply_highlight (hex);
            else
                this.body_view.apply_color (hex);
        } catch (Error e) {
            if (!(e is Gtk.DialogError.DISMISSED) && !(e is IOError.CANCELLED))
                debug ("Could not pick compose color: %s", e.message);
        }
    }

    private Gtk.DropDown build_font_drop () {
        var labels = new Gtk.StringList (null);
        this.font_families = new GenericArray<string> ();
        append_font (labels, _("Sans Serif"), "sans-serif");
        append_font (labels, _("Serif"), "serif");
        append_font (labels, _("Monospace"), "monospace");

        var installed = installed_font_names ();
        string[] catalog = {
            "Adwaita Sans",
            "Adwaita Mono",
            "Arial",
            "Caladea",
            "Calibri",
            "Cambria",
            "Cantarell",
            "Carlito",
            "Comfortaa",
            "Comic Sans MS",
            "Consolas",
            "Courier New",
            "DejaVu Sans",
            "DejaVu Sans Mono",
            "DejaVu Serif",
            "FreeMono",
            "FreeSans",
            "FreeSerif",
            "Georgia",
            "IBM Plex Sans",
            "Inter",
            "Liberation Mono",
            "Liberation Sans",
            "Liberation Serif",
            "Noto Sans",
            "Noto Serif",
            "Source Code Pro",
            "Source Sans 3",
            "Tahoma",
            "Times New Roman",
            "Trebuchet MS",
            "Ubuntu",
            "Verdana",
        };

        var extra = new GenericArray<string> ();
        foreach (var family in catalog) {
            if (installed.contains (family.down ()))
                extra.add (family);
        }
        extra.sort ((a, b) => a.collate (b));
        for (uint i = 0; i < extra.length; i++)
            append_font (labels, extra[i], extra[i]);

        return new Gtk.DropDown (labels, null);
    }

    private void append_font (Gtk.StringList labels, string label, string family) {
        labels.append (label);
        this.font_families.add (family);
    }

    private GenericSet<string> installed_font_names () {
        var names = new GenericSet<string> (str_hash, str_equal);
        Pango.FontFamily[] families;
        get_pango_context ().list_families (out families);
        foreach (unowned var family in families) {
            unowned string name = family.get_name ();
            if (name != null && name.length > 0)
                names.add (name.down ());
        }
        return names;
    }

    private void reload_signature_model () {
        this.signatures = load_signatures ();
        var names = new Gtk.StringList (null);
        names.append (_("None"));
        var last = "";
        var account = selected_account ();
        if (account != null)
            last = this.signature_store.default_name (account.signature_key);
        uint selected = 0;
        for (uint i = 0; i < this.signatures.length; i++) {
            names.append (this.signatures[i].name);
            if (last.length > 0 && this.signatures[i].name == last)
                selected = i + 1;
        }

        this.rebuilding_signatures = true;
        this.signature_drop.model = names;
        this.signature_drop.selected = selected;
        this.signature_index = selected;
        this.rebuilding_signatures = false;
    }

    private GenericArray<MailSignature> load_signatures () {
        var account = selected_account ();
        if (account == null)
            return new GenericArray<MailSignature> ();
        return this.signature_store.list (account.signature_key);
    }

    private void on_from_account_changed () {
        reload_signature_model ();
        if (this.toolbar_live)
            apply_selected_signature.begin ();
    }

    private void on_signature_selected () {
        if (this.rebuilding_signatures)
            return;

        var selected = this.signature_drop.selected;
        if (selected == Gtk.INVALID_LIST_POSITION)
            return;

        this.signature_index = selected;
        if (this.toolbar_live)
            apply_selected_signature.begin ();
    }

    private async void apply_selected_signature () {
        string html = "";
        if (this.signature_index > 0 && this.signature_index <= this.signatures.length)
            html = this.signatures[this.signature_index - 1].compose_html ();
        try {
            yield this.body_view.set_signature_html (html);
        } catch (Error e) {
            debug ("Could not apply signature: %s", e.message);
        }
    }

    private async void prompt_insert_image () {
        yield ComposeExtras.prompt_insert_image (this, this.body_view);
        this.body_mutated = true;
    }

    private async void attach_files () {
        var dialog = new Gtk.FileDialog () {
            title = _("Attach Files"),
        };

        try {
            var files = yield dialog.open_multiple (this, null);
            for (uint i = 0; i < files.get_n_items (); i++) {
                var file = files.get_item (i) as File;
                if (file != null)
                    yield add_attachment_file (file);
            }
        } catch (Error e) {
            if (e is IOError.CANCELLED || e is Gtk.DialogError.DISMISSED)
                return;
            this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                timeout = 4,
            });
        }
    }

    private async void add_attachment_file (File file) {
        try {
            var info = yield file.query_info_async (
                FileAttribute.STANDARD_DISPLAY_NAME + "," +
                FileAttribute.STANDARD_CONTENT_TYPE + "," +
                FileAttribute.STANDARD_SIZE + "," +
                FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NONE,
                Priority.DEFAULT,
                null
            );
            if (is_folder_info (info)) {
                show_compose_toast (_("Folders cannot be attached."));
                return;
            }
            if (info.get_size () > MAX_ATTACHMENT_BYTES) {
                show_compose_toast (too_large_message (info.get_display_name ()), 6);
                return;
            }

            string? etag;
            var bytes = yield file.load_bytes_async (null, out etag);
            if (bytes.get_size () > MAX_ATTACHMENT_BYTES) {
                show_compose_toast (too_large_message (info.get_display_name ()), 6);
                return;
            }

            bool uncertain;
            unowned uint8[] data = bytes.get_data ();
            var mime = ContentType.guess (info.get_display_name (), data, out uncertain);
            if (mime == null || mime.length == 0)
                mime = info.get_content_type () ?? "application/octet-stream";

            this.attachments.add (new Attachment () {
                filename = info.get_display_name (),
                mime_type = mime,
                data = bytes,
                file = file,
            });
            refresh_attachment_chips ();
        } catch (Error e) {
            show_compose_toast (
                _("Could not attach “%s”.").printf (file.get_basename () ?? file.get_uri ())
            );
        }
    }

    private void add_file_drop_target (Gtk.Widget widget) {
        var target = new Gtk.DropTarget (Type.INVALID, Gdk.DragAction.COPY);
        target.set_gtypes ({ typeof (Gdk.FileList), typeof (File) });
        target.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        target.accept.connect (compose_drop_is_external);
        target.drop.connect ((value, x, y) => {
            var files = compose_usable_drop_files (value);
            if (files.length == 0)
                return false;
            handle_dropped_files.begin (files);
            return true;
        });
        widget.add_controller (target);
    }

    private async void handle_dropped_files (GenericArray<File> files) {
        var accepted = new GenericArray<File> ();
        var infos = new GenericArray<FileInfo> ();
        var oversized = 0;
        string? oversized_name = null;
        var had_folder = false;

        for (uint i = 0; i < files.length; i++) {
            var file = files[i];
            if (!claim_drop (file))
                continue;

            FileInfo info;
            try {
                info = yield file.query_info_async (
                    FileAttribute.STANDARD_DISPLAY_NAME + "," +
                    FileAttribute.STANDARD_CONTENT_TYPE + "," +
                    FileAttribute.STANDARD_SIZE + "," +
                    FileAttribute.STANDARD_TYPE,
                    FileQueryInfoFlags.NONE,
                    Priority.DEFAULT,
                    null
                );
            } catch (Error e) {
                continue;
            }

            if (is_folder_info (info)) {
                had_folder = true;
                continue;
            }
            if (info.get_size () > MAX_ATTACHMENT_BYTES) {
                oversized++;
                oversized_name = info.get_display_name ();
                continue;
            }

            accepted.add (file);
            infos.add (info);
        }

        if (had_folder)
            show_compose_toast (_("Folders cannot be attached."));
        if (oversized == 1 && oversized_name != null)
            show_compose_toast (too_large_message (oversized_name), 6);
        else if (oversized > 1)
            show_compose_toast (too_large_message_many (oversized), 6);

        if (accepted.length == 0)
            return;

        if (accepted.length == 1 && is_jpeg_or_png (infos[0])) {
            yield prompt_image_drop (accepted[0], infos[0]);
            return;
        }

        for (uint i = 0; i < accepted.length; i++)
            yield add_attachment_file (accepted[i]);
    }

    private async void prompt_image_drop (File file, FileInfo info) {
        var dialog = new Adw.AlertDialog (
            _("Attach or insert this image?"),
            _("“%s” can be attached to the message or placed in the body.").printf (info.get_display_name ())
        );
        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("attach", _("Attach"));
        dialog.add_response ("insert", _("Insert"));
        dialog.set_response_appearance ("insert", Adw.ResponseAppearance.SUGGESTED);
        dialog.default_response = "insert";
        dialog.close_response = "cancel";

        var response = yield dialog.choose (this, null);
        if (response == "attach")
            yield add_attachment_file (file);
        else if (response == "insert")
            yield insert_inline_image (file, info);
    }

    private async void insert_inline_image (File file, FileInfo info) {
        try {
            string? etag;
            var bytes = yield file.load_bytes_async (null, out etag);
            if (bytes.get_size () > MAX_ATTACHMENT_BYTES) {
                show_compose_toast (too_large_message (info.get_display_name ()), 6);
                return;
            }

            bool uncertain;
            unowned uint8[] data = bytes.get_data ();
            var mime = ContentType.guess (info.get_display_name (), data, out uncertain);
            if (mime == null || mime.length == 0)
                mime = info.get_content_type ();
            if (mime != null && mime.length > 0)
                mime = ContentType.get_mime_type (mime) ?? mime;
            if (mime == null || mime.length == 0 || !(ContentType.is_a (mime, "image/jpeg") || ContentType.is_a (mime, "image/png"))) {
                var name = info.get_display_name ().down ();
                mime = name.has_suffix (".png") ? "image/png" : "image/jpeg";
            }

            var shrunk = this.body_view.insert_image (bytes, mime, info.get_display_name ());
            this.body_mutated = true;
            if (shrunk)
                show_compose_toast (_("The image was resized to stay under 2 MB."), 4);
        } catch (Error e) {
            show_compose_toast (
                _("Could not insert “%s”.").printf (info.get_display_name ())
            );
        }
    }

    private bool claim_drop (File file) {
        var key = file.get_uri ();
        if (key == null || key.length == 0)
            key = file.get_path () ?? file.get_basename () ?? "";
        if (key.length == 0)
            return true;
        if (this.recent_drops.contains (key))
            return false;

        this.recent_drops.set (key, 1);
        var captured = key;
        Timeout.add (800, () => {
            this.recent_drops.remove (captured);
            return Source.REMOVE;
        });
        return true;
    }

    private void show_compose_toast (string message, uint timeout = 4) {
        this.toast_overlay.add_toast (new Adw.Toast (message) {
            timeout = timeout,
        });
    }

    private static string too_large_message (string filename) {
        return _("“%s” is too large to attach. Use a file transfer service and send the link instead.").printf (filename);
    }

    private static string too_large_message_many (uint count) {
        return _("%u files are too large to attach. Use a file transfer service and send the links instead.").printf (count);
    }

    private static bool is_folder_info (FileInfo info) {
        var type = info.get_file_type ();
        return type == FileType.DIRECTORY || type == FileType.MOUNTABLE;
    }

    private static bool is_jpeg_or_png (FileInfo info) {
        var name = info.get_display_name ().down ();
        if (name.has_suffix (".jpg") || name.has_suffix (".jpeg") || name.has_suffix (".png"))
            return true;

        var content = info.get_content_type ();
        if (content == null || content.length == 0)
            return false;

        return ContentType.is_a (content, "image/jpeg") || ContentType.is_a (content, "image/png");
    }

    private void refresh_attachment_chips () {
        Gtk.Widget? child = this.attachments_box.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            this.attachments_box.remove (child);
            child = next;
        }

        for (uint i = 0; i < this.attachments.length; i++)
            append_attachment_chip (this.attachments[i]);

        this.attachments_box.visible = this.attachments.length > 0;
    }

    private void append_attachment_chip (Attachment attachment) {
        var chip = new AttachmentChip (attachment, true);
        chip.removed.connect (() => {
            this.attachments.remove (attachment);
            refresh_attachment_chips ();
        });
        this.attachments_box.append (chip);
        exclude_from_tab_chain (chip);
    }

    private void skip_toolbar_on_tab (Gtk.Widget field) {
        var keys = new Gtk.EventControllerKey ();
        keys.set_propagation_phase (Gtk.PropagationPhase.CAPTURE);
        keys.key_pressed.connect ((keyval, keycode, state) => {
            if (keyval != Gdk.Key.Tab)
                return false;
            var mods = state & Gtk.accelerator_get_default_mod_mask ();
            if (mods != 0)
                return false;
            this.body_view.grab_focus ();
            return true;
        });
        field.add_controller (keys);
    }

    private static void exclude_from_tab_chain (Gtk.Widget widget) {
        if (widget is Gtk.Popover)
            return;

        widget.focusable = false;
        widget.focus_on_click = false;
        for (var child = widget.get_first_child (); child != null; child = child.get_next_sibling ())
            exclude_from_tab_chain (child);
    }
}

public class Mail.ComposeHtmlView : Gtk.Box {
    private const int64 MAX_INLINE_IMAGE_BYTES = 2 * 1024 * 1024;
    private const int INLINE_SMALL_WIDTH = 160;
    private const int INLINE_MEDIUM_WIDTH = 320;

    private WebKit.NetworkSession network_session;
    private WebKit.WebView webview;
    private Gtk.Stack stack;
    private SimpleAction image_size_small;
    private SimpleAction image_size_medium;
    private SimpleAction image_size_original;
    private SimpleAction image_delete;
    private SimpleAction unlink_action;
    private SimpleAction learn_spelling;
    private string[] spell_langs = {};
    private HashTable<string, StoredInlineImage> inline_images = new HashTable<string, StoredInlineImage> (str_hash, str_equal);
    private uint image_serial;
    private string? current_image_id;
    private bool loaded;
    private bool focus_editor;
    private SourceFunc? loaded_callback;

    private class StoredInlineImage {
        public string id;
        public string alt;
        public string mime;
        public Bytes original;
        public Gdk.Pixbuf pixbuf;
    }

    private class EncodedInline {
        public Bytes bytes;
        public string mime;
        public Gdk.Pixbuf pixbuf;
    }

    public signal void ready ();
    public signal void files_dropped (GenericArray<File> files);

    public ComposeHtmlView (
        MessageContent? quoted,
        bool forward_quote,
        bool focus_editor = true,
        bool resend = false,
        string signature_html = "",
        string? initial_html = null
    ) {
        Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
        hexpand = true;
        vexpand = true;
        add_css_class ("compose-body");
        this.focus_editor = focus_editor;

        var settings = new WebKit.Settings () {
            enable_javascript = true,
            enable_javascript_markup = false,
            javascript_can_open_windows_automatically = false,
            javascript_can_access_clipboard = false,
            allow_modal_dialogs = false,
            enable_html5_database = false,
            enable_html5_local_storage = false,
            enable_page_cache = false,
            auto_load_images = true,
        };

        this.network_session = new WebKit.NetworkSession.ephemeral ();
        this.webview = (WebKit.WebView) Object.new (typeof (WebKit.WebView),
            "network-session", this.network_session,
            "settings", settings,
            "hexpand", true,
            "vexpand", true
        );
        var manager = this.webview.get_user_content_manager ();
        manager.script_message_received.connect (on_script_message);
        if (!manager.register_script_message_handler ("compose", (string) null))
            warning ("Could not register compose script message handler");
        this.webview.add_css_class ("compose-body");
        this.webview.decide_policy.connect (on_decide_policy);
        this.webview.load_changed.connect (on_load_changed);
        this.webview.context_menu.connect (on_context_menu);
        enable_spell_checking ();
        add_editing_shortcuts ();
        add_file_drop_target ();
        add_image_size_actions ();
        update_webview_background ();
        this.webview.realize.connect (update_webview_background);
        Adw.StyleManager.get_default ().notify["dark"].connect (update_webview_background);

        var placeholder = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            hexpand = true,
            vexpand = true,
        };
        placeholder.add_css_class ("compose-body-placeholder");

        this.stack = new Gtk.Stack () {
            hexpand = true,
            vexpand = true,
            transition_type = Gtk.StackTransitionType.NONE,
        };
        this.stack.add_css_class ("compose-body-stack");
        this.stack.add_named (placeholder, "loading");
        this.stack.add_named (this.webview, "body");
        append (this.stack);
        this.webview.load_html (
            build_document (quoted, forward_quote, resend, signature_html, initial_html),
            "about:blank"
        );
    }

    private void add_file_drop_target () {
        var target = new Gtk.DropTarget (Type.INVALID, Gdk.DragAction.COPY);
        target.set_gtypes ({ typeof (Gdk.FileList), typeof (File) });
        target.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        target.accept.connect (compose_drop_is_external);
        target.drop.connect ((value, x, y) => {
            var files = compose_usable_drop_files (value);
            if (files.length == 0)
                return false;
            files_dropped (files);
            return true;
        });
        this.webview.add_controller (target);
    }

    private void add_image_size_actions () {
        this.image_size_small = new SimpleAction ("compose-image-small", null);
        this.image_size_medium = new SimpleAction ("compose-image-medium", null);
        this.image_size_original = new SimpleAction ("compose-image-original", null);
        this.image_delete = new SimpleAction ("compose-image-delete", null);
        this.unlink_action = new SimpleAction ("compose-unlink", null);
        this.image_size_small.activate.connect (() => apply_to_current_image ("small"));
        this.image_size_medium.activate.connect (() => apply_to_current_image ("medium"));
        this.image_size_original.activate.connect (() => apply_to_current_image ("original"));
        this.image_delete.activate.connect (delete_current_image);
        this.unlink_action.activate.connect (remove_current_link);
        this.learn_spelling = new SimpleAction ("compose-learn-spelling", null);
        this.learn_spelling.activate.connect (() => learn_selected_spelling.begin ());
    }

    private void remove_current_link () {
        this.webview.evaluate_javascript.begin (
            "window.mailCompose && window.mailCompose.removeLink && window.mailCompose.removeLink();",
            -1,
            null,
            null,
            null,
            (obj, res) => {
                try {
                    this.webview.evaluate_javascript.end (res);
                } catch (Error e) {
                    debug ("Could not remove link: %s", e.message);
                }
            }
        );
    }

    private void apply_to_current_image (string size) {
        if (this.current_image_id != null)
            apply_stored_image_size (this.current_image_id, size);
    }

    private void delete_current_image () {
        if (this.current_image_id != null)
            delete_stored_image (this.current_image_id);
    }

    private void on_script_message (JSC.Value value) {
        string? text = null;
        if (value.is_string ())
            text = value.to_string ();
        else
            text = value.to_json (0);
        handle_compose_command (text ?? "");
    }

    private void handle_compose_command (string raw) {
        var payload = raw ?? "";
        if (payload.has_prefix ("\"") && payload.has_suffix ("\"") && payload.length >= 2)
            payload = payload.substring (1, payload.length - 2).replace ("\\\"", "\"");
        var parts = payload.split ("|", 3);
        if (parts.length < 2)
            return;
        if (parts[0] == "select") {
            this.current_image_id = parts[1];
            return;
        }
        if (parts[0] == "size" && parts.length >= 3) {
            this.current_image_id = parts[1];
            apply_stored_image_size (parts[1], parts[2]);
            return;
        }
        if (parts[0] == "delete") {
            this.current_image_id = parts[1];
            delete_stored_image (parts[1]);
        }
    }

    public bool insert_image (Bytes bytes, string mime, string alt) throws Error {
        var pixbuf = pixbuf_from_bytes (bytes);
        var store_bytes = bytes;
        var store_mime = mime;
        var store_pixbuf = pixbuf;
        var shrunk = false;
        var keep_original = (mime == "image/jpeg" || mime == "image/png")
            && bytes.get_size () <= MAX_INLINE_IMAGE_BYTES;
        if (!keep_original) {
            var encoded = compress_under_limit (pixbuf, MAX_INLINE_IMAGE_BYTES);
            store_bytes = encoded.bytes;
            store_mime = encoded.mime;
            store_pixbuf = encoded.pixbuf;
            shrunk = true;
        }

        this.image_serial++;
        var id = "img%u".printf (this.image_serial);
        var stored = new StoredInlineImage ();
        stored.id = id;
        stored.alt = alt;
        stored.mime = store_mime;
        stored.original = store_bytes;
        stored.pixbuf = store_pixbuf;
        this.inline_images.set (id, stored);
        this.current_image_id = id;

        unowned uint8[] data = store_bytes.get_data ();
        var html = "<img class=\"mail-inline-image\" draggable=\"true\" data-mail-id=\"%s\" data-mail-size=\"original\" src=\"data:%s;base64,%s\" alt=\"%s\" width=\"%d\" height=\"%d\" style=\"max-width:100%%;height:auto;\">".printf (
            id,
            store_mime,
            Base64.encode (data),
            Markup.escape_text (alt),
            store_pixbuf.get_width (),
            store_pixbuf.get_height ()
        );
        insert_image_markup (html, id);
        return shrunk;
    }

    private void apply_stored_image_size (string id, string size) {
        var stored = this.inline_images.get (id);
        if (stored == null)
            return;

        EncodedInline encoded;
        try {
            if (size == "small")
                encoded = encode_fit_width (stored, INLINE_SMALL_WIDTH);
            else if (size == "medium")
                encoded = encode_fit_width (stored, INLINE_MEDIUM_WIDTH);
            else
                encoded = encode_original (stored);
        } catch (Error e) {
            debug ("Could not encode compose image: %s", e.message);
            return;
        }

        unowned uint8[] data = encoded.bytes.get_data ();
        var src = "data:%s;base64,%s".printf (encoded.mime, Base64.encode (data));
        var js = "window.mailCompose && window.mailCompose.replaceImage(%s,%s,%d,%d,%s);".printf (
            js_string (id),
            js_string (src),
            encoded.pixbuf.get_width (),
            encoded.pixbuf.get_height (),
            js_string (size)
        );
        this.webview.evaluate_javascript.begin (js, -1, null, null, null, (obj, res) => {
            try {
                this.webview.evaluate_javascript.end (res);
            } catch (Error e) {
                debug ("Could not replace compose image: %s", e.message);
            }
        });
    }

    private void delete_stored_image (string id) {
        this.inline_images.remove (id);
        if (this.current_image_id == id)
            this.current_image_id = null;
        var js = "window.mailCompose && window.mailCompose.removeImage(%s);".printf (js_string (id));
        this.webview.evaluate_javascript.begin (js, -1, null, null, null, (obj, res) => {
            try {
                this.webview.evaluate_javascript.end (res);
            } catch (Error e) {
                debug ("Could not delete compose image: %s", e.message);
            }
        });
    }

    private static Gdk.Pixbuf pixbuf_from_bytes (Bytes bytes) throws Error {
        var loader = new Gdk.PixbufLoader ();
        loader.write_bytes (bytes);
        loader.close ();
        unowned var pixbuf = loader.get_pixbuf ();
        if (pixbuf == null)
            throw new IOError.FAILED ("Invalid image");
        return pixbuf.copy ();
    }

    private static EncodedInline encode_jpeg (Gdk.Pixbuf pixbuf, int quality) throws Error {
        uint8[] buffer;
        pixbuf.save_to_buffer (out buffer, "jpeg", "quality", quality.to_string ());
        var encoded = new EncodedInline ();
        encoded.bytes = new Bytes (buffer);
        encoded.mime = "image/jpeg";
        encoded.pixbuf = pixbuf;
        return encoded;
    }

    private static EncodedInline encode_png (Gdk.Pixbuf pixbuf) throws Error {
        uint8[] buffer;
        pixbuf.save_to_buffer (out buffer, "png");
        var encoded = new EncodedInline ();
        encoded.bytes = new Bytes (buffer);
        encoded.mime = "image/png";
        encoded.pixbuf = pixbuf;
        return encoded;
    }

    private static EncodedInline encode_original (StoredInlineImage stored) {
        var encoded = new EncodedInline ();
        encoded.bytes = stored.original;
        encoded.mime = stored.mime;
        encoded.pixbuf = stored.pixbuf;
        return encoded;
    }

    private static EncodedInline encode_fit_width (StoredInlineImage stored, int max_width) throws Error {
        if (stored.pixbuf.get_width () <= max_width)
            return encode_original (stored);

        var height = (stored.pixbuf.get_height () * max_width + stored.pixbuf.get_width () / 2) / stored.pixbuf.get_width ();
        if (height < 1)
            height = 1;
        var scaled = stored.pixbuf.scale_simple (max_width, height, Gdk.InterpType.BILINEAR);
        if (scaled == null)
            throw new IOError.FAILED ("Could not scale image");
        if (stored.mime == "image/png" && scaled.get_has_alpha ()) {
            var png = encode_png (scaled);
            if (png.bytes.get_size () <= MAX_INLINE_IMAGE_BYTES)
                return png;
        }
        var jpeg = encode_jpeg (scaled, 80);
        if (jpeg.bytes.get_size () <= MAX_INLINE_IMAGE_BYTES)
            return jpeg;
        return compress_under_limit (scaled, MAX_INLINE_IMAGE_BYTES);
    }

    private static EncodedInline compress_under_limit (Gdk.Pixbuf pixbuf, int64 max_bytes) throws Error {
        var current = pixbuf;
        var quality = 85;
        EncodedInline? last = null;
        for (int i = 0; i < 14; i++) {
            EncodedInline encoded;
            if (i == 0 && current.get_has_alpha ()) {
                encoded = encode_png (current);
                if (encoded.bytes.get_size () <= max_bytes)
                    return encoded;
            }
            encoded = encode_jpeg (current, quality);
            last = encoded;
            if (encoded.bytes.get_size () <= max_bytes)
                return encoded;
            if (quality > 55) {
                quality -= 10;
                continue;
            }
            quality = 80;
            var width = (current.get_width () * 4) / 5;
            var height = (current.get_height () * 4) / 5;
            if (width < 48 || height < 48)
                break;
            var scaled = current.scale_simple (width, height, Gdk.InterpType.BILINEAR);
            if (scaled == null)
                break;
            current = scaled;
        }
        if (last == null)
            throw new IOError.FAILED ("Could not compress image");
        return last;
    }

    public override bool grab_focus () {
        return this.webview.grab_focus ();
    }

    public void print (Gtk.Window? parent) {
        var operation = new WebKit.PrintOperation (this.webview);
        operation.run_dialog (parent);
    }

    private void enable_spell_checking () {
        var languages = Utils.spell_language_codes ();
        this.spell_langs = new string[languages.length];
        for (uint i = 0; i < languages.length; i++)
            this.spell_langs[i] = languages[i];

        var context = this.webview.get_context ();
        context.set_spell_checking_languages (this.spell_langs);
        context.set_spell_checking_enabled (true);
        if (!Utils.hunspell_dictionaries_present_for (languages)) {
            warning (
                "No Hunspell dictionary found for compose spell checking. Install hunspell and a dictionary for your language (for example hunspell-it)."
            );
        }
    }

    private static string html_spell_lang () {
        unowned string[] names = Intl.get_language_names ();
        foreach (unowned string name in names) {
            if (name == null || name.length == 0 || name == "C" || name == "POSIX")
                continue;
            var cleaned = name.split (".")[0].split ("@")[0];
            if (cleaned.length == 0)
                continue;
            return cleaned.replace ("_", "-");
        }
        return "";
    }

    private bool on_context_menu (WebKit.ContextMenu menu, WebKit.HitTestResult hit) {
        if (!hit.context_is_editable ())
            return false;

        var misspelled = false;
        var has_learn = false;
        var spelling_insert = 0;
        for (int i = (int) menu.get_n_items () - 1; i >= 0; i--) {
            var item = menu.get_item_at_position (i);
            var action = item.get_stock_action ();
            if (action == WebKit.ContextMenuAction.UNICODE
                || action == WebKit.ContextMenuAction.OPEN_IMAGE_IN_NEW_WINDOW
                || action == WebKit.ContextMenuAction.DOWNLOAD_IMAGE_TO_DISK
                || action == WebKit.ContextMenuAction.COPY_IMAGE_URL_TO_CLIPBOARD) {
                menu.remove (item);
                continue;
            }

            if (action == WebKit.ContextMenuAction.LEARN_SPELLING)
                has_learn = true;
            if (is_spelling_action (action))
                misspelled = true;

            var label = stock_menu_label (action);
            if (label == null)
                continue;

            menu.remove (item);
            menu.insert (new WebKit.ContextMenuItem.from_stock_action_with_label (action, label), i);
        }

        if (misspelled) {
            select_spell_word ();
            if (!has_learn) {
                for (uint i = 0; i < menu.get_n_items (); i++) {
                    var action = menu.get_item_at_position (i).get_stock_action ();
                    if (action == WebKit.ContextMenuAction.SPELLING_GUESS
                        || action == WebKit.ContextMenuAction.NO_GUESSES_FOUND)
                        spelling_insert = (int) i + 1;
                    else if (action == WebKit.ContextMenuAction.IGNORE_SPELLING && spelling_insert == 0)
                        spelling_insert = (int) i;
                }
                menu.insert (
                    new WebKit.ContextMenuItem.from_gaction (this.learn_spelling, _("Add to Dictionary"), null),
                    spelling_insert
                );
            }
        }

        if (hit.context_is_link ()) {
            menu.append (new WebKit.ContextMenuItem.separator ());
            menu.append (new WebKit.ContextMenuItem.from_gaction (this.unlink_action, _("Remove Link"), null));
        }

        if (hit.context_is_image ()) {
            var sizes = new WebKit.ContextMenu ();
            sizes.append (new WebKit.ContextMenuItem.from_gaction (this.image_size_small, _("Small"), null));
            sizes.append (new WebKit.ContextMenuItem.from_gaction (this.image_size_medium, _("Medium"), null));
            sizes.append (new WebKit.ContextMenuItem.from_gaction (this.image_size_original, _("Original"), null));
            menu.prepend (new WebKit.ContextMenuItem.separator ());
            menu.prepend (new WebKit.ContextMenuItem.from_gaction (this.image_delete, _("Delete"), null));
            menu.prepend (new WebKit.ContextMenuItem.with_submenu (_("Image Size"), sizes));
        }

        return false;
    }

    private void select_spell_word () {
        this.webview.evaluate_javascript.begin (
            "window.mailCompose && window.mailCompose.selectSpellWord && window.mailCompose.selectSpellWord();",
            -1,
            null,
            null,
            null,
            (obj, res) => {
                try {
                    this.webview.evaluate_javascript.end (res);
                } catch (Error e) {
                    debug ("Could not select spelled word: %s", e.message);
                }
            }
        );
    }

    private async void learn_selected_spelling () {
        string word = "";
        try {
            var value = yield this.webview.evaluate_javascript (
                "window.mailCompose && window.mailCompose.selectSpellWord ? window.mailCompose.selectSpellWord() : ''",
                -1,
                null,
                null,
                null
            );
            if (value.is_string ())
                word = value.to_string ().strip ();
        } catch (Error e) {
            debug ("Could not read spelled word: %s", e.message);
        }
        if (word.length == 0)
            return;
        Utils.learn_enchant_word (word, this.spell_langs);
        if (this.spell_langs.length > 0)
            this.webview.get_context ().set_spell_checking_languages (this.spell_langs);
        this.webview.evaluate_javascript.begin (
            "window.mailCompose && window.mailCompose.recheckSpellWord && window.mailCompose.recheckSpellWord();",
            -1,
            null,
            null,
            null,
            (obj, res) => {
                try {
                    this.webview.evaluate_javascript.end (res);
                } catch (Error e) {
                    debug ("Could not recheck spelled word: %s", e.message);
                }
            }
        );
    }

    private static bool is_spelling_action (WebKit.ContextMenuAction action) {
        switch (action) {
            case WebKit.ContextMenuAction.SPELLING_GUESS:
            case WebKit.ContextMenuAction.NO_GUESSES_FOUND:
            case WebKit.ContextMenuAction.IGNORE_SPELLING:
            case WebKit.ContextMenuAction.LEARN_SPELLING:
            case WebKit.ContextMenuAction.IGNORE_GRAMMAR:
                return true;
            default:
                return false;
        }
    }

    private static string? stock_menu_label (WebKit.ContextMenuAction action) {
        switch (action) {
            case WebKit.ContextMenuAction.PASTE_AS_PLAIN_TEXT:
                return _("Paste as Plain Text");
            case WebKit.ContextMenuAction.INSERT_EMOJI:
                return _("Insert Emoji");
            case WebKit.ContextMenuAction.LEARN_SPELLING:
                return _("Add to Dictionary");
            case WebKit.ContextMenuAction.IGNORE_SPELLING:
                return _("Ignore Spelling");
            default:
                return null;
        }
    }

    public void apply_command (string command) {
        this.webview.grab_focus ();
        this.webview.execute_editing_command (command);
    }

    public void insert_text (string text) {
        if (text.length == 0)
            return;
        this.webview.grab_focus ();
        this.webview.execute_editing_command_with_argument ("InsertText", text);
    }

    public void insert_html (string html) {
        insert_image_markup (html, null);
    }

    private void insert_image_markup (string html, string? id) {
        if (html.length == 0)
            return;
        this.webview.grab_focus ();
        var bind = id != null && id.length > 0
            ? "if (window.mailCompose) { window.mailCompose.bindLastImage(%s); window.mailCompose.selectLastImage(); }".printf (js_string (id))
            : "if (window.mailCompose) window.mailCompose.selectLastImage();";
        var js = """
            (function () {
                var editor = document.getElementById('editor');
                if (editor)
                    editor.focus();
                document.execCommand('insertHTML', false, %s);
                %s
            })();
        """.printf (js_string (html), bind);
        this.webview.evaluate_javascript.begin (js, -1, null, null, null, (obj, res) => {
            try {
                this.webview.evaluate_javascript.end (res);
            } catch (Error e) {
                debug ("Could not insert compose HTML: %s", e.message);
            }
        });
    }

    public void apply_color (string color) {
        apply_css_edit ("foreColor", color);
    }

    public void apply_highlight (string color) {
        apply_css_edit ("hiliteColor", color.length > 0 ? color : "transparent");
    }

    private void apply_css_edit (string command, string value) {
        this.webview.grab_focus ();
        var js = """
            (function () {
                document.execCommand('styleWithCSS', false, true);
                var cmd = %s;
                var value = %s;
                if (cmd === 'hiliteColor') {
                    if (!document.execCommand('hiliteColor', false, value))
                        document.execCommand('backColor', false, value);
                    return;
                }
                document.execCommand('foreColor', false, value ? value : 'inherit');
            })();
        """.printf (js_string (command), js_string (value));
        this.webview.evaluate_javascript.begin (js, -1, null, null, null, (obj, res) => {
            try {
                this.webview.evaluate_javascript.end (res);
            } catch (Error e) {
                debug ("Could not apply compose style: %s", e.message);
            }
        });
    }

    private void add_editing_shortcuts () {
        var shortcuts = new Gtk.ShortcutController () {
            scope = Gtk.ShortcutScope.LOCAL,
        };
        add_edit_shortcut (shortcuts, "<Control>z", WebKit.EDITING_COMMAND_UNDO);
        add_edit_shortcut (shortcuts, "<Control><Shift>z", WebKit.EDITING_COMMAND_REDO);
        add_edit_shortcut (shortcuts, "<Control>y", WebKit.EDITING_COMMAND_REDO);
        add_edit_shortcut (shortcuts, "<Control>b", "Bold");
        add_edit_shortcut (shortcuts, "<Control>i", "Italic");
        add_edit_shortcut (shortcuts, "<Control>u", "Underline");
        add_edit_shortcut (shortcuts, "<Control><Shift>x", "Strikethrough");
        add_edit_shortcut (shortcuts, "<Control>a", WebKit.EDITING_COMMAND_SELECT_ALL);
        add_controller (shortcuts);

        var keys = new Gtk.EventControllerKey ();
        keys.set_propagation_phase (Gtk.PropagationPhase.CAPTURE);
        keys.key_pressed.connect (on_edit_key);
        this.webview.add_controller (keys);
    }

    private void add_edit_shortcut (Gtk.ShortcutController controller, string trigger, string command) {
        var parsed = Gtk.ShortcutTrigger.parse_string (trigger);
        if (parsed == null)
            return;

        controller.add_shortcut (new Gtk.Shortcut (parsed, new Gtk.CallbackAction ((widget, args) => {
            apply_command (command);
            return true;
        })));
    }

    private bool on_edit_key (uint keyval, uint keycode, Gdk.ModifierType state) {
        var mods = state & Gtk.accelerator_get_default_mod_mask ();
        if ((mods & Gdk.ModifierType.CONTROL_MASK) == 0)
            return false;

        var shift = (mods & Gdk.ModifierType.SHIFT_MASK) != 0;
        var key = Gdk.keyval_to_lower (keyval);
        if (key == Gdk.Key.z) {
            apply_command (shift ? WebKit.EDITING_COMMAND_REDO : WebKit.EDITING_COMMAND_UNDO);
            return true;
        }
        if (key == Gdk.Key.y) {
            apply_command (WebKit.EDITING_COMMAND_REDO);
            return true;
        }
        if (key == Gdk.Key.b && !shift) {
            apply_command ("Bold");
            return true;
        }
        if (key == Gdk.Key.i && !shift) {
            apply_command ("Italic");
            return true;
        }
        if (key == Gdk.Key.u && !shift) {
            apply_command ("Underline");
            return true;
        }
        if (key == Gdk.Key.x && shift) {
            apply_command ("Strikethrough");
            return true;
        }
        return false;
    }

    public void apply_font (string family) {
        this.webview.grab_focus ();
        this.webview.execute_editing_command_with_argument ("FontName", family);
    }

    public void apply_size (string size) {
        this.webview.grab_focus ();
        this.webview.execute_editing_command_with_argument ("FontSize", size);
    }

    public async void set_editor_html (string html) throws Error {
        yield wait_loaded ();
        yield this.webview.evaluate_javascript (
            """
            (function () {
                var editor = document.getElementById('editor');
                if (!editor)
                    return;
                var html = %s;
                editor.innerHTML = html && html.length ? html : '<br>';
            })();
            """.printf (js_string (html)),
            -1,
            null,
            null,
            null
        );
    }

    public async string get_editor_html () throws Error {
        yield wait_loaded ();
        var value = yield this.webview.evaluate_javascript (
            """
            (function () {
                var editor = document.getElementById('editor');
                return editor ? editor.innerHTML : '';
            })();
            """,
            -1,
            null,
            null,
            null
        );
        return value.is_string () ? value.to_string () : "";
    }

    public async void set_signature_html (string html) throws Error {
        yield wait_loaded ();
        yield this.webview.evaluate_javascript (
            """
            (function () {
                var editor = document.getElementById('editor');
                if (!editor)
                    return;
                var sig = editor.querySelector(':scope > .mail-signature');
                var html = %s;
                if (!html) {
                    if (sig)
                        sig.remove();
                    return;
                }
                if (!sig) {
                    sig = document.createElement('div');
                    sig.className = 'mail-signature';
                    var quote = editor.querySelector(':scope > .mail-quote');
                    if (quote)
                        editor.insertBefore(sig, quote);
                    else
                        editor.appendChild(sig);
                }
                sig.innerHTML = html;
            })();
            """.printf (js_string (html)),
            -1,
            null,
            null,
            null
        );
    }

    public async string get_plain () throws Error {
        string plain;
        string html;
        yield get_bodies (out plain, out html);
        return plain;
    }

    public async void get_bodies (out string plain, out string html) throws Error {
        yield wait_loaded ();
        var value = yield this.webview.evaluate_javascript (
            """
            (function () {
                var editor = document.getElementById('editor');
                if (!editor)
                    return '\x1e';
                return editor.innerText + '\x1e' + editor.innerHTML;
            })();
            """,
            -1,
            null,
            null,
            null
        );
        var raw = value.is_string () ? value.to_string () : "";
        var split = raw.index_of_char ('\x1e');
        if (split < 0) {
            plain = raw;
            html = wrap_outgoing ("");
            return;
        }

        plain = raw.substring (0, split);
        html = wrap_outgoing (raw.substring (split + 1));
    }

    private async void wait_loaded () {
        if (this.loaded)
            return;

        this.loaded_callback = wait_loaded.callback;
        if (this.loaded) {
            this.loaded_callback = null;
            return;
        }

        yield;
    }

    private void on_load_changed (WebKit.LoadEvent load_event) {
        if (load_event != WebKit.LoadEvent.FINISHED)
            return;

        this.loaded = true;
        this.stack.visible_child_name = "body";
        place_caret.begin ();
        ready ();
        if (this.loaded_callback != null)
            Idle.add ((owned) this.loaded_callback);
    }

    private async void place_caret () {
        var focus = this.focus_editor ? "editor.focus();" : "";
        try {
            yield this.webview.evaluate_javascript (
                editor_helpers_js (),
                -1,
                null,
                null,
                null
            );
        } catch (Error e) {
            debug ("Could not install compose helpers: %s", e.message);
        }

        try {
            yield this.webview.evaluate_javascript (
                """
                (function () {
                    var editor = document.getElementById('editor');
                    if (!editor)
                        return;
                    %s
                    var node = editor.firstElementChild || editor;
                    var range = document.createRange();
                    range.setStart(node, 0);
                    range.collapse(true);
                    var sel = window.getSelection();
                    sel.removeAllRanges();
                    sel.addRange(range);
                })();
                """.printf (focus),
                -1,
                null,
                null,
                null
            );
        } catch (Error e) {
            debug ("Could not place compose caret: %s", e.message);
        }
    }

    private void update_webview_background () {
        var rgba = Gdk.RGBA ();
        rgba.parse (Adw.StyleManager.get_default ().dark ? "#1e1e1e" : "#ffffff");
        this.webview.set_background_color (rgba);
    }

    private bool on_decide_policy (WebKit.PolicyDecision decision, WebKit.PolicyDecisionType type) {
        if (type != WebKit.PolicyDecisionType.NAVIGATION_ACTION
            && type != WebKit.PolicyDecisionType.NEW_WINDOW_ACTION)
            return false;

        var navigation = decision as WebKit.NavigationPolicyDecision;
        if (navigation == null)
            return false;

        var action = navigation.get_navigation_action ();
        var uri = action.get_request ().get_uri ();
        if (handle_compose_uri (uri)) {
            decision.ignore ();
            return true;
        }
        if (uri != null && uri.has_prefix ("file:")) {
            decision.ignore ();
            return true;
        }

        if (action.get_navigation_type () == WebKit.NavigationType.OTHER)
            return false;

        if (action.get_navigation_type () != WebKit.NavigationType.LINK_CLICKED) {
            decision.ignore ();
            return true;
        }

        if (uri != null && uri.length > 0) {
            try {
                AppInfo.launch_default_for_uri (uri, null);
            } catch (Error e) {
                warning ("Could not open link: %s", e.message);
            }
        }

        decision.ignore ();
        return true;
    }

    private bool handle_compose_uri (string? uri) {
        if (uri == null || !uri.has_prefix ("mail-compose:"))
            return false;
        var payload = uri.substring ("mail-compose:".length);
        if (payload.has_prefix ("//do/"))
            payload = payload.substring (5);
        else if (payload.has_prefix ("//"))
            payload = payload.substring (2);
        var decoded = Uri.unescape_string (payload);
        handle_compose_command (decoded ?? payload);
        return true;
    }

    private static string build_document (
        MessageContent? quoted,
        bool forward_quote,
        bool resend,
        string signature_html,
        string? initial_html
    ) {
        var editor = new StringBuilder ();
        if (initial_html != null) {
            editor.append (initial_html.length > 0 ? initial_html : "<p><br></p>");
        } else if (quoted != null && resend) {
            var fragment = Utils.compose_edit_fragment (quoted);
            editor.append (fragment.length > 0 ? fragment : "<p><br></p>");
        } else {
            editor.append ("<p><br></p>");
            if (signature_html.length > 0) {
                editor.append ("<div class=\"mail-signature\">");
                editor.append (signature_html);
                editor.append ("</div>");
            }
            if (quoted != null) {
                editor.append ("<p><br></p>");
                editor.append ("<blockquote class=\"mail-quote");
                if (forward_quote)
                    editor.append (" forward");
                editor.append ("\">");
                var attribution = Utils.quote_attribution_html (quoted);
                if (attribution.length > 0) {
                    editor.append ("<div class=\"mail-attribution\">");
                    editor.append (attribution);
                    editor.append ("</div>");
                }
                var fragment = Utils.quote_html_fragment (quoted);
                if (fragment.length > 0) {
                    editor.append ("<div class=\"mail-quote-body\">");
                    editor.append (fragment);
                    editor.append ("</div>");
                }
                editor.append ("</blockquote>");
            }
        }

        var html = new StringBuilder ();
        html.append ("<!DOCTYPE html><html><head><meta charset=\"utf-8\">");
        html.append (compose_style (false));
        html.append ("</head><body><div id=\"editor\" contenteditable=\"true\" spellcheck=\"true\"");
        var lang = html_spell_lang ();
        if (lang.length > 0)
            html.append_printf (" lang=\"%s\"", lang);
        html.append (">");
        html.append (editor.str);
        html.append ("</div></body></html>");
        return html.str;
    }

    private static string wrap_outgoing (string inner) {
        var html = new StringBuilder ();
        html.append ("<!DOCTYPE html><html><head><meta charset=\"utf-8\">");
        html.append (compose_style (true));
        html.append ("</head><body>");
        html.append ("<div class=\"mail-compose\" style=\"padding:12px 20px 16px 20px;\">");
        html.append (inner);
        html.append ("</div></body></html>");
        return html.str;
    }

    private static string compose_style (bool outgoing) {
        var dark = Adw.StyleManager.get_default ().dark;
        var bg = dark ? "#1e1e1e" : "#ffffff";
        var fg = dark ? "#eeeeee" : "#1a1a1a";
        var css = new StringBuilder ("<style>");
        if (!outgoing) {
            css.append_printf ("""
html { color-scheme: light dark; background: %s; }
body {
  margin: 0;
  padding: 12px 16px 16px 20px;
  background: %s;
  color: %s;
  font: 15px/1.4 system-ui, sans-serif;
}
""", bg, bg, fg);
            css.append ("""
#editor { outline: none; min-height: 12em; }
#editor > p { margin: 0; }
#editor ul, #editor ol {
  margin: 0.2em 0;
  padding-inline-start: 1.6em;
}
#editor li { margin: 0.12em 0; }
#editor ul ul, #editor ol ol, #editor ul ol, #editor ol ul { margin: 0; }
#editor blockquote:not(.mail-quote) {
  margin: 0 0 0 1.5em;
  padding: 0;
  border: none;
}
#editor img.mail-inline-image {
  height: auto;
  max-width: 100%;
  cursor: grab;
  outline: none;
}
#editor img.mail-inline-image.mail-img-selected {
  outline: 2px solid #3584e4;
  outline-offset: 2px;
}
#mail-img-size {
  position: absolute;
  z-index: 20;
  display: none;
  gap: 2px;
  padding: 3px;
  border-radius: 999px;
  background: Canvas;
  color: CanvasText;
  border: 1px solid color-mix(in srgb, CanvasText 18%, transparent);
  box-shadow: 0 2px 10px color-mix(in srgb, CanvasText 18%, transparent);
  user-select: none;
  -webkit-user-select: none;
  pointer-events: auto;
  touch-action: manipulation;
}
#mail-img-size button {
  margin: 0;
  border: 0;
  background: transparent;
  color: inherit;
  font: 12px/1.2 system-ui, sans-serif;
  padding: 5px 10px;
  border-radius: 999px;
  cursor: pointer;
}
#mail-img-size button[aria-pressed="true"] {
  background: #3584e4;
  color: #fff;
}
#mail-img-size button.mail-img-delete {
  color: #c01c28;
}
""");
        } else {
            css.append ("""
body {
  margin: 0;
  padding: 0;
  font: 14px/1.4 sans-serif;
  color: #1a1a1a;
}
.mail-compose { padding: 12px 20px 16px 20px; }
body > p, .mail-compose > p { margin: 0; }
body ul, body ol, .mail-compose ul, .mail-compose ol {
  margin: 0.2em 0;
  padding-inline-start: 1.6em;
}
body li, .mail-compose li { margin: 0.12em 0; }
body ul ul, body ol ol, body ul ol, body ol ul,
.mail-compose ul ul, .mail-compose ol ol, .mail-compose ul ol, .mail-compose ol ul { margin: 0; }
blockquote:not(.mail-quote) {
  margin: 0 0 0 1.5em;
  padding: 0;
  border: none;
}
.mail-compose img {
  max-width: 100%;
  height: auto;
}
""");
        }

        css.append ("""
.mail-quote {
  margin: 0.75em 0 0 0;
  padding: 0 0 0 12px;
  border-left: 2px solid """);
        css.append (outgoing ? "#b0b0b0" : "color-mix(in srgb, CanvasText 38%, transparent)");
        css.append (""";
  color: inherit;
}
.mail-quote.forward {
  border-left-width: 3px;
  border-left-color: #3584e4;
}
""");
        if (!outgoing) {
            css.append ("""
@media (prefers-color-scheme: dark) {
  .mail-quote.forward { border-left-color: #78baff; }
}
""");
        }
        css.append ("""
.mail-quote p,
.mail-quote li,
.mail-quote h1,
.mail-quote h2,
.mail-quote h3,
.mail-quote h4,
.mail-quote h5,
.mail-quote h6 {
  margin: 0;
}
.mail-quote .mail-attribution {
  margin: 0 0 1.15em 0;
  font-style: italic;
  color: """);
        css.append (outgoing ? "#5c5c5c" : "color-mix(in srgb, CanvasText 52%, transparent)");
        css.append (""";
}
.mail-quote img {
  max-width: 100%;
  height: auto;
}
.mail-signature {
  margin: 1.7em 0 1em 0;
}
.mail-signature p {
  margin: 0;
}
.mail-signature-mark {
  margin: 0 0 0.35em 0;
}
.mail-signature img {
  max-width: 100%;
  height: auto;
}
""");
        css.append ("</style>");
        return css.str;
    }

    private static string editor_helpers_js () {
        return """
            (function () {
                var editor = document.getElementById('editor');
                if (!editor || editor.dataset.mailKeys === '1')
                    return;
                editor.dataset.mailKeys = '1';
                var applying = false;
                var selectedImg = null;
                var contextLink = null;
                var labels = {
                    small: """ + js_string (_("Small")) + """,
                    medium: """ + js_string (_("Medium")) + """,
                    original: """ + js_string (_("Original")) + """,
                    remove: """ + js_string (_("Delete")) + """
                };

                function closest(node, selector) {
                    if (!node)
                        return null;
                    if (node.nodeType === 3)
                        node = node.parentElement;
                    return node && node.closest ? node.closest(selector) : null;
                }

                function listItem() {
                    var sel = window.getSelection();
                    if (!sel || !sel.rangeCount)
                        return null;
                    return closest(sel.anchorNode, 'li');
                }

                function inLockedRegion() {
                    var sel = window.getSelection();
                    if (!sel || !sel.rangeCount)
                        return false;
                    return !!closest(sel.anchorNode, '.mail-quote, .mail-signature');
                }

                function resizableImage(node) {
                    return node && node.tagName === 'IMG' && editor.contains(node)
                        && !closest(node, '.mail-quote, .mail-signature');
                }

                function postCompose(message) {
                    try {
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.compose) {
                            window.webkit.messageHandlers.compose.postMessage(message);
                            return;
                        }
                    } catch (err) {
                    }
                    var iframe = document.getElementById('mail-compose-bridge');
                    if (!iframe) {
                        iframe = document.createElement('iframe');
                        iframe.id = 'mail-compose-bridge';
                        iframe.setAttribute('hidden', 'true');
                        iframe.setAttribute('aria-hidden', 'true');
                        iframe.style.display = 'none';
                        iframe.style.width = '0';
                        iframe.style.height = '0';
                        iframe.style.border = '0';
                        iframe.style.position = 'absolute';
                        document.documentElement.appendChild(iframe);
                    }
                    iframe.src = 'mail-compose://do/' + encodeURIComponent(message);
                }

                function imageId(img) {
                    return img && img.getAttribute('data-mail-id');
                }

                function barAction(e, run) {
                    e.preventDefault();
                    e.stopPropagation();
                    if (e.stopImmediatePropagation)
                        e.stopImmediatePropagation();
                    run();
                }

                function ensureBar() {
                    var bar = document.getElementById('mail-img-size');
                    if (bar)
                        return bar;
                    bar = document.createElement('div');
                    bar.id = 'mail-img-size';
                    bar.setAttribute('contenteditable', 'false');
                    bar.addEventListener('pointerdown', function (e) {
                        e.preventDefault();
                        e.stopPropagation();
                    });
                    ['small', 'medium', 'original'].forEach(function (size) {
                        var button = document.createElement('button');
                        button.type = 'button';
                        button.dataset.size = size;
                        button.textContent = labels[size];
                        button.addEventListener('pointerdown', function (e) {
                            barAction(e, function () {
                                var id = imageId(selectedImg);
                                if (id)
                                    postCompose('size|' + id + '|' + size);
                            });
                        });
                        bar.appendChild(button);
                    });
                    var remove = document.createElement('button');
                    remove.type = 'button';
                    remove.className = 'mail-img-delete';
                    remove.textContent = labels.remove;
                    remove.addEventListener('pointerdown', function (e) {
                        barAction(e, function () {
                            var id = imageId(selectedImg);
                            if (id)
                                postCompose('delete|' + id);
                        });
                    });
                    bar.appendChild(remove);
                    document.body.appendChild(bar);
                    return bar;
                }

                function markBar() {
                    var bar = document.getElementById('mail-img-size');
                    if (!bar)
                        return;
                    var size = selectedImg && selectedImg.getAttribute('data-mail-size') || 'original';
                    var buttons = bar.querySelectorAll('button[data-size]');
                    for (var i = 0; i < buttons.length; i++)
                        buttons[i].setAttribute('aria-pressed', buttons[i].dataset.size === size ? 'true' : 'false');
                }

                function placeBar() {
                    var bar = ensureBar();
                    if (!selectedImg) {
                        bar.style.display = 'none';
                        return;
                    }
                    bar.style.display = 'flex';
                    markBar();
                    var rect = selectedImg.getBoundingClientRect();
                    var top = window.scrollY + rect.top - bar.offsetHeight - 8;
                    if (top < window.scrollY + 4)
                        top = window.scrollY + rect.bottom + 8;
                    bar.style.top = top + 'px';
                    bar.style.left = Math.max(8, window.scrollX + rect.left) + 'px';
                }

                function clearSelection() {
                    if (selectedImg)
                        selectedImg.classList.remove('mail-img-selected');
                    selectedImg = null;
                    var bar = document.getElementById('mail-img-size');
                    if (bar)
                        bar.style.display = 'none';
                }

                function selectImage(img) {
                    if (selectedImg === img) {
                        placeBar();
                    } else {
                        if (selectedImg)
                            selectedImg.classList.remove('mail-img-selected');
                        selectedImg = img;
                        img.classList.add('mail-inline-image', 'mail-img-selected');
                        placeBar();
                    }
                    var id = imageId(img);
                    if (id)
                        postCompose('select|' + id);
                }

                window.mailCompose = {
                    bindLastImage: function (id) {
                        var images = editor.querySelectorAll('img');
                        if (!images.length)
                            return;
                        var img = images[images.length - 1];
                        img.classList.add('mail-inline-image');
                        img.setAttribute('draggable', 'true');
                        img.setAttribute('data-mail-id', id);
                        if (!img.getAttribute('data-mail-size'))
                            img.setAttribute('data-mail-size', 'original');
                    },
                    requestSize: function (size) {
                        var id = imageId(selectedImg);
                        if (id)
                            postCompose('size|' + id + '|' + size);
                    },
                    requestDelete: function () {
                        var id = imageId(selectedImg);
                        if (id)
                            postCompose('delete|' + id);
                    },
                    replaceImage: function (id, src, width, height, size) {
                        var img = editor.querySelector('img[data-mail-id="' + id + '"]');
                        if (!img)
                            return;
                        img.src = src;
                        img.setAttribute('width', width);
                        img.setAttribute('height', height);
                        img.style.maxWidth = '100%';
                        img.style.height = 'auto';
                        img.style.removeProperty('width');
                        img.setAttribute('data-mail-size', size);
                        selectImage(img);
                    },
                    removeImage: function (id) {
                        var img = editor.querySelector('img[data-mail-id="' + id + '"]');
                        if (img)
                            img.remove();
                        clearSelection();
                    },
                    removeLink: function () {
                        var link = contextLink;
                        contextLink = null;
                        if (!link || !editor.contains(link))
                            return;
                        if (closest(link, '.mail-quote, .mail-signature'))
                            return;
                        var parent = link.parentNode;
                        while (link.firstChild)
                            parent.insertBefore(link.firstChild, link);
                        parent.removeChild(link);
                        parent.normalize();
                    },
                    spellWord: function () {
                        var sel = window.getSelection();
                        if (!sel || !sel.rangeCount)
                            return '';
                        var text = sel.toString().replace(/^\s+|\s+$/g, '');
                        if (text && !/\s/.test(text))
                            return text;
                        var range = sel.getRangeAt(0);
                        var node = range.startContainer;
                        if (node.nodeType !== 3)
                            return '';
                        var data = node.data;
                        var offset = range.startOffset;
                        var isWord = function (ch) {
                            return /[A-Za-zÀ-ÿ0-9'’\-]/.test(ch);
                        };
                        var start = offset;
                        var end = offset;
                        while (start > 0 && isWord(data.charAt(start - 1)))
                            start--;
                        while (end < data.length && isWord(data.charAt(end)))
                            end++;
                        return data.slice(start, end);
                    },
                    selectSpellWord: function () {
                        var sel = window.getSelection();
                        if (!sel || !sel.rangeCount)
                            return '';
                        if (!sel.isCollapsed) {
                            var selected = sel.toString().replace(/^\s+|\s+$/g, '');
                            return selected && !/\s/.test(selected) ? selected : '';
                        }
                        var range = sel.getRangeAt(0);
                        var node = range.startContainer;
                        if (node.nodeType !== 3)
                            return '';
                        var data = node.data;
                        var offset = range.startOffset;
                        var isWord = function (ch) {
                            return /[A-Za-zÀ-ÿ0-9'’\-]/.test(ch);
                        };
                        var start = offset;
                        var end = offset;
                        while (start > 0 && isWord(data.charAt(start - 1)))
                            start--;
                        while (end < data.length && isWord(data.charAt(end)))
                            end++;
                        if (start >= end)
                            return '';
                        range = document.createRange();
                        range.setStart(node, start);
                        range.setEnd(node, end);
                        sel.removeAllRanges();
                        sel.addRange(range);
                        return data.slice(start, end);
                    },
                    recheckSpellWord: function () {
                        var word = this.selectSpellWord();
                        if (!word)
                            return;
                        document.execCommand('insertText', false, word);
                    },
                    selectLastImage: function () {
                        var images = editor.querySelectorAll('img.mail-inline-image');
                        if (images.length)
                            selectImage(images[images.length - 1]);
                    }
                };

                function hrefForToken(token) {
                    if (/^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$/i.test(token))
                        return 'mailto:' + token;
                    if (/^https?:\/\/[^\s<>]+$/i.test(token))
                        return token;
                    if (/^www\.[^\s<>]+\.[A-Z]{2,}/i.test(token))
                        return 'https://' + token;
                    if (/^(?:[A-Z0-9](?:[A-Z0-9\-]*[A-Z0-9])?\.)+(?:com|org|net|edu|gov|io|it|eu|app|dev|info|biz|co|uk|us|de|fr|es|nl|be|ch|at|pl|me|tv|xyz|cloud|mail|online)(?:\/[^\s<>]*)?$/i.test(token)
                        && token.indexOf('@') < 0)
                        return 'https://' + token;
                    return null;
                }

                function placeCaretAfter(node) {
                    var sel = window.getSelection();
                    var range = document.createRange();
                    range.setStartAfter(node);
                    range.collapse(true);
                    sel.removeAllRanges();
                    sel.addRange(range);
                }

                function tryAutoLink(forceEnd) {
                    if (applying || inLockedRegion())
                        return;
                    var sel = window.getSelection();
                    if (!sel || !sel.rangeCount || !sel.isCollapsed)
                        return;
                    var node = sel.anchorNode;
                    if (!node || node.nodeType !== 3)
                        return;
                    if (closest(node, 'a'))
                        return;
                    var data = node.data;
                    var offset = sel.anchorOffset;
                    if (offset < 1)
                        return;
                    var delim = /[\s.,;:!?)]/;
                    var tokenEnd = offset;
                    if (!forceEnd) {
                        if (!delim.test(data.charAt(tokenEnd - 1)))
                            return;
                        tokenEnd--;
                    }
                    while (tokenEnd > 0 && delim.test(data.charAt(tokenEnd - 1)))
                        tokenEnd--;
                    var start = tokenEnd;
                    while (start > 0 && !/[\s<>"'()\[\]{}]/.test(data.charAt(start - 1)))
                        start--;
                    var token = data.slice(start, tokenEnd).replace(/[.,;:!?]+$/g, '');
                    if (!token)
                        return;
                    var href = hrefForToken(token);
                    if (!href)
                        return;
                    applying = true;
                    var range = document.createRange();
                    range.setStart(node, start);
                    range.setEnd(node, start + token.length);
                    sel.removeAllRanges();
                    sel.addRange(range);
                    document.execCommand('createLink', false, href);
                    var link = closest(window.getSelection().anchorNode, 'a');
                    if (link)
                        placeCaretAfter(link);
                    else
                        window.getSelection().collapseToEnd();
                    applying = false;
                }

                function tryAutoList() {
                    if (applying || inLockedRegion() || listItem())
                        return;
                    var sel = window.getSelection();
                    if (!sel || !sel.rangeCount || !sel.isCollapsed)
                        return;
                    var node = sel.anchorNode;
                    if (!node || node.nodeType !== 3)
                        return;
                    var offset = sel.anchorOffset;
                    var prefix = node.data.slice(0, offset);
                    var unordered = prefix.match(/^(?:[-*•]) $/);
                    var ordered = prefix.match(/^\d{1,3}[.)] $/);
                    var match = unordered || ordered;
                    if (!match)
                        return;
                    var block = closest(node, 'p, div, h1, h2, h3, h4, h5, h6') || node.parentElement;
                    if (!block || block.id === 'editor')
                        return;
                    var before = node.data.slice(0, offset - match[0].length);
                    if (before.replace(/\u00a0/g, ' ').trim().length > 0)
                        return;
                    applying = true;
                    node.data = before + node.data.slice(offset);
                    var range = document.createRange();
                    range.setStart(node, before.length);
                    range.collapse(true);
                    sel.removeAllRanges();
                    sel.addRange(range);
                    document.execCommand(ordered ? 'insertOrderedList' : 'insertUnorderedList');
                    applying = false;
                }

                editor.addEventListener('click', function (e) {
                    if (resizableImage(e.target)) {
                        e.stopPropagation();
                        selectImage(e.target);
                    }
                });

                document.addEventListener('pointerdown', function (e) {
                    if (!e.target || !e.target.closest)
                        return;
                    if (e.target.closest('#mail-img-size, #mail-compose-bridge'))
                        return;
                    if (resizableImage(e.target))
                        return;
                    clearSelection();
                });

                editor.addEventListener('dragstart', function (e) {
                    if (resizableImage(e.target))
                        clearSelection();
                });

                editor.addEventListener('contextmenu', function (e) {
                    if (resizableImage(e.target))
                        selectImage(e.target);
                    contextLink = closest(e.target, 'a');
                    if (!resizableImage(e.target) && window.mailCompose && window.mailCompose.selectSpellWord)
                        window.mailCompose.selectSpellWord();
                });

                document.addEventListener('scroll', function () {
                    if (selectedImg)
                        placeBar();
                }, true);

                editor.addEventListener('keydown', function (e) {
                    if (e.key === 'Escape' && selectedImg)
                        clearSelection();
                    if ((e.key === 'Delete' || e.key === 'Backspace') && selectedImg && imageId(selectedImg)) {
                        e.preventDefault();
                        postCompose('delete|' + imageId(selectedImg));
                        return;
                    }
                    if (inLockedRegion())
                        return;
                    if (e.key === 'Enter' || e.key === ' ')
                        tryAutoLink(true);
                    if (e.key === 'Tab') {
                        if (!listItem())
                            return;
                        e.preventDefault();
                        document.execCommand(e.shiftKey ? 'outdent' : 'indent');
                    }
                });

                editor.addEventListener('input', function (e) {
                    var paste = e.inputType === 'insertFromPaste';
                    if (e.inputType && e.inputType !== 'insertText'
                        && e.inputType !== 'insertCompositionText' && !paste)
                        return;
                    tryAutoList();
                    tryAutoLink(paste);
                });
            })();
        """;
    }

    private static string js_string (string value) {
        var builder = new StringBuilder ("\"");
        int i = 0;
        unichar c;
        while (value.get_next_char (ref i, out c)) {
            switch (c) {
                case '\\':
                    builder.append ("\\\\");
                    break;
                case '"':
                    builder.append ("\\\"");
                    break;
                case '\n':
                    builder.append ("\\n");
                    break;
                case '\r':
                    builder.append ("\\r");
                    break;
                case '<':
                    builder.append ("\\u003c");
                    break;
                default:
                    if (c < 32)
                        builder.append_printf ("\\u%04x", (uint) c);
                    else
                        builder.append_unichar (c);
                    break;
            }
        }
        builder.append_c ('"');
        return builder.str;
    }
}

private GenericArray<File> compose_drop_files (Value value) {
    var files = new GenericArray<File> ();
    if (value.type () == typeof (Gdk.FileList)) {
        unowned Gdk.FileList list = (Gdk.FileList) value.get_boxed ();
        if (list != null) {
            foreach (unowned File file in list.get_files ()) {
                if (file != null)
                    files.add (file);
            }
        }
        return files;
    }

    if (value.holds (typeof (File))) {
        var file = value.get_object () as File;
        if (file != null)
            files.add (file);
    }

    return files;
}

private bool compose_drop_is_external (Gdk.Drop drop) {
    if (drop.get_drag () != null)
        return false;
    var formats = drop.get_formats ();
    return formats.contain_gtype (typeof (Gdk.FileList)) || formats.contain_gtype (typeof (File));
}

private bool compose_is_usable_drop_file (File file) {
    if (!file.is_native ())
        return false;
    var path = file.get_path ();
    if (path == null || !Path.is_absolute (path))
        return false;
    return FileUtils.test (path, FileTest.IS_REGULAR);
}

private GenericArray<File> compose_usable_drop_files (Value value) {
    var files = compose_drop_files (value);
    var usable = new GenericArray<File> ();
    for (uint i = 0; i < files.length; i++) {
        if (compose_is_usable_drop_file (files[i]))
            usable.add (files[i]);
    }
    return usable;
}

namespace Mail.ComposeExtras {
    public static async void prompt_insert_image (Gtk.Widget parent, ComposeHtmlView view) {
        var dialog = new Gtk.FileDialog () {
            title = _("Insert Image"),
        };
        var images = new Gtk.FileFilter ();
        images.name = _("Images");
        images.add_mime_type ("image/png");
        images.add_mime_type ("image/jpeg");
        images.add_mime_type ("image/webp");
        var filters = new GLib.ListStore (typeof (Gtk.FileFilter));
        filters.append (images);
        dialog.filters = filters;
        dialog.default_filter = images;

        try {
            var file = yield dialog.open (parent.get_root () as Gtk.Window, null);
            if (file == null)
                return;
            var info = yield file.query_info_async (
                FileAttribute.STANDARD_DISPLAY_NAME + "," + FileAttribute.STANDARD_CONTENT_TYPE,
                FileQueryInfoFlags.NONE,
                Priority.DEFAULT,
                null
            );
            string? etag;
            var bytes = yield file.load_bytes_async (null, out etag);
            bool uncertain;
            unowned uint8[] data = bytes.get_data ();
            var mime = ContentType.guess (info.get_display_name (), data, out uncertain);
            if (mime == null || mime.length == 0)
                mime = info.get_content_type ();
            if (mime != null && mime.length > 0)
                mime = ContentType.get_mime_type (mime) ?? mime;
            if (mime == null || mime.length == 0)
                mime = "image/jpeg";
            view.insert_image (bytes, mime, info.get_display_name ());
        } catch (Error e) {
            if (e is IOError.CANCELLED || e is Gtk.DialogError.DISMISSED)
                return;
            warning ("Could not insert image: %s", e.message);
        }
    }
}
