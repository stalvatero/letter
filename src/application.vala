public class Mail.Application : Adw.Application {
    public AccountStore accounts { get; private set; }
    public ContactStore contacts { get; private set; }
    public CalendarStore calendars { get; private set; }
    public Notifier notifier { get; private set; }
    public bool shutting_down { get; private set; }

    private Settings settings;
    private bool quit_in_progress;
    private WelcomeDialog? welcome;
    private SetupWindow? setup_window;
    private uint welcome_idle;
    private bool activate_pending;

    private const ActionEntry[] ACTION_ENTRIES = {
        { "quit", on_quit },
        { "about", on_about },
        { "welcome", on_welcome },
        { "preferences", on_preferences },
        { "shortcuts", on_shortcuts },
        { "refresh", on_refresh },
        { "new-message", on_new_message },
        { "online-accounts", on_online_accounts },
        { "open-calendar", on_open_calendar },
        { "open-contacts", on_open_contacts },
        { "notification-open", on_notification_open, "s" },
        { "notification-archive", on_notification_archive, "s" },
        { "notification-delete", on_notification_delete, "s" },
    };

    public Application () {
        Object (
            application_id: Config.APP_ID,
            resource_base_path: Config.RESOURCE_PATH,
            flags: ApplicationFlags.HANDLES_COMMAND_LINE
        );
    }

    construct {
        this.accounts = new AccountStore ();
        this.contacts = new ContactStore ();
        this.calendars = new CalendarStore ();
        this.notifier = new Notifier ();
        this.notifier.activated.connect ((kind, token) => {
            handle_notification (kind, new Variant.string (token));
        });
        this.notifier.fallback.connect (on_notification_fallback);
        this.settings = new Settings (Config.APP_ID);

        OptionEntry[] options = {
            { "new-message", '\0', OptionFlags.NONE, OptionArg.NONE, null, _("Compose a new message"), null },
            { null }
        };
        add_main_option_entries (options);
    }

    public override void startup () {
        Camel.init ("", true);
        Camel.Provider.init ();
        E.SourceCamel.register_types ();

        base.startup ();

        Utils.migrate_legacy_app_dirs ();
        migrate_settings_from_mail ();
        normalize_body_cache_days ();
        this.accounts.load.begin ();
        this.accounts.changed.connect (on_accounts_changed);
        this.accounts.changed.connect (on_accounts_changed_ui);
        Environment.set_application_name (Utils.app_display_name ());
        Gtk.Window.set_default_icon_name (Config.APP_ID);

        add_action_entries (ACTION_ENTRIES, this);
        this.notifier.start.begin ();
        set_accels_for_action ("app.quit", { "<Ctrl>q" });
        set_accels_for_action ("app.preferences", { "<Ctrl>comma" });
        set_accels_for_action ("win.refresh", { "F5" });
        set_accels_for_action ("win.search", { "<Ctrl>f" });
        set_accels_for_action ("win.compose", { "<Ctrl>n" });
        set_accels_for_action ("win.reply", { "<Ctrl>r" });
        set_accels_for_action ("win.reply-all", { "<Ctrl><Shift>r" });
        set_accels_for_action ("win.mark-unread", { "<Ctrl>u" });
        set_accels_for_action ("win.bookmark", { "<Ctrl><Shift>b" });
        set_accels_for_action ("win.delete", { "Delete", "<Ctrl>d" });
        set_accels_for_action ("win.print", { "<Ctrl>p" });
        set_accels_for_action ("win.fullscreen", { "F11" });
        set_accels_for_action ("app.shortcuts", { "<Ctrl>question", "F1" });
        bind_color_scheme ();
    }

    private void migrate_settings_from_mail () {
        if (this.settings.get_boolean ("settings-migrated"))
            return;

        string[] keys = {
            "window-width",
            "window-height",
            "window-maximized",
            "show-folder-sidebar",
            "folder-pane-width",
            "last-account-uid",
            "last-folder",
            "collapsed-folders",
            "color-scheme",
            "reader-zoom",
            "reading-pane",
            "message-pane-width",
            "compose-width",
            "compose-height",
            "trusted-senders",
            "sync-interval",
            "body-cache-days",
            "mark-as-read",
            "conversation-view",
            "notifications",
            "notification-sound",
            "last-download-folder",
            "compose-signatures",
            "compose-signature-name",
            "account-signatures",
            "account-signature-choice",
            "signatures-migrated",
            "welcome-shown",
        };

        string old_app_id = Config.PROFILE == "development"
            ? "io.github.stalvatero.Mail.Devel"
            : "io.github.stalvatero.Mail";

        try {
            var old = new Settings (old_app_id);
            for (uint i = 0; i < keys.length; i++) {
                var key = keys[i];
                try {
                    this.settings.set_value (key, old.get_value (key));
                } catch (Error e) {
                    // Best-effort migration: skip keys/types that don't match.
                }
            }
        } catch (Error e) {
            // Previous schema might not exist (fresh install, no old version, etc.)
        }

        this.settings.set_boolean ("settings-migrated", true);
        this.settings.apply ();
    }

    private void normalize_body_cache_days () {
        var days = this.settings.get_int ("body-cache-days");
        if (days == 0 || days == 60 || days == 180 || days == 365)
            return;

        int next;
        if (days < 90)
            next = 60;
        else if (days < 270)
            next = 180;
        else
            next = 365;

        this.settings.set_int ("body-cache-days", next);
        this.settings.apply ();
    }

    public override void activate () {
        present_for_accounts.begin ();
    }

    public bool has_mail_accounts () {
        return this.accounts.has_mail_accounts ();
    }

    private async void present_for_accounts () {
        if (this.activate_pending)
            return;
        this.activate_pending = true;
        try {
            if (!this.accounts.loaded)
                yield this.accounts.load ();
            show_window_for_accounts ();
        } finally {
            this.activate_pending = false;
        }
    }

    private void show_window_for_accounts () {
        if (this.accounts.has_mail_accounts ()) {
            dismiss_setup_window ();
            var window = main_window ();
            if (window == null)
                window = new Window (this);
            window.present ();
            queue_welcome (window);
            return;
        }

        /* No mail yet: keep the empty three-pane shell closed. */
        var main = main_window ();
        if (main != null)
            main.visible = false;

        if (this.setup_window == null) {
            this.setup_window = new SetupWindow (this);
            this.setup_window.close_request.connect (() => {
                this.setup_window = null;
                return false;
            });
        }
        this.setup_window.present ();
    }

    private void dismiss_setup_window () {
        if (this.setup_window == null)
            return;
        var win = this.setup_window;
        this.setup_window = null;
        win.destroy ();
    }

    public override int command_line (ApplicationCommandLine command_line) {
        var options = command_line.get_options_dict ();
        var new_message = false;
        if (options.contains ("new-message")) {
            var value = options.lookup_value ("new-message", VariantType.BOOLEAN);
            new_message = value != null && value.get_boolean ();
        }

        activate ();
        if (new_message)
            on_new_message ();
        return 0;
    }

    private void on_new_message () {
        activate ();
        var window = main_window ();
        if (window == null)
            return;
        window.activate_action ("compose", null);
    }

    private Window? main_window () {
        var active = get_active_window () as Window;
        if (active != null)
            return active;
        foreach (var window in get_windows ()) {
            var mail = window as Window;
            if (mail != null)
                return mail;
        }
        return null;
    }

    private void on_accounts_changed () {
        this.contacts.bind_registry (this.accounts.registry);
        this.calendars.bind_registry (this.accounts.registry);
    }

    private void on_accounts_changed_ui () {
        if (!this.accounts.loaded)
            return;
        /* User may add mail in Online Accounts while SetupWindow is open. */
        if (this.setup_window != null || !this.accounts.has_mail_accounts ())
            show_window_for_accounts ();
    }

    public void show_mail_toast (string message) {
        foreach (var window in get_windows ()) {
            var mail = window as Window;
            if (mail == null)
                continue;
            mail.show_toast (message);
            return;
        }
    }

    private void on_quit () {
        request_quit.begin ();
    }

    public async void request_quit () {
        if (this.quit_in_progress)
            return;

        this.quit_in_progress = true;
        var composes = new GenericArray<ComposeWindow> ();
        foreach (var window in get_windows ()) {
            var compose = window as ComposeWindow;
            if (compose != null)
                composes.add (compose);
        }
        for (uint i = 0; i < composes.length; i++) {
            composes[i].present_for_attention ();
            if (yield composes[i].offer_close ())
                continue;
            this.quit_in_progress = false;
            return;
        }

        this.shutting_down = true;
        var windows = new GenericArray<Gtk.Window> ();
        foreach (var window in get_windows ())
            windows.add (window);
        for (uint i = 0; i < windows.length; i++)
            windows[i].close ();
        quit ();
    }

    private void on_welcome () {
        var parent = get_active_window ();
        if (parent == null)
            return;
        present_welcome (parent);
    }

    private void queue_welcome (Gtk.Window parent) {
        if (this.settings.get_boolean ("welcome-shown") || this.welcome != null)
            return;
        if (this.welcome_idle != 0)
            return;
        this.welcome_idle = Idle.add (() => {
            this.welcome_idle = 0;
            present_welcome (parent);
            return Source.REMOVE;
        });
    }

    private void present_welcome (Gtk.Window parent) {
        if (this.welcome != null) {
            this.welcome.present (parent);
            return;
        }

        var dialog = new WelcomeDialog ();
        this.welcome = dialog;
        dialog.closed.connect (() => {
            this.welcome = null;
            this.settings.set_boolean ("welcome-shown", true);
        });
        dialog.present (parent);
    }

    private void on_about () {
        var about = new Adw.AboutDialog () {
            application_name = Utils.app_display_name (),
            application_icon = Config.APP_ID,
            developer_name = "Salvatore Oscurato",
            version = Config.VERSION,
            comments = _("A GNOME mail client that shares accounts with Calendar and Contacts."),
            website = "https://github.com/stalvatero/letter",
            issue_url = "https://github.com/stalvatero/letter/issues",
            copyright = "© 2026 Salvatore Oscurato",
            license_type = Gtk.License.GPL_3_0,
            developers = { "Salvatore Oscurato" },
            translator_credits = _("translator-credits"),
        };
        about.present (get_active_window ());
    }

    private void on_preferences () {
        var dialog = new PreferencesDialog (this.accounts, get_active_window () as Window);
        dialog.present (get_active_window ());
    }

    private void on_shortcuts () {
        var dialog = new Adw.ShortcutsDialog ();

        var general = new Adw.ShortcutsSection (_("General"));
        general.add (new Adw.ShortcutsItem (_("Quit"), "<Ctrl>q"));
        general.add (new Adw.ShortcutsItem (_("Preferences"), "<Ctrl>comma"));
        general.add (new Adw.ShortcutsItem (_("Keyboard shortcuts"), "F1"));
        dialog.add (general);

        var mail = new Adw.ShortcutsSection (_("Letter shortcuts"));
        mail.add (new Adw.ShortcutsItem (_("Search"), "<Ctrl>f"));
        mail.add (new Adw.ShortcutsItem (_("New message"), "<Ctrl>n"));
        mail.add (new Adw.ShortcutsItem (_("Reply"), "R"));
        mail.add (new Adw.ShortcutsItem (_("Reply All"), "<Shift>r"));
        mail.add (new Adw.ShortcutsItem (_("Forward"), "F"));
        mail.add (new Adw.ShortcutsItem (_("Archive"), "A"));
        mail.add (new Adw.ShortcutsItem (_("Mark as unread"), "<Ctrl>u"));
        mail.add (new Adw.ShortcutsItem (_("Bookmark"), "<Ctrl><Shift>b"));
        mail.add (new Adw.ShortcutsItem (_("Delete"), "Delete"));
        mail.add (new Adw.ShortcutsItem (_("Print"), "<Ctrl>p"));
        mail.add (new Adw.ShortcutsItem (_("Zoom In"), "<Ctrl>plus"));
        mail.add (new Adw.ShortcutsItem (_("Zoom Out"), "<Ctrl>minus"));
        mail.add (new Adw.ShortcutsItem (_("Reset Zoom"), "<Ctrl>0"));
        mail.add (new Adw.ShortcutsItem (_("Refresh"), "F5"));
        mail.add (new Adw.ShortcutsItem (_("Fullscreen"), "F11"));
        mail.add (new Adw.ShortcutsItem (_("Toggle sidebar"), "F9"));
        dialog.add (mail);

        dialog.present (get_active_window ());
    }

    private void on_refresh () {
        this.accounts.load.begin ();
        var win = get_active_window () as Window;
        win?.refresh_now ();
    }

    private void on_online_accounts () {
        Utils.open_online_accounts ();
    }

    private void on_open_calendar () {
        Utils.launch_desktop ("org.gnome.Calendar.desktop");
    }

    private void on_open_contacts () {
        Utils.launch_desktop ("org.gnome.Contacts.desktop");
    }

    private void on_notification_open (SimpleAction action, Variant? param) {
        handle_notification ("open", param);
    }

    private void on_notification_archive (SimpleAction action, Variant? param) {
        handle_notification ("archive", param);
    }

    private void on_notification_delete (SimpleAction action, Variant? param) {
        handle_notification ("delete", param);
    }

    private void handle_notification (string kind, Variant? param) {
        activate ();
        var raw = param != null ? param.get_string () : "";
        var token = this.notifier.resolve (raw);
        var win = main_window ();
        if (win == null)
            return;
        win.handle_notification (kind, token);
    }

    private void on_notification_fallback (string title, string body, string token, bool actions, bool sound) {
        var key = this.notifier.remember (token);
        var notification = new Notification (title);
        notification.set_body (body);
        notification.set_category ("email.arrived");
        notification.set_icon (new ThemedIcon (Config.APP_ID));
        if (actions) {
            notification.set_default_action_and_target_value (
                "app.notification-open",
                new Variant.string (key)
            );
            notification.add_button_with_target_value (
                _("Archive"),
                "app.notification-archive",
                new Variant.string (key)
            );
            notification.add_button_with_target_value (
                _("Delete"),
                "app.notification-delete",
                new Variant.string (key)
            );
        }
        send_notification (key, notification);
        if (sound)
            Utils.play_notification_sound (this.settings.get_string ("notification-sound"));
    }

    private void bind_color_scheme () {
        apply_color_scheme ();
        this.settings.changed["color-scheme"].connect (apply_color_scheme);
    }

    private void apply_color_scheme () {
        var manager = Adw.StyleManager.get_default ();
        switch (this.settings.get_string ("color-scheme")) {
            case "light":
                manager.color_scheme = Adw.ColorScheme.FORCE_LIGHT;
                break;
            case "dark":
                manager.color_scheme = Adw.ColorScheme.FORCE_DARK;
                break;
            default:
                manager.color_scheme = Adw.ColorScheme.DEFAULT;
                break;
        }
    }
}
