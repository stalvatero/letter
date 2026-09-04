public class Mail.PreferencesDialog : Adw.PreferencesDialog {
    private AccountStore store;
    private Window? host;
    private Adw.PreferencesGroup cache_group;
    private Adw.ActionRow total_row;
    private Adw.ComboRow sound_row;
    private Adw.ComboRow interval_row;
    private Adw.ComboRow cache_days_row;
    private GenericArray<Gtk.ToggleButton> section_chips = new GenericArray<Gtk.ToggleButton> ();
    private Settings settings;
    private SignatureStore signatures;
    private Adw.PreferencesGroup accounts_group;
    private GenericArray<Adw.ActionRow> account_rows = new GenericArray<Adw.ActionRow> ();
    private bool updating_sound;

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

        var page = new Adw.PreferencesPage () {
            title = _("General"),
            icon_name = "mail-unread-symbolic",
        };

        var integration = new Adw.PreferencesGroup () {
            title = _("GNOME integration"),
            description = _("Letter reads the same Evolution Data Server used by Calendar and Contacts, and the same GNOME Online Accounts for Google, Microsoft 365, and IMAP."),
        };

        integration.add (count_row (_("Mail accounts"), store.items.get_n_items ()));
        integration.add (count_row (_("Calendars"), store.calendar_count));
        integration.add (count_row (_("Address books"), store.contact_count));

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
        reading.add (pane_row);

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
        reading.add (read_row);

        var conversation_row = new Adw.SwitchRow () {
            title = _("Conversations"),
            subtitle = _("Group related messages into threads."),
            active = this.settings.get_boolean ("conversation-view"),
        };
        conversation_row.notify["active"].connect (() => {
            this.settings.set_boolean ("conversation-view", conversation_row.active);
        });
        reading.add (conversation_row);

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
        });
        notifications.add (notify_row);

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
        notifications.add (this.sound_row);

        var sync = new Adw.PreferencesGroup () {
            title = _("Synchronization"),
            description = _("Headers stay local for every folder. Bodies and attachments are kept only for the period you choose. The first sync can take a while; after that, folders stay up to date."),
        };

        this.interval_row = new Adw.ComboRow () {
            title = _("Check for new mail"),
            subtitle_lines = 2,
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
        sync.add (this.interval_row);

        this.cache_days_row = new Adw.ComboRow () {
            title = _("Download message bodies"),
            subtitle_lines = 2,
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
        sync.add (this.cache_days_row);

        this.cache_group = new Adw.PreferencesGroup () {
            title = _("Local library"),
            description = _("Letter stores headers and recent bodies itself. At startup it trims bodies outside your download window. Clearing an account removes only that local copy; mail stays on the server."),
        };
        this.total_row = new Adw.ActionRow () {
            title = _("Disk used"),
            sensitive = false,
        };
        this.cache_group.add (this.total_row);
        fill_cache_accounts ();

        var accounts = new Adw.PreferencesGroup () {
            title = _("Accounts"),
            description = _("Add or remove providers in GNOME Settings. Changes appear here automatically."),
        };
        this.accounts_group = accounts;

        var settings_row = new Adw.ActionRow () {
            title = _("Add Account"),
            subtitle = _("Google, Microsoft 365, Exchange, IMAP"),
            activatable = true,
        };
        settings_row.add_prefix (new Gtk.Image.from_icon_name ("list-add-symbolic"));
        settings_row.add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
        settings_row.activated.connect (() => Utils.open_online_accounts ());
        accounts.add (settings_row);
        fill_mail_accounts ();
        this.store.changed.connect (fill_mail_accounts);

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
        deps_group.add (deps_row);

        var chips = new Adw.WrapBox () {
            hexpand = true,
            child_spacing = 8,
            line_spacing = 8,
            justify = Adw.JustifyMode.NONE,
            wrap_policy = Adw.WrapPolicy.NATURAL,
        };
        add_section_chip (chips, _("GNOME integration"), integration);
        add_section_chip (chips, _("Reading"), reading);
        add_section_chip (chips, _("Notifications"), notifications);
        add_section_chip (chips, _("Synchronization"), sync);
        add_section_chip (chips, _("Local library"), this.cache_group);
        add_section_chip (chips, _("Accounts"), accounts);
        add_section_chip (chips, _("Dependencies"), deps_group);

        var nav = new Adw.PreferencesGroup ();
        nav.add_css_class ("filter-nav");
        nav.add (chips);
        page.add (nav);
        page.add (integration);
        page.add (reading);
        page.add (notifications);
        page.add (sync);
        page.add (this.cache_group);
        page.add (accounts);
        page.add (deps_group);

        add (page);
        widen_page_content (page, PAGE_CONTENT_WIDTH);
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

    private void add_section_chip (Adw.WrapBox chips, string label, Adw.PreferencesGroup group) {
        var chip = new Gtk.ToggleButton.with_label (label) {
            valign = Gtk.Align.CENTER,
        };
        chip.add_css_class ("filter-chip");
        chip.add_css_class ("flat");
        if (this.section_chips.length > 0)
            chip.group = this.section_chips[0];
        chip.toggled.connect (() => {
            if (chip.active)
                scroll_to_group (group);
        });
        this.section_chips.add (chip);
        chips.append (chip);
    }

    private void scroll_to_group (Adw.PreferencesGroup group) {
        Idle.add (() => {
            var scrolled = find_scrolled (group);
            if (scrolled == null)
                return Source.REMOVE;

            Graphene.Rect bounds;
            if (!group.compute_bounds (scrolled, out bounds))
                return Source.REMOVE;

            var adj = scrolled.get_vadjustment ();
            var target = adj.value + bounds.origin.y;
            var max_scroll = adj.upper - adj.page_size;
            if (max_scroll < adj.lower)
                max_scroll = adj.lower;
            if (target < adj.lower)
                target = adj.lower;
            if (target > max_scroll)
                target = max_scroll;
            adj.value = target;
            return Source.REMOVE;
        });
    }

    private static Gtk.ScrolledWindow? find_scrolled (Gtk.Widget widget) {
        Gtk.Widget? current = widget;
        while (current != null) {
            var scrolled = current as Gtk.ScrolledWindow;
            if (scrolled != null)
                return scrolled;
            current = current.get_parent ();
        }
        return null;
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
        var text = _("Keep full messages for this period. Older bodies are removed at startup; headers stay for search.");
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
        for (uint i = 0; i < this.account_rows.length; i++)
            this.accounts_group.remove (this.account_rows[i]);
        this.account_rows = new GenericArray<Adw.ActionRow> ();

        for (uint i = 0; i < this.store.items.get_n_items (); i++) {
            var account = this.store.items.get_item (i) as Account;
            if (account == null || !account.has_mail || account.kind == AccountKind.LOCAL)
                continue;

            var row = new Adw.ActionRow () {
                title = account.display_name,
                subtitle = account.email != null && account.email.length > 0
                    ? account.email
                    : account.kind.label (),
            };
            var icon = Utils.account_brand_image (account, 28);
            icon.valign = Gtk.Align.CENTER;
            row.add_prefix (icon);

            var edit = new Gtk.Button.with_label (_("Edit")) {
                valign = Gtk.Align.CENTER,
                tooltip_text = _("Open this account in GNOME Settings"),
            };
            edit.add_css_class ("flat");
            var captured = account;
            edit.clicked.connect (() => {
                if (captured.goa_id != null && captured.goa_id.length > 0)
                    Utils.open_online_account (captured.goa_id);
                else
                    Utils.open_online_accounts ();
            });

            var firms = new Gtk.Button.with_label (_("Signatures")) {
                valign = Gtk.Align.CENTER,
            };
            firms.add_css_class ("flat");
            firms.clicked.connect (() => {
                push_subpage (new SignatureListPage (captured, this.signatures));
            });

            row.add_suffix (edit);
            row.add_suffix (firms);
            this.accounts_group.add (row);
            this.account_rows.add (row);
        }
    }

    private void fill_cache_accounts () {
        refresh_total_row ();
        for (uint i = 0; i < this.store.items.get_n_items (); i++) {
            var account = this.store.items.get_item (i) as Account;
            if (account == null || account.kind == AccountKind.LOCAL || account.source_uid == null)
                continue;

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
            this.cache_group.add (row);
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
