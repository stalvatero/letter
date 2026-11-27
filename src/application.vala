public class Mail.Application : Adw.Application {
    public AccountStore accounts { get; private set; }
    public ContactStore contacts { get; private set; }
    public CalendarStore calendars { get; private set; }
    public Notifier notifier { get; private set; }
    public OutboxStore? outbox { get; set; }
    public bool shutting_down { get; private set; }

    private Settings settings;
    private bool quit_in_progress;
    private WelcomeDialog? welcome;
    private SetupWindow? setup_window;
    private uint welcome_idle;
    private bool activate_pending;
    private bool checking_updates;
    private bool idle_update_checked;
    private uint idle_update_source;
    private string? update_latest;
    private string? update_url;
    /* Quiet idle check found a newer release — windows show menu badges. */
    public bool update_available { get; private set; }
    /* Microsoft Graph scope upgrade — at most one prompt per account per session. */
    private HashTable<string, bool> graph_reconsent_prompted =
        new HashTable<string, bool> (str_hash, str_equal);
    private bool graph_reconsent_running;

    private const ActionEntry[] ACTION_ENTRIES = {
        { "quit", on_quit },
        { "about", on_about },
        { "welcome", on_welcome },
        { "preferences", on_preferences },
        { "shortcuts", on_shortcuts },
        { "check-updates", on_check_updates },
        { "refresh", on_refresh },
        { "new-message", on_new_message },
        { "online-accounts", on_online_accounts },
        { "add-mail-account", on_add_mail_account },
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
            flags: ApplicationFlags.HANDLES_OPEN | ApplicationFlags.HANDLES_COMMAND_LINE
        );
    }

    construct {
        this.settings = new Settings (Config.APP_ID);
        this.accounts = new AccountStore (this.settings);
        this.contacts = new ContactStore ();
        this.calendars = new CalendarStore ();
        this.notifier = new Notifier ();
        this.notifier.activated.connect ((kind, token) => {
            handle_notification (kind, new Variant.string (token));
        });
        this.notifier.fallback.connect (on_notification_fallback);

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

        /* Letter chrome symbolics (GResource) — reliable on KDE/Cinnamon/Flatpak
         * where hicolor/actions is not indexed like Adwaita. */
        var display = Gdk.Display.get_default ();
        if (display != null) {
            Gtk.IconTheme.get_for_display (display).add_resource_path (
                "/io/github/stalvatero/Letter/icons"
            );
        }

        Utils.bind_app_settings (this.settings);
        Utils.migrate_legacy_app_dirs ();
        migrate_settings_from_mail ();
        migrate_welcome_tour_version ();
        normalize_body_cache_days ();
        this.accounts.load.begin ((obj, res) => {
            this.accounts.load.end (res);
            queue_goa_accounts_prompt ();
            /* Drop Sent-harvested addresses that already live in rubriche. */
            this.contacts.refresh_book_email_index.begin ();
        });
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
        set_accels_for_action ("win.undo", { "<Ctrl>z" });
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
            "notification-sound-aggregate",
            "last-download-folder",
            "compose-signatures",
            "compose-signature-name",
            "account-signatures",
            "account-signature-choice",
            "signatures-migrated",
            "welcome-shown",
            "welcome-tour-version",
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
        hold ();
        try {
            if (!this.accounts.loaded)
                yield this.accounts.load ();
            /* Recover existing GOA mail when preference was left on “Letter only”
             * (common in Flatpak sandbox settings) but Online Accounts has mail. */
            yield maybe_reenable_goa_for_existing_mail ();
            show_window_for_accounts ();
        } finally {
            this.activate_pending = false;
            release ();
        }
    }

    private async void maybe_reenable_goa_for_existing_mail () {
        if (this.accounts.has_mail_accounts ())
            return;
        if (Environment.get_variable ("LETTER_SKIP_GOA") == "1")
            return;
        if (!Utils.has_gnome_online_accounts ())
            return;
        if (this.settings.get_boolean ("use-goa-accounts"))
            return;
        message ("Application: no Letter Identity mail — re-enabling GNOME Online Accounts");
        yield this.accounts.set_use_goa_accounts (true);
    }

    /** After Preferences removes an Identity account (may open SetupWindow). */
    public void on_identity_account_removed () {
        show_window_for_accounts ();
    }

    /** Preferences toggled use-goa-accounts — rebind each window’s mail engine. */
    public void on_goa_preference_changed () {
        foreach (var window in get_windows ()) {
            var mail = window as Window;
            if (mail == null)
                continue;
            mail.release_mail_backend ();
            mail.on_accounts_changed_public ();
        }
        on_accounts_changed ();
        show_mail_toast (
            this.accounts.using_goa
                ? _("GNOME Online Accounts enabled")
                : _("Using Letter Identity accounts only")
        );
    }

    private void queue_goa_accounts_prompt () {
        if (this.settings.get_boolean ("goa-accounts-prompted"))
            return;
        if (Environment.get_variable ("LETTER_SKIP_GOA") == "1") {
            this.settings.set_boolean ("goa-accounts-prompted", true);
            return;
        }
        if (!Utils.has_gnome_online_accounts ()) {
            this.settings.set_boolean ("goa-accounts-prompted", true);
            return;
        }
        Idle.add (() => {
            present_goa_accounts_prompt ();
            return Source.REMOVE;
        });
    }

    /** After main window is up: offer in-place Graph scope re-consent if needed. */
    private void queue_microsoft_graph_reconsent () {
        if (!IdentityOAuth.microsoft_mail_uses_graph ())
            return;
        Idle.add (() => {
            present_microsoft_graph_reconsent.begin ();
            return Source.REMOVE;
        });
    }

    private async void present_microsoft_graph_reconsent () {
        if (this.graph_reconsent_running)
            return;
        if (!IdentityOAuth.microsoft_mail_uses_graph ())
            return;

        IdentityCatalog catalog;
        try {
            catalog = IdentityCatalog.load ();
        } catch (Error e) {
            warning ("Graph re-consent catalog: %s", e.message);
            return;
        }

        Gtk.Window? parent = get_active_window ();
        if (parent == null)
            parent = main_window ();

        this.graph_reconsent_running = true;
        try {
            var needing = new GenericArray<IdentityAccount> ();
            for (uint i = 0; i < catalog.accounts.length; i++) {
                var acc = catalog.accounts[i];
                if (!acc.enabled)
                    continue;
                if (!IdentityOAuth.graph_scopes_need_reconsent (acc))
                    continue;
                if (this.graph_reconsent_prompted.contains (acc.id))
                    continue;
                this.graph_reconsent_prompted.set (acc.id, true);
                needing.add (acc);
            }
            if (needing.length == 0)
                return;

            var updated = yield IdentityMicrosoftReconsent.prompt_and_reconsent_all (
                parent, needing
            );
            if (updated > 0) {
                show_mail_toast (_("Microsoft permissions updated"));
                this.accounts.reload_identity ();
            }
        } finally {
            this.graph_reconsent_running = false;
        }
    }

    private void present_goa_accounts_prompt () {
        if (this.settings.get_boolean ("goa-accounts-prompted"))
            return;
        var parent = get_active_window ();
        if (parent == null)
            parent = main_window ();
        if (parent == null)
            return;

        var dialog = new Adw.AlertDialog (
            _("Use GNOME Online Accounts?"),
            _("This system has GNOME Online Accounts.\n\n• GNOME accounts — one sign-in shared with Calendar and Contacts; mail uses the Evolution stack that GNOME already provides.\n\n• Letter Identity — accounts added in Letter use Letter’s own engine: more flexible sync, smoother local search, and cache-first behaviour tailored to this app.\n\nYou can use either or both. The same address is shown once. Change this anytime in Preferences → Accounts.")
        );
        dialog.add_response ("identity", _("Letter only"));
        dialog.add_response ("goa", _("Include GNOME accounts"));
        dialog.set_response_appearance ("goa", Adw.ResponseAppearance.SUGGESTED);
        dialog.default_response = "goa";
        dialog.close_response = "goa";
        dialog.response.connect ((response) => {
            var enable = response != "identity";
            apply_goa_prompt_choice.begin (enable);
        });
        dialog.present (parent);
    }

    private async void apply_goa_prompt_choice (bool enable) {
        this.settings.set_boolean ("goa-accounts-prompted", true);
        if (enable == this.accounts.goa_preference_enabled ()) {
            this.settings.set_boolean ("use-goa-accounts", enable);
            return;
        }
        foreach (var window in get_windows ()) {
            var mail = window as Window;
            mail?.release_mail_backend ();
        }
        yield this.accounts.set_use_goa_accounts (enable);
        on_goa_preference_changed ();
    }

    private void show_window_for_accounts () {
        if (this.accounts.has_mail_accounts ()) {
            /* Versioned welcome runs as its own window so the mail shell is
             * not visible underneath — chrome icons freeze after the tour. */
            if (needs_welcome_tour ()) {
                cancel_welcome ();
                var main = main_window ();
                if (main != null)
                    main.visible = false;
                present_setup_tour_window ();
                return;
            }

            Utils.freeze_chrome_icons ();
            /* Present main first so destroying SetupWindow is never the last
             * window — otherwise Gtk.Application quits immediately. */
            var window = main_window ();
            if (window == null)
                window = new Window (this);
            window.visible = true;
            window.present ();
            dismiss_setup_window ();
            window.apply_chrome_icons ();
            schedule_idle_update_check ();
            queue_microsoft_graph_reconsent ();
            return;
        }

        cancel_welcome ();

        /* No mail yet: keep the empty three-pane shell closed. */
        var main = main_window ();
        if (main != null)
            main.visible = false;

        present_setup_tour_window ();
    }

    private void present_setup_tour_window () {
        if (this.setup_window == null) {
            this.setup_window = new SetupWindow (this);
            this.setup_window.tour_finished.connect (on_setup_tour_finished);
            this.setup_window.close_request.connect (() => {
                this.setup_window = null;
                return false;
            });
        }
        this.setup_window.present ();
    }

    private void on_setup_tour_finished () {
        mark_welcome_tour_complete ();
        Utils.freeze_chrome_icons ();
        finish_setup_tour.begin ();
    }

    private async void finish_setup_tour () {
        /* Last chance to pick up host GOA mail if preference was left off. */
        yield maybe_reenable_goa_for_existing_mail ();
        show_window_for_accounts ();
        if (this.accounts.has_mail_accounts ())
            return;

        Gtk.Window? parent = this.setup_window;
        if (parent == null)
            parent = get_active_window ();
        var dialog = new Adw.AlertDialog (
            _("No mail accounts found"),
            _("Letter did not detect any mail accounts. Add Google, Microsoft 365, or IMAP in Letter, or on GNOME use Settings → Online Accounts.")
        );
        dialog.add_response ("ok", _("OK"));
        dialog.add_response ("add", _("Add Account"));
        dialog.set_response_appearance ("add", Adw.ResponseAppearance.SUGGESTED);
        dialog.default_response = "add";
        dialog.response.connect ((response) => {
            if (response == "add")
                activate_action ("add-mail-account", null);
        });
        dialog.present (parent);
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

        var files = new GenericArray<File> ();
        var argv = command_line.get_arguments ();
        for (int i = 1; i < argv.length; i++) {
            var arg = argv[i];
            if (arg.has_prefix ("-"))
                continue;
            files.add (command_line.create_file_for_arg (arg));
        }

        if (new_message || files.length == 0)
            activate ();
        if (new_message)
            on_new_message ();

        for (int i = 0; i < files.length; i++)
            open_eml_file.begin (files[i]);
        return 0;
    }

    public override void open (File[] files, string hint) {
        foreach (var file in files)
            open_eml_file.begin (file);
    }

    private async void open_eml_file (File file) {
        hold ();
        try {
            if (!EmlViewerWindow.looks_like_eml (file)) {
                warning ("Ignoring non-message file: %s", file.get_uri ());
                return;
            }
            var mail = yield EmlViewerWindow.load_file (file);
            var viewer = new EmlViewerWindow (this, mail, file.get_basename ());
            viewer.present ();
        } catch (Error e) {
            critical ("Failed to open %s: %s", file.get_uri (), e.message);
            var parent = get_active_window ();
            if (parent != null) {
                var dialog = new Adw.AlertDialog (
                    _("Could not open this message file."),
                    e.message
                );
                dialog.add_response ("ok", _("OK"));
                dialog.present (parent);
            } else {
                show_mail_toast (_("Could not open this message file."));
            }
        } finally {
            release ();
        }
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

    public void show_send_toast (string message) {
        foreach (var window in get_windows ()) {
            var mail = window as Window;
            if (mail == null)
                continue;
            mail.show_send_toast (message);
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
        var mail = main_window ();
        if (mail != null)
            yield mail.prepare_quit ();

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

    private void migrate_welcome_tour_version () {
        /* Legacy welcome-shown → version 1 so WELCOME_TOUR_VERSION 2 forces a re-show. */
        if (!this.settings.get_boolean ("welcome-shown"))
            return;
        if (this.settings.get_int ("welcome-tour-version") != 0)
            return;
        this.settings.set_int ("welcome-tour-version", 1);
    }

    private bool needs_welcome_tour () {
        return this.settings.get_int ("welcome-tour-version")
            < AppearanceChrome.WELCOME_TOUR_VERSION;
    }

    private void mark_welcome_tour_complete () {
        this.settings.set_int (
            "welcome-tour-version",
            AppearanceChrome.WELCOME_TOUR_VERSION
        );
        this.settings.set_boolean ("welcome-shown", true);
    }

    private void queue_welcome (Gtk.Window parent) {
        if (!needs_welcome_tour () || this.welcome != null)
            return;
        if (this.welcome_idle != 0)
            return;
        this.welcome_idle = Idle.add (() => {
            this.welcome_idle = 0;
            if (!this.accounts.has_mail_accounts ())
                return Source.REMOVE;
            present_welcome (parent);
            return Source.REMOVE;
        });
    }

    private void cancel_welcome () {
        if (this.welcome_idle != 0) {
            Source.remove (this.welcome_idle);
            this.welcome_idle = 0;
        }
        if (this.welcome != null) {
            var dialog = this.welcome;
            this.welcome = null;
            dialog.force_close ();
        }
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
            mark_welcome_tour_complete ();
            /* Help → Welcome can reopen after freeze; only apply when we
             * were waiting to lock chrome for this process. */
            if (!Utils.chrome_icons_are_frozen ()) {
                Utils.freeze_chrome_icons ();
                var window = parent as Window;
                if (window == null)
                    window = main_window ();
                window?.apply_chrome_icons ();
            }
        });
        dialog.present (parent);
    }

    private void on_about () {
        var about = new Adw.AboutDialog () {
            application_name = Utils.app_display_name (),
            application_icon = Config.APP_ID,
            developer_name = "Salvatore Oscurato",
            version = Config.VERSION,
            comments = _("A modern email client for your desktop. Letter Identity signs you in from Letter; on GNOME you can also share accounts with Calendar and Contacts."),
            website = "https://github.com/stalvatero/letter",
            issue_url = "https://github.com/stalvatero/letter/issues",
            copyright = "© 2026 Salvatore Oscurato",
            license_type = Gtk.License.GPL_3_0,
            developers = { "Salvatore Oscurato" },
            translator_credits = _("translator-credits"),
        };
        /* Third-party icons — acknowledgement, not a second app license. */
        about.add_acknowledgement_section (
            _("UI icons"),
            {
                "IconOven Stroke (MIT) — © 2026 Appic Marketing LLC — https://iconoven.com",
            }
        );
        about.present (get_active_window ());
    }

    private void on_check_updates () {
        if (this.checking_updates)
            return;
        /* Badge already proved a newer release — open it without a re-fetch. */
        if (this.update_available
            && this.update_latest != null
            && this.update_latest.length > 0
            && this.update_url != null
            && this.update_url.length > 0) {
            var current = Utils.normalize_version (Config.VERSION);
            present_update_available (
                get_active_window (),
                this.update_latest,
                current,
                this.update_url
            );
            clear_update_available ();
            return;
        }
        check_for_updates.begin (false);
    }

    /* Once per session, after the UI has settled — no toast on success/fail. */
    private void schedule_idle_update_check () {
        if (this.idle_update_checked || this.idle_update_source != 0)
            return;
        this.idle_update_source = Timeout.add_seconds (90, () => {
            this.idle_update_source = 0;
            idle_check_for_updates.begin ();
            return Source.REMOVE;
        });
    }

    private async void idle_check_for_updates () {
        if (this.idle_update_checked)
            return;
        this.idle_update_checked = true;
        if (this.checking_updates)
            return;
        yield check_for_updates (true);
    }

    private async void check_for_updates (bool quiet) {
        this.checking_updates = true;
        var action = lookup_action ("check-updates") as SimpleAction;
        action?.set_enabled (false);

        var parent = get_active_window ();
        var win = parent as Window;
        if (!quiet)
            win?.show_toast (_("Checking for updates…"));

        try {
            var release = yield Utils.fetch_latest_github_release ("stalvatero", "letter");
            var current = Utils.normalize_version (Config.VERSION);
            var latest = release.version;
            if (Utils.compare_versions (latest, current) > 0) {
                this.update_latest = latest;
                this.update_url = release.html_url;
                this.update_available = true;
                notify_property ("update-available");
                if (!quiet) {
                    present_update_available (parent, latest, current, release.html_url);
                    clear_update_available ();
                }
            } else {
                clear_update_available ();
                if (!quiet)
                    present_up_to_date (parent, current);
            }
        } catch (Error e) {
            warning ("Update check failed: %s", e.message);
            if (!quiet)
                present_update_check_failed (parent);
        } finally {
            this.checking_updates = false;
            action?.set_enabled (true);
        }
    }

    public void clear_update_available () {
        if (!this.update_available
            && (this.update_latest == null || this.update_latest.length == 0))
            return;
        this.update_available = false;
        this.update_latest = null;
        this.update_url = null;
        notify_property ("update-available");
    }

    private void present_up_to_date (Gtk.Window? parent, string version) {
        var dialog = new Adw.AlertDialog (
            _("Up to Date"),
            _("You are already using the latest version (%s).").printf (version)
        );
        dialog.add_response ("ok", _("OK"));
        dialog.present (parent);
    }

    private void present_update_available (
        Gtk.Window? parent,
        string latest,
        string current,
        string html_url
    ) {
        var dialog = new Adw.AlertDialog (
            _("Update Available"),
            _("Letter %s is available. You have version %s.").printf (latest, current)
        );
        dialog.add_response ("close", _("Close"));
        dialog.add_response ("open", _("Open Release Page"));
        dialog.set_response_appearance ("open", Adw.ResponseAppearance.SUGGESTED);
        dialog.default_response = "open";
        dialog.response.connect ((response_id) => {
            if (response_id != "open")
                return;
            try {
                AppInfo.launch_default_for_uri (html_url, null);
            } catch (Error e) {
                warning ("Could not open release page: %s", e.message);
            }
        });
        dialog.present (parent);
    }

    private void present_update_check_failed (Gtk.Window? parent) {
        var dialog = new Adw.AlertDialog (
            _("Could Not Check for Updates"),
            _("Check your network connection and try again.")
        );
        dialog.add_response ("ok", _("OK"));
        dialog.present (parent);
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
        mail.add (new Adw.ShortcutsItem (_("Send message"), "<Ctrl>Return"));
        mail.add (new Adw.ShortcutsItem (_("Reply"), "R"));
        mail.add (new Adw.ShortcutsItem (_("Reply All"), "<Shift>r"));
        mail.add (new Adw.ShortcutsItem (_("Forward"), "F"));
        mail.add (new Adw.ShortcutsItem (_("Archive"), "A"));
        mail.add (new Adw.ShortcutsItem (_("Mark as unread"), "<Ctrl>u"));
        mail.add (new Adw.ShortcutsItem (_("Bookmark"), "<Ctrl><Shift>b"));
        mail.add (new Adw.ShortcutsItem (_("Delete"), "Delete"));
        mail.add (new Adw.ShortcutsItem (_("Undo"), "<Ctrl>z"));
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

    private void on_add_mail_account () {
        var parent = get_active_window ();
        var dialog = new IdentityImapDialog ();
        dialog.account_added.connect ((id) => {
            this.accounts.reload_identity ();
            /* SetupWindow is open when Identity was empty — flip to main shell. */
            show_window_for_accounts ();
            show_mail_toast (_("Account added"));
            debug ("Identity account added: %s", id);
        });
        dialog.present (parent);
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
