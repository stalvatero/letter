public class Mail.PreferencesDialog : Adw.PreferencesDialog {
    private AccountStore store;
    private Window? host;
    private Adw.PreferencesGroup cache_group;
    private Adw.ActionRow total_row;
    private Adw.ComboRow sound_row;
    private Adw.SwitchRow aggregate_sound_row;
    private Adw.ComboRow interval_row;
    private Adw.ComboRow cache_days_row;
    private Adw.SwitchRow rail_enabled_row;
    private Adw.ComboRow rail_color_row;
    private Adw.ActionRow rail_palette_row;
    private Adw.SwitchRow avatars_row;
    private Gtk.Box rail_swatch_box;
    private Gtk.Button rail_picker_button;
    private Settings settings;
    private SignatureStore signatures;
    private Adw.PreferencesGroup accounts_group;
    private GenericArray<Adw.ActionRow> account_rows = new GenericArray<Adw.ActionRow> ();
    private GenericArray<Adw.ActionRow> cache_account_rows = new GenericArray<Adw.ActionRow> ();
    private Adw.ActionRow? account_drop_highlight;
    private bool updating_sound;
    private bool updating_rail_swatches;
    private bool updating_account_order;

    private const string[] SOUND_IDS = {
        "message-new-instant",
        "message",
        "complete",
        "bell",
    };
    private const uint SOUND_CUSTOM = 4;
    private const uint SOUND_SILENT = 5;
    private const int PAGE_CONTENT_WIDTH = 800;

    public PreferencesDialog (AccountStore store, Window? host) {
        Object (
            title: _("Preferences"),
            content_width: PAGE_CONTENT_WIDTH
        );
        this.store = store;
        this.host = host;
        this.settings = new Settings (Config.APP_ID);
        this.signatures = new SignatureStore (this.settings);
        this.signatures.migrate_if_needed (store);

        Adw.PreferencesGroup? integration = null;
        if (Utils.is_gnome_session ()) {
            integration = new Adw.PreferencesGroup () {
                title = _("GNOME integration"),
                description = _("These counts are for GNOME Online Accounts with Evolution Data Server (Calendar and Contacts). If you only use Letter Identity, you can ignore this section."),
            };
            add_prefs_row (integration, count_row (_("Mail accounts"), store.items.get_n_items ()));
            add_prefs_row (integration, count_row (_("Calendars"), store.calendar_count));
            add_prefs_row (integration, count_row (_("Address books"), store.contact_count));
        }

        var appearance = new Adw.PreferencesGroup () {
            title = _("Appearance"),
        };
        var theme_row = new Adw.ComboRow () {
            title = _("Application theme"),
            subtitle = _("Choose your personal experience."),
            subtitle_lines = 2,
            model = new Gtk.StringList ({
                _("Follow system"),
                _("Light"),
                _("Dark"),
            }),
        };
        var theme = this.settings.get_string ("color-scheme");
        theme_row.selected = theme == "light" ? 1 : theme == "dark" ? 2 : 0;
        theme_row.notify["selected"].connect (() => {
            switch (theme_row.selected) {
                case 1:
                    this.settings.set_string ("color-scheme", "light");
                    break;
                case 2:
                    this.settings.set_string ("color-scheme", "dark");
                    break;
                default:
                    this.settings.set_string ("color-scheme", "default");
                    break;
            }
        });
        this.settings.changed["color-scheme"].connect (() => {
            var next = this.settings.get_string ("color-scheme");
            var want = next == "light" ? 1 : next == "dark" ? 2 : 0;
            if (theme_row.selected != want)
                theme_row.selected = want;
        });
        add_prefs_row (appearance, theme_row);

        var body_bg_row = new Adw.ComboRow () {
            title = _("Reading mode"),
            subtitle = _("Choose the background colour of the message body."),
            subtitle_lines = 2,
            model = new Gtk.StringList ({
                _("Always light"),
                _("Follow system"),
            }),
        };
        var body_bg = this.settings.get_string ("message-body-background");
        body_bg_row.selected = body_bg == "follow-system" ? 1 : 0;
        body_bg_row.notify["selected"].connect (() => {
            this.settings.set_string (
                "message-body-background",
                body_bg_row.selected == 1 ? "follow-system" : "always-light"
            );
        });
        add_prefs_row (appearance, body_bg_row);

        migrate_account_rail_settings (this.settings);

        this.rail_enabled_row = new Adw.SwitchRow () {
            title = _("Enable account rail"),
            subtitle = _("Show or hide the sidebar for quick account switching."),
            subtitle_lines = 2,
            active = this.settings.get_boolean ("account-rail-enabled"),
        };
        this.rail_enabled_row.notify["active"].connect (() => {
            this.settings.set_boolean ("account-rail-enabled", this.rail_enabled_row.active);
            update_rail_prefs_visibility ();
        });
        add_prefs_row (appearance, this.rail_enabled_row);

        this.rail_color_row = new Adw.ComboRow () {
            title = _("Account rail colour"),
            subtitle = _("Accent colour, follow the window theme, or a custom colour."),
            subtitle_lines = 2,
            model = new Gtk.StringList ({
                _("Default"),
                _("Follow system"),
                _("Custom"),
            }),
        };
        var rail_mode = this.settings.get_string ("account-rail");
        this.rail_color_row.selected = rail_mode == "theme" ? 1 : rail_mode == "custom" ? 2 : 0;
        this.rail_color_row.notify["selected"].connect (() => {
            switch (this.rail_color_row.selected) {
                case 1:
                    this.settings.set_string ("account-rail", "theme");
                    break;
                case 2:
                    this.settings.set_string ("account-rail", "custom");
                    break;
                default:
                    this.settings.set_string ("account-rail", "default");
                    break;
            }
            update_rail_prefs_visibility ();
        });
        add_prefs_row (appearance, this.rail_color_row);

        this.rail_palette_row = build_rail_palette_row ();
        add_prefs_row (appearance, this.rail_palette_row);

        this.avatars_row = new Adw.SwitchRow () {
            title = _("Account pictures"),
            subtitle = _("Show profile pictures or initials in the accounts rail."),
            subtitle_lines = 2,
            active = this.settings.get_boolean ("account-avatars"),
        };
        this.avatars_row.notify["active"].connect (() => {
            this.settings.set_boolean ("account-avatars", this.avatars_row.active);
        });
        add_prefs_row (appearance, this.avatars_row);
        update_rail_prefs_visibility ();

        var reading = new Adw.PreferencesGroup () {
            title = _("Reading"),
        };
        var pane_row = new Adw.ComboRow () {
            title = _("Reading pane"),
            subtitle = _("Beside the list, below it, or hidden."),
            subtitle_lines = 2,
            model = new Gtk.StringList ({
                _("On the right"),
                _("Below the list"),
                _("Hidden"),
            }),
        };
        var current = this.settings.get_string ("reading-pane");
        pane_row.selected = current == "bottom" ? 1 : current == "hidden" ? 2 : 0;
        pane_row.notify["selected"].connect (() => {
            switch (pane_row.selected) {
                case 1:
                    this.settings.set_string ("reading-pane", "bottom");
                    break;
                case 2:
                    this.settings.set_string ("reading-pane", "hidden");
                    break;
                default:
                    this.settings.set_string ("reading-pane", "right");
                    break;
            }
        });
        add_prefs_row (reading, pane_row);

        var read_row = new Adw.ComboRow () {
            title = _("Mark as read"),
            subtitle = _("When an open message is marked as read."),
            subtitle_lines = 2,
            model = new Gtk.StringList ({
                _("On selection"),
                _("After 5 seconds"),
                _("Never"),
            }),
        };
        var mark = this.settings.get_string ("mark-as-read");
        read_row.selected = mark == "delay" ? 1 : mark == "never" ? 2 : 0;
        read_row.notify["selected"].connect (() => {
            switch (read_row.selected) {
                case 1:
                    this.settings.set_string ("mark-as-read", "delay");
                    break;
                case 2:
                    this.settings.set_string ("mark-as-read", "never");
                    break;
                default:
                    this.settings.set_string ("mark-as-read", "selection");
                    break;
            }
        });
        add_prefs_row (reading, read_row);

        var recovery_row = new Adw.SwitchRow () {
            title = _("Retry failed remote images"),
            subtitle = _("If an image from a trusted sender fails to load because the site’s HTTPS certificate chain is incomplete, download it again with a stricter recovery path. Off by default; uses extra network requests."),
            subtitle_lines = 5,
            active = this.settings.get_boolean ("recover-remote-images"),
        };
        recovery_row.notify["active"].connect (() => {
            this.settings.set_boolean ("recover-remote-images", recovery_row.active);
        });
        add_prefs_row (reading, recovery_row);

        var conversation_row = new Adw.SwitchRow () {
            title = _("Conversations"),
            subtitle = _("Group related messages into threads."),
            active = this.settings.get_boolean ("conversation-view"),
        };
        conversation_row.notify["active"].connect (() => {
            this.settings.set_boolean ("conversation-view", conversation_row.active);
        });
        add_prefs_row (reading, conversation_row);

        var notifications = new Adw.PreferencesGroup () {
            title = _("Notifications"),
        };
        var notify_row = new Adw.SwitchRow () {
            title = _("Notifications"),
            subtitle = _("Desktop alerts for new mail."),
            active = this.settings.get_boolean ("notifications"),
        };
        notify_row.notify["active"].connect (() => {
            this.settings.set_boolean ("notifications", notify_row.active);
            this.sound_row.sensitive = notify_row.active;
            this.aggregate_sound_row.sensitive = notify_row.active;
        });
        add_prefs_row (notifications, notify_row);

        this.sound_row = new Adw.ComboRow () {
            title = _("Notification sound"),
            subtitle_lines = 2,
            model = new Gtk.StringList ({
                _("Default"),
                _("Message"),
                _("Complete"),
                _("Bell"),
                _("Custom file…"),
                _("Silent"),
            }),
            sensitive = notify_row.active,
        };
        var play = new Gtk.Button.from_icon_name ("media-playback-start-symbolic") {
            valign = Gtk.Align.CENTER,
            tooltip_text = _("Play the selected sound"),
            has_frame = false,
        };
        play.add_css_class ("flat");
        play.clicked.connect (on_preview_sound);
        this.sound_row.add_suffix (play);
        refresh_sound_row ();
        this.sound_row.notify["selected"].connect (() => {
            on_sound_selected.begin ();
        });
        add_prefs_row (notifications, this.sound_row);

        this.aggregate_sound_row = new Adw.SwitchRow () {
            title = _("Aggregate sound"),
            subtitle = _("On: one sound for all new mail in a check cycle. Off: a sound for every new message."),
            subtitle_lines = 4,
            active = this.settings.get_boolean ("notification-sound-aggregate"),
            sensitive = notify_row.active,
        };
        this.aggregate_sound_row.notify["active"].connect (() => {
            this.settings.set_boolean ("notification-sound-aggregate", this.aggregate_sound_row.active);
        });
        add_prefs_row (notifications, this.aggregate_sound_row);

        var sync = new Adw.PreferencesGroup () {
            title = _("Synchronization"),
            description = _("Headers stay local for every folder. Bodies and attachments are kept only for the period you choose. The first sync can take a while; after that, folders stay up to date. Letter Microsoft accounts use on-demand attachments for smarter disk use."),
        };

        this.interval_row = new Adw.ComboRow () {
            title = _("Check for new mail"),
            subtitle_lines = 3,
            model = new Gtk.StringList ({
                _("Every minute"),
                _("Every 5 minutes"),
                _("Every 15 minutes"),
                _("Every 30 minutes"),
                _("Manually (F5)"),
            }),
        };
        this.interval_row.selected = interval_index (this.settings.get_int ("sync-interval"));
        this.interval_row.notify["selected"].connect (() => {
            int[] values = { 60, 300, 900, 1800, 0 };
            var index = (int) this.interval_row.selected;
            if (index >= 0 && index < values.length)
                this.settings.set_int ("sync-interval", values[index]);
            update_interval_subtitle ();
        });
        update_interval_subtitle ();
        add_prefs_row (sync, this.interval_row);

        this.cache_days_row = new Adw.ComboRow () {
            title = _("Download message bodies"),
            subtitle_lines = 5,
            model = new Gtk.StringList ({
                _("Last 2 months"),
                _("Last 6 months"),
                _("Last year"),
                _("Download all"),
            }),
        };
        this.cache_days_row.selected = cache_days_index (this.settings.get_int ("body-cache-days"));
        this.cache_days_row.notify["selected"].connect (() => {
            int[] values = { 60, 180, 365, 0 };
            var index = (int) this.cache_days_row.selected;
            if (index >= 0 && index < values.length)
                this.settings.set_int ("body-cache-days", values[index]);
            update_cache_subtitle ();
        });
        update_cache_subtitle ();
        add_prefs_row (sync, this.cache_days_row);

        this.cache_group = new Adw.PreferencesGroup () {
            title = _("Local library"),
            description = _("Letter caches headers and message bodies for every folder below. Attachments download when you open a message and then stay on disk until you Reset. First fill can take hours; Inbox checks and sending stay responsive."),
        };
        this.total_row = new Adw.ActionRow () {
            title = _("Disk used"),
            sensitive = false,
        };
        add_prefs_row (this.cache_group, this.total_row);
        fill_cache_accounts ();

        var accounts = new Adw.PreferencesGroup () {
            title = _("Accounts"),
            description = _("Add Letter Identity accounts here. On GNOME you can also opt in to Online Accounts — each row is marked Letter or GNOME. Drag accounts to set the order in the rail and Local library."),
        };
        this.accounts_group = accounts;

        var letter_row = new Adw.ActionRow () {
            title = _("Add account"),
            subtitle = _("Google, Microsoft, or IMAP — passwords and tokens stay in the system keyring"),
            activatable = true,
        };
        letter_row.add_prefix (new Gtk.Image.from_icon_name ("list-add-symbolic"));
        letter_row.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic") {
            valign = Gtk.Align.CENTER,
        });
        letter_row.activated.connect (() => {
            var app = this.host?.get_application () as Application;
            if (app != null)
                app.activate_action ("add-mail-account", null);
            else {
                var dialog = new IdentityImapDialog ();
                dialog.account_added.connect (() => this.store.reload_identity ());
                dialog.present (this.host);
            }
        });
        add_prefs_row (accounts, letter_row);

        /* GOA UI only when the host actually has GNOME Online Accounts
         * (not KDE / Cinnamon / Cosmic without GOA). */
        var goa_available = Utils.has_gnome_online_accounts ()
            && Environment.get_variable ("LETTER_SKIP_GOA") != "1";
        if (goa_available) {
            var goa_on = this.settings.get_boolean ("use-goa-accounts");
            var goa_switch = new Adw.SwitchRow () {
                title = _("Use GNOME Online Accounts"),
                subtitle = _("GNOME accounts share sign-in with Calendar and Contacts and use the Evolution mail stack. Letter Identity uses Letter’s own engine — more flexible sync and faster local search. Same address in both is shown once and uses Letter."),
                active = goa_on,
            };
            var settings_row = new Adw.ActionRow () {
                title = _("Open GNOME Online Accounts"),
                subtitle = _("Manage system accounts in Settings"),
                activatable = goa_on,
                sensitive = goa_on,
            };
            settings_row.add_prefix (new Gtk.Image.from_icon_name ("network-workgroup-symbolic"));
            settings_row.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic") {
                valign = Gtk.Align.CENTER,
            });
            settings_row.activated.connect (() => {
                if (settings_row.sensitive)
                    Utils.open_online_accounts ();
            });
            goa_switch.notify["active"].connect (() => {
                settings_row.sensitive = goa_switch.active;
                settings_row.activatable = goa_switch.active;
                if (goa_switch.active == this.store.goa_preference_enabled ())
                    return;
                apply_goa_preference.begin (goa_switch.active);
            });
            add_prefs_row (accounts, goa_switch);
            add_prefs_row (accounts, settings_row);
        }
        fill_mail_accounts ();
        this.store.changed.connect (() => {
            fill_mail_accounts ();
            fill_cache_accounts ();
        });
        this.settings.changed["account-order"].connect (() => {
            if (this.updating_account_order)
                return;
            fill_mail_accounts ();
            fill_cache_accounts ();
        });

        /* Top-level pages — Adw.PreferencesDialog shows a ViewSwitcher
         * in the header (same pattern as GNOME Terminal / Settings). */
        var accounts_page = new Adw.PreferencesPage () {
            name = "accounts",
            title = _("Accounts"),
            icon_name = "avatar-default-symbolic",
        };
        accounts_page.add (accounts);
        accounts_page.add (this.cache_group);

        var appearance_page = new Adw.PreferencesPage () {
            name = "appearance",
            title = _("Appearance"),
            icon_name = "preferences-desktop-appearance-symbolic",
        };
        appearance_page.add (appearance);
        appearance_page.add (reading);

        var contacts_compose = new Adw.PreferencesGroup () {
            title = _("Contacts and compose"),
        };
        var all_contacts_row = new Adw.SwitchRow () {
            title = _("Use contacts from all accounts"),
            subtitle = _("Search address books and directories for every mail account, not only the account selected in From."),
            active = this.settings.get_boolean ("compose-contacts-all-accounts"),
        };
        all_contacts_row.notify["active"].connect (() => {
            this.settings.set_boolean (
                "compose-contacts-all-accounts",
                all_contacts_row.active
            );
        });
        add_prefs_row (contacts_compose, all_contacts_row);

        var collected_row = new Adw.ActionRow () {
            title = _("Recent addresses"),
            subtitle = _("Addresses gathered from sent mail. Remove ones you do not want in suggestions while writing an email."),
            activatable = true,
        };
        var manage_collected = new Gtk.Button.with_label (_("Manage")) {
            valign = Gtk.Align.CENTER,
        };
        manage_collected.add_css_class ("flat");
        manage_collected.clicked.connect (open_collected_addresses);
        collected_row.activated.connect (open_collected_addresses);
        collected_row.add_suffix (manage_collected);
        add_prefs_row (contacts_compose, collected_row);

        var behavior_page = new Adw.PreferencesPage () {
            name = "behavior",
            title = _("Behavior"),
            icon_name = "preferences-system-symbolic",
        };
        behavior_page.add (sync);
        behavior_page.add (contacts_compose);
        behavior_page.add (notifications);

        add (accounts_page);
        add (appearance_page);
        add (behavior_page);
        widen_page_content (accounts_page, PAGE_CONTENT_WIDTH);
        widen_page_content (appearance_page, PAGE_CONTENT_WIDTH);
        widen_page_content (behavior_page, PAGE_CONTENT_WIDTH);

        /* GNOME-only for now — other desktops use Letter Identity without this tab. */
        if (integration != null) {
            var deps_group = new Adw.PreferencesGroup ();
            var deps_row = new Adw.ActionRow () {
                title = _("Dependencies and recommended packages"),
                subtitle = _("Check the software requirements for Letter to work correctly."),
                activatable = true,
            };
            deps_row.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic") {
                valign = Gtk.Align.CENTER,
            });
            deps_row.activated.connect (() => {
                push_subpage (new DependencyListPage ());
            });
            add_prefs_row (deps_group, deps_row);

            var integrations_page = new Adw.PreferencesPage () {
                name = "integrations",
                title = _("Integrations"),
                icon_name = "application-x-addon-symbolic",
            };
            integrations_page.add (integration);
            integrations_page.add (deps_group);
            add (integrations_page);
            widen_page_content (integrations_page, PAGE_CONTENT_WIDTH);
        }
        /* PreferencesDialog has no widget tree until mapped — polish then. */
        this.map.connect (() => {
            polish_prefs_rows_under (this);
        });
    }

    private void open_collected_addresses () {
        var app = this.host?.get_application () as Application;
        if (app == null)
            return;
        var dialog = new CollectedAddressesDialog (app.contacts);
        dialog.present (this);
    }

    private static void add_prefs_row (Adw.PreferencesGroup group, Adw.ActionRow row) {
        polish_prefs_row (row);
        group.add (row);
    }

    private static void widen_page_content (Adw.PreferencesPage page, int size) {
        Gtk.Widget? widget = page.get_first_child ();
        while (widget != null) {
            var clamp = widget as Adw.Clamp;
            if (clamp != null) {
                clamp.maximum_size = size;
                clamp.tightening_threshold = int.max (400, size - 200);
                return;
            }
            widget = widget.get_first_child ();
        }
    }

    private static Gtk.ListItemFactory? prefs_combo_factory;

    /** Reserve action space (CSS) and right-align ComboRow values. */
    private static void polish_prefs_rows_under (Gtk.Widget widget) {
        var row = widget as Adw.ActionRow;
        if (row != null)
            polish_prefs_row (row);
        for (var child = widget.get_first_child (); child != null; child = child.get_next_sibling ())
            polish_prefs_rows_under (child);
    }

    private static void polish_prefs_row (Adw.ActionRow row) {
        if (row.has_css_class ("prefs-row-polished"))
            return;
        row.add_css_class ("prefs-row-polished");

        var combo = row as Adw.ComboRow;
        if (combo != null)
            combo.factory = prefs_combo_value_factory ();

        row.map.connect (() => {
            align_prefs_row_suffixes (row);
            /* ComboRow builds suffix children asynchronously; re-pack once. */
            Idle.add (() => {
                align_prefs_row_suffixes (row);
                return Source.REMOVE;
            });
        });
        if (row.get_mapped ()) {
            align_prefs_row_suffixes (row);
            Idle.add (() => {
                align_prefs_row_suffixes (row);
                return Source.REMOVE;
            });
        }
    }

    private static Gtk.ListItemFactory prefs_combo_value_factory () {
        if (prefs_combo_factory != null)
            return prefs_combo_factory;

        var factory = new Gtk.SignalListItemFactory ();
        factory.setup.connect ((obj) => {
            var list_item = (Gtk.ListItem) obj;
            var label = new Gtk.Label ("") {
                xalign = 1.0f,
                ellipsize = Pango.EllipsizeMode.END,
                hexpand = true,
                halign = Gtk.Align.FILL,
            };
            label.add_css_class ("prefs-combo-value");
            list_item.child = label;
        });
        factory.bind.connect ((obj) => {
            var list_item = (Gtk.ListItem) obj;
            var label = list_item.child as Gtk.Label;
            var value = list_item.item as Gtk.StringObject;
            if (label == null)
                return;
            label.label = value != null ? value.string : "";
            label.xalign = 1.0f;
        });
        prefs_combo_factory = factory;
        return factory;
    }

    private static void align_prefs_row_suffixes (Adw.ActionRow row) {
        var suffixes = find_widget_with_class (row, "suffixes");
        if (suffixes == null)
            return;

        var box = suffixes as Gtk.Box;
        Gtk.Widget? spacer = null;
        for (var child = suffixes.get_first_child (); child != null; child = child.get_next_sibling ()) {
            if (child.has_css_class ("prefs-suffix-spacer")) {
                spacer = child;
                break;
            }
        }

        /* Leading expander: keep the reserved action column, pack real
         * controls (combo, chevron, switch, buttons, GOA arrow) on the end. */
        if (spacer == null) {
            spacer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            spacer.add_css_class ("prefs-suffix-spacer");
            spacer.hexpand = true;
            if (box != null)
                box.prepend (spacer);
            else
                spacer.insert_before (suffixes, suffixes.get_first_child ());
        } else if (suffixes.get_first_child () != spacer) {
            spacer.unparent ();
            if (box != null)
                box.prepend (spacer);
            else
                spacer.insert_before (suffixes, suffixes.get_first_child ());
        }
        spacer.hexpand = true;

        for (var child = suffixes.get_first_child (); child != null; child = child.get_next_sibling ()) {
            if (child.has_css_class ("prefs-suffix-spacer"))
                continue;
            child.hexpand = false;
            child.halign = Gtk.Align.END;
        }
    }

    private static Gtk.Widget? find_widget_with_class (Gtk.Widget widget, string css_class) {
        if (widget.has_css_class (css_class))
            return widget;
        for (var child = widget.get_first_child (); child != null; child = child.get_next_sibling ()) {
            var found = find_widget_with_class (child, css_class);
            if (found != null)
                return found;
        }
        return null;
    }

    private static void migrate_account_rail_settings (Settings settings) {
        if (settings.get_string ("account-rail") != "hide")
            return;
        settings.set_boolean ("account-rail-enabled", false);
        settings.set_string ("account-rail", "default");
    }

    private void update_rail_prefs_visibility () {
        var enabled = this.rail_enabled_row.active;
        this.rail_color_row.visible = enabled;
        this.avatars_row.visible = enabled;
        this.rail_palette_row.visible = enabled && this.rail_color_row.selected == 2;
        if (this.rail_palette_row.visible)
            sync_rail_swatches ();
    }

    private Adw.ActionRow build_rail_palette_row () {
        var row = new Adw.ActionRow () {
            title = _("Custom colour"),
            subtitle = _("Choose a colour or pick a new one"),
            subtitle_lines = 2,
            activatable = false,
        };

        this.rail_swatch_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            valign = Gtk.Align.CENTER,
            hexpand = false,
        };

        Gtk.ToggleButton? group = null;
        for (int i = 0; i < 9; i++) {
            var accent = (Adw.AccentColor) i;
            var rgba = accent.to_rgba ();
            var hex = rgba_to_hex (rgba);
            var swatch = new Gtk.ToggleButton () {
                tooltip_text = accent_color_label (accent),
                valign = Gtk.Align.CENTER,
                halign = Gtk.Align.CENTER,
            };
            swatch.add_css_class ("circular");
            swatch.add_css_class ("rail-swatch");
            swatch.set_data ("rail-hex", hex);
            apply_swatch_css (swatch, hex);
            if (group != null)
                swatch.group = group;
            else
                group = swatch;
            var captured = hex;
            swatch.toggled.connect (() => {
                if (this.updating_rail_swatches || !swatch.active)
                    return;
                this.settings.set_string ("account-rail-color", captured);
                sync_rail_picker_preview ();
            });
            this.rail_swatch_box.append (swatch);
        }

        this.rail_picker_button = new Gtk.Button () {
            tooltip_text = _("Choose a custom colour"),
            valign = Gtk.Align.CENTER,
            icon_name = "color-select-symbolic",
        };
        this.rail_picker_button.add_css_class ("circular");
        this.rail_picker_button.add_css_class ("rail-swatch-picker");
        this.rail_picker_button.clicked.connect (() => {
            pick_rail_color.begin ();
        });
        this.rail_swatch_box.append (this.rail_picker_button);

        row.add_suffix (this.rail_swatch_box);
        return row;
    }

    private async void pick_rail_color () {
        /* Own Gtk window (not Adw.Dialog): ColorChooserWidget textures work,
         * and we can size to the palette vs editor natural requisition. */
        var parent = this.host;
        var dialog = new Gtk.ColorChooserDialog (_("Choose Colour"), parent) {
            modal = true,
            use_alpha = false,
            resizable = false,
        };

        var initial = Gdk.RGBA ();
        if (!initial.parse (this.settings.get_string ("account-rail-color")))
            initial.parse ("#3584e4");
        dialog.set_rgba (initial);

        var ccw = find_color_chooser_widget (dialog);
        if (ccw != null) {
            ccw.notify["show-editor"].connect (() => {
                Idle.add (() => {
                    fit_color_chooser_dialog (dialog);
                    return Source.REMOVE;
                });
            });
        }

        dialog.map.connect (() => {
            fit_color_chooser_dialog (dialog);
            Idle.add (() => {
                fit_color_chooser_dialog (dialog);
                return Source.REMOVE;
            });
        });

        var response = yield run_color_chooser_async (dialog);
        if (response == Gtk.ResponseType.OK) {
            this.settings.set_string ("account-rail-color", rgba_to_hex (dialog.get_rgba ()));
            if (this.rail_color_row.selected != 2)
                this.rail_color_row.selected = 2;
            sync_rail_swatches ();
        }
        dialog.destroy ();
    }

    private static Gtk.ColorChooserWidget? find_color_chooser_widget (Gtk.Widget widget) {
        var chooser = widget as Gtk.ColorChooserWidget;
        if (chooser != null)
            return chooser;
        for (var child = widget.get_first_child (); child != null; child = child.get_next_sibling ()) {
            var found = find_color_chooser_widget (child);
            if (found != null)
                return found;
        }
        return null;
    }

    private static Gtk.ScrolledWindow? find_scrolled_window (Gtk.Widget widget) {
        var scrolled = widget as Gtk.ScrolledWindow;
        if (scrolled != null)
            return scrolled;
        for (var child = widget.get_first_child (); child != null; child = child.get_next_sibling ()) {
            var found = find_scrolled_window (child);
            if (found != null)
                return found;
        }
        return null;
    }

    private static void fit_color_chooser_dialog (Gtk.ColorChooserDialog dialog) {
        var ccw = find_color_chooser_widget (dialog);
        var scrolled = find_scrolled_window (dialog);
        if (ccw == null || scrolled == null)
            return;

        int nat_w, nat_h;
        ccw.measure (Gtk.Orientation.HORIZONTAL, -1, null, out nat_w, null, null);
        ccw.measure (Gtk.Orientation.VERTICAL, -1, null, out nat_h, null, null);

        /* ColorChooserDialog wraps the widget in a ScrolledWindow with a low
         * max-content height, so the editor view scrolls inside empty chrome
         * instead of growing the window. Lift the clamp and size to content. */
        scrolled.set_max_content_width (-1);
        scrolled.set_max_content_height (-1);
        scrolled.set_min_content_width (nat_w);
        scrolled.set_min_content_height (nat_h);
        scrolled.propagate_natural_width = true;
        scrolled.propagate_natural_height = true;
        scrolled.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.NEVER);

        dialog.set_size_request (-1, -1);
        dialog.queue_resize ();

        int dlg_w, dlg_h;
        dialog.measure (Gtk.Orientation.HORIZONTAL, -1, null, out dlg_w, null, null);
        dialog.measure (Gtk.Orientation.VERTICAL, -1, null, out dlg_h, null, null);
        dialog.set_default_size (dlg_w, dlg_h);
        /* Mapped windows ignore default-size alone; pin then keep resizable=false. */
        dialog.set_size_request (dlg_w, dlg_h);
    }

    private async int run_color_chooser_async (Gtk.ColorChooserDialog dialog) {
        int response = Gtk.ResponseType.CANCEL;
        SourceFunc resume = run_color_chooser_async.callback;
        dialog.response.connect ((response_id) => {
            response = response_id;
            Idle.add ((owned) resume);
        });
        dialog.present ();
        yield;
        return response;
    }

    private void sync_rail_swatches () {
        if (this.rail_swatch_box == null)
            return;
        this.updating_rail_swatches = true;
        var current = normalize_hex (this.settings.get_string ("account-rail-color"));
        var matched = false;
        for (var child = this.rail_swatch_box.get_first_child (); child != null; child = child.get_next_sibling ()) {
            var swatch = child as Gtk.ToggleButton;
            if (swatch == null)
                continue;
            var hex = swatch.get_data<string> ("rail-hex");
            if (hex == null)
                continue;
            var on = normalize_hex (hex) == current;
            swatch.active = on;
            if (on)
                matched = true;
        }
        this.updating_rail_swatches = false;
        sync_rail_picker_preview ();
        if (!matched)
            apply_swatch_css (this.rail_picker_button, current);
    }

    private void sync_rail_picker_preview () {
        var current = normalize_hex (this.settings.get_string ("account-rail-color"));
        var matched = false;
        for (var child = this.rail_swatch_box.get_first_child (); child != null; child = child.get_next_sibling ()) {
            var swatch = child as Gtk.ToggleButton;
            if (swatch == null)
                continue;
            var hex = swatch.get_data<string> ("rail-hex");
            if (hex != null && normalize_hex (hex) == current) {
                matched = true;
                break;
            }
        }
        if (matched)
            this.rail_picker_button.remove_css_class ("rail-swatch");
        else {
            this.rail_picker_button.add_css_class ("rail-swatch");
            apply_swatch_css (this.rail_picker_button, current);
        }
    }

    private static void apply_swatch_css (Gtk.Widget widget, string hex) {
        var old_class = widget.get_data<string> ("rail-swatch-class");
        if (old_class != null)
            widget.remove_css_class (old_class);

        var name = "rail-swatch-%s".printf (hex.replace ("#", ""));
        widget.add_css_class (name);
        widget.set_data ("rail-swatch-class", name);

        var provider = widget.get_data<Gtk.CssProvider> ("rail-swatch-css");
        if (provider == null) {
            provider = new Gtk.CssProvider ();
            widget.set_data ("rail-swatch-css", provider);
            Gtk.StyleContext.add_provider_for_display (
                Gdk.Display.get_default (),
                provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1
            );
        }
        provider.load_from_string (
            ".%s { --rail-swatch-color: %s; background: %s; }".printf (name, hex, hex)
        );
    }

    private static string rgba_to_hex (Gdk.RGBA rgba) {
        return "#%02x%02x%02x".printf (
            (uint) (rgba.red * 255.0 + 0.5),
            (uint) (rgba.green * 255.0 + 0.5),
            (uint) (rgba.blue * 255.0 + 0.5)
        );
    }

    private static string normalize_hex (string value) {
        var text = value.strip ().down ();
        if (!text.has_prefix ("#"))
            text = "#" + text;
        return text;
    }

    private static string accent_color_label (Adw.AccentColor accent) {
        switch (accent) {
            case Adw.AccentColor.BLUE:
                return _("Blue");
            case Adw.AccentColor.TEAL:
                return _("Teal");
            case Adw.AccentColor.GREEN:
                return _("Green");
            case Adw.AccentColor.YELLOW:
                return _("Yellow");
            case Adw.AccentColor.ORANGE:
                return _("Orange");
            case Adw.AccentColor.RED:
                return _("Red");
            case Adw.AccentColor.PINK:
                return _("Pink");
            case Adw.AccentColor.PURPLE:
                return _("Purple");
            case Adw.AccentColor.SLATE:
                return _("Slate");
            default:
                return _("Accent");
        }
    }

    private static uint interval_index (int seconds) {
        if (seconds <= 0)
            return 4;
        if (seconds <= 60)
            return 0;
        if (seconds <= 300)
            return 1;
        if (seconds <= 900)
            return 2;
        return 3;
    }

    private static uint cache_days_index (int days) {
        if (days <= 0)
            return 3;
        if (days >= 365)
            return 2;
        if (days >= 180)
            return 1;
        return 0;
    }

    private void update_interval_subtitle () {
        var text = _("How often to refresh mail while Letter is open.");
        if (this.interval_row.selected == 0) {
            this.interval_row.subtitle = "%s\n%s".printf (
                text,
                _("Very frequent checks may hit server rate limits.")
            );
            this.interval_row.add_css_class ("warning");
        } else {
            this.interval_row.subtitle = text;
            this.interval_row.remove_css_class ("warning");
        }
    }

    private void update_cache_subtitle () {
        var text = _("Keep complete emails on disk for the selected period for fast browsing and search indexing. Needs disk space.");
        if (this.cache_days_row.selected == 3) {
            this.cache_days_row.subtitle = "%s\n%s".printf (
                text,
                _("Downloading everything can take time and fill the disk.")
            );
            this.cache_days_row.add_css_class ("warning");
        } else {
            this.cache_days_row.subtitle = text;
            this.cache_days_row.remove_css_class ("warning");
        }
    }

    private void fill_mail_accounts () {
        clear_account_drop_highlight ();
        for (uint i = 0; i < this.account_rows.length; i++)
            this.accounts_group.remove (this.account_rows[i]);
        this.account_rows = new GenericArray<Adw.ActionRow> ();

        var accounts = collect_preference_accounts (true);
        Account.sort_for_display (accounts, this.settings.get_strv ("account-order"));

        for (uint i = 0; i < accounts.length; i++) {
            var account = accounts[i];
            var row = new Adw.ActionRow () {
                title = account.display_name,
                subtitle = account.email != null && account.email.length > 0
                    ? account.email
                    : account.kind.label (),
                tooltip_text = account.provenance_tooltip,
            };
            row.set_data ("order-key", account.order_key);

            var icon = Utils.account_brand_image (account, 28);
            icon.valign = Gtk.Align.CENTER;
            /* Prefixes pack right-to-left: add brand first, handle last → handle leftmost. */
            row.add_prefix (icon);

            if (account.is_letter_identity || account.has_goa)
                row.add_suffix (Utils.account_provenance_image (account, 16));

            var handle = new Gtk.Image.from_icon_name ("list-drag-handle-symbolic") {
                valign = Gtk.Align.CENTER,
                tooltip_text = _("Drag to reorder"),
            };
            handle.add_css_class ("dim-label");
            handle.add_css_class ("account-drag-handle");
            row.add_prefix (handle);

            var captured = account;

            var firms = new Gtk.Button.with_label (_("Signatures")) {
                valign = Gtk.Align.CENTER,
            };
            firms.add_css_class ("flat");
            firms.clicked.connect (() => {
                push_subpage (new SignatureListPage (captured, this.signatures));
            });

            if (account.is_letter_identity) {
                var edit = new Gtk.Button.with_label (_("Edit")) {
                    valign = Gtk.Align.CENTER,
                    tooltip_text = _("Change account label, sender name, or connection"),
                };
                edit.add_css_class ("flat");
                edit.clicked.connect (() => open_identity_edit (captured));
                row.add_suffix (edit);

                var remove = new Gtk.Button.with_label (_("Remove")) {
                    valign = Gtk.Align.CENTER,
                    tooltip_text = _("Remove this Letter Identity account"),
                };
                remove.add_css_class ("flat");
                remove.clicked.connect (() => confirm_remove_identity.begin (captured));
                row.add_suffix (remove);
            } else {
                var edit = new Gtk.Button.with_label (_("Edit")) {
                    valign = Gtk.Align.CENTER,
                    tooltip_text = _("Open this account in GNOME Settings"),
                };
                edit.add_css_class ("flat");
                edit.clicked.connect (() => {
                    if (captured.goa_id != null && captured.goa_id.length > 0)
                        Utils.open_online_account (captured.goa_id);
                    else
                        Utils.open_online_accounts ();
                });
                row.add_suffix (edit);
            }
            row.add_suffix (firms);
            setup_account_row_dnd (row, handle, account);
            add_prefs_row (this.accounts_group, row);
            this.account_rows.add (row);
        }
    }

    private async void apply_goa_preference (bool enabled) {
        yield this.store.set_use_goa_accounts (enabled);
        var app = this.host?.get_application () as Application;
        if (app != null)
            app.on_goa_preference_changed ();
    }

    private void open_identity_edit (Account account) {
        var id = account.source_uid ?? account.uid;
        if (id == null || id.length == 0)
            return;
        try {
            var dialog = new IdentityEditDialog (id);
            dialog.account_updated.connect (() => {
                this.store.reload_identity ();
                var app = this.host?.get_application () as Application;
                if (app != null) {
                    /* Account list + rail pick up the new display name. */
                    foreach (var window in app.get_windows ()) {
                        var mail = window as Window;
                        mail?.on_accounts_changed_public ();
                    }
                }
            });
            dialog.present (this);
        } catch (Error e) {
            var err = new Adw.AlertDialog (_("Could not open account"), e.message);
            err.add_response ("ok", _("OK"));
            err.present (this);
        }
    }

    private async void confirm_remove_identity (Account account) {
        var id = account.source_uid ?? account.uid;
        if (id == null || id.length == 0)
            return;

        var size = format_size (IdentityCatalog.local_library_bytes (id));
        var dialog = new Adw.AlertDialog (
            _("Remove “%s”?").printf (account.display_name),
            _("This cannot be undone. Letter deletes the account and its sign-in secrets (password or OAuth tokens). Mail on the server is not deleted.\n\nLocal library on disk: %s.").printf (size)
        );
        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("keep", _("Remove, keep cache"));
        dialog.add_response ("wipe", _("Remove and delete cache"));
        dialog.set_response_appearance ("wipe", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.default_response = "cancel";
        dialog.close_response = "cancel";

        var response = yield dialog.choose (this, null);
        if (response != "keep" && response != "wipe")
            return;

        var wipe = response == "wipe";
        try {
            IdentityCatalog.remove_account (id, wipe);
            this.store.reload_identity ();

            var app = this.host?.get_application () as Application;
            if (app != null)
                app.on_identity_account_removed ();

            add_toast (new Adw.Toast (
                wipe
                    ? _("Account removed and local cache deleted")
                    : _("Account removed (local cache kept)")
            ) {
                timeout = 4,
            });
        } catch (Error e) {
            add_toast (new Adw.Toast (e.message) {
                timeout = 6,
            });
        }
    }

    private static Gtk.Widget build_account_drag_preview (Account account) {
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10) {
            valign = Gtk.Align.CENTER,
        };
        box.add_css_class ("account-drag-preview");

        var icon = Utils.account_brand_image (account, 28);
        icon.valign = Gtk.Align.CENTER;
        box.append (icon);

        var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            valign = Gtk.Align.CENTER,
            hexpand = true,
        };
        var title = new Gtk.Label (account.display_name) {
            xalign = 0f,
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 28,
        };
        title.add_css_class ("heading");
        var subtitle_text = account.email != null && account.email.length > 0
            ? account.email
            : account.kind.label ();
        var subtitle = new Gtk.Label (subtitle_text) {
            xalign = 0f,
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 28,
        };
        subtitle.add_css_class ("caption");
        subtitle.add_css_class ("dim-label");
        labels.append (title);
        labels.append (subtitle);
        box.append (labels);
        return box;
    }

    private GenericArray<Account> collect_preference_accounts (bool mail_only) {
        var accounts = new GenericArray<Account> ();
        for (uint i = 0; i < this.store.items.get_n_items (); i++) {
            var account = this.store.items.get_item (i) as Account;
            if (account == null || account.kind == AccountKind.LOCAL)
                continue;
            if (mail_only && !account.has_mail)
                continue;
            if (!mail_only && account.source_uid == null)
                continue;
            accounts.add (account);
        }
        return accounts;
    }

    private void setup_account_row_dnd (Adw.ActionRow row, Gtk.Widget handle, Account account) {
        var drag = new Gtk.DragSource () {
            actions = Gdk.DragAction.MOVE,
        };
        drag.prepare.connect ((x, y) => {
            var key = row.get_data<string> ("order-key");
            if (key == null || key.length == 0)
                return null;
            return new Gdk.ContentProvider.for_value (key);
        });
        drag.drag_begin.connect ((gdk_drag) => {
            row.add_css_class ("account-row-dragging");
            /* Compact chip under the cursor — full-row WidgetPaintable was
             * centered on the pointer and spilled out of the dialog. */
            var preview = build_account_drag_preview (account);
            var drag_icon = new Gtk.DragIcon.get_for_drag (gdk_drag);
            drag_icon.child = preview;
        });
        drag.drag_end.connect ((gdk_drag, delete_data) => {
            row.remove_css_class ("account-row-dragging");
            clear_account_drop_highlight ();
        });
        drag.drag_cancel.connect ((gdk_drag, reason) => {
            row.remove_css_class ("account-row-dragging");
            clear_account_drop_highlight ();
            return false;
        });
        handle.add_controller (drag);
        handle.cursor = new Gdk.Cursor.from_name ("grab", null);

        var drop = new Gtk.DropTarget (typeof (string), Gdk.DragAction.MOVE);
        drop.accept.connect ((gdk_drop) => {
            return this.account_rows.length > 1;
        });
        drop.enter.connect ((x, y) => {
            update_account_drop_highlight (row, y);
            return Gdk.DragAction.MOVE;
        });
        drop.motion.connect ((x, y) => {
            update_account_drop_highlight (row, y);
            return Gdk.DragAction.MOVE;
        });
        drop.leave.connect (() => {
            clear_account_drop_highlight ();
        });
        drop.drop.connect ((value, x, y) => {
            clear_account_drop_highlight ();
            var dragged = value.get_string ();
            var target = row.get_data<string> ("order-key");
            if (dragged == null || target == null || dragged == target)
                return false;
            return apply_account_reorder (dragged, target, y < row.get_height () / 2.0);
        });
        row.add_controller (drop);
    }

    private void update_account_drop_highlight (Adw.ActionRow row, double y) {
        clear_account_drop_highlight ();
        this.account_drop_highlight = row;
        if (y < row.get_height () / 2.0)
            row.add_css_class ("account-drop-above");
        else
            row.add_css_class ("account-drop-below");
    }

    private void clear_account_drop_highlight () {
        if (this.account_drop_highlight == null)
            return;
        this.account_drop_highlight.remove_css_class ("account-drop-above");
        this.account_drop_highlight.remove_css_class ("account-drop-below");
        this.account_drop_highlight = null;
    }

    private bool apply_account_reorder (string dragged_key, string target_key, bool before) {
        var keys = new GenericArray<string> ();
        for (uint i = 0; i < this.account_rows.length; i++) {
            var key = this.account_rows[i].get_data<string> ("order-key");
            if (key != null && key.length > 0)
                keys.add (key);
        }

        int from = -1;
        int to = -1;
        for (uint i = 0; i < keys.length; i++) {
            if (keys[i] == dragged_key)
                from = (int) i;
            if (keys[i] == target_key)
                to = (int) i;
        }
        if (from < 0 || to < 0 || from == to)
            return false;

        keys.remove_index (from);
        if (from < to)
            to--;
        int insert = before ? to : to + 1;
        if (insert < 0)
            insert = 0;
        if (insert > (int) keys.length)
            insert = (int) keys.length;
        keys.insert (insert, dragged_key);

        var order = new string[keys.length];
        for (uint i = 0; i < keys.length; i++)
            order[i] = keys[i];

        this.updating_account_order = true;
        this.settings.set_strv ("account-order", order);
        this.updating_account_order = false;
        fill_mail_accounts ();
        fill_cache_accounts ();
        return true;
    }

    private void fill_cache_accounts () {
        refresh_total_row ();
        for (uint i = 0; i < this.cache_account_rows.length; i++)
            this.cache_group.remove (this.cache_account_rows[i]);
        this.cache_account_rows = new GenericArray<Adw.ActionRow> ();

        var accounts = collect_preference_accounts (false);
        Account.sort_for_display (accounts, this.settings.get_strv ("account-order"));

        for (uint i = 0; i < accounts.length; i++) {
            var account = accounts[i];
            var row = new Adw.ActionRow () {
                title = account.display_name,
                subtitle = cache_subtitle (account),
            };
            var button = new Gtk.Button.with_label (_("Reset")) {
                valign = Gtk.Align.CENTER,
            };
            button.add_css_class ("flat");
            button.tooltip_text = _("Delete Letter’s local copy and rebuild it from the server");
            var captured = account;
            var captured_row = row;
            button.clicked.connect (() => {
                confirm_reset.begin (captured, captured_row);
            });
            row.add_suffix (button);
            add_prefs_row (this.cache_group, row);
            this.cache_account_rows.add (row);
        }
    }

    private void refresh_total_row () {
        this.total_row.subtitle = format_size (MailSession.total_storage_bytes (this.store));
    }

    private static string cache_subtitle (Account account) {
        return "%s · %s".printf (format_size (MailSession.account_storage_bytes (account)), account.kind.label ());
    }

    private async void confirm_reset (Account account, Adw.ActionRow row) {
        var size = format_size (MailSession.account_storage_bytes (account));
        var dialog = new Adw.AlertDialog (
            _("Reset “%s”?").printf (account.display_name),
            _("This deletes Letter’s local library for this account (%s). Messages stay on the server. The next sync rebuilds headers and recent bodies from scratch. Use this if the account is damaged or stuck.").printf (size)
        );
        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("reset", _("Reset Local Library"));
        dialog.set_response_appearance ("reset", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.default_response = "cancel";
        dialog.close_response = "cancel";

        var response = yield dialog.choose (this, null);
        if (response != "reset")
            return;

        var session = this.host?.peek_session ();
        if (session == null) {
            add_toast (new Adw.Toast (_("Open a Letter window first, then try again.")) {
                timeout = 5,
            });
            return;
        }

        row.sensitive = false;
        try {
            yield session.reset_account_storage (account);
            this.host?.rebuild_account (account);
            row.subtitle = cache_subtitle (account);
            refresh_total_row ();
            add_toast (new Adw.Toast (_("Local library cleared. Letter is rebuilding “%s”.").printf (account.display_name)) {
                timeout = 5,
            });
        } catch (Error e) {
            add_toast (new Adw.Toast (e.message) {
                timeout = 5,
            });
        } finally {
            row.sensitive = true;
        }
    }

    private static Adw.ActionRow count_row (string title, uint count) {
        var row = new Adw.ActionRow () {
            title = title,
            subtitle = count.to_string (),
        };
        row.sensitive = false;
        return row;
    }

    private void on_preview_sound () {
        Utils.play_notification_sound (this.settings.get_string ("notification-sound"));
    }

    private uint sound_choice_index (string choice) {
        if (choice == "none")
            return SOUND_SILENT;
        if (choice == "message-new-email")
            return 0;
        if (Utils.notification_sound_is_file (choice))
            return SOUND_CUSTOM;
        for (uint i = 0; i < SOUND_IDS.length; i++) {
            if (SOUND_IDS[i] == choice)
                return i;
        }
        return 0;
    }

    private void refresh_sound_row () {
        this.updating_sound = true;
        this.sound_row.selected = sound_choice_index (this.settings.get_string ("notification-sound"));
        this.updating_sound = false;
        update_sound_subtitle ();
    }

    private void update_sound_subtitle () {
        var choice = this.settings.get_string ("notification-sound");
        if (Utils.notification_sound_is_file (choice)) {
            var path = Utils.notification_sound_filename (choice);
            this.sound_row.subtitle = path != null
                ? File.new_for_path (path).get_basename ()
                : _("Custom file…");
        } else if (choice == "none")
            this.sound_row.subtitle = _("No notification sound.");
        else
            this.sound_row.subtitle = _("Played with new-mail alerts.");
    }

    private async void on_sound_selected () {
        if (this.updating_sound)
            return;

        var selected = this.sound_row.selected;
        if (selected == SOUND_SILENT) {
            this.settings.set_string ("notification-sound", "none");
            update_sound_subtitle ();
            return;
        }

        if (selected == SOUND_CUSTOM) {
            var picked = yield pick_custom_sound ();
            if (picked == null) {
                refresh_sound_row ();
                return;
            }
            this.settings.set_string ("notification-sound", picked);
            update_sound_subtitle ();
            return;
        }

        if (selected < SOUND_IDS.length) {
            this.settings.set_string ("notification-sound", SOUND_IDS[selected]);
            update_sound_subtitle ();
        }
    }

    private async string? pick_custom_sound () {
        var audio = new Gtk.FileFilter () {
            name = _("Audio files"),
        };
        audio.add_mime_type ("audio/ogg");
        audio.add_mime_type ("audio/x-vorbis+ogg");
        audio.add_mime_type ("audio/vorbis");
        audio.add_mime_type ("audio/flac");
        audio.add_mime_type ("audio/x-flac");
        audio.add_mime_type ("audio/wav");
        audio.add_mime_type ("audio/x-wav");
        audio.add_mime_type ("audio/mpeg");
        audio.add_pattern ("*.ogg");
        audio.add_pattern ("*.oga");
        audio.add_pattern ("*.wav");
        audio.add_pattern ("*.flac");
        audio.add_pattern ("*.mp3");

        var all = new Gtk.FileFilter () {
            name = _("All files"),
        };
        all.add_pattern ("*");

        var filters = new ListStore (typeof (Gtk.FileFilter));
        filters.append (audio);
        filters.append (all);

        var dialog = new Gtk.FileDialog () {
            title = _("Choose a sound"),
            filters = filters,
            default_filter = audio,
        };
        var stored = this.settings.get_string ("notification-sound");
        if (Utils.notification_sound_is_file (stored)) {
            var current = Utils.notification_sound_filename (stored);
            if (current != null) {
                var file = File.new_for_path (current);
                dialog.initial_file = file;
                var parent = file.get_parent ();
                if (parent != null)
                    dialog.initial_folder = parent;
            }
        }

        try {
            var file = yield dialog.open (this.get_root () as Gtk.Window, null);
            return file.get_uri ();
        } catch (Error e) {
            if (e is IOError.CANCELLED || e is Gtk.DialogError.DISMISSED)
                return null;
            add_toast (new Adw.Toast (e.message) {
                timeout = 4,
            });
            return null;
        }
    }
}
