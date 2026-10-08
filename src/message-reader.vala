public class Mail.MessageReader : Gtk.Box {
    public signal void invitation_respond (Invitation invitation, InvitationStatus status);
    public signal void compose_to (Recipient recipient);
    public signal void forward_image (Attachment attachment);

    private const double ZOOM_MIN = 0.5;
    private const double ZOOM_MAX = 3.0;
    private const double ZOOM_STEP = 1.1;
    /* White cover over the previous mail until the next one has painted.
     * Off while we see whether the GPU texture is enough on its own. */
    private const bool READER_WHITE_VEIL = false;

    private Settings settings;
    private Gtk.Label subject_label;
    private Gtk.Label from_label;
    private Gtk.Label date_label;
    private RecipientRow to_row;
    private RecipientRow cc_row;
    private Adw.WrapBox attachments_box;
    private MessageActionBar header_actions;
    private Gtk.Box priority_badge;
    private Adw.Banner trust_banner;
    private InvitationBar invitation_bar;

    private WebKit.NetworkSession network_session;
    private static bool inline_scheme_ready;
    private WebKit.WebView? webview;
    private ulong body_loaded_id;
    private ulong body_failed_id;
    private bool load_remote_images;
    private bool document_ready;
    private bool expect_document;
    private Gtk.Box white_cover;
    private uint cover_epoch;
    private bool reader_gone;
    private SimpleAction view_image_action;
    private SimpleAction save_image_action;
    private SimpleAction forward_image_action;
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
        this.settings.changed["message-body-background"].connect (on_body_background_changed);
        Adw.StyleManager.get_default ().notify["dark"].connect (on_body_background_changed);
        sync_body_chrome_class ();

        var header = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) {
            hexpand = true,
        };

        this.header_actions = new MessageActionBar ();
        this.header_actions.add_css_class ("in-reader");
        this.header_actions.halign = Gtk.Align.END;
        this.header_actions.hexpand = true;
        this.header_actions.valign = Gtk.Align.CENTER;
        this.header_actions.visible = false;

        this.priority_badge = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4) {
            visible = false,
            hexpand = false,
            halign = Gtk.Align.START,
            valign = Gtk.Align.CENTER,
        };
        this.priority_badge.add_css_class ("priority-badge");
        var priority_icon = new Gtk.Image.from_icon_name ("mail-mark-important-symbolic");
        priority_icon.add_css_class ("priority-badge-icon");
        var priority_label = new Gtk.Label (_("Important message")) {
            xalign = 0,
            use_markup = false,
        };
        priority_label.add_css_class ("caption");
        this.priority_badge.append (priority_icon);
        this.priority_badge.append (priority_label);

        var actions_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            hexpand = true,
            valign = Gtk.Align.CENTER,
        };
        actions_row.add_css_class ("reader-action-row");
        actions_row.append (this.priority_badge);
        actions_row.append (this.header_actions);
        header.append (actions_row);

        var meta_block = new Gtk.Box (Gtk.Orientation.VERTICAL, 4) {
            margin_start = 20,
            margin_end = 20,
            margin_top = 2,
            margin_bottom = 8,
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
        this.to_row.write_to.connect ((recipient) => compose_to (recipient));
        meta_block.append (this.to_row);
        this.cc_row = new RecipientRow (_("Cc:"));
        this.cc_row.write_to.connect ((recipient) => compose_to (recipient));
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

        this.view_image_action = new SimpleAction ("view-image", null);
        this.view_image_action.activate.connect (() => view_context_image.begin ());
        this.save_image_action = new SimpleAction ("save-image", null);
        this.save_image_action.activate.connect (() => save_context_image.begin ());
        this.forward_image_action = new SimpleAction ("forward-image", null);
        this.forward_image_action.activate.connect (() => forward_context_image.begin ());
        ensure_inline_image_scheme ();
        this.network_session = new WebKit.NetworkSession.ephemeral ();
        this.webview = create_reader_view ();
        this.white_cover = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            can_target = false,
            visible = false,
            hexpand = true,
            vexpand = true,
            halign = Gtk.Align.FILL,
            valign = Gtk.Align.FILL,
        };
        this.white_cover.add_css_class ("message-body-placeholder");
        var overlay = new Gtk.Overlay () {
            hexpand = true,
            vexpand = true,
        };
        overlay.child = this.webview;
        overlay.add_overlay (this.white_cover);
        append (overlay);
        load_reader_html (blank_html (), false);
    }

    private bool body_follow_dark () {
        return this.settings.get_string ("message-body-background") == "follow-system"
            && Adw.StyleManager.get_default ().dark;
    }

    private void sync_body_chrome_class () {
        if (body_follow_dark ())
            add_css_class ("body-follow-dark");
        else
            remove_css_class ("body-follow-dark");
        update_webview_background ();
    }

    private void update_webview_background () {
        if (this.webview == null)
            return;
        var rgba = Gdk.RGBA ();
        rgba.parse (body_follow_dark () ? "#1e1e1e" : "#ffffff");
        this.webview.set_background_color (rgba);
    }

    private void on_body_background_changed () {
        sync_body_chrome_class ();
        if (this.current != null)
            load_body_html (this.current.html);
        else
            load_reader_html (blank_html (), false);
    }

    private string blank_html () {
        var bg = body_follow_dark () ? "#1e1e1e" : "#ffffff";
        return """
<!DOCTYPE html><html><head><meta charset="utf-8"><style>
html, body { margin: 0; height: 100%; background: %s; }
</style></head><body></body></html>
""".printf (bg);
    }

    /* Drawn inside the living surface. A GTK spinner would sit under the
     * GPU plane and could not cover it. */
    private string waiting_html () {
        var dark = body_follow_dark ();
        var bg = dark ? "#1e1e1e" : "#ffffff";
        var ring = dark ? "rgba(238, 238, 238, 0.14)" : "rgba(34, 34, 34, 0.14)";
        var tip = dark ? "rgba(238, 238, 238, 0.55)" : "rgba(34, 34, 34, 0.55)";
        return """
<!DOCTYPE html><html><head><meta charset="utf-8"><style>
html, body { margin: 0; height: 100%; background: %s; }
.spin {
  width: 28px; height: 28px; box-sizing: border-box;
  border: 2.5px solid %s;
  border-top-color: %s;
  border-radius: 50%;
  position: absolute; left: 50%; top: 38%; margin-left: -14px;
  animation: letter-spin 0.7s linear infinite;
}
@keyframes letter-spin { to { transform: rotate(360deg); } }
</style></head><body><div class="spin"></div></body></html>
""".printf (bg, ring, tip);
    }

    /* Covers the previous mail immediately. The web view stays mapped;
     * the next paint is white, and the new document is drawn underneath. */
    public void hold_white () {
        if (!READER_WHITE_VEIL || this.reader_gone)
            return;
        this.cover_epoch++;
        this.white_cover.visible = true;
    }

    public override void dispose () {
        this.reader_gone = true;
        this.cover_epoch++;
        retire_webview ();
        base.dispose ();
    }

    public void zoom_in () {
        var current = this.webview != null
            ? this.webview.zoom_level
            : this.settings.get_double ("reader-zoom");
        apply_zoom (current * ZOOM_STEP, true);
    }

    public void zoom_out () {
        var current = this.webview != null
            ? this.webview.zoom_level
            : this.settings.get_double ("reader-zoom");
        apply_zoom (current / ZOOM_STEP, true);
    }

    public void zoom_reset () {
        apply_zoom (1.0, true);
    }

    private void apply_zoom (double zoom, bool persist) {
        zoom = zoom.clamp (ZOOM_MIN, ZOOM_MAX);
        if (Math.fabs (zoom - 1.0) < 0.03)
            zoom = 1.0;
        if (this.webview != null)
            this.webview.zoom_level = zoom;
        if (persist)
            this.settings.set_double ("reader-zoom", zoom);
    }

    private void add_zoom_scroll (WebKit.WebView view) {
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
        view.add_controller (scroll);
    }

    public void set_show_header_actions (bool show) {
        this.allow_header_actions = show;
        this.header_actions.visible = show && this.current != null;
    }

    public void set_show_invitation_actions (bool show) {
        this.invitation_bar.set_actions_visible (show);
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

    public void set_priority_badge (bool show) {
        this.priority_badge.visible = show;
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
        if (this.current == null || this.webview == null || !this.document_ready)
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
        this.priority_badge.visible = false;
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
        load_reader_html (message != null ? waiting_html () : blank_html (), false);
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
        var allow_remote = trusted || !content.has_remote_images;
        var same_body = this.document_ready
            && this.current != null
            && this.current.uid == content.uid
            && this.trust_banner.revealed == needs_trust
            && this.webview != null
            && this.load_remote_images == allow_remote;

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
        this.load_remote_images = allow_remote;
        bind_attachments (content.attachments);
        this.invitation_bar.bind (content.invitation);
        if (!same_body)
            load_body_html (content.html);
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
        this.priority_badge.visible = false;
        this.attachments_box.visible = false;
        this.invitation_bar.bind (null);
        this.trust_banner.revealed = false;
        this.load_remote_images = false;
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
        this.load_remote_images = true;
        bind_attachments (content.attachments);
        reload_with_images.begin (content);
    }

    private async void resolve_book_trust (MessageContent content, string? sender, uint epoch) {
        var found = yield this.contacts.has_book_email (sender);
        if (epoch != this.trust_epoch || this.current != content)
            return;
        if (found) {
            this.trust_banner.revealed = false;
            this.load_remote_images = true;
            bind_attachments (content.attachments);
            reload_with_images.begin (content);
            return;
        }
        this.trust_banner.revealed = content.has_remote_images;
    }

    private WebKit.WebView create_reader_view () {
        var settings = new WebKit.Settings () {
            /* Engine on so we can lift dark-on-dark text after load.
             * Markup stays off: <script> in mail never runs. */
            enable_javascript = true,
            enable_javascript_markup = false,
            javascript_can_open_windows_automatically = false,
            javascript_can_access_clipboard = false,
            allow_modal_dialogs = false,
            enable_html5_database = false,
            enable_html5_local_storage = false,
            enable_page_cache = false,
            enable_back_forward_navigation_gestures = false,
            /* Each wheel notch is one paint. The animated interpolation
             * repaints the whole visible page on every intermediate frame. */
            enable_smooth_scrolling = false,
            /* Inline images are letterimg:, served by us. Remote http images
             * stay gated by the document policy below, not by this switch:
             * turning it off would also skip letterimg:, and the text would
             * paint without its pictures. */
            auto_load_images = true,
            /* One GPU surface for the life of the reader. main() pins it to
             * the GPU that drives the display. The next mail replaces the
             * document; tearing this surface down is what flashes black. */
            hardware_acceleration_policy = WebKit.HardwareAccelerationPolicy.ALWAYS,
        };
        prefer_one_web_process (settings);
        var view = (WebKit.WebView) Object.new (typeof (WebKit.WebView),
            "network-session", this.network_session,
            "settings", settings,
            "hexpand", true,
            "vexpand", true,
            "margin-start", 20,
            "margin-end", 20,
            "margin-top", 12,
            "margin-bottom", 16
        );
        view.add_css_class ("message-body");
        view.decide_policy.connect (on_decide_policy);
        view.context_menu.connect (on_context_menu);
        var rgba = Gdk.RGBA ();
        rgba.parse (body_follow_dark () ? "#1e1e1e" : "#ffffff");
        view.set_background_color (rgba);
        view.realize.connect (update_webview_background);
        add_zoom_scroll (view);
        var zoom = this.settings.get_double ("reader-zoom").clamp (ZOOM_MIN, ZOOM_MAX);
        if (Math.fabs (zoom - 1.0) < 0.03)
            zoom = 1.0;
        view.zoom_level = zoom;
        return view;
    }

    private static bool web_process_limited;

    /* Site isolation gives every origin in a message its own WebKit process.
     * Those processes stay alive, so a few hours of mail becomes gigabytes.
     * One process per view is enough: the document is replaced in place. */
    /* Host webkitgtk-6.0.vapi stops before the 2.42 feature API. */
    [CCode (cname = "webkit_settings_get_all_features", cheader_filename = "webkit/webkit.h")]
    private static extern void* all_webkit_features ();
    [CCode (cname = "webkit_feature_list_unref", cheader_filename = "webkit/webkit.h")]
    private static extern void unref_webkit_features (void* list);
    [CCode (cname = "webkit_feature_list_get_length", cheader_filename = "webkit/webkit.h")]
    private static extern size_t webkit_feature_count (void* list);
    [CCode (cname = "webkit_feature_list_get", cheader_filename = "webkit/webkit.h")]
    private static extern void* webkit_feature_at (void* list, size_t index);
    [CCode (cname = "webkit_feature_get_identifier", cheader_filename = "webkit/webkit.h")]
    private static extern unowned string webkit_feature_id (void* feature);
    [CCode (cname = "webkit_settings_set_feature_enabled", cheader_filename = "webkit/webkit.h")]
    private static extern void set_webkit_feature (WebKit.Settings settings, void* feature, bool enabled);

    public static void prefer_one_web_process (WebKit.Settings settings) {
        var list = all_webkit_features ();
        var found = false;
        var n = webkit_feature_count (list);
        for (size_t i = 0; i < n; i++) {
            var feature = webkit_feature_at (list, i);
            if (webkit_feature_id (feature) != "SiteIsolationEnabled")
                continue;
            set_webkit_feature (settings, feature, false);
            found = true;
            break;
        }
        unref_webkit_features (list);
        if (web_process_limited)
            return;
        web_process_limited = true;
        Utils.sync_log (found
            ? "web process: one process per view"
            : "web process: site isolation feature missing");
    }

    /* Before any reader WebView exists. The handler has to be on the context
     * before the web process starts, or letterimg: never resolves. */
    public static void ensure_inline_image_scheme () {
        if (inline_scheme_ready)
            return;
        inline_scheme_ready = true;
        var context = WebKit.WebContext.get_default ();
        context.register_uri_scheme ("letterimg", on_inline_image_request);
        var security = context.get_security_manager ();
        security.register_uri_scheme_as_cors_enabled ("letterimg");
        Utils.sync_log ("reader serves inline images after the text");
    }

    private static bool inline_request_logged;

    private static void on_inline_image_request (WebKit.URISchemeRequest request) {
        var uri = request.get_uri ();
        var image = InlineImagePages.lookup (uri);
        if (!inline_request_logged) {
            inline_request_logged = true;
            Utils.sync_log ("inline image %s %s".printf (
                image != null && image.data != null ? "ok" : "miss",
                uri ?? ""
            ));
        }
        if (image == null || image.data == null) {
            request.finish_error (new IOError.NOT_FOUND ("missing inline image"));
            return;
        }
        var stream = new MemoryInputStream.from_bytes (image.data);
        request.finish (stream, (int64) image.data.get_size (), image.mime_type);
    }

    /* Only when the reader itself goes away. Between messages the same
     * view stays mapped and load_html() replaces the document. */
    private void retire_webview () {
        var old = this.webview;
        if (old == null)
            return;
        disconnect_body_handlers (old);
        this.webview = null;
        this.document_ready = false;
        if (old.parent != null)
            old.unparent ();
        old.terminate_web_process ();
    }

    private void disconnect_body_handlers (WebKit.WebView view) {
        if (this.body_loaded_id != 0) {
            view.disconnect (this.body_loaded_id);
            this.body_loaded_id = 0;
        }
        if (this.body_failed_id != 0) {
            view.disconnect (this.body_failed_id);
            this.body_failed_id = 0;
        }
    }

    private void load_body_html (string html) {
        var body = html;
        if (body_follow_dark ())
            body = adapt_html_for_dark_canvas (body);
        load_reader_html (html_with_print_chrome (this.current, body), true);
    }

    /* Dark-follow reading: near-white newsletter canvases → dark, near-black
     * text → light. Coloured bands (brand blues/oranges) stay as authored. */
    private static string adapt_html_for_dark_canvas (string html) {
        var result = rewrite_light_backgrounds (html);
        return lift_dark_text_colors (result);
    }

    private static string rewrite_light_backgrounds (string html) {
        var result = html;
        try {
            var bg_re = new Regex (
                "background-color\\s*:\\s*([^;\"'\\}]+)",
                RegexCompileFlags.CASELESS
            );
            result = bg_re.replace_eval (result, -1, 0, 0, (match, builder) => {
                var raw = match.fetch (1) ?? "";
                var important = Regex.match_simple ("!important", raw, RegexCompileFlags.CASELESS);
                var value = raw.replace ("!important", "").strip ();
                if (!css_background_is_light (value)) {
                    builder.append (match.fetch (0) ?? "");
                    return false;
                }
                builder.append ("background-color:");
                builder.append (important ? "#1e1e1e !important" : "#1e1e1e");
                return false;
            });
        } catch (RegexError e) {
            warning ("Could not adapt light CSS backgrounds: %s", e.message);
        }
        try {
            /* Solid-colour shorthand only — leave background:url(...) alone. */
            var shorthand = new Regex (
                "background\\s*:\\s*([^;\"'\\}]+)",
                RegexCompileFlags.CASELESS
            );
            result = shorthand.replace_eval (result, -1, 0, 0, (match, builder) => {
                var raw = match.fetch (1) ?? "";
                var value = raw.replace ("!important", "").strip ();
                if (Regex.match_simple ("url\\s*\\(", value, RegexCompileFlags.CASELESS)
                    || !css_background_is_light (first_css_color_token (value))) {
                    builder.append (match.fetch (0) ?? "");
                    return false;
                }
                var important = Regex.match_simple ("!important", raw, RegexCompileFlags.CASELESS);
                builder.append ("background:");
                builder.append (important ? "#1e1e1e !important" : "#1e1e1e");
                return false;
            });
        } catch (RegexError e) {
            warning ("Could not adapt light background shorthand: %s", e.message);
        }
        try {
            var attr_re = new Regex (
                "\\bbgcolor\\s*=\\s*(\"?)([^\"'\\s>]+)\\1",
                RegexCompileFlags.CASELESS
            );
            result = attr_re.replace_eval (result, -1, 0, 0, (match, builder) => {
                var quote = match.fetch (1) ?? "";
                var value = match.fetch (2) ?? "";
                if (!css_background_is_light (value)) {
                    builder.append (match.fetch (0) ?? "");
                    return false;
                }
                builder.append ("bgcolor=");
                builder.append (quote);
                builder.append ("#1e1e1e");
                builder.append (quote);
                return false;
            });
        } catch (RegexError e) {
            warning ("Could not adapt bgcolor attributes: %s", e.message);
        }
        return result;
    }

    /* Outlook / Word HTML often sets style="color:black" (named), which stays
     * black on our dark canvas. Rewrite dark foreground colours in the markup
     * before WebKit paints — does not need JavaScript. */
    private static string lift_dark_text_colors (string html) {
        var result = html;
        try {
            var style_re = new Regex (
                "(?<!background-)(?<!border-)(?<!outline-)color\\s*:\\s*([^;\"'\\}]+)",
                RegexCompileFlags.CASELESS
            );
            result = style_re.replace_eval (result, -1, 0, 0, (match, builder) => {
                var raw = match.fetch (1) ?? "";
                var important = Regex.match_simple ("!important", raw, RegexCompileFlags.CASELESS);
                var value = raw.replace ("!important", "").strip ();
                if (!css_foreground_is_dark (value)) {
                    builder.append (match.fetch (0) ?? "");
                    return false;
                }
                builder.append ("color:");
                builder.append (important ? "#eeeeee !important" : "#eeeeee");
                return false;
            });
        } catch (RegexError e) {
            warning ("Could not lift dark CSS colours: %s", e.message);
        }
        try {
            var attr_re = new Regex (
                "\\bcolor\\s*=\\s*(\"?)([^\"'\\s>]+)\\1",
                RegexCompileFlags.CASELESS
            );
            result = attr_re.replace_eval (result, -1, 0, 0, (match, builder) => {
                var quote = match.fetch (1) ?? "";
                var value = match.fetch (2) ?? "";
                if (!css_foreground_is_dark (value)) {
                    builder.append (match.fetch (0) ?? "");
                    return false;
                }
                builder.append ("color=");
                builder.append (quote);
                builder.append ("#eeeeee");
                builder.append (quote);
                return false;
            });
        } catch (RegexError e) {
            warning ("Could not lift dark colour attributes: %s", e.message);
        }
        return result;
    }

    private static string first_css_color_token (string raw) {
        var value = raw.strip ();
        var space = value.index_of_char (' ');
        if (space > 0)
            value = value.substring (0, space);
        return value;
    }

    private static bool css_background_is_light (string raw) {
        var value = raw.strip ().down ();
        if (value.length == 0)
            return false;
        if (value.has_prefix ("#") == false && !value.has_prefix ("rgb")
            && value[0] != '#' && value.get_char (0).isalnum ()) {
            /* bgcolor="ffffff" without hash */
            if (value.length == 3 || value.length == 6) {
                bool hexish = true;
                for (int i = 0; i < value.length; i++) {
                    var c = value[i];
                    if (!c.isxdigit ()) {
                        hexish = false;
                        break;
                    }
                }
                if (hexish)
                    value = "#" + value;
            }
        }
        if (value == "white" || value == "canvas")
            return true;
        if (value.has_prefix ("#")) {
            int r, g, b;
            if (!parse_html_hex_color (value, out r, out g, out b))
                return false;
            return relative_luminance (r, g, b) >= 230.0 && near_gray (r, g, b);
        }
        if (value.has_prefix ("rgb")) {
            int r, g, b;
            if (!parse_css_rgb_color (value, out r, out g, out b))
                return false;
            return relative_luminance (r, g, b) >= 230.0 && near_gray (r, g, b);
        }
        return false;
    }

    private static bool near_gray (int r, int g, int b) {
        return int.max (r, int.max (g, b)) - int.min (r, int.min (g, b)) < 40;
    }

    private static bool css_foreground_is_dark (string raw) {
        var value = raw.strip ().down ();
        if (value.length == 0)
            return false;
        if (value == "black" || value == "windowtext" || value == "currentcolor"
            || value == "text" || value == "canvastext")
            return true;
        if (value.has_prefix ("#")) {
            int r, g, b;
            if (!parse_html_hex_color (value, out r, out g, out b))
                return false;
            return relative_luminance (r, g, b) < 160.0;
        }
        if (value.has_prefix ("rgb")) {
            int r, g, b;
            if (!parse_css_rgb_color (value, out r, out g, out b))
                return false;
            return relative_luminance (r, g, b) < 160.0;
        }
        return false;
    }

    private static double relative_luminance (int r, int g, int b) {
        return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    }

    private static bool parse_html_hex_color (string value, out int r, out int g, out int b) {
        r = g = b = 0;
        var hex = value.substring (1).strip ();
        if (hex.length == 3) {
            hex = "%c%c%c%c%c%c".printf (
                hex[0], hex[0], hex[1], hex[1], hex[2], hex[2]
            );
        }
        if (hex.length != 6)
            return false;
        uint64 n = 0;
        if (!uint64.try_parse (hex, out n, null, 16))
            return false;
        r = (int) ((n >> 16) & 0xff);
        g = (int) ((n >> 8) & 0xff);
        b = (int) (n & 0xff);
        return true;
    }

    private static bool parse_css_rgb_color (string value, out int r, out int g, out int b) {
        r = g = b = 0;
        try {
            var re = new Regex ("rgba?\\(\\s*(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)");
            MatchInfo info;
            if (!re.match (value, 0, out info))
                return false;
            r = int.parse (info.fetch (1));
            g = int.parse (info.fetch (2));
            b = int.parse (info.fetch (3));
            return true;
        } catch (RegexError e) {
            return false;
        }
    }

    /* becomes_ready: a real message (or its error page). The waiting page
     * stays unreadable so Print does not catch the spinner. */
    private void load_reader_html (string html, bool becomes_ready) {
        var view = this.webview;
        if (view == null)
            return;

        if (becomes_ready && this.document_ready)
            hold_white ();

        disconnect_body_handlers (view);
        this.html_epoch++;
        var epoch = this.html_epoch;
        var cover = this.cover_epoch;
        this.expect_document = becomes_ready;
        this.document_ready = false;
        this.body_loaded_id = view.load_changed.connect ((event) => {
            if (epoch != this.html_epoch || event != WebKit.LoadEvent.FINISHED)
                return;
            if (this.body_loaded_id != 0) {
                view.disconnect (this.body_loaded_id);
                this.body_loaded_id = 0;
            }
            if (this.expect_document)
                this.document_ready = true;
            if (this.expect_document && body_follow_dark ())
                fix_dark_on_dark_text.begin (view, epoch);
            release_white_after_paint (cover, epoch);
        });
        this.body_failed_id = view.load_failed.connect ((event, uri, error) => {
            if (epoch != this.html_epoch)
                return false;
            if (error.matches (WebKit.NetworkError.quark (), WebKit.NetworkError.CANCELLED))
                return false;
            if (this.expect_document)
                this.document_ready = true;
            release_white_after_paint (cover, epoch);
            return false;
        });
        view.load_html (
            "%s\n<!-- mail-reload %u -->".printf (html, epoch),
            InlineImagePages.DOCUMENT
        );
    }

    /* Drop the cover on the frame after the new document has loaded, so
     * the paint that reveals the view is already the new mail. */
    private void release_white_after_paint (uint cover, uint epoch) {
        if (!READER_WHITE_VEIL)
            return;
        add_tick_callback (() => {
            if (this.reader_gone || cover != this.cover_epoch || epoch != this.html_epoch)
                return false;
            this.white_cover.visible = false;
            return false;
        });
    }

    /* Dark text (incl. Outlook navy) on our dark canvas is unreadable.
     * Bright brand colours and light-on-dark text are left alone. */
    private async void fix_dark_on_dark_text (WebKit.WebView view, uint epoch) {
        const string js = """
(() => {
  const PAGE = [0x1e, 0x1e, 0x1e];
  const LIGHT = '#eeeeee';
  const LINK = '#8cb4ff';
  const parse = (c) => {
    if (!c || c === 'transparent')
      return null;
    const m = c.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([0-9.]+))?/);
    if (!m)
      return null;
    if (m[4] !== undefined && Number(m[4]) <= 0.01)
      return null;
    return [Number(m[1]), Number(m[2]), Number(m[3])];
  };
  const lum = (r, g, b) => 0.2126 * r + 0.7152 * g + 0.0722 * b;
  const contrast = (a, b) => {
    const L1 = lum(a[0], a[1], a[2]) / 255;
    const L2 = lum(b[0], b[1], b[2]) / 255;
    const hi = Math.max(L1, L2);
    const lo = Math.min(L1, L2);
    return (hi + 0.05) / (lo + 0.05);
  };
  const bgOf = (el) => {
    let n = el;
    while (n && n !== document.documentElement) {
      const bg = parse(getComputedStyle(n).backgroundColor);
      if (bg)
        return bg;
      n = n.parentElement;
    }
    return PAGE;
  };
  if (!document.body)
    return;
  document.body.querySelectorAll('*').forEach((el) => {
    if (el.closest && el.closest('.mail-print-header'))
      return;
    const cs = getComputedStyle(el);
    const fg = parse(cs.color);
    const bg = bgOf(el);
    if (!fg)
      return;
    const fgL = lum(fg[0], fg[1], fg[2]);
    const bgL = lum(bg[0], bg[1], bg[2]);
    /* Light text on a light newsletter canvas → darken the canvas. */
    if (fgL >= 200 && bgL >= 230) {
      el.style.setProperty('background-color', '#1e1e1e', 'important');
      return;
    }
    if (fgL >= 165)
      return;
    if (bgL >= 170)
      return;
    if (contrast(fg, bg) >= 3.2)
      return;
    const link = el.tagName === 'A' || (el.closest && el.closest('a'));
    el.style.setProperty('color', link ? LINK : LIGHT, 'important');
  });
})();
""";
        try {
            yield view.evaluate_javascript (js, -1, null, null, null);
        } catch (Error e) {
            if (epoch != this.html_epoch)
                return;
            warning ("Could not adapt message colours for dark reading: %s", e.message);
        }
    }

    private string reader_screen_style (bool rich_html) {
        if (!body_follow_dark ()) {
            return """
html { color-scheme: only light; }
@media screen {
  .mail-print-header { display: none !important; }
  .mail-compose { padding: 0 !important; }
  html, body { background: #ffffff; color: #222222; }
}
""";
        }
        if (rich_html) {
            /* Dark canvas defaults. Near-black inline greys are lifted after
             * load (fix_dark_on_dark_text); intentional hues stay. */
            return """
html { color-scheme: dark light; }
@media screen {
  .mail-print-header { display: none !important; }
  .mail-compose { padding: 0 !important; }
  html, body { background: #1e1e1e !important; color: #eeeeee !important; }
}
""";
        }
        return """
html { color-scheme: dark; }
@media screen {
  .mail-print-header { display: none !important; }
  .mail-compose { padding: 0 !important; }
  html, body { background: #1e1e1e !important; color: #eeeeee !important; }
}
""";
    }

    private string html_with_print_chrome (MessageContent? content, string html) {
        if (content == null)
            return html;

        var style = "<style>\n%s".printf (reader_screen_style (content.rich_html));
        style += """
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
        /* auto-load stays on so letterimg: inline images still arrive.
         * This policy is what keeps http images out until the sender is trusted. */
        var head = style;
        if (!this.load_remote_images)
            head = "<meta http-equiv=\"Content-Security-Policy\" content=\"img-src letterimg: data: blob:;\">" + style;
        var chrome = print_header_markup (content);
        var body = html;
        var lower = body.down ();
        if (!lower.contains ("<html")) {
            return "<!DOCTYPE html><html><head><meta charset=\"utf-8\">%s</head><body>%s%s</body></html>".printf (
                head,
                chrome,
                body
            );
        }

        body = insert_after_open_tag (body, "head", head);
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
        /* Reload would fetch the reader base URL and wipe the mail. Back,
         * forward and stop are the same browser chrome. letterimg: is not a
         * real URL, so WebKit’s save/copy-address entries do nothing useful.
         * “Copy Link with Highlight” needs a shareable page URL — drop it. */
        var insert_at = 0;
        for (int i = (int) menu.get_n_items () - 1; i >= 0; i--) {
            var item = menu.get_item_at_position (i);
            if (is_copy_link_with_highlight (item)) {
                menu.remove (item);
                continue;
            }
            var action = item.get_stock_action ();
            if (action == WebKit.ContextMenuAction.RELOAD
                || action == WebKit.ContextMenuAction.GO_BACK
                || action == WebKit.ContextMenuAction.GO_FORWARD
                || action == WebKit.ContextMenuAction.STOP
                || action == WebKit.ContextMenuAction.OPEN_IMAGE_IN_NEW_WINDOW
                || action == WebKit.ContextMenuAction.OPEN_FRAME_IN_NEW_WINDOW
                || action == WebKit.ContextMenuAction.OPEN_LINK_IN_NEW_WINDOW
                || action == WebKit.ContextMenuAction.DOWNLOAD_IMAGE_TO_DISK
                || action == WebKit.ContextMenuAction.COPY_IMAGE_URL_TO_CLIPBOARD) {
                if (action == WebKit.ContextMenuAction.OPEN_IMAGE_IN_NEW_WINDOW
                    || action == WebKit.ContextMenuAction.OPEN_FRAME_IN_NEW_WINDOW
                    || action == WebKit.ContextMenuAction.DOWNLOAD_IMAGE_TO_DISK)
                    insert_at = i;
                menu.remove (item);
            }
        }
        trim_context_separators (menu);

        if (hit.context_is_image ()) {
            var uri = hit.get_image_uri ();
            if (uri != null && uri.length > 0)
                this.context_image_uri = uri;
        }
        if (this.context_image_uri != null) {
            var at = insert_at.clamp (0, (int) menu.get_n_items ());
            menu.insert (
                new WebKit.ContextMenuItem.from_gaction (this.view_image_action, _("View Image"), null),
                at
            );
            menu.insert (
                new WebKit.ContextMenuItem.from_gaction (this.save_image_action, _("Save Image As…"), null),
                at + 1
            );
            menu.insert (
                new WebKit.ContextMenuItem.from_gaction (this.forward_image_action, _("Forward Image"), null),
                at + 2
            );
        }
        return menu.get_n_items () == 0;
    }

    /* Present in WebKitGTK C API; missing from the Vala bindings. */
    [CCode (cname = "webkit_context_menu_item_get_title")]
    private static extern unowned string? context_menu_item_title (WebKit.ContextMenuItem item);

    private static bool is_copy_link_with_highlight (WebKit.ContextMenuItem item) {
        var title = context_menu_item_title (item);
        if (title == null || title.length == 0)
            return false;
        var down = title.down ();
        return down.contains ("link with highlight")
            || down.contains ("testo evidenziato")
            || down.contains ("link zum markierten")
            || down.contains ("link do texto destacado");
    }

    private static void trim_context_separators (WebKit.ContextMenu menu) {
        var previous_separator = true;
        for (int i = 0; i < (int) menu.get_n_items ();) {
            var item = menu.get_item_at_position (i);
            var separator = item.is_separator ();
            if (separator && (previous_separator || i == (int) menu.get_n_items () - 1)) {
                menu.remove (item);
                continue;
            }
            previous_separator = separator;
            i++;
        }
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

    private async void save_context_image () {
        var uri = this.context_image_uri;
        if (uri == null || uri.length == 0)
            return;
        try {
            yield Utils.save_image_uri (uri, get_root () as Gtk.Window);
        } catch (Error e) {
            if (e is IOError.CANCELLED || e is Gtk.DialogError.DISMISSED)
                return;
            warning ("Could not save image: %s", e.message);
            show_reader_toast (e.message);
        }
    }

    private async void forward_context_image () {
        var uri = this.context_image_uri;
        if (uri == null || uri.length == 0)
            return;
        try {
            var attachment = yield Utils.attachment_from_image_uri (uri);
            forward_image (attachment);
        } catch (Error e) {
            warning ("Could not forward image: %s", e.message);
            show_reader_toast (e.message);
        }
    }

    private void show_reader_toast (string message) {
        Gtk.Widget? widget = this;
        while (widget != null) {
            var overlay = widget as Adw.ToastOverlay;
            if (overlay != null) {
                overlay.add_toast (new Adw.Toast (message) {
                    timeout = 4,
                });
                return;
            }
            widget = widget.get_parent ();
        }
    }
}

private class Mail.RecipientRow : Gtk.Box {
    public signal void write_to (Recipient recipient);

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
        this.chips.write_to.connect ((recipient) => write_to (recipient));
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
    public signal void write_to (Recipient recipient);

    private const int MAX_LINES = 2;
    private const int SPACING = 6;

    private GenericArray<Gtk.Widget> chips = new GenericArray<Gtk.Widget> ();
    private Gtk.Button more_button;
    private Gtk.Label more_label;
    private bool expanded;
    private Gtk.PopoverMenu? chip_menu;
    private Gtk.Widget? menu_chip;
    private string? menu_chip_tooltip;

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
        dismiss_chip_menu ();
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
        dismiss_chip_menu ();
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

    private Gtk.Widget make_chip (Recipient recipient) {
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

        var click = new Gtk.GestureClick () {
            button = Gdk.BUTTON_SECONDARY,
        };
        click.pressed.connect ((n_press, x, y) => {
            popup_chip_menu (box, recipient, x, y);
            click.set_state (Gtk.EventSequenceState.CLAIMED);
        });
        box.add_controller (click);
        return box;
    }

    private void popup_chip_menu (Gtk.Widget chip, Recipient recipient, double x, double y) {
        dismiss_chip_menu ();

        /* Hide the hover tooltip so it does not sit on top of the menu. */
        this.menu_chip = chip;
        this.menu_chip_tooltip = chip.tooltip_text;
        chip.set_has_tooltip (false);

        var email = Utils.sanitize_recipient_text (recipient.email);
        var group = new SimpleActionGroup ();

        var write = new SimpleAction ("write-to", null);
        write.set_enabled (email.length > 0 && email.contains ("@"));
        write.activate.connect (() => write_to (recipient));
        group.add_action (write);

        var copy = new SimpleAction ("copy-email", null);
        copy.set_enabled (email.length > 0);
        copy.activate.connect (() => copy_chip_email (chip, email));
        group.add_action (copy);

        var menu = new Menu ();
        menu.append (_("Write to"), "chip.write-to");
        menu.append (_("Copy Email"), "chip.copy-email");

        chip.insert_action_group ("chip", group);
        var popover = new Gtk.PopoverMenu.from_model (menu) {
            has_arrow = false,
            halign = Gtk.Align.START,
        };
        popover.set_parent (chip);
        popover.set_pointing_to (Gdk.Rectangle () {
            x = (int) x,
            y = (int) y,
            width = 1,
            height = 1,
        });
        popover.closed.connect (() => {
            Idle.add (() => {
                if (this.chip_menu == popover) {
                    this.chip_menu = null;
                    if (popover.parent != null)
                        popover.unparent ();
                    chip.insert_action_group ("chip", null);
                    restore_chip_tooltip ();
                }
                return Source.REMOVE;
            });
        });
        this.chip_menu = popover;
        popover.popup ();
    }

    private void dismiss_chip_menu () {
        var popover = this.chip_menu;
        this.chip_menu = null;
        restore_chip_tooltip ();
        if (popover == null)
            return;
        popover.popdown ();
        if (popover.parent != null)
            popover.unparent ();
    }

    private void restore_chip_tooltip () {
        var chip = this.menu_chip;
        var tip = this.menu_chip_tooltip;
        this.menu_chip = null;
        this.menu_chip_tooltip = null;
        if (chip == null)
            return;
        if (tip != null && tip.length > 0)
            chip.tooltip_text = tip;
        else
            chip.set_has_tooltip (false);
    }

    private void copy_chip_email (Gtk.Widget chip, string email) {
        chip.get_clipboard ().set_text (email);
        Gtk.Widget? widget = chip;
        while (widget != null) {
            var overlay = widget as Adw.ToastOverlay;
            if (overlay != null) {
                overlay.add_toast (new Adw.Toast (_("Address copied")) {
                    timeout = 2,
                });
                return;
            }
            widget = widget.parent;
        }
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
        var action = seen ? "win.mark-unread" : "win.mark-read";
        if (this.seen_button.action_name != action)
            this.seen_button.action_name = action;
        if (seen) {
            this.seen_button.icon_name = "mail-unread-symbolic";
            this.seen_button.tooltip_text = _("Mark as Unread");
        } else {
            this.seen_button.icon_name = "mail-read-symbolic";
            this.seen_button.tooltip_text = _("Mark as Read");
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
        sep.margin_top = 4;
        sep.margin_bottom = 4;
        sep.margin_start = 6;
        sep.margin_end = 6;
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
