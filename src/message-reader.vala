public class Mail.MessageReader : Gtk.Box {
    public signal void invitation_respond (Invitation invitation, InvitationStatus status);

    private const double ZOOM_MIN = 0.5;
    private const double ZOOM_MAX = 3.0;
    private const double ZOOM_STEP = 1.1;

    private Settings settings;
    private Gtk.Label subject_label;
    private Gtk.Label from_label;
    private Gtk.Label date_label;
    private RecipientRow to_row;
    private RecipientRow cc_row;
    private Adw.WrapBox attachments_box;
    private MessageActionBar header_actions;
    private Adw.Banner trust_banner;
    private InvitationBar invitation_bar;
    private WebKit.NetworkSession network_session;
    private WebKit.WebView webview;
    private Gtk.Stack stack;
    private SimpleAction view_image_action;
    private string? context_image_uri;
    private MessageContent? current;
    private Account? mailbox;
    private Identity? mailbox_identity;
    private ContactStore? contacts;
    private uint html_epoch;
    private uint trust_epoch;
    private bool allow_header_actions = true;

    public MessageReader () {
        Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
    }

    construct {
        add_css_class ("message-reader");
        hexpand = true;
        vexpand = true;
        this.settings = new Settings (Config.APP_ID);

        var header = new Gtk.Box (Gtk.Orientation.VERTICAL, 6) {
            hexpand = true,
        };

        this.header_actions = new MessageActionBar ();
        this.header_actions.add_css_class ("in-reader");
        this.header_actions.halign = Gtk.Align.END;
        this.header_actions.hexpand = true;
        this.header_actions.visible = false;

        var actions_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) {
            hexpand = true,
        };
        actions_row.add_css_class ("reader-action-row");
        actions_row.append (this.header_actions);
        header.append (actions_row);

        var meta_block = new Gtk.Box (Gtk.Orientation.VERTICAL, 6) {
            margin_start = 20,
            margin_end = 20,
            margin_top = 10,
            margin_bottom = 12,
        };

        this.subject_label = new Gtk.Label ("") {
            xalign = 0,
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            use_markup = false,
            selectable = true,
            hexpand = true,
            valign = Gtk.Align.START,
        };
        this.subject_label.add_css_class ("title-2");
        meta_block.append (this.subject_label);

        var meta = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        this.from_label = new Gtk.Label ("") {
            xalign = 0,
            hexpand = true,
            ellipsize = Pango.EllipsizeMode.END,
            use_markup = false,
            selectable = true,
        };
        this.from_label.add_css_class ("heading");
        meta.append (this.from_label);

        this.date_label = new Gtk.Label ("") {
            xalign = 1,
            use_markup = false,
            selectable = true,
        };
        this.date_label.add_css_class ("dim-label");
        this.date_label.add_css_class ("numeric");
        meta.append (this.date_label);
        meta_block.append (meta);

        this.to_row = new RecipientRow (_("To:"));
        meta_block.append (this.to_row);
        this.cc_row = new RecipientRow (_("Cc:"));
        meta_block.append (this.cc_row);

        this.attachments_box = new Adw.WrapBox () {
            visible = false,
            hexpand = true,
            vexpand = false,
            child_spacing = 8,
            line_spacing = 6,
            justify = Adw.JustifyMode.NONE,
            wrap_policy = Adw.WrapPolicy.NATURAL,
        };
        this.attachments_box.add_css_class ("attachments");
        meta_block.append (this.attachments_box);
        header.append (meta_block);

        this.trust_banner = new Adw.Banner (_("Remote images are blocked until you trust this sender.")) {
            button_label = _("Trust Sender"),
            revealed = false,
            use_markup = false,
        };
        this.trust_banner.button_clicked.connect (on_trust_sender);

        this.invitation_bar = new InvitationBar ();
        this.invitation_bar.respond.connect ((status) => {
            var invitation = this.current != null ? this.current.invitation : null;
            if (invitation != null)
                invitation_respond (invitation, status);
        });

        append (header);
        append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
        append (this.trust_banner);
        append (this.invitation_bar);

        var settings = new WebKit.Settings () {
            enable_javascript = false,
            enable_javascript_markup = false,
            javascript_can_open_windows_automatically = false,
            javascript_can_access_clipboard = false,
            allow_modal_dialogs = false,
            enable_html5_database = false,
            enable_html5_local_storage = false,
            enable_page_cache = false,
            auto_load_images = false,
        };

        this.network_session = new WebKit.NetworkSession.ephemeral ();
        this.webview = (WebKit.WebView) Object.new (typeof (WebKit.WebView),
            "network-session", this.network_session,
            "settings", settings,
            "hexpand", true,
            "vexpand", true
        );
        this.webview.add_css_class ("message-body");
        this.webview.decide_policy.connect (on_decide_policy);
        this.webview.context_menu.connect (on_context_menu);
        this.view_image_action = new SimpleAction ("view-image", null);
        this.view_image_action.activate.connect (() => view_context_image.begin ());
        this.webview.load_changed.connect (on_webview_load_changed);
        update_webview_background ();

        var placeholder = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            hexpand = true,
            vexpand = true,
        };
        placeholder.add_css_class ("message-body-placeholder");

        this.stack = new Gtk.Stack () {
            hexpand = true,
            vexpand = true,
            transition_type = Gtk.StackTransitionType.NONE,
            margin_start = 20,
            margin_end = 20,
            margin_top = 12,
            margin_bottom = 16,
        };
        this.stack.add_css_class ("message-body-stack");
        this.stack.add_named (placeholder, "loading");
        this.stack.add_named (this.webview, "body");
        append (this.stack);
        apply_zoom (this.settings.get_double ("reader-zoom"), false);
        add_zoom_scroll ();
    }

    public void zoom_in () {
        apply_zoom (this.webview.zoom_level * ZOOM_STEP, true);
    }

    public void zoom_out () {
        apply_zoom (this.webview.zoom_level / ZOOM_STEP, true);
    }

    public void zoom_reset () {
        apply_zoom (1.0, true);
    }

    private void apply_zoom (double zoom, bool persist) {
        zoom = zoom.clamp (ZOOM_MIN, ZOOM_MAX);
        if (Math.fabs (zoom - 1.0) < 0.03)
            zoom = 1.0;
        this.webview.zoom_level = zoom;
        if (persist)
            this.settings.set_double ("reader-zoom", zoom);
    }

    private void add_zoom_scroll () {
        var scroll = new Gtk.EventControllerScroll (Gtk.EventControllerScrollFlags.VERTICAL);
        scroll.set_propagation_phase (Gtk.PropagationPhase.CAPTURE);
        scroll.scroll.connect ((dx, dy) => {
            var mods = scroll.get_current_event_state () & Gtk.accelerator_get_default_mod_mask ();
            if ((mods & Gdk.ModifierType.CONTROL_MASK) == 0)
                return false;
            if (dy < 0)
                zoom_in ();
            else if (dy > 0)
                zoom_out ();
            return true;
        });
        this.webview.add_controller (scroll);
    }

    public void set_show_header_actions (bool show) {
        this.allow_header_actions = show;
        this.header_actions.visible = show && this.current != null;
    }

    public void set_bookmarked (bool bookmarked) {
        this.header_actions.set_bookmarked (bookmarked);
    }

    public void set_seen (bool seen, bool enabled) {
        this.header_actions.set_seen (seen, enabled);
    }

    public void set_outgoing (bool outgoing, bool draft = false) {
        this.header_actions.set_outgoing (outgoing, draft);
    }

    public void set_important (bool visible, bool important) {
        this.header_actions.set_important (visible, important);
    }

    public void set_invitation_busy (bool busy) {
        this.invitation_bar.set_busy (busy);
    }

    public void show_invitation_status (InvitationStatus status) {
        this.invitation_bar.show_status (status);
    }

    public void set_mailbox (Account? account, Identity? identity) {
        this.mailbox = account;
        this.mailbox_identity = identity;
    }

    public void set_contacts (ContactStore? store) {
        this.contacts = store;
    }

    public void print (Gtk.Window? parent) {
        if (this.current == null || this.stack.visible_child_name != "body")
            return;

        var operation = new WebKit.PrintOperation (this.webview);
        operation.run_dialog (parent);
    }

    public void show_loading (Message? message = null) {
        this.current = null;
        this.trust_epoch++;
        this.trust_banner.revealed = false;
        this.to_row.visible = false;
        this.cc_row.visible = false;
        this.header_actions.visible = false;
        this.attachments_box.visible = false;
        this.invitation_bar.bind (null);
        if (message != null) {
            this.subject_label.label = message.subject ?? "";
            this.from_label.label = message.from ?? "";
            this.date_label.label = Utils.format_message_datetime (message.date);
        } else {
            this.subject_label.label = "";
            this.from_label.label = "";
            this.date_label.label = "";
        }
        this.stack.visible_child_name = "loading";
    }

    public void show_content (MessageContent content, bool outgoing = false) {
        var sender = content.from_email ?? Utils.email_from_header (content.from);
        var trusted = Utils.remote_content_allowed (
            this.settings,
            sender,
            this.mailbox,
            this.mailbox_identity,
            outgoing
        );
        var check_book = !trusted
            && content.has_remote_images
            && Utils.mailbox_uses_org_trust (this.mailbox)
            && this.contacts != null;
        var needs_trust = content.has_remote_images && !trusted && !check_book;
        var same_body = this.current != null
            && this.current.uid == content.uid
            && this.stack.visible_child_name == "body"
            && this.trust_banner.revealed == needs_trust
            && this.webview.get_settings ().auto_load_images == (trusted || !content.has_remote_images);

        this.current = content;
        this.trust_epoch++;
        var epoch = this.trust_epoch;
        this.subject_label.label = content.subject;
        this.from_label.label = content.from;
        this.date_label.label = Utils.format_message_datetime (content.date);
        this.to_row.bind (content.to_recipients);
        this.cc_row.bind (content.cc_recipients);
        this.header_actions.visible = this.allow_header_actions;

        this.trust_banner.revealed = needs_trust;
        this.webview.get_settings ().auto_load_images = trusted || !content.has_remote_images;
        bind_attachments (content.attachments);
        this.invitation_bar.bind (content.invitation);
        if (!same_body)
            load_body_html (content.html);
        else
            this.stack.visible_child_name = "body";
        if (check_book)
            resolve_book_trust.begin (content, sender, epoch);
    }

    public void show_error (string message) {
        this.current = null;
        this.trust_epoch++;
        this.subject_label.label = _("Could Not Open Message");
        this.from_label.label = "";
        this.date_label.label = "";
        this.to_row.visible = false;
        this.cc_row.visible = false;
        this.header_actions.visible = false;
        this.attachments_box.visible = false;
        this.invitation_bar.bind (null);
        this.trust_banner.revealed = false;
        this.webview.get_settings ().auto_load_images = false;
        load_body_html (MessageContent.text_to_html (message));
    }

    private void on_trust_sender () {
        var content = this.current;
        if (content == null)
            return;

        var email = content.from_email ?? Utils.email_from_header (content.from);
        if (email == null || email.length == 0)
            return;

        Utils.trust_sender (this.settings, email);
        content.from_email = email;
        this.trust_banner.revealed = false;
        this.webview.get_settings ().auto_load_images = true;
        bind_attachments (content.attachments);
        reload_with_images.begin (content);
    }

    private async void resolve_book_trust (MessageContent content, string? sender, uint epoch) {
        var found = yield this.contacts.has_book_email (sender);
        if (epoch != this.trust_epoch || this.current != content)
            return;
        if (found) {
            this.trust_banner.revealed = false;
            this.webview.get_settings ().auto_load_images = true;
            bind_attachments (content.attachments);
            reload_with_images.begin (content);
            return;
        }
        this.trust_banner.revealed = content.has_remote_images;
    }

    private void load_body_html (string html) {
        this.html_epoch++;
        this.stack.visible_child_name = "loading";
        this.webview.stop_loading ();
        this.webview.load_html (
            "%s\n<!-- mail-reload %u -->".printf (
                html_with_print_chrome (this.current, html),
                this.html_epoch
            ),
            "about:blank"
        );
    }

    private string html_with_print_chrome (MessageContent? content, string html) {
        if (content == null)
            return html;

        var style = """<style>
html { color-scheme: only light; }
@media screen {
  .mail-print-header { display: none !important; }
  .mail-compose { padding: 0 !important; }
  html, body { background: #ffffff; color: #222222; }
}
@media print {
  .mail-print-header, .mail-print-header * {
    all: unset !important;
    display: revert !important;
    font-family: "Cantarell", "Liberation Sans", Helvetica, Arial, sans-serif !important;
    font-size: 9pt !important;
    font-weight: 400 !important;
    font-style: normal !important;
    line-height: 1.25 !important;
    letter-spacing: normal !important;
    text-transform: none !important;
    color: #222 !important;
    background: transparent !important;
    border: 0 none !important;
    box-shadow: none !important;
    margin: 0 !important;
    padding: 0 !important;
  }
  .mail-print-header {
    display: block !important;
    width: 100% !important;
    box-sizing: border-box !important;
    margin: 0 0 10pt !important;
  }
  .mail-print-origin {
    display: block !important;
    font-size: 8pt !important;
    line-height: 1.2 !important;
    color: #666 !important;
    margin: 0 0 4pt !important;
  }
  .mail-print-rule {
    display: block !important;
    width: 100% !important;
    height: 0 !important;
    border: 0 none !important;
    border-top: 0.6pt solid #bbb !important;
    margin: 0 0 8pt !important;
  }
  .mail-print-subject {
    display: block !important;
    font-size: 12pt !important;
    font-weight: 600 !important;
    line-height: 1.25 !important;
    color: #111 !important;
    margin: 0 0 6pt !important;
  }
  .mail-print-meta {
    display: table !important;
    width: 100% !important;
    border-collapse: collapse !important;
  }
  .mail-print-meta tr {
    display: table-row !important;
  }
  .mail-print-label, .mail-print-value {
    display: table-cell !important;
    vertical-align: top !important;
    font-size: 8.5pt !important;
    line-height: 1.3 !important;
    padding: 0 0 1.5pt !important;
  }
  .mail-print-label {
    font-weight: 600 !important;
    color: #444 !important;
    white-space: nowrap !important;
    width: 1% !important;
    padding-right: 10pt !important;
  }
  .mail-print-value {
    color: #222 !important;
  }
}
</style>""";
        var chrome = print_header_markup (content);
        var body = html;
        var lower = body.down ();
        if (!lower.contains ("<html")) {
            return "<!DOCTYPE html><html><head><meta charset=\"utf-8\">%s</head><body>%s%s</body></html>".printf (
                style,
                chrome,
                body
            );
        }

        body = insert_after_open_tag (body, "head", style);
        body = insert_after_open_tag (body, "body", chrome);
        return body;
    }

    private string print_header_markup (MessageContent content) {
        var rows = new StringBuilder ();
        append_print_row (rows, _("From"), content.from);
        append_print_row (rows, _("Date"), Utils.format_message_datetime (content.date));
        if (content.to != null && content.to.length > 0)
            append_print_row (rows, _("To"), content.to);
        if (content.cc != null && content.cc.length > 0)
            append_print_row (rows, _("Cc"), content.cc);
        if (content.attachments != null && content.attachments.length > 0) {
            var names = new StringBuilder ();
            for (uint i = 0; i < content.attachments.length; i++) {
                if (i > 0)
                    names.append (", ");
                names.append (content.attachments[i].filename ?? _("Attachment"));
            }
            append_print_row (rows, _("Attachments"), names.str);
        }

        return (
            "<div class=\"mail-print-header\">" +
            "<div class=\"mail-print-origin\">%s</div>" +
            "<hr class=\"mail-print-rule\">" +
            "<div class=\"mail-print-subject\">%s</div>" +
            "<table class=\"mail-print-meta\">%s</table>" +
            "</div>"
        ).printf (
            Markup.escape_text (print_origin_line ()),
            Markup.escape_text (content.subject ?? _("(No subject)")),
            rows.str
        );
    }

    private string print_origin_line () {
        var line = print_app_name ();
        if (this.mailbox != null)
            line += " - " + this.mailbox.kind.label ();
        var who = print_mailbox_who ();
        if (who.length > 0)
            line += " - " + who;
        return line;
    }

    private static string print_app_name () {
        return _("Letter");
    }

    private string print_mailbox_who () {
        var name = this.mailbox_identity != null ? this.mailbox_identity.name : null;
        var address = this.mailbox_identity != null ? this.mailbox_identity.address : null;
        if ((name == null || name.length == 0) && this.mailbox != null)
            name = this.mailbox.display_name;
        if ((address == null || address.length == 0) && this.mailbox != null)
            address = this.mailbox.email;
        if (address == null || address.length == 0)
            return name ?? "";
        if (name == null || name.length == 0 || name == address)
            return address;
        return "%s <%s>".printf (name, address);
    }

    private static void append_print_row (StringBuilder rows, string label, string? value) {
        if (value == null || value.length == 0)
            return;
        rows.append_printf (
            "<tr><th class=\"mail-print-label\">%s</th><td class=\"mail-print-value\">%s</td></tr>",
            Markup.escape_text (label),
            Markup.escape_text (value).replace ("\n", "<br>")
        );
    }

    private static string insert_after_open_tag (string html, string tag, string insert) {
        var needle = "<" + tag;
        var lower = html.down ();
        var start = 0;
        int at = -1;
        while (start < lower.length) {
            var i = lower.index_of (needle, start);
            if (i < 0)
                break;
            var after = i + needle.length;
            var next = after < lower.length ? lower[after] : '>';
            if (next == '>' || next.isspace ()) {
                at = i;
                break;
            }
            start = after;
        }
        if (at < 0)
            return html;
        var gt = html.index_of (">", at);
        if (gt < 0)
            return html;
        return html.substring (0, gt + 1) + insert + html.substring (gt + 1);
    }

    private async void reload_with_images (MessageContent content) {
        try {
            yield this.network_session.get_website_data_manager ().clear (
                WebKit.WebsiteDataTypes.MEMORY_CACHE,
                0,
                null
            );
        } catch (Error e) {
            debug ("Could not clear blocked-image cache: %s", e.message);
        }

        Idle.add (reload_with_images.callback);
        yield;
        if (this.current != content)
            return;

        load_body_html (content.html);
        this.stack.visible_child_name = "body";
    }

    private void bind_attachments (GenericArray<Attachment>? attachments) {
        Gtk.Widget? child = this.attachments_box.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            this.attachments_box.remove (child);
            child = next;
        }

        if (attachments == null || attachments.length == 0) {
            this.attachments_box.visible = false;
            return;
        }

        if (attachments.length > 1)
            this.attachments_box.append (make_download_all_button ());

        for (uint i = 0; i < attachments.length; i++)
            this.attachments_box.append (new AttachmentChip (attachments[i]));

        this.attachments_box.visible = true;
    }

    private Gtk.Button make_download_all_button () {
        var contents = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        contents.append (new Gtk.Image.from_icon_name ("folder-download-symbolic"));
        contents.append (new Gtk.Label (_("Download All")) {
            use_markup = false,
        });
        var button = new Gtk.Button () {
            child = contents,
            valign = Gtk.Align.CENTER,
            hexpand = false,
            tooltip_text = _("Save all attachments"),
        };
        button.add_css_class ("suggested-action");
        button.add_css_class ("pill");
        button.add_css_class ("attachment-download-all");
        button.clicked.connect (() => save_all_attachments.begin ());
        return button;
    }

    private async void save_all_attachments () {
        var attachments = this.current != null ? this.current.attachments : null;
        if (attachments == null || attachments.length == 0)
            return;

        try {
            yield Utils.save_attachments (attachments, get_root () as Gtk.Window);
        } catch (Error e) {
            if (e is IOError.CANCELLED || e is Gtk.DialogError.DISMISSED)
                return;
            warning ("%s", e.message);
            Gtk.Widget? widget = this;
            while (widget != null) {
                var overlay = widget as Adw.ToastOverlay;
                if (overlay != null) {
                    overlay.add_toast (new Adw.Toast (e.message) {
                        timeout = 4,
                    });
                    return;
                }
                widget = widget.parent;
            }
        }
    }

    private void on_webview_load_changed (WebKit.LoadEvent event) {
        if (event == WebKit.LoadEvent.COMMITTED || event == WebKit.LoadEvent.FINISHED)
            this.stack.visible_child_name = "body";
    }

    private void update_webview_background () {
        var rgba = Gdk.RGBA ();
        rgba.parse ("#ffffff");
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
        if (action.get_navigation_type () != WebKit.NavigationType.LINK_CLICKED)
            return false;

        var uri = action.get_request ().get_uri ();
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

    private bool on_context_menu (WebKit.ContextMenu menu, WebKit.HitTestResult hit) {
        this.context_image_uri = null;
        if (!hit.context_is_image ())
            return false;

        var uri = hit.get_image_uri ();
        if (uri != null && uri.length > 0)
            this.context_image_uri = uri;

        var insert_at = 0;
        for (int i = (int) menu.get_n_items () - 1; i >= 0; i--) {
            var item = menu.get_item_at_position (i);
            var action = item.get_stock_action ();
            if (action == WebKit.ContextMenuAction.OPEN_IMAGE_IN_NEW_WINDOW
                || action == WebKit.ContextMenuAction.OPEN_FRAME_IN_NEW_WINDOW) {
                insert_at = i;
                menu.remove (item);
            }
        }

        if (this.context_image_uri != null) {
            menu.insert (
                new WebKit.ContextMenuItem.from_gaction (this.view_image_action, _("View Image"), null),
                insert_at
            );
        }
        return false;
    }

    private async void view_context_image () {
        var uri = this.context_image_uri;
        if (uri == null || uri.length == 0)
            return;
        try {
            yield Utils.open_or_preview_image_uri (uri, get_root () as Gtk.Window);
        } catch (Error e) {
            warning ("Could not open image: %s", e.message);
        }
    }
}

private class Mail.RecipientRow : Gtk.Box {
    private RecipientChips chips;

    public RecipientRow (string caption_text) {
        Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 8);

        var caption = new Gtk.Label (caption_text) {
            xalign = 0,
            yalign = 0,
            width_chars = 4,
            valign = Gtk.Align.START,
            use_markup = false,
        };
        caption.add_css_class ("dim-label");
        caption.add_css_class ("caption");
        append (caption);

        this.chips = new RecipientChips ();
        append (this.chips);
    }

    public void bind (GenericArray<Recipient>? recipients) {
        var empty = recipients == null || recipients.length == 0;
        visible = !empty;
        if (!empty)
            this.chips.bind (recipients);
    }
}

private class Mail.RecipientChips : Gtk.Widget {
    private const int MAX_LINES = 2;
    private const int SPACING = 6;

    private GenericArray<Gtk.Widget> chips = new GenericArray<Gtk.Widget> ();
    private Gtk.Button more_button;
    private Gtk.Label more_label;
    private bool expanded;

    static construct {
        set_css_name ("recipient-chips");
    }

    construct {
        hexpand = true;
        this.more_label = new Gtk.Label ("") {
            use_markup = false,
            single_line_mode = true,
        };
        this.more_button = new Gtk.Button () {
            child = this.more_label,
            focus_on_click = false,
            has_frame = false,
            valign = Gtk.Align.CENTER,
        };
        this.more_button.add_css_class ("flat");
        this.more_button.add_css_class ("recipient-more");
        this.more_button.set_parent (this);
        this.more_button.clicked.connect (on_more_clicked);
    }

    public override void dispose () {
        for (uint i = 0; i < this.chips.length; i++) {
            if (this.chips[i].get_parent () == this)
                this.chips[i].unparent ();
        }
        this.chips.remove_range (0, this.chips.length);
        if (this.more_button.get_parent () == this)
            this.more_button.unparent ();
        base.dispose ();
    }

    public void bind (GenericArray<Recipient>? recipients) {
        this.expanded = false;
        for (uint i = 0; i < this.chips.length; i++)
            this.chips[i].unparent ();
        this.chips.remove_range (0, this.chips.length);

        if (recipients != null) {
            for (uint i = 0; i < recipients.length; i++) {
                var chip = make_chip (recipients[i]);
                chip.set_parent (this);
                this.chips.add (chip);
            }
        }

        queue_resize ();
    }

    private void on_more_clicked () {
        this.expanded = !this.expanded;
        queue_resize ();
    }

    private static Gtk.Widget make_chip (Recipient recipient) {
        var label = new Gtk.Label (recipient.chip_label) {
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 22,
            single_line_mode = true,
            use_markup = false,
        };
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) {
            valign = Gtk.Align.CENTER,
            tooltip_text = recipient.tooltip,
        };
        box.add_css_class ("recipient-chip");
        box.append (label);
        return box;
    }

    public override Gtk.SizeRequestMode get_request_mode () {
        return Gtk.SizeRequestMode.HEIGHT_FOR_WIDTH;
    }

    public override void measure (
        Gtk.Orientation orientation,
        int for_size,
        out int minimum,
        out int natural,
        out int minimum_baseline,
        out int natural_baseline
    ) {
        minimum_baseline = -1;
        natural_baseline = -1;

        if (this.chips.length == 0) {
            minimum = 0;
            natural = 0;
            return;
        }

        int line_height = 0;
        int min_chip = 0;
        int total_width = 0;
        int dummy_min;
        int dummy_nat;
        for (uint i = 0; i < this.chips.length; i++) {
            int cmin, cnat, hmin, hnat;
            this.chips[i].measure (Gtk.Orientation.HORIZONTAL, -1, out cmin, out cnat, out dummy_min, out dummy_nat);
            this.chips[i].measure (Gtk.Orientation.VERTICAL, -1, out hmin, out hnat, out dummy_min, out dummy_nat);
            min_chip = int.max (min_chip, cmin);
            line_height = int.max (line_height, hnat);
            total_width += cnat;
            if (i > 0)
                total_width += SPACING;
        }

        if (orientation == Gtk.Orientation.HORIZONTAL) {
            minimum = min_chip;
            natural = total_width;
            return;
        }

        int width = for_size > 0 ? for_size : total_width;
        int height;
        uint shown;
        layout (width, false, out height, out shown);
        minimum = line_height;
        natural = int.max (line_height, height);
    }

    public override void size_allocate (int width, int height, int baseline) {
        if (width < 1) {
            hide_unallocated ();
            return;
        }

        int used_height;
        uint shown;
        layout (width, true, out used_height, out shown);
    }

    private void hide_unallocated () {
        this.more_button.set_child_visible (false);
        for (uint i = 0; i < this.chips.length; i++)
            this.chips[i].set_child_visible (false);
    }

    private void layout (int width, bool allocate, out int height, out uint shown) {
        shown = 0;
        height = 0;
        uint total = this.chips.length;
        if (total == 0) {
            if (allocate)
                this.more_button.set_child_visible (false);
            return;
        }

        int dummy_min;
        int dummy_nat;
        var widths = new int[total];
        var heights = new int[total];
        for (uint i = 0; i < total; i++) {
            int cmin, cnat, hmin, hnat;
            this.chips[i].measure (Gtk.Orientation.HORIZONTAL, -1, out cmin, out cnat, out dummy_min, out dummy_nat);
            this.chips[i].measure (Gtk.Orientation.VERTICAL, -1, out hmin, out hnat, out dummy_min, out dummy_nat);
            widths[i] = int.max (cmin, cnat);
            heights[i] = int.max (hmin, hnat);
        }

        int max_lines = this.expanded ? int.MAX : MAX_LINES;
        int line = 0;
        int x = 0;
        int y = 0;
        int line_height = 0;

        for (uint i = 0; i < total; i++) {
            int cw = widths[i];
            int ch = heights[i];
            bool wrap = x > 0 && width > 0 && x + cw > width;
            int next_line = wrap ? line + 1 : line;
            if (next_line >= max_lines)
                break;

            uint remaining_after = total - i - 1;
            if (!this.expanded && remaining_after > 0 && next_line == MAX_LINES - 1) {
                int place_x = wrap ? 0 : x;
                int after = place_x + cw + SPACING + overflow_width (remaining_after);
                if (width > 0 && after > width)
                    break;
            }

            if (wrap) {
                y += line_height + SPACING;
                x = 0;
                line++;
                line_height = 0;
            }

            if (allocate) {
                this.chips[i].set_child_visible (true);
                var transform = new Gsk.Transform ();
                transform = transform.translate ({ (float) x, (float) y });
                this.chips[i].allocate (cw, ch, -1, transform);
            }

            shown++;
            x += cw + SPACING;
            line_height = int.max (line_height, ch);
            height = y + line_height;
        }

        uint hidden = total - shown;
        bool show_more = this.expanded || hidden > 0;
        if (show_more) {
            if (this.expanded) {
                this.more_label.label = _("Show less");
                this.more_button.tooltip_text = _("Show fewer recipients");
            } else {
                this.more_label.label = _("+ %u").printf (hidden);
                this.more_button.tooltip_text = ngettext (
                    "%u more recipient",
                    "%u more recipients",
                    hidden
                ).printf (hidden);
            }

            int omin, onat, ohmin, ohnat;
            this.more_button.measure (Gtk.Orientation.HORIZONTAL, -1, out omin, out onat, out dummy_min, out dummy_nat);
            this.more_button.measure (Gtk.Orientation.VERTICAL, -1, out ohmin, out ohnat, out dummy_min, out dummy_nat);
            onat = int.max (omin, onat);
            ohnat = int.max (ohmin, ohnat);

            if (x > 0 && width > 0 && x + onat > width && (this.expanded || line + 1 < MAX_LINES)) {
                y += line_height + SPACING;
                x = 0;
                line++;
                line_height = ohnat;
            }

            if (allocate && onat > 0 && ohnat > 0) {
                this.more_button.set_child_visible (true);
                var transform = new Gsk.Transform ();
                transform = transform.translate ({ (float) x, (float) y });
                this.more_button.allocate (onat, int.max (ohnat, line_height), -1, transform);
            }

            height = int.max (height, y + int.max (line_height, ohnat));
        } else if (allocate) {
            this.more_label.label = "";
            this.more_button.tooltip_text = null;
            this.more_button.set_child_visible (false);
        }

        if (allocate) {
            for (uint i = shown; i < total; i++)
                this.chips[i].set_child_visible (false);
        }
    }

    private int overflow_width (uint count) {
        this.more_label.label = _("+ %u").printf (count);
        int min, nat, dummy_min, dummy_nat;
        this.more_button.measure (Gtk.Orientation.HORIZONTAL, -1, out min, out nat, out dummy_min, out dummy_nat);
        return nat;
    }
}

public class Mail.MessageActionBar : Gtk.Box {
    private Gtk.Button reply_button;
    private Gtk.Button reply_all_button;
    private Gtk.Button forward_button;
    private Gtk.Widget compose_separator;
    private Gtk.Button seen_button;
    private Gtk.Widget more_separator;
    private Gtk.Button? bookmark_button;
    private Gtk.Button? important_button;
    private Gtk.Button print_button;
    private bool bulk;
    private bool important_allowed;

    public MessageActionBar (bool show_bookmark = true) {
        Object (orientation: Gtk.Orientation.HORIZONTAL, spacing: 0);
        add_css_class ("message-action-bar");
        hexpand = false;
        valign = Gtk.Align.CENTER;

        this.reply_button = action_button ("mail-reply-sender-symbolic", _("Reply"), "win.reply");
        this.reply_all_button = action_button ("mail-reply-all-symbolic", _("Reply All"), "win.reply-all");
        this.forward_button = action_button ("mail-forward-symbolic", _("Forward"), "win.forward");
        append (this.reply_button);
        append (this.reply_all_button);
        append (this.forward_button);

        this.compose_separator = group_separator ();
        append (this.compose_separator);

        append (action_button ("package-x-generic-symbolic", _("Archive"), "win.archive"));
        append (action_button ("folder-symbolic", _("Move"), "win.move"));
        append (action_button ("user-trash-symbolic", _("Delete"), "win.delete"));

        append (group_separator ());

        this.seen_button = action_button ("mail-read-symbolic", _("Mark as Read"), "win.mark-read");
        append (this.seen_button);

        this.more_separator = group_separator ();
        append (this.more_separator);

        if (show_bookmark) {
            this.bookmark_button = action_button ("bookmark-new-symbolic", _("Bookmark"), "win.bookmark");
            append (this.bookmark_button);
            this.important_button = action_button (
                "mail-mark-important-symbolic",
                _("Mark as Important"),
                "win.mark-important"
            );
            this.important_button.visible = false;
            append (this.important_button);
        }
        this.print_button = action_button ("document-print-symbolic", _("Print"), "win.print");
        append (this.print_button);
    }

    public void set_bulk (bool bulk) {
        this.bulk = bulk;
        this.reply_button.visible = !bulk;
        this.reply_all_button.visible = !bulk;
        this.forward_button.visible = !bulk;
        this.compose_separator.visible = !bulk;
        this.more_separator.visible = !bulk;
        if (this.bookmark_button != null)
            this.bookmark_button.visible = !bulk;
        if (this.important_button != null)
            this.important_button.visible = !bulk && this.important_allowed;
        this.print_button.visible = !bulk;
    }

    public void set_outgoing (bool outgoing, bool draft = false) {
        if (draft) {
            this.reply_button.icon_name = "document-edit-symbolic";
            this.reply_button.tooltip_text = _("Edit Draft");
            this.reply_button.action_name = "win.send-again";
            this.reply_all_button.visible = false;
            this.forward_button.visible = false;
        } else if (outgoing) {
            this.reply_button.icon_name = "mail-send-symbolic";
            this.reply_button.tooltip_text = _("Send Again");
            this.reply_button.action_name = "win.send-again";
            this.reply_all_button.visible = !this.bulk;
            this.forward_button.visible = !this.bulk;
        } else {
            this.reply_button.icon_name = "mail-reply-sender-symbolic";
            this.reply_button.tooltip_text = _("Reply");
            this.reply_button.action_name = "win.reply";
            this.reply_all_button.visible = !this.bulk;
            this.forward_button.visible = !this.bulk;
        }
    }

    public void set_seen (bool seen, bool enabled) {
        this.seen_button.sensitive = enabled;
        if (seen) {
            this.seen_button.icon_name = "mail-unread-symbolic";
            this.seen_button.tooltip_text = _("Mark as Unread");
            this.seen_button.action_name = "win.mark-unread";
        } else {
            this.seen_button.icon_name = "mail-read-symbolic";
            this.seen_button.tooltip_text = _("Mark as Read");
            this.seen_button.action_name = "win.mark-read";
        }
    }

    public void set_bookmarked (bool bookmarked) {
        if (this.bookmark_button == null)
            return;
        this.bookmark_button.icon_name = bookmarked
            ? "user-bookmarks-symbolic"
            : "bookmark-new-symbolic";
        this.bookmark_button.tooltip_text = bookmarked
            ? _("Remove Bookmark")
            : _("Bookmark");
        if (bookmarked)
            this.bookmark_button.add_css_class ("accent");
        else
            this.bookmark_button.remove_css_class ("accent");
    }

    public void set_important (bool visible, bool important) {
        this.important_allowed = visible;
        if (this.important_button == null)
            return;
        this.important_button.visible = visible && !this.bulk;
        this.important_button.tooltip_text = important
            ? _("Not Important")
            : _("Mark as Important");
        if (important)
            this.important_button.add_css_class ("accent");
        else
            this.important_button.remove_css_class ("accent");
    }

    private static Gtk.Widget group_separator () {
        var sep = new Gtk.Separator (Gtk.Orientation.VERTICAL) {
            valign = Gtk.Align.FILL,
        };
        sep.add_css_class ("message-action-separator");
        sep.margin_top = 6;
        sep.margin_bottom = 6;
        sep.margin_start = 8;
        sep.margin_end = 8;
        return sep;
    }

    private static Gtk.Button action_button (string icon, string tooltip, string action) {
        var button = new Gtk.Button.from_icon_name (icon) {
            tooltip_text = tooltip,
            action_name = action,
            has_frame = false,
        };
        button.add_css_class ("flat");
        button.add_css_class ("message-action-button");
        return button;
    }
}
