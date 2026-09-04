[GtkTemplate (ui = "/io/github/stalvatero/Letter/window.ui")]
public class Mail.Window : Adw.ApplicationWindow {
    static construct {
        typeof (SearchField).ensure ();
    }
    private const int ACCOUNT_RAIL_WIDTH = 56;
    private const int ACCOUNT_PANE_MIN = 220;
    private const int ACCOUNT_PANE_MAX = 320;
    private const int FOLDER_PANE_MIN = 200;
    private const int FOLDER_PANE_MAX = 520;
    private const int MESSAGE_PANE_MIN = 260;
    private const int MESSAGE_PANE_MAX = 560;
    private const int WINDOW_MIN_WIDTH = 800;
    private const int WINDOW_MIN_HEIGHT = 520;

    [GtkChild]
    private unowned Adw.ToastOverlay toast_overlay;
    [GtkChild]
    private unowned Adw.OverlaySplitView folder_split;
    [GtkChild]
    private unowned Gtk.Box account_rail;
    [GtkChild]
    private unowned Gtk.Button account_rail_add;
    [GtkChild]
    private unowned Gtk.Box account_rail_list;
    [GtkChild]
    private unowned Adw.ToolbarView account_pane;
    [GtkChild]
    private unowned Adw.HeaderBar account_header;
    [GtkChild]
    private unowned Adw.Bin sidebar_bin;
    [GtkChild]
    private unowned Adw.StatusPage no_accounts_page;
    [GtkChild]
    private unowned Gtk.Paned content_split;
    [GtkChild]
    private unowned Gtk.ToggleButton sidebar_button;
    [GtkChild]
    private unowned Adw.WindowTitle folder_title;
    [GtkChild]
    private unowned Adw.Bin folder_bin;
    [GtkChild]
    private unowned Adw.StatusPage no_folders_page;
    [GtkChild]
    private unowned Adw.WindowTitle conversation_title;
    [GtkChild]
    private unowned Gtk.ToggleButton unread_filter_button;
    [GtkChild]
    private unowned Gtk.ToggleButton conversation_button;
    [GtkChild]
    private unowned SearchField message_search;
    [GtkChild]
    private unowned Gtk.MenuButton menu_button;
    [GtkChild]
    private unowned Gtk.Paned message_split;
    [GtkChild]
    private unowned Adw.Bin list_bin;
    [GtkChild]
    private unowned Adw.StatusPage conversation_page;
    [GtkChild]
    private unowned Adw.Bin reader_bin;
    [GtkChild]
    private unowned Adw.StatusPage reader_page;
    [GtkChild]
    private unowned Adw.Spinner conversation_sync_spinner;
    [GtkChild]
    private unowned Gtk.Box folder_status_bar;
    [GtkChild]
    private unowned Gtk.Label folder_status_label;

    private Settings settings;
    private Gtk.ListBox account_list;
    private Gtk.ListBox folder_list;
    private Gtk.ListView message_list;
    private GLib.ListStore message_store;
    private Gtk.MultiSelection message_selection;
    private uint selection_anchor = Gtk.INVALID_LIST_POSITION;
    private Gtk.ScrolledWindow account_scrolled;
    private Gtk.ScrolledWindow folder_scrolled;
    private Gtk.ScrolledWindow message_scrolled;
    private Gtk.Box list_pane;
    private Adw.Bin list_body;
    private Gtk.Revealer search_banner;
    private MailSession? mail_session;
    private Account? selected_account;
    private bool selecting_account;
    private Folder? selected_folder;
    private Folder? bookmarks_folder;
    private MessageReader message_reader;
    private Gtk.Box reader_pane;
    private Gtk.Revealer thread_revealer;
    private Gtk.ScrolledWindow thread_scroll;
    private Gtk.ListBox thread_list;
    private Gtk.Box? thread_action_bar;
    private bool restoring_thread;
    private uint thread_scroll_source;
    private Cancellable? folder_cancellable;
    private Cancellable? body_cancellable;
    private Cancellable? idle_cancellable;
    private bool clamping_pane;
    private bool clamping_message_pane;
    private Adw.SpinnerPaintable folder_spinner;
    private Adw.SpinnerPaintable conversation_spinner;
    private HashTable<string, GenericArray<Message>> message_cache;
    private HashTable<string, GenericArray<Folder>> folder_tree_cache;
    private Gtk.PopoverMenu? context_menu;
    private SimpleActionGroup? context_actions;
    private Gtk.Widget? context_host;
    private string? open_message_uid;
    private MessageContent? open_content;
    private Message? open_message;
    private Conversation? open_conversation;
    private uint sync_source;
    private bool sync_pump_running;
    private bool mailbox_bootstrapping;
    private bool folder_tree_needs_refresh;
    private bool continue_startup_after_tree;
    private bool warming_trees;
    private HashTable<string, uint8> notified_uids;
    private GenericArray<MailSyncJob> sync_jobs;
    private bool restoring_selection;
    private string? pending_select_uid;
    private bool tearing_down;
    private HashTable<string, uint8> hidden_uids;
    private HashTable<string, uint8> collapsed_folders;
    private Gtk.SizeGroup account_header_sizes;
    private Gtk.SizeGroup account_row_sizes;
    private uint sync_status_token;
    private bool unread_only;
    private bool conversation_view;
    private uint conversation_index_source;
    private uint mark_seen_source;
    private int64 last_full_align;
    private const int FULL_ALIGN_SECONDS = 300;
    private const int SYNC_KIND_TREE = 0;
    private const int SYNC_KIND_HEADERS = 1;
    private const int SYNC_KIND_BODIES = 2;
    private const int SYNC_KIND_CACHE_ALIGN = 3;
    private const int RANK_NEW_MAIL = 10;
    private const int RANK_SELECTED_HEADERS = 20;
    private const int RANK_SELECTED_BODIES = 30;
    private const int RANK_TREE = 40;
    private const int RANK_BACKGROUND = 100;
    private const int RANK_CACHE = 150;
    private const int RANK_CACHE_ALIGN = 500;
    private SearchQuery search_query = new SearchQuery ();
    private string search_text = "";
    private GenericArray<string> search_tokens = new GenericArray<string> ();
    private uint search_source;
    private GenericArray<Message>? search_results;
    private uint search_generation;
    private bool clearing_search;
    private const int SEARCH_LIMIT = 400;
    private const int SEARCH_SCAN_YIELD = 400;

    private const ActionEntry[] WINDOW_ACTIONS = {
        { "toggle-sidebar", on_toggle_sidebar },
        { "compose", on_compose },
        { "refresh", on_refresh },
        { "search", on_search },
        { "reply", on_reply },
        { "reply-all", on_reply_all },
        { "forward", on_forward },
        { "send-again", on_send_again },
        { "move", on_move },
        { "archive", on_archive },
        { "delete", on_delete },
        { "mark-unread", on_mark_unread },
        { "mark-read", on_mark_read },
        { "bookmark", on_bookmark },
        { "mark-important", on_mark_important },
        { "mark-spam", on_mark_spam },
        { "print", on_print },
        { "zoom-in", on_zoom_in },
        { "zoom-out", on_zoom_out },
        { "zoom-reset", on_zoom_reset },
        { "fullscreen", on_fullscreen, null, "false" },
    };

    private enum ComposeKind {
        REPLY,
        REPLY_ALL,
        FORWARD,
        SEND_AGAIN
    }

    public Window (Application app) {
        Object (application: app);

        this.settings = new Settings (Config.APP_ID);
        add_action_entries (WINDOW_ACTIONS, this);
        Utils.add_mail_letter_shortcuts (this);
        set_message_actions_enabled (false);
        notify["fullscreened"].connect (sync_fullscreen_action);
        bind_primary_menu ();

        if (Config.PROFILE == "development")
            add_css_class ("devel");

        this.title = Utils.app_display_name ();
        this.conversation_title.title = Utils.app_display_name ();

        default_width = this.settings.get_int ("window-width")
            .clamp (WINDOW_MIN_WIDTH, 4000);
        default_height = this.settings.get_int ("window-height")
            .clamp (WINDOW_MIN_HEIGHT, 4000);
        maximized = this.settings.get_boolean ("window-maximized");
        width_request = WINDOW_MIN_WIDTH;
        height_request = WINDOW_MIN_HEIGHT;
        this.folder_split.show_sidebar = true;
        this.sidebar_button.active = this.settings.get_boolean ("show-folder-sidebar");
        this.sidebar_button.toggled.connect (() => {
            apply_account_sidebar (this.sidebar_button.active);
        });
        apply_account_sidebar (this.sidebar_button.active);
        this.content_split.position = this.settings.get_int ("folder-pane-width")
            .clamp (FOLDER_PANE_MIN, FOLDER_PANE_MAX);
        this.content_split.notify["position"].connect (on_folder_pane_resized);
        this.message_split.position = this.settings.get_int ("message-pane-width")
            .clamp (MESSAGE_PANE_MIN, MESSAGE_PANE_MAX);
        this.message_split.notify["position"].connect (on_message_pane_resized);
        this.settings.changed["reading-pane"].connect (apply_reading_pane);
        apply_reading_pane ();

        this.folder_spinner = new Adw.SpinnerPaintable (this.no_folders_page);
        this.conversation_spinner = new Adw.SpinnerPaintable (this.conversation_page);
        this.message_cache = new HashTable<string, GenericArray<Message>> (str_hash, str_equal);
        this.folder_tree_cache = new HashTable<string, GenericArray<Folder>> (str_hash, str_equal);
        this.hidden_uids = new HashTable<string, uint8> (str_hash, str_equal);
        this.collapsed_folders = new HashTable<string, uint8> (str_hash, str_equal);
        this.account_header_sizes = new Gtk.SizeGroup (Gtk.SizeGroupMode.VERTICAL);
        this.account_row_sizes = new Gtk.SizeGroup (Gtk.SizeGroupMode.VERTICAL);
        foreach (var key in this.settings.get_strv ("collapsed-folders")) {
            if (key.length > 0)
                this.collapsed_folders.set (key, 1);
        }
        this.notified_uids = new HashTable<string, uint8> (str_hash, str_equal);
        this.sync_jobs = new GenericArray<MailSyncJob> ();
        this.message_reader = new MessageReader ();
        this.message_reader.set_contacts (app.contacts);
        this.message_reader.invitation_respond.connect ((invitation, status) => {
            respond_invitation.begin (invitation, status);
        });
        this.thread_list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.MULTIPLE,
            hexpand = true,
            show_separators = false,
            activate_on_single_click = false,
        };
        this.thread_list.add_css_class ("thread-list");
        this.thread_list.row_selected.connect (on_thread_row_selected);
        this.thread_list.row_activated.connect (on_thread_row_activated);
        this.thread_list.selected_rows_changed.connect (on_thread_selection_changed);
        var thread_keys = new Gtk.EventControllerKey ();
        thread_keys.key_pressed.connect ((keyval, keycode, state) => {
            if (keyval == Gdk.Key.a && (state & Gdk.ModifierType.CONTROL_MASK) != 0) {
                this.thread_list.select_all ();
                return true;
            }
            return false;
        });
        this.thread_list.add_controller (thread_keys);
        var thread_title = new Gtk.Label (_("Messages in this conversation")) {
            xalign = 0,
            wrap = true,
            hexpand = true,
            use_markup = false,
        };
        thread_title.add_css_class ("thread-strip-title");
        thread_title.add_css_class ("caption-heading");
        this.thread_action_bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) {
            valign = Gtk.Align.CENTER,
            visible = false,
        };
        this.thread_action_bar.add_css_class ("thread-action-bar");
        this.thread_action_bar.append (thread_action_button ("package-x-generic-symbolic", _("Archive"), "win.archive"));
        this.thread_action_bar.append (thread_action_button ("folder-symbolic", _("Move"), "win.move"));
        this.thread_action_bar.append (thread_action_button ("user-trash-symbolic", _("Delete"), "win.delete"));
        var thread_header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            hexpand = true,
            valign = Gtk.Align.CENTER,
        };
        thread_header.add_css_class ("thread-strip-header");
        thread_header.append (thread_title);
        thread_header.append (this.thread_action_bar);
        this.thread_scroll = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            vscrollbar_policy = Gtk.PolicyType.AUTOMATIC,
            hexpand = true,
            max_content_height = 168,
            propagate_natural_height = true,
            child = this.thread_list,
        };
        var thread_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        thread_box.add_css_class ("thread-strip");
        thread_box.append (thread_header);
        thread_box.append (this.thread_scroll);
        this.thread_revealer = new Gtk.Revealer () {
            child = thread_box,
            transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN,
        };
        this.reader_pane = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        this.reader_pane.append (this.thread_revealer);
        this.reader_pane.append (this.message_reader);

        this.account_list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.SINGLE,
            valign = Gtk.Align.START,
            hexpand = true,
        };
        this.account_list.add_css_class ("navigation-sidebar");
        this.account_list.add_css_class ("account-list");
        this.account_list.row_activated.connect (on_account_activated);

        this.folder_list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.SINGLE,
            valign = Gtk.Align.START,
            hexpand = true,
        };
        this.folder_list.add_css_class ("navigation-sidebar");
        this.folder_list.add_css_class ("folder-list");
        this.folder_list.row_activated.connect (on_folder_activated);
        var folder_keys = new Gtk.EventControllerKey ();
        folder_keys.key_pressed.connect ((keyval, keycode, state) => {
            return on_folder_key_pressed (keyval);
        });
        this.folder_list.add_controller (folder_keys);

        this.message_store = new ListStore (typeof (Conversation));
        this.message_selection = new Gtk.MultiSelection (this.message_store);
        var factory = new Gtk.SignalListItemFactory ();
        factory.setup.connect (on_message_item_setup);
        factory.bind.connect (on_message_item_bind);
        factory.unbind.connect (on_message_item_unbind);
        this.message_list = new Gtk.ListView (this.message_selection, factory) {
            hexpand = true,
            vexpand = true,
            single_click_activate = false,
        };
        this.message_list.add_css_class ("message-list");
        this.message_selection.selection_changed.connect ((pos, n) => {
            on_message_selection_changed ();
        });
        this.message_list.activate.connect (on_message_activated);
        var alt_click = new Gtk.GestureClick () {
            button = Gdk.BUTTON_PRIMARY,
        };
        alt_click.set_propagation_phase (Gtk.PropagationPhase.CAPTURE);
        alt_click.pressed.connect ((n_press, x, y) => {
            var state = alt_click.get_current_event_state ();
            if ((state & Gdk.ModifierType.ALT_MASK) == 0)
                return;
            var position = message_position_at (x, y);
            if (position == Gtk.INVALID_LIST_POSITION)
                return;
            apply_range_selection (position, (state & Gdk.ModifierType.CONTROL_MASK) != 0);
            alt_click.set_state (Gtk.EventSequenceState.CLAIMED);
        });
        this.message_list.add_controller (alt_click);
        var keys = new Gtk.EventControllerKey ();
        keys.key_pressed.connect ((keyval, keycode, state) => {
            if (keyval == Gdk.Key.a && (state & Gdk.ModifierType.CONTROL_MASK) != 0) {
                this.message_selection.select_all ();
                return true;
            }
            return false;
        });
        this.message_list.add_controller (keys);

        this.account_scrolled = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            hexpand = true,
            vexpand = true,
            child = this.account_list,
        };
        this.folder_scrolled = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            hexpand = true,
            vexpand = true,
            child = this.folder_list,
        };
        this.message_scrolled = new Gtk.ScrolledWindow () {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            hexpand = true,
            vexpand = true,
            child = this.message_list,
        };
        var search_bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            hexpand = true,
        };
        search_bar.add_css_class ("search-banner");
        var search_label = new Gtk.Label (_("Search Results")) {
            hexpand = true,
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.END,
        };
        search_label.add_css_class ("heading");
        var close_search = new Gtk.Button.with_label (_("Close Search"));
        close_search.add_css_class ("flat");
        close_search.clicked.connect (on_search_stopped);
        search_bar.append (search_label);
        search_bar.append (close_search);
        this.search_banner = new Gtk.Revealer () {
            child = search_bar,
            transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN,
            hexpand = true,
            reveal_child = false,
        };
        this.list_body = new Adw.Bin () {
            hexpand = true,
            vexpand = true,
            child = this.message_scrolled,
        };
        this.list_pane = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        this.list_pane.append (this.search_banner);
        this.list_pane.append (this.list_body);

        this.unread_filter_button.toggled.connect (on_unread_filter_toggled);
        this.conversation_view = this.settings.get_boolean ("conversation-view");
        this.conversation_button.active = this.conversation_view;
        this.conversation_button.tooltip_text = this.conversation_view
            ? _("Showing conversations")
            : _("Group by conversation");
        this.conversation_button.toggled.connect (on_conversation_toggled);
        this.settings.changed["conversation-view"].connect (on_conversation_view_setting);
        this.message_search.query_changed.connect (on_search_changed);
        this.message_search.stopped.connect (on_search_stopped);
        this.message_search.tooltip_text = _("Search all folders. Filter with contains:, from: and to:");
        this.message_search.bind_contacts (app.contacts);
        this.settings.changed["mark-as-read"].connect (on_mark_as_read_setting);

        app.accounts.changed.connect (on_accounts_changed);
        on_accounts_changed ();

        this.settings.changed["sync-interval"].connect (restart_sync_timer);
        this.settings.changed["body-cache-days"].connect (() => {
            this.mail_session?.reset_prefetch_progress ();
            enqueue_cache_align ();
        });
        restart_sync_timer ();

        close_request.connect (on_close_request);
    }

    private void on_accounts_changed () {
        var app = get_application () as Application;
        if (app == null)
            return;

        var store = app.accounts;
        var previous_uid = this.selected_account?.source_uid ?? this.selected_account?.uid;

        while (this.account_list.get_row_at_index (0) != null)
            this.account_list.remove (this.account_list.get_row_at_index (0));

        var accounts = new GenericArray<Account> ();
        for (uint i = 0; i < store.items.get_n_items (); i++) {
            var account = (Account) store.items.get_item (i);
            if (account.kind == AccountKind.LOCAL)
                continue;
            accounts.add (account);
        }
        accounts.sort ((a, b) => {
            if (a.has_mail != b.has_mail)
                return a.has_mail ? -1 : 1;
            return a.display_name.collate (b.display_name);
        });
        for (uint i = 0; i < accounts.length; i++)
            this.account_list.append (new AccountRow (accounts[i]));

        fill_account_rail ();

        if (this.account_list.get_row_at_index (0) == null) {
            this.sidebar_bin.child = this.no_accounts_page;
            if (store.error_message != null)
                this.no_accounts_page.description = Markup.escape_text (store.error_message);
        } else {
            this.sidebar_bin.child = this.account_scrolled;
        }

        if (store.registry != null && this.mail_session == null) {
            this.mail_session = new MailSession (store.registry);
            this.mail_session.folder_changed.connect (on_camel_folder_changed);
            this.mail_session.message_sent.connect (on_message_sent);
            this.mail_session.draft_saved.connect (on_draft_saved);
            this.mail_session.transfer_failed.connect (on_transfer_failed);
            bind_reader_mailbox ();
        }

        restore_account_selection (previous_uid);
        preload_folder_trees_from_disk ();
        warm_other_account_trees.begin ();
    }

    public void show_toast (string message) {
        this.toast_overlay.add_toast (new Adw.Toast (message) {
            timeout = 5,
        });
    }

    public MailSession? peek_session () {
        return this.mail_session;
    }

    private void bind_reader_mailbox () {
        var account = this.selected_account;
        Identity? identity = null;
        if (this.mail_session != null && account != null)
            identity = this.mail_session.get_identity (account);
        this.message_reader.set_mailbox (account, identity);
    }

    public void handle_notification (string kind, string token) {
        present ();
        var app = get_application () as Application;
        if (app != null) {
            app.notifier.withdraw (token);
            app.withdraw_notification (app.notifier.remember (token));
        }

        string account_uid;
        string folder_name;
        string uid;
        if (!parse_notification_token (token, out account_uid, out folder_name, out uid))
            return;

        var account = this.selected_account;
        if (account == null || (account.source_uid ?? account.uid) != account_uid)
            return;

        var folder = folder_by_full_name (folder_name);
        var message = folder != null ? find_cached_message (account, folder, uid) : null;
        if (folder == null || message == null)
            return;

        if (kind == "open") {
            open_notified_message (folder, uid);
            return;
        }

        this.open_conversation = conversation_for_message (message);
        this.open_message = message;
        this.open_message_uid = message.uid;
        if (kind == "archive")
            archive_open_message.begin ();
        else if (kind == "delete")
            delete_open_message.begin ();
    }

    public void rebuild_account (Account account) {
        var prefix = "%s\n".printf (account.source_uid ?? account.uid);
        var message_keys = new GenericArray<string> ();
        this.message_cache.foreach ((key, messages) => {
            if (key.has_prefix (prefix))
                message_keys.add (key);
        });
        for (uint i = 0; i < message_keys.length; i++)
            this.message_cache.remove (message_keys[i]);

        var hidden_keys = new GenericArray<string> ();
        this.hidden_uids.foreach ((key, value) => {
            if (key.has_prefix (prefix))
                hidden_keys.add (key);
        });
        for (uint i = 0; i < hidden_keys.length; i++)
            this.hidden_uids.remove (hidden_keys[i]);

        this.idle_cancellable?.cancel ();
        this.idle_cancellable = new Cancellable ();
        this.sync_jobs = new GenericArray<MailSyncJob> ();

        if (this.selected_account != null && accounts_are_same (this.selected_account, account))
            load_folders.begin (account);
    }

    private void restore_account_selection (string? previous_uid) {
        if (this.account_list.get_row_at_index (0) == null)
            return;

        var wanted = previous_uid;
        if (wanted == null || wanted.length == 0)
            wanted = this.settings.get_string ("last-account-uid");

        AccountRow? match = null;
        AccountRow? preferred = null;
        AccountRow? first = null;

        for (int i = 0; this.account_list.get_row_at_index (i) != null; i++) {
            var row = this.account_list.get_row_at_index (i) as AccountRow;
            if (row == null)
                continue;

            if (first == null)
                first = row;
            if (preferred == null && row.account.kind != AccountKind.LOCAL)
                preferred = row;
            if (account_matches_uid (row.account, wanted))
                match = row;
        }

        var row = match ?? preferred ?? first;
        if (row == null)
            return;

        this.account_list.select_row (row);
        if (this.selected_account != null && accounts_are_same (this.selected_account, row.account)) {
            this.selected_account = row.account;
            sync_account_selection (row.account);
            return;
        }

        on_account_activated (row);
    }

    private static bool accounts_are_same (Account a, Account b) {
        return account_matches_uid (a, b.uid)
            || account_matches_uid (a, b.source_uid)
            || account_matches_uid (a, b.email)
            || account_matches_uid (a, b.goa_id);
    }

    private static bool account_matches_uid (Account account, string? uid) {
        if (uid == null || uid.length == 0)
            return false;

        return account.uid == uid
            || account.source_uid == uid
            || account.email == uid
            || account.goa_id == uid;
    }

    private bool is_current_account (Account account) {
        return this.selected_account != null && accounts_are_same (this.selected_account, account);
    }

    private bool is_showing_list () {
        return this.list_bin.child == this.list_pane && this.list_body.child == this.message_scrolled;
    }

    private bool is_searching {
        get {
            return this.search_text.length > 0;
        }
    }

    private GenericArray<Conversation> listed_conversations (GenericArray<Conversation> conversations) {
        if (!this.unread_only)
            return conversations;

        var listed = new GenericArray<Conversation> ();
        for (uint i = 0; i < conversations.length; i++) {
            var conversation = conversations[i];
            if (conversation.seen
                && (this.open_conversation == null || conversation.id != this.open_conversation.id))
                continue;
            listed.add (conversation);
        }
        return listed;
    }

    private GenericArray<Message> extra_thread_messages (Account account, Folder current) {
        var extras = new GenericArray<Message> ();
        var folders = folders_from_tree ();
        for (uint i = 0; i < folders.length; i++) {
            var folder = folders[i];
            if (folder.full_name == current.full_name)
                continue;
            if (folder.kind == FolderKind.JUNK || folder.kind == FolderKind.TRASH
                || folder.is_virtual_view)
                continue;
            var cached = this.message_cache.get (message_cache_key (account, folder));
            if (cached == null)
                continue;
            for (uint j = 0; j < cached.length; j++)
                extras.add (cached[j]);
        }
        return extras;
    }

    private GenericArray<Folder> mailbox_sync_folders () {
        mark_inbox_tree_on_sidebar ();
        var folders = folders_from_tree (false);
        folders.sort ((a, b) => {
            int rank = mailbox_sync_rank (a) - mailbox_sync_rank (b);
            if (rank != 0)
                return rank;
            if (a.kind == FolderKind.INBOX && b.kind != FolderKind.INBOX)
                return -1;
            if (b.kind == FolderKind.INBOX && a.kind != FolderKind.INBOX)
                return 1;
            return a.name.collate (b.name);
        });
        return folders;
    }

    private static int mailbox_sync_rank (Folder folder) {
        if (folder.kind == FolderKind.INBOX)
            return 0;
        if (folder.watch_new_mail)
            return 1;

        switch (folder.kind) {
            case FolderKind.SENT:
                return 2;
            case FolderKind.DRAFTS:
                return 3;
            case FolderKind.NORMAL:
                return 4;
            case FolderKind.ARCHIVE:
            case FolderKind.ALL:
                return 5;
            case FolderKind.JUNK:
                return 6;
            case FolderKind.TRASH:
                return 7;
            default:
                return 4;
        }
    }

    private void store_folder_messages (
        Account account,
        Folder folder,
        GenericArray<Message> messages,
        HashTable<string, uint8>? known_uids = null
    ) {
        var key = message_cache_key (account, folder);
        var previous = this.message_cache.get (key);
        var known = known_uids;
        if (known == null) {
            known = new HashTable<string, uint8> (str_hash, str_equal);
            if (previous != null) {
                for (uint i = 0; i < previous.length; i++)
                    known.set (previous[i].uid, 1);
            }
        }
        this.message_cache.set (key, messages);
        int total;
        int unread;
        message_counts (messages, out total, out unread);
        folder.unread = unread;
        folder.total = total;
        refresh_folder_badge (folder);
        if (is_current_folder (folder) && this.search_text.length == 0)
            display_messages (account, folder, messages);
        else
            queue_conversation_refresh ();
        sync_bookmarks_folder ();
        sync_important_markers ();
        if (known.length > 0)
            notify_new_arrivals (account, folder, messages, known);
    }

    private bool folder_skips_body_prefetch (Folder folder) {
        return folder.kind == FolderKind.JUNK || folder.kind == FolderKind.TRASH;
    }

    private async void hydrate_folder_headers (Account account, Folder folder, Cancellable cancellable) {
        if (this.mail_session == null || folder.is_virtual_view)
            return;

        var key = message_cache_key (account, folder);
        var existing = this.message_cache.get (key);
        if (existing != null && existing.length > 0)
            return;

        try {
            var cached = yield this.mail_session.list_messages (
                account,
                folder,
                false,
                cancellable,
                is_current_folder (folder)
            );
            if (cancellable.is_cancelled () || !is_current_account (account))
                return;
            var live = this.message_cache.get (key);
            if (live != null && live.length > 0)
                return;
            store_folder_messages (account, folder, cached);
        } catch (Error e) {
            if (e is IOError.CANCELLED)
                return;
            debug ("Mailbox headers %s: %s", folder.name, e.message);
        }
    }

    private async void align_folder_with_server (
        Account account,
        Folder folder,
        Cancellable cancellable,
        bool high = false
    ) {
        if (this.mail_session == null)
            return;

        var key = message_cache_key (account, folder);
        var cached = this.message_cache.get (key);
        var known = snapshot_uids (cached);
        var current = is_current_folder (folder);
        var t0 = Utils.sync_tick ();
        Utils.sync_log ("Graph refresh_info “%s” (watch=%s high=%s)".printf (
            folder.name,
            current ? "current" : "bg",
            high ? "yes" : "no"
        ));
        try {
            var messages = yield this.mail_session.list_messages (
                account,
                folder,
                true,
                cancellable,
                current,
                cached,
                high
            );
            if (cancellable.is_cancelled () || !is_current_account (account))
                return;
            store_folder_messages (account, folder, messages, known);
            Utils.sync_log ("Graph refresh_info “%s” ok %s → %u headers".printf (
                folder.name,
                Utils.sync_ms (t0),
                messages.length
            ));
        } catch (Error e) {
            if (e is IOError.CANCELLED)
                return;
            Utils.sync_log ("Graph refresh_info “%s” FAILED %s: %s".printf (folder.name, Utils.sync_ms (t0), e.message));
            debug ("Mailbox sync %s: %s", folder.name, e.message);
        }
    }

    private int background_header_rank (Folder folder) {
        return RANK_BACKGROUND + mailbox_sync_rank (folder) * 2;
    }

    private int background_body_rank (Folder folder) {
        return RANK_BACKGROUND + mailbox_sync_rank (folder) * 2 + 1;
    }

    private Folder? sync_job_folder (MailSyncJob job) {
        if (job.folder == null)
            return null;

        var folders = folders_from_tree ();
        for (uint i = 0; i < folders.length; i++) {
            if (folders[i].full_name == job.folder.full_name)
                return folders[i];
        }
        return job.folder;
    }

    private void enqueue_sync_job (int kind, Folder? folder, int rank) {
        var name = folder != null ? folder.full_name : "";
        for (uint i = 0; i < this.sync_jobs.length; i++) {
            var job = this.sync_jobs[i];
            var job_name = job.folder != null ? job.folder.full_name : "";
            if (job.kind != kind || job_name != name)
                continue;
            if (rank < job.rank)
                job.rank = rank;
            if (folder != null)
                job.folder = folder;
            return;
        }

        var job = new MailSyncJob ();
        job.kind = kind;
        job.folder = folder;
        job.rank = rank;
        this.sync_jobs.add (job);
    }

    private void demote_selected_sync_jobs (Folder keep) {
        for (uint i = 0; i < this.sync_jobs.length; i++) {
            var job = this.sync_jobs[i];
            if (job.folder == null || job.folder.full_name == keep.full_name)
                continue;
            if (job.kind == SYNC_KIND_HEADERS && job.rank == RANK_SELECTED_HEADERS)
                job.rank = background_header_rank (job.folder);
            else if (job.kind == SYNC_KIND_BODIES && job.rank == RANK_SELECTED_BODIES)
                job.rank = background_body_rank (job.folder);
        }
    }

    private void boost_folder_sync (Folder folder) {
        if (folder.is_virtual_view)
            return;
        demote_selected_sync_jobs (folder);
        enqueue_sync_job (SYNC_KIND_HEADERS, folder, RANK_SELECTED_HEADERS);
        if (!folder_skips_body_prefetch (folder))
            enqueue_sync_job (SYNC_KIND_BODIES, folder, RANK_SELECTED_BODIES);
        pump_sync.begin ();
    }

    private void enqueue_new_mail_sync () {
        var folders = mailbox_sync_folders ();
        for (uint i = 0; i < folders.length; i++) {
            var folder = folders[i];
            if (folder.watch_new_mail || folder.kind == FolderKind.INBOX)
                enqueue_sync_job (SYNC_KIND_HEADERS, folder, RANK_BACKGROUND);
        }
        pump_sync.begin ();
    }

    private void enqueue_background_after_tree (GenericArray<string> added) {
        var added_set = new HashTable<string, uint8> (str_hash, str_equal);
        for (uint i = 0; i < added.length; i++)
            added_set.set (added[i], 1);

        var inbox = find_folder_kind (FolderKind.INBOX);
        var inbox_name = inbox != null ? inbox.full_name : null;
        var folders = mailbox_sync_folders ();
        Utils.sync_log ("startup background: %u folders, %u new, skip inbox=%s".printf (
            folders.length,
            added.length,
            inbox_name ?? "-"
        ));
        for (uint i = 0; i < folders.length; i++) {
            var folder = folders[i];
            if (folder.is_virtual_view || folder.is_gmail_namespace)
                continue;
            var is_new = added_set.contains (folder.full_name);
            var header_rank = is_new ? RANK_CACHE : RANK_BACKGROUND;
            if (inbox_name == null || folder.full_name != inbox_name)
                enqueue_sync_job (SYNC_KIND_HEADERS, folder, header_rank);
            if (!folder_skips_body_prefetch (folder))
                enqueue_sync_job (SYNC_KIND_BODIES, folder, header_rank + 1);
        }
        enqueue_cache_align ();
        pump_sync.begin ();
        watch_new_mail_folders.begin ();
    }

    private void enqueue_cache_align () {
        var folders = mailbox_sync_folders ();
        for (uint i = 0; i < folders.length; i++) {
            var folder = folders[i];
            if (folder.is_virtual_view || folder.is_gmail_namespace)
                continue;
            if (folder_skips_body_prefetch (folder))
                continue;
            enqueue_sync_job (SYNC_KIND_CACHE_ALIGN, folder, RANK_CACHE_ALIGN);
        }
        pump_sync.begin ();
    }

    private void finish_startup_tree (GenericArray<string> added) {
        if (!this.continue_startup_after_tree)
            return;
        this.continue_startup_after_tree = false;
        enqueue_background_after_tree (added);
    }

    private GenericArray<Folder> reuse_sidebar_folders (
        GenericArray<Folder> incoming,
        GenericArray<string> added
    ) {
        var current = folders_from_tree (false);
        var by_name = new HashTable<string, Folder> (str_hash, str_equal);
        for (uint i = 0; i < current.length; i++)
            by_name.set (current[i].full_name, current[i]);

        var resolved = new GenericArray<Folder> ();
        for (uint i = 0; i < incoming.length; i++) {
            var next = incoming[i];
            var existing = by_name.get (next.full_name);
            if (existing != null) {
                existing.name = next.name;
                existing.indent = next.indent;
                existing.flags = next.flags;
                existing.watch_new_mail = next.watch_new_mail;
                if (next.total >= 0)
                    existing.total = next.total;
                if (next.unread >= 0)
                    existing.unread = next.unread;
                resolved.add (existing);
            } else {
                added.add (next.full_name);
                resolved.add (next);
            }
        }
        return resolved;
    }

    private MailSyncJob? take_best_sync_job () {
        if (this.sync_jobs.length == 0)
            return null;

        uint best = 0;
        for (uint i = 1; i < this.sync_jobs.length; i++) {
            if (this.sync_jobs[i].rank < this.sync_jobs[best].rank)
                best = i;
        }
        var job = this.sync_jobs[best];
        this.sync_jobs.remove_index (best);
        return job;
    }

    private async void run_sync_job (Account account, MailSyncJob job, Cancellable cancellable) {
        if (job.kind == SYNC_KIND_TREE) {
            if (this.mail_session == null)
                return;
            var token = show_sync_status (_("Checking folders…"));
            try {
                var folders = yield this.mail_session.list_folders (account, null, true);
                if (cancellable.is_cancelled () || !is_current_account (account))
                    return;
                if (folders.length == 0) {
                    finish_startup_tree (new GenericArray<string> ());
                    return;
                }
                var added = new GenericArray<string> ();
                var resolved = reuse_sidebar_folders (folders, added);
                Utils.sync_log ("folder tree compare: %s (%u added)".printf (
                    added.length == 0 ? "unchanged" : "diff",
                    added.length
                ));
                apply_folder_tree (resolved);
                remember_folder_tree (account, resolved);
                mark_inbox_tree_on_sidebar ();
                this.last_full_align = Utils.sync_tick ();
                finish_startup_tree (added);
            } catch (Error e) {
                if (!(e is IOError.CANCELLED))
                    debug ("Folder tree refresh: %s", e.message);
                if (!(e is IOError.CANCELLED) && is_current_account (account))
                    finish_startup_tree (new GenericArray<string> ());
            } finally {
                hide_sync_status (token);
            }
            return;
        }

        var folder = sync_job_folder (job);
        if (folder == null)
            return;

        if (job.kind == SYNC_KIND_HEADERS) {
            if (this.mail_session.folder_has_pending_flags (account, folder))
                return;
            var current = is_current_folder (folder);
            uint token = 0;
            if (current) {
                this.conversation_sync_spinner.visible = true;
                token = show_sync_status (_("Updating “%s”…").printf (folder.name));
            }
            var high = current;
            yield align_folder_with_server (account, folder, cancellable, high);
            if (current)
                this.conversation_sync_spinner.visible = false;
            if (token != 0)
                hide_sync_status (token);
            return;
        }

        if (folder_skips_body_prefetch (folder))
            return;

        if (job.kind == SYNC_KIND_CACHE_ALIGN) {
            yield run_cache_align (account, folder, cancellable);
            return;
        }

        uint token = 0;
        if (is_current_folder (folder))
            token = show_sync_status (_("Downloading messages in “%s”…").printf (folder.name));
        try {
            var listed = this.message_cache.get (message_cache_key (account, folder));
            if (listed == null || listed.length == 0)
                return;
            var days = body_cache_days ();
            var fetched = yield this.mail_session.prefetch_recent (
                account,
                folder,
                listed,
                days,
                cancellable
            );
            if (fetched >= MailSession.PREFETCH_NETWORK_CHUNK)
                enqueue_sync_job (SYNC_KIND_BODIES, folder, job.rank);
        } catch (Error e) {
            if (!(e is IOError.CANCELLED))
                debug ("Prefetch %s: %s", folder.name, e.message);
        } finally {
            if (token != 0)
                hide_sync_status (token);
        }
    }

    private int body_cache_days () {
        var days = this.settings.get_int ("body-cache-days");
        if (days > 0)
            days = days.clamp (60, 365);
        return days;
    }

    private async void run_cache_align (Account account, Folder folder, Cancellable cancellable) {
        try {
            yield hydrate_folder_headers (account, folder, cancellable);
            if (cancellable.is_cancelled () || !is_current_account (account))
                return;

            var listed = this.message_cache.get (message_cache_key (account, folder));
            if (listed == null || listed.length == 0)
                return;

            var days = body_cache_days ();
            yield this.mail_session.prune_stale_bodies (account, folder, listed, days, cancellable);
            if (cancellable.is_cancelled () || !is_current_account (account))
                return;

            enqueue_sync_job (SYNC_KIND_BODIES, folder, RANK_CACHE_ALIGN);
        } catch (Error e) {
            if (!(e is IOError.CANCELLED))
                debug ("Cache align %s: %s", folder.name, e.message);
        }
    }

    private async void pump_sync () {
        if (this.sync_pump_running)
            return;

        var account = this.selected_account;
        if (this.mail_session == null || account == null || account.kind == AccountKind.LOCAL || !account.has_mail)
            return;

        this.sync_pump_running = true;
        var cancellable = this.idle_cancellable ?? new Cancellable ();
        this.idle_cancellable = cancellable;
        try {
            while (!cancellable.is_cancelled ()) {
                var job = take_best_sync_job ();
                if (job == null)
                    break;

                Utils.sync_log ("sync job kind=%d rank=%d folder=%s queue=%u".printf (
                    job.kind,
                    job.rank,
                    job.folder != null ? job.folder.name : "tree",
                    this.sync_jobs.length
                ));
                yield run_sync_job (account, job, cancellable);
                Idle.add (pump_sync.callback);
                yield;
            }
        } finally {
            this.sync_pump_running = false;
        }
    }

    private async void hydrate_remaining (Account account, Cancellable cancellable) {
        var folders = mailbox_sync_folders ();
        for (uint i = 0; i < folders.length; i++) {
            if (cancellable.is_cancelled () || !is_current_account (account))
                break;
            yield hydrate_folder_headers (account, folders[i], cancellable);
            Idle.add (hydrate_remaining.callback);
            yield;
        }
    }

    private async void sync_mailbox (Cancellable cancellable) {
        var account = this.selected_account;
        if (this.mail_session == null || account == null)
            return;

        var current = this.selected_folder;
        var token = show_sync_status (_("Reading mailbox…"));
        try {
            if (current != null)
                yield hydrate_folder_headers (account, current, cancellable);
        } finally {
            hide_sync_status (token);
        }
    }

    private void queue_conversation_refresh () {
        if (!this.conversation_view || this.search_text.length > 0 || this.selected_folder == null)
            return;

        if (this.conversation_index_source != 0)
            Source.remove (this.conversation_index_source);

        this.conversation_index_source = Timeout.add (200, () => {
            this.conversation_index_source = 0;
            redisplay_current_list ();
            return Source.REMOVE;
        });
    }

    private GenericArray<Message> listed_messages (GenericArray<Message> messages) {
        if (!this.unread_only)
            return messages;

        var listed = new GenericArray<Message> ();
        for (uint i = 0; i < messages.length; i++) {
            var message = messages[i];
            if (message.seen && message.uid != this.open_message_uid)
                continue;
            listed.add (message);
        }
        return listed;
    }

    private bool message_matches_search (Message message) {
        if (this.search_query.is_empty)
            return this.search_text.length == 0;

        ensure_search_blob (message);
        return SearchQuery.matches_message (message, this.search_query);
    }

    private static void ensure_search_blob (Message message) {
        if (message.search_blob != null && message.search_blob.length > 0)
            return;

        var blob = new StringBuilder ();
        Utils.append_search_part (blob, message.subject);
        Utils.append_search_part (blob, message.from);
        Utils.append_search_part (blob, message.to);
        Utils.append_search_part (blob, message.cc);
        Utils.append_search_part (blob, message.list_address);
        Utils.append_search_part (blob, message.preview);
        message.search_blob = blob.str;
    }

    private void on_search () {
        this.message_search.grab_focus ();
    }

    private void on_search_changed () {
        if (this.clearing_search)
            return;

        if (this.search_source != 0)
            Source.remove (this.search_source);

        this.search_source = Timeout.add (280, () => {
            this.search_source = 0;
            apply_search_query (this.message_search.query ());
            return Source.REMOVE;
        });
    }

    private void on_search_stopped () {
        if (this.search_source != 0) {
            Source.remove (this.search_source);
            this.search_source = 0;
        }
        this.message_search.clear ();
        apply_search_query (new SearchQuery ());
    }

    private void apply_search_query (SearchQuery query) {
        var key = query.key;
        if (this.search_text == key)
            return;

        this.search_query = query;
        this.search_text = key;
        this.search_tokens = query.highlight_tokens ();
        this.search_generation++;
        if (query.is_empty) {
            this.search_results = null;
            this.search_tokens = new GenericArray<string> ();
            this.search_banner.reveal_child = false;
            highlight_selected_folder ();
            redisplay_current_list ();
            return;
        }

        enter_search_mode ();
        run_global_search.begin ();
    }

    private void enter_search_mode () {
        this.folder_list.unselect_all ();
        this.search_banner.reveal_child = true;
        this.conversation_title.title = _("Search Results");
        this.conversation_title.subtitle = "";
        apply_offline_heading ();
        if (this.list_bin.child != this.list_pane)
            this.list_bin.child = this.list_pane;
    }

    private void clear_search_state () {
        if (this.search_source != 0) {
            Source.remove (this.search_source);
            this.search_source = 0;
        }
        this.search_results = null;
        this.search_query = new SearchQuery ();
        this.search_text = "";
        this.search_tokens = new GenericArray<string> ();
        this.search_generation++;
        this.search_banner.reveal_child = false;
        this.clearing_search = true;
        this.message_search.clear ();
        this.clearing_search = false;
    }

    private async void run_global_search () {
        var account = this.selected_account;
        var query = this.search_text;
        if (this.mail_session == null || account == null || query.length == 0)
            return;

        var generation = this.search_generation;
        var results = new GenericArray<Message> ();
        var folders = folders_from_tree ();
        var pending = new GenericArray<Folder> ();
        var seen = new HashTable<string, uint8> (str_hash, str_equal);
        uint scanned = 0;

        for (uint i = 0; i < folders.length; i++) {
            if (generation != this.search_generation || this.search_text != query)
                return;

            var folder = folders[i];
            var cached = this.message_cache.get (message_cache_key (account, folder));
            if (cached == null || cached.length == 0) {
                if (search_camel_rank (folder) < 1000)
                    pending.add (folder);
                continue;
            }

            for (uint j = 0; j < cached.length; j++) {
                if (message_matches_search (cached[j]))
                    add_search_hit (results, seen, cached[j]);
                scanned++;
                if (scanned % SEARCH_SCAN_YIELD != 0)
                    continue;
                Idle.add (run_global_search.callback);
                yield;
                if (generation != this.search_generation || this.search_text != query)
                    return;
            }
        }

        sort_messages_by_date (results);
        trim_search_results (results);
        if (generation != this.search_generation || this.search_text != query)
            return;

        this.search_results = results;
        if (results.length == 0 && pending.length > 0) {
            show_conversation_loading (
                _("Searching"),
                _("Looking in every folder…")
            );
        } else {
            display_search_results (results);
        }

        if (pending.length == 0)
            return;

        pending.sort ((a, b) => search_camel_rank (a) - search_camel_rank (b));
        var token = show_sync_status (_("Searching remaining folders…"));
        var added_remote = false;
        try {
            for (uint i = 0; i < pending.length; i++) {
                if (generation != this.search_generation || this.search_text != query)
                    break;

                try {
                    var found = yield this.mail_session.search_folder (account, pending[i], this.search_query);
                    if (generation != this.search_generation || this.search_text != query)
                        break;
                    for (uint j = 0; j < found.length; j++) {
                        if (add_search_hit (results, seen, found[j]))
                            added_remote = true;
                    }
                } catch (Error e) {
                    if (e is IOError.CANCELLED)
                        break;
                    debug ("Search %s: %s", pending[i].name, e.message);
                }

                Idle.add (run_global_search.callback);
                yield;
            }
        } finally {
            hide_sync_status (token);
            if (generation == this.search_generation && this.search_text == query) {
                if (added_remote) {
                    sort_messages_by_date (results);
                    trim_search_results (results);
                    this.search_results = results;
                }
                display_search_results (results);
            }
        }
    }

    private static int search_camel_rank (Folder folder) {
        if (folder.is_virtual_view)
            return 1000;
        if (folder.kind == FolderKind.JUNK || folder.kind == FolderKind.TRASH)
            return 1000;
        if (folder.kind == FolderKind.INBOX)
            return 0;
        if (folder.kind == FolderKind.SENT)
            return 1;
        if (folder.kind == FolderKind.DRAFTS)
            return 2;
        if (folder.is_archive_mailbox)
            return 80;
        return 10;
    }

    private static bool add_search_hit (
        GenericArray<Message> results,
        HashTable<string, uint8> seen,
        Message message
    ) {
        var key = "%s\n%s".printf (message.folder_full_name ?? "", message.uid);
        if (seen.contains (key))
            return false;
        seen.set (key, 1);
        results.add (message);
        return true;
    }

    private static void sort_messages_by_date (GenericArray<Message> messages) {
        messages.sort ((a, b) => {
            if (a.date < b.date)
                return 1;
            if (a.date > b.date)
                return -1;
            return 0;
        });
    }

    private static void trim_search_results (GenericArray<Message> results) {
        while (results.length > SEARCH_LIMIT)
            results.remove_index (results.length - 1);
    }

    private void display_search_results (GenericArray<Message> messages) {
        for (uint i = 0; i < messages.length; i++)
            messages[i].show_folder = true;

        var hit_keys = new HashTable<string, uint8> (str_hash, str_equal);
        for (uint i = 0; i < messages.length; i++)
            hit_keys.set (message_flag_key (messages[i]), 1);

        GenericArray<Conversation> conversations;
        if (this.conversation_view) {
            conversations = Conversation.group (messages, related_thread_messages (messages));
            for (uint i = 0; i < conversations.length; i++) {
                var conversation = conversations[i];
                conversation.list_folder = null;
                for (uint j = 0; j < conversation.messages.length; j++)
                    conversation.messages[j].show_folder = true;
                conversation.refresh ();
                var hit = newest_search_hit (conversation, hit_keys);
                if (hit != null)
                    conversation.prefer_preview (hit);
            }
        } else {
            conversations = Conversation.as_singles (messages);
        }

        var listed = listed_conversations (conversations);
        this.conversation_title.title = _("Search Results");
        this.conversation_title.subtitle = ngettext (
            "%d match",
            "%d matches",
            (int) listed.length
        ).printf ((int) listed.length);
        apply_offline_heading ();

        if (listed.length == 0) {
            this.message_store.remove_all ();
            show_conversation_placeholder (
                _("No Matches"),
                _("No messages in any folder match the search.")
            );
            return;
        }

        show_conversation_list (listed);
    }

    private GenericArray<Message> related_thread_messages (GenericArray<Message> hits) {
        var extras = new GenericArray<Message> ();
        var account = this.selected_account;
        if (account == null || hits.length == 0)
            return extras;

        var hashes = new HashTable<string, uint8> (str_hash, str_equal);
        var keys = new HashTable<string, uint8> (str_hash, str_equal);
        var skip = new HashTable<string, uint8> (str_hash, str_equal);
        for (uint i = 0; i < hits.length; i++) {
            remember_thread_keys (hits[i], hashes, keys);
            skip.set (message_flag_key (hits[i]), 1);
        }

        var folders = folders_from_tree ();
        for (int pass = 0; pass < 2; pass++) {
            for (uint i = 0; i < folders.length; i++) {
                var folder = folders[i];
                if (folder.kind == FolderKind.JUNK || folder.kind == FolderKind.TRASH
                    || folder.is_virtual_view)
                    continue;
                var cached = this.message_cache.get (message_cache_key (account, folder));
                if (cached == null)
                    continue;
                for (uint j = 0; j < cached.length; j++) {
                    var message = cached[j];
                    var id = message_flag_key (message);
                    if (skip.contains (id))
                        continue;
                    if (!message_shares_thread (message, hashes, keys))
                        continue;
                    skip.set (id, 1);
                    extras.add (message);
                    remember_thread_keys (message, hashes, keys);
                }
            }
        }

        return extras;
    }

    private static void remember_thread_keys (
        Message message,
        HashTable<string, uint8> hashes,
        HashTable<string, uint8> keys
    ) {
        if (message.msgid_hash != 0)
            hashes.set (message.msgid_hash.to_string (), 1);
        var refs = message.msgid_refs;
        if (refs != null) {
            for (uint i = 0; i < refs.length; i++) {
                if (refs[i] != 0)
                    hashes.set (refs[i].to_string (), 1);
            }
        }
        if (message.conversation_key != null && message.conversation_key.length > 0)
            keys.set (message.conversation_key, 1);
    }

    private static bool message_shares_thread (
        Message message,
        HashTable<string, uint8> hashes,
        HashTable<string, uint8> keys
    ) {
        if (message.conversation_key != null && message.conversation_key.length > 0
            && keys.contains (message.conversation_key))
            return true;
        if (message.msgid_hash != 0 && hashes.contains (message.msgid_hash.to_string ()))
            return true;
        var refs = message.msgid_refs;
        if (refs == null)
            return false;
        for (uint i = 0; i < refs.length; i++) {
            if (refs[i] != 0 && hashes.contains (refs[i].to_string ()))
                return true;
        }
        return false;
    }

    private static Message? newest_search_hit (
        Conversation conversation,
        HashTable<string, uint8> hit_keys
    ) {
        Message? best = null;
        for (uint i = 0; i < conversation.messages.length; i++) {
            var message = conversation.messages[i];
            if (!hit_keys.contains (message_flag_key (message)))
                continue;
            if (best == null || message.date > best.date)
                best = message;
        }
        return best;
    }

    private Message? pick_listed_open (Conversation conversation) {
        if (this.search_results != null && this.search_results.length > 0) {
            var hit_keys = new HashTable<string, uint8> (str_hash, str_equal);
            for (uint i = 0; i < this.search_results.length; i++)
                hit_keys.set (message_flag_key (this.search_results[i]), 1);
            var hit = newest_search_hit (conversation, hit_keys);
            if (hit != null)
                return hit;
        }

        if (viewing_bookmarks ()) {
            if (this.open_conversation == conversation && this.open_message != null
                && conversation.contains (this.open_message.uid, this.open_message.folder_full_name)) {
                if (this.open_message.flagged)
                    return this.open_message;
                return conversation.pick_flagged (this.open_message)
                    ?? conversation.pick_flagged ()
                    ?? this.open_message;
            }
            return conversation.pick_flagged () ?? conversation.pick_open ();
        }

        return conversation.pick_open ();
    }

    private bool viewing_bookmarks () {
        if (this.selected_folder == null)
            return false;
        if (this.selected_folder.is_virtual_view)
            return true;
        return is_gmail_account () && this.selected_folder.kind == FolderKind.STARRED;
    }

    private bool is_gmail_account () {
        return this.selected_account != null && this.selected_account.kind == AccountKind.GOOGLE;
    }

    private void redisplay_current_list () {
        var account = this.selected_account;
        var folder = this.selected_folder;
        if (account == null || folder == null)
            return;

        if (folder.is_virtual_view) {
            show_bookmarked_messages ();
            return;
        }

        var cache = this.message_cache.get (message_cache_key (account, folder));
        if (cache == null) {
            load_messages.begin (folder);
            return;
        }

        display_messages (account, folder, cache);
    }

    private void highlight_selected_folder () {
        var folder = this.selected_folder;
        if (folder == null)
            return;

        for (int i = 0; this.folder_list.get_row_at_index (i) != null; i++) {
            var row = this.folder_list.get_row_at_index (i) as FolderRow;
            if (row == null || row.folder.full_name != folder.full_name)
                continue;
            this.folder_list.select_row (row);
            return;
        }
    }

    private void on_unread_filter_toggled () {
        this.unread_only = this.unread_filter_button.active;
        this.unread_filter_button.tooltip_text = this.unread_only
            ? _("Showing unread messages")
            : _("Show unread only");
        if (this.search_text.length > 0 && this.search_results != null)
            display_search_results (this.search_results);
        else
            redisplay_current_list ();
    }

    private void on_conversation_toggled () {
        this.settings.set_boolean ("conversation-view", this.conversation_button.active);
    }

    private void on_conversation_view_setting () {
        var enabled = this.settings.get_boolean ("conversation-view");
        if (this.conversation_button.active != enabled)
            this.conversation_button.active = enabled;
        this.conversation_view = enabled;
        this.conversation_button.tooltip_text = enabled
            ? _("Showing conversations")
            : _("Group by conversation");
        if (this.search_text.length > 0 && this.search_results != null)
            display_search_results (this.search_results);
        else
            redisplay_current_list ();
    }

    private void schedule_mark_seen (Account account, Folder folder, Message message) {
        cancel_mark_seen ();
        if (message.seen)
            return;

        var mode = this.settings.get_string ("mark-as-read");
        if (mode == "never")
            return;

        if (mode != "delay") {
            commit_mark_seen (account, folder, message);
            return;
        }

        var uid = message.uid;
        this.mark_seen_source = Timeout.add_seconds (5, () => {
            this.mark_seen_source = 0;
            if (this.open_message_uid != uid || this.open_message == null)
                return Source.REMOVE;
            if (!is_current_account (account))
                return Source.REMOVE;
            commit_mark_seen (account, folder, this.open_message);
            return Source.REMOVE;
        });
    }

    private void commit_mark_seen (Account account, Folder folder, Message message) {
        if (message.seen)
            return;

        mark_message_seen (message, folder);
        this.mail_session.queue_mark_seen (account, folder, message.uid);
    }

    private void cancel_mark_seen () {
        if (this.mark_seen_source != 0) {
            Source.remove (this.mark_seen_source);
            this.mark_seen_source = 0;
        }
    }

    private void on_mark_as_read_setting () {
        if (this.settings.get_string ("mark-as-read") == "never")
            cancel_mark_seen ();
    }

    private Folder? folder_for_message (Message? message) {
        if (message != null && message.folder_full_name != null) {
            var folders = folders_from_tree ();
            for (uint i = 0; i < folders.length; i++) {
                if (folders[i].full_name == message.folder_full_name)
                    return folders[i];
            }
        }

        return this.selected_folder;
    }

    private bool is_current_folder (Folder folder) {
        return this.selected_folder != null && this.selected_folder.full_name == folder.full_name;
    }

    private void on_account_activated (Gtk.ListBoxRow row) {
        var account_row = row as AccountRow;
        if (account_row == null)
            return;
        activate_account (account_row.account);
    }

    private void activate_account (Account account) {
        if (this.selecting_account && this.selected_account != null
            && accounts_are_same (this.selected_account, account))
            return;

        if (this.selected_account != null && !accounts_are_same (this.selected_account, account))
            remember_folder_tree (this.selected_account, folders_from_tree (false));

        this.selecting_account = true;
        this.selected_account = account;
        this.selected_folder = null;
        this.bookmarks_folder = null;
        clear_search_state ();
        this.settings.set_string ("last-account-uid", account.source_uid ?? account.uid);
        this.folder_title.title = account.display_name;
        this.folder_title.subtitle = account.has_mail
            ? account.kind.label ()
            : _("Offline");
        this.idle_cancellable?.cancel ();
        this.idle_cancellable = new Cancellable ();
        this.sync_jobs = new GenericArray<MailSyncJob> ();
        this.mail_session?.unwatch_all_folders ();
        bind_reader_mailbox ();
        sync_account_selection (account);
        this.selecting_account = false;
        load_folders.begin (account);
    }

    private void sync_account_selection (Account account) {
        for (int i = 0; this.account_list.get_row_at_index (i) != null; i++) {
            var row = this.account_list.get_row_at_index (i) as AccountRow;
            if (row != null && accounts_are_same (row.account, account)) {
                this.account_list.select_row (row);
                break;
            }
        }

        for (var child = this.account_rail_list.get_first_child (); child != null; child = child.get_next_sibling ()) {
            var button = rail_button_from_child (child);
            if (button == null)
                continue;
            var rail_account = button.get_data<Account> ("account");
            button.active = rail_account != null && accounts_are_same (rail_account, account);
        }
    }

    private Gtk.ToggleButton? rail_button_from_child (Gtk.Widget child) {
        var button = child as Gtk.ToggleButton;
        if (button != null)
            return button;

        var box = child as Gtk.Box;
        if (box == null)
            return null;
        return box.get_first_child () as Gtk.ToggleButton;
    }

    private void fill_account_rail () {
        var guard = this.selecting_account;
        this.selecting_account = true;

        Gtk.Widget? child = this.account_rail_list.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            this.account_rail_list.remove (child);
            child = next;
        }

        Gtk.ToggleButton? group = null;
        for (int i = 0; this.account_list.get_row_at_index (i) != null; i++) {
            var row = this.account_list.get_row_at_index (i) as AccountRow;
            if (row == null)
                continue;

            var account = row.account;
            var button = new Gtk.ToggleButton () {
                tooltip_text = account.display_name,
                valign = Gtk.Align.CENTER,
                halign = Gtk.Align.CENTER,
                hexpand = true,
            };
            button.add_css_class ("flat");
            button.add_css_class ("account-rail-icon");
            if (!account.has_mail)
                button.add_css_class ("account-offline");
            if (group != null)
                button.group = group;
            else
                group = button;
            button.set_data ("account", account);
            button.child = Utils.account_brand_image (account, 28);
            button.toggled.connect (() => {
                if (!button.active || this.selecting_account)
                    return;
                if (this.selected_account != null && accounts_are_same (this.selected_account, account))
                    return;
                activate_account (account);
            });
            if (this.selected_account != null && accounts_are_same (this.selected_account, account))
                button.active = true;

            var slot = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
                hexpand = true,
                vexpand = false,
                valign = Gtk.Align.FILL,
                halign = Gtk.Align.FILL,
            };
            slot.add_css_class ("account-rail-slot");
            slot.append (button);
            this.account_rail_list.append (slot);
        }

        sync_account_row_sizes ();
        if (this.selected_account != null)
            sync_account_selection (this.selected_account);
        this.selecting_account = guard;
    }

    private void sync_account_row_sizes () {
        this.account_header_sizes = new Gtk.SizeGroup (Gtk.SizeGroupMode.VERTICAL);
        this.account_header_sizes.add_widget (this.account_header);
        this.account_header_sizes.add_widget (this.account_rail_add);

        this.account_row_sizes = new Gtk.SizeGroup (Gtk.SizeGroupMode.VERTICAL);
        Gtk.Widget? rail = this.account_rail_list.get_first_child ();
        for (int i = 0; this.account_list.get_row_at_index (i) != null && rail != null; i++) {
            this.account_row_sizes.add_widget (this.account_list.get_row_at_index (i));
            this.account_row_sizes.add_widget (rail);
            rail = rail.get_next_sibling ();
        }
    }

    private void apply_account_sidebar (bool expanded) {
        this.account_pane.visible = expanded;
        this.account_rail.visible = true;
        this.folder_split.show_sidebar = true;
        if (expanded) {
            this.folder_split.min_sidebar_width = ACCOUNT_RAIL_WIDTH + ACCOUNT_PANE_MIN;
            this.folder_split.max_sidebar_width = ACCOUNT_RAIL_WIDTH + ACCOUNT_PANE_MAX;
            this.folder_split.sidebar_width_fraction = 0.28f;
        } else {
            this.folder_split.min_sidebar_width = ACCOUNT_RAIL_WIDTH;
            this.folder_split.max_sidebar_width = ACCOUNT_RAIL_WIDTH;
            this.folder_split.sidebar_width_fraction = 0.01f;
        }
        this.sidebar_button.tooltip_text = expanded
            ? _("Hide account list")
            : _("Show account list");
    }

    private void set_conversation_heading (string title, string? subtitle) {
        this.conversation_title.title = title;
        this.conversation_title.subtitle = subtitle ?? "";
        apply_offline_heading ();
    }

    private void apply_offline_heading () {
        if (this.selected_account == null || this.selected_account.has_mail)
            return;

        if (this.conversation_title.title == null || this.conversation_title.title.length == 0)
            this.conversation_title.title = _("Offline");
        this.conversation_title.subtitle = _("Offline — enable the service in Online Accounts settings");
    }

    private async void load_folders (Account account) {
        this.folder_cancellable?.cancel ();
        this.folder_cancellable = new Cancellable ();
        var cancellable = this.folder_cancellable;
        var current = account;

        if (current.kind == AccountKind.LOCAL)
            return;

        if (!current.has_mail && current.source_uid == null) {
            show_folder_status (
                _("Offline"),
                _("Enable the mail service in Online Accounts settings")
            );
            set_conversation_heading (_("Offline"), null);
            return;
        }

        if (this.mail_session == null) {
            show_folder_status (
                _("Evolution Data Server Unavailable"),
                _("Letter needs the same data server used by Calendar and Contacts.")
            );
            return;
        }

        var cached = cached_folder_tree (current);
        if (cached != null && cached.length > 0) {
            this.folder_tree_needs_refresh = true;
            present_folder_tree (current, cached, true, cancellable);
            return;
        }

        this.no_folders_page.title = _("Loading Folders");
        this.no_folders_page.description = "";
        show_folder_loading ();
        show_conversation_placeholder (
            _("Select a Folder"),
            _("Messages from the selected folder will appear here.")
        );

        /* Brand-new Online Accounts entries need a moment before EDS publishes
         * the Camel mail source and folder list. */
        if (current.has_mail && (current.source_uid == null || current.source_uid.length == 0)) {
            this.no_folders_page.description = Markup.escape_text (
                _("Preparing mail for “%s”…").printf (current.display_name)
            );
            show_folder_loading ();
            current = yield wait_for_mail_source (current, cancellable);
            if (cancellable.is_cancelled () || !is_current_account (current))
                return;
            if (current.source_uid == null || current.source_uid.length == 0) {
                show_folder_status (
                    _("Mail Account Not Ready"),
                    _("Evolution Data Server has not published this account yet. Try again in a moment.")
                );
                return;
            }
        }

        try {
            var local = yield this.mail_session.list_folders (current, cancellable, false);
            if (cancellable.is_cancelled () || !is_current_account (current))
                return;
            if (local.length > 0) {
                this.folder_tree_needs_refresh = true;
                present_folder_tree (current, local, true, cancellable);
                return;
            }
        } catch (Error e) {
            debug ("Local folder tree: %s", e.message);
            if (cancellable.is_cancelled () || !is_current_account (current))
                return;
        }

        this.no_folders_page.title = _("Loading Folders");
        this.no_folders_page.description = Markup.escape_text (
            _("Connecting to “%s”…").printf (current.display_name)
        );
        show_folder_loading ();
        show_conversation_placeholder (
            _("Select a Folder"),
            _("Messages from the selected folder will appear here.")
        );

        try {
            var folders = yield list_folders_with_retry (current, cancellable);
            if (cancellable.is_cancelled () || !is_current_account (current))
                return;

            if (folders.length == 0) {
                show_folder_status (
                    _("No Folders"),
                    _("The account did not publish any subscribed folders.")
                );
                return;
            }

            present_folder_tree (current, folders, true, cancellable);
            this.last_full_align = Utils.sync_tick ();
        } catch (Error e) {
            if (cancellable.is_cancelled () || !is_current_account (current))
                return;

            if (!current.has_mail) {
                show_folder_status (
                    _("Offline"),
                    _("Enable the mail service in Online Accounts settings")
                );
                set_conversation_heading (_("Offline"), null);
                return;
            }

            show_folder_status (_("Could Not Load Folders"), e.message);
            this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                timeout = 5,
            });
        }
    }

    private async Account wait_for_mail_source (Account account, Cancellable? cancellable) {
        for (int attempt = 0; attempt < 45; attempt++) {
            if (cancellable != null && cancellable.is_cancelled ())
                return account;

            var live = live_account (account);
            if (live != null) {
                account = live;
                if (this.selected_account != null && accounts_are_same (this.selected_account, account))
                    this.selected_account = account;
                if (account.source_uid != null && account.source_uid.length > 0)
                    return account;
            }

            Timeout.add_seconds (1, () => {
                wait_for_mail_source.callback ();
                return Source.REMOVE;
            });
            yield;
        }
        return account;
    }

    private async GenericArray<Folder> list_folders_with_retry (
        Account account,
        Cancellable? cancellable
    ) throws Error {
        Error? last_error = null;
        for (int attempt = 0; attempt < 12; attempt++) {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Cancelled");

            var live = live_account (account);
            if (live != null)
                account = live;

            try {
                var folders = yield this.mail_session.list_folders (account, cancellable, true);
                if (folders.length > 0)
                    return folders;
            } catch (Error e) {
                last_error = e;
                if (e is IOError.CANCELLED)
                    throw e;
            }

            this.no_folders_page.title = _("Loading Folders");
            this.no_folders_page.description = Markup.escape_text (
                _("Waiting for folders from “%s”…").printf (account.display_name)
            );
            show_folder_loading ();

            Timeout.add_seconds (2, () => {
                list_folders_with_retry.callback ();
                return Source.REMOVE;
            });
            yield;
        }

        if (last_error != null)
            throw last_error;
        return new GenericArray<Folder> ();
    }

    private Account? live_account (Account account) {
        var app = get_application () as Application;
        if (app == null)
            return null;
        for (uint i = 0; i < app.accounts.items.get_n_items (); i++) {
            var item = app.accounts.items.get_item (i) as Account;
            if (item != null && accounts_are_same (item, account))
                return item;
        }
        return null;
    }

    private static string folder_tree_key (Account account) {
        return account.source_uid ?? account.uid;
    }

    private GenericArray<Folder>? cached_folder_tree (Account account) {
        string[] keys = folder_tree_keys (account);
        foreach (var key in keys) {
            var ram = this.folder_tree_cache.get (key);
            if (ram != null && ram.length > 0)
                return ram;
        }

        foreach (var key in keys) {
            var disk = load_folder_tree_from_disk_key (key);
            if (disk != null && disk.length > 0) {
                foreach (var store_key in keys)
                    this.folder_tree_cache.set (store_key, disk);
                return disk;
            }
        }
        return null;
    }

    private static string[] folder_tree_keys (Account account) {
        if (account.source_uid != null && account.source_uid.length > 0
            && account.source_uid != account.uid)
            return { account.source_uid, account.uid };
        return { folder_tree_key (account) };
    }

    private void remember_folder_tree (Account account, GenericArray<Folder> folders) {
        if (folders.length == 0)
            return;

        var stored = new GenericArray<Folder> ();
        for (uint i = 0; i < folders.length; i++)
            stored.add (folders[i]);
        foreach (var key in folder_tree_keys (account)) {
            this.folder_tree_cache.set (key, stored);
            save_folder_tree_to_disk_key (key, stored);
        }
    }

    private void preload_folder_trees_from_disk () {
        var app = get_application () as Application;
        if (app == null)
            return;

        for (uint i = 0; i < app.accounts.items.get_n_items (); i++) {
            var account = app.accounts.items.get_item (i) as Account;
            if (account == null || account.kind == AccountKind.LOCAL || !account.has_mail)
                continue;
            cached_folder_tree (account);
        }
    }

    private async void warm_other_account_trees () {
        var app = get_application () as Application;
        if (app == null || this.mail_session == null || this.warming_trees)
            return;

        this.warming_trees = true;
        var current = this.selected_account;
        try {
            for (uint i = 0; i < app.accounts.items.get_n_items (); i++) {
                var account = app.accounts.items.get_item (i) as Account;
                if (account == null || account.kind == AccountKind.LOCAL || !account.has_mail)
                    continue;
                if (current != null && accounts_are_same (current, account))
                    continue;
                if (cached_folder_tree (account) != null)
                    continue;

                try {
                    var folders = yield this.mail_session.list_folders (account, null, false);
                    if (folders.length == 0)
                        continue;
                    remember_folder_tree (account, folders);
                    Utils.sync_log ("warmed folder tree for %s (%u folders)".printf (
                        account.display_name,
                        folders.length
                    ));
                } catch (Error e) {
                    debug ("Could not warm folder tree %s: %s", account.display_name, e.message);
                }
            }
        } finally {
            this.warming_trees = false;
        }
    }

    private static GenericArray<Folder>? load_folder_tree_from_disk_key (string account_uid) {
        var path = MailSession.folder_tree_cache_file (account_uid);
        if (!FileUtils.test (path, FileTest.IS_REGULAR))
            return null;

        try {
            var key = new KeyFile ();
            key.load_from_file (path, KeyFileFlags.NONE);
            if (key.get_integer ("tree", "version") != 1)
                return null;

            var count = key.get_integer ("tree", "count");
            if (count <= 0)
                return null;

            var folders = new GenericArray<Folder> ();
            for (int i = 0; i < count; i++) {
                var group = "folder%d".printf (i);
                folders.add (new Folder () {
                    name = key.get_string (group, "name"),
                    full_name = key.get_string (group, "full-name"),
                    unread = key.get_integer (group, "unread"),
                    total = key.get_integer (group, "total"),
                    indent = (uint) key.get_integer (group, "indent"),
                    flags = (uint) key.get_integer (group, "flags"),
                });
            }
            return folders;
        } catch (Error e) {
            debug ("Could not read folder tree cache: %s", e.message);
            return null;
        }
    }

    private static void save_folder_tree_to_disk_key (string account_uid, GenericArray<Folder> folders) {
        try {
            File.new_for_path (MailSession.folder_tree_cache_dir ()).make_directory_with_parents ();
            var key = new KeyFile ();
            key.set_integer ("tree", "version", 1);
            key.set_integer ("tree", "count", (int) folders.length);
            for (uint i = 0; i < folders.length; i++) {
                var folder = folders[i];
                var group = "folder%u".printf (i);
                key.set_string (group, "name", folder.name);
                key.set_string (group, "full-name", folder.full_name);
                key.set_integer (group, "unread", folder.unread);
                key.set_integer (group, "total", folder.total);
                key.set_integer (group, "indent", (int) folder.indent);
                key.set_integer (group, "flags", (int) folder.flags);
            }
            key.save_to_file (MailSession.folder_tree_cache_file (account_uid));
        } catch (Error e) {
            debug ("Could not write folder tree cache: %s", e.message);
        }
    }

    private void present_folder_tree (
        Account account,
        GenericArray<Folder> folders,
        bool restore,
        Cancellable cancellable
    ) {
        this.folder_bin.child = this.folder_scrolled;
        apply_folder_tree (folders);
        remember_folder_tree (account, folders);
        mark_inbox_tree_on_sidebar ();
        warm_other_account_trees.begin ();

        if (!restore)
            return;

        if (account.has_mail)
            this.mailbox_bootstrapping = true;
        restore_folder_selection ();
        if (account.has_mail)
            startup_refresh.begin (cancellable);
        else
            set_conversation_heading (
                this.selected_folder != null ? this.selected_folder.name : _("Offline"),
                null
            );
    }

    private async void startup_refresh (Cancellable cancellable) {
        var account = this.selected_account;
        try {
            if (this.mail_session == null || account == null || account.kind == AccountKind.LOCAL || !account.has_mail)
                return;

            Utils.sync_log ("startup disk hydrate for %s".printf (account.display_name));
            yield sync_mailbox (cancellable);
            if (cancellable.is_cancelled () || !is_current_account (account))
                return;

            yield hydrate_remaining (account, cancellable);
            if (cancellable.is_cancelled () || !is_current_account (account))
                return;

            this.mailbox_bootstrapping = false;
            var inbox = find_folder_kind (FolderKind.INBOX);
            if (inbox != null)
                boost_folder_sync (inbox);
            if (this.selected_folder != null
                && (inbox == null || this.selected_folder.full_name != inbox.full_name))
                boost_folder_sync (this.selected_folder);

            if (this.folder_tree_needs_refresh) {
                this.folder_tree_needs_refresh = false;
                this.continue_startup_after_tree = true;
                enqueue_sync_job (SYNC_KIND_TREE, null, RANK_TREE);
                pump_sync.begin ();
            } else {
                enqueue_background_after_tree (new GenericArray<string> ());
            }
        } finally {
            this.mailbox_bootstrapping = false;
        }
    }

    private void mark_inbox_tree_on_sidebar () {
        uint heavy_indent = 0;
        var under_heavy = false;

        for (int i = 0; this.folder_list.get_row_at_index (i) != null; i++) {
            var row = this.folder_list.get_row_at_index (i) as FolderRow;
            if (row == null)
                continue;

            var folder = row.folder;
            if (under_heavy && folder.indent <= heavy_indent)
                under_heavy = false;

            if (folder_is_heavy_watch_root (folder)) {
                folder.watch_new_mail = false;
                under_heavy = true;
                heavy_indent = folder.indent;
                continue;
            }

            if (under_heavy) {
                folder.watch_new_mail = false;
                continue;
            }

            folder.watch_new_mail = folder_watches_new_mail (folder);
        }
    }

    private static bool folder_is_heavy_watch_root (Folder folder) {
        switch (folder.kind) {
            case FolderKind.ARCHIVE:
            case FolderKind.ALL:
            case FolderKind.JUNK:
            case FolderKind.TRASH:
            case FolderKind.SENT:
            case FolderKind.DRAFTS:
            case FolderKind.OUTBOX:
                return true;
            default:
                return false;
        }
    }

    private static bool folder_watches_new_mail (Folder folder) {
        if (folder.is_virtual_view || folder.is_gmail_namespace)
            return false;
        return true;
    }

    private void restore_folder_selection () {
        var saved = this.settings.get_string ("last-folder");
        FolderRow? match = null;
        FolderRow? inbox = null;

        for (int i = 0; this.folder_list.get_row_at_index (i) != null; i++) {
            var row = this.folder_list.get_row_at_index (i) as FolderRow;
            if (row == null)
                continue;

            if (inbox == null && row.folder.kind == FolderKind.INBOX)
                inbox = row;
            if (saved.length > 0 && row.folder.full_name == saved)
                match = row;
        }

        var row = match ?? inbox;
        if (row == null)
            return;

        this.folder_list.select_row (row);
        on_folder_activated (row);
    }

    private void on_folder_activated (Gtk.ListBoxRow row) {
        var folder_row = row as FolderRow;
        if (folder_row == null)
            return;

        this.selected_folder = folder_row.folder;
        this.settings.set_string ("last-folder", folder_row.folder.full_name);
        if (is_searching)
            clear_search_state ();

        this.conversation_title.title = folder_row.folder.name;
        this.conversation_title.subtitle = folder_counts_label (folder_row.folder);
        apply_offline_heading ();
        var keep_uid = this.pending_select_uid;
        this.pending_select_uid = null;
        if (keep_uid == null) {
            this.open_message_uid = null;
            this.open_content = null;
            this.open_message = null;
            cancel_mark_seen ();
            set_message_actions_enabled (false);
            show_reader_empty ();
        } else {
            this.open_message_uid = keep_uid;
            this.open_content = null;
            this.open_message = find_cached_message (this.selected_account, folder_row.folder, keep_uid);
            cancel_mark_seen ();
        }

        load_messages.begin (folder_row.folder);
    }

    private async void load_messages (Folder folder) {
        var account = this.selected_account;
        if (this.mail_session == null || account == null)
            return;

        var cache_key = message_cache_key (account, folder);
        if (folder.is_virtual_view) {
            show_bookmarked_messages ();
            return;
        }
        var cached = this.message_cache.get (cache_key);
        if (cached != null)
            display_messages (account, folder, cached);
        else
            show_conversation_loading (
                _("Loading Messages"),
                _("Fetching the list from “%s”…").printf (folder.name)
            );

        if (!this.mailbox_bootstrapping)
            boost_folder_sync (folder);

        try {
            yield this.mail_session.follow_folder (account, folder);
        } catch (Error e) {
            debug ("Could not watch “%s”: %s", folder.name, e.message);
        }

        if (!is_current_folder (folder))
            return;
        if (this.message_cache.get (cache_key) != null)
            return;

        yield hydrate_folder_headers (
            account,
            folder,
            this.idle_cancellable ?? new Cancellable ()
        );
        if (!is_current_folder (folder))
            return;
        cached = this.message_cache.get (cache_key);
        if (cached != null)
            display_messages (account, folder, cached);
    }

    private void show_bookmarked_messages () {
        var account = this.selected_account;
        var folder = ensure_bookmarks_folder ();
        if (account == null)
            return;

        var messages = collect_flagged_messages ();
        folder.total = (int) messages.length;
        int unread = 0;
        for (uint i = 0; i < messages.length; i++) {
            messages[i].show_folder = true;
            if (!messages[i].seen)
                unread++;
        }
        folder.unread = unread;
        refresh_folder_badge (folder);

        if (messages.length == 0) {
            this.message_store.remove_all ();
            show_conversation_placeholder (
                _("No Bookmarks"),
                _("Bookmark a message to collect it here. Bookmarks sync with the flag used by Outlook, Gmail, and IMAP.")
            );
            update_folder_heading (folder, 0);
            return;
        }

        GenericArray<Conversation> conversations;
        if (this.conversation_view) {
            conversations = Conversation.group (messages, related_thread_messages (messages));
            for (uint i = 0; i < conversations.length; i++) {
                conversations[i].list_folder = null;
                for (uint j = 0; j < conversations[i].messages.length; j++)
                    conversations[i].messages[j].show_folder = true;
                conversations[i].refresh ();
            }
        } else {
            conversations = Conversation.as_singles (messages);
        }

        var listed = listed_conversations (conversations);
        update_folder_heading (folder, listed.length);
        if (listed.length == 0) {
            this.message_store.remove_all ();
            show_conversation_placeholder (
                _("No Unread Bookmarks"),
                _("Turn off the unread filter to see the rest of this folder.")
            );
            return;
        }

        show_conversation_list (listed);
    }

    private GenericArray<Message> collect_flagged_messages () {
        var result = new GenericArray<Message> ();
        var account = this.selected_account;
        if (account == null)
            return result;

        var folders = folders_from_tree (false);
        for (uint i = 0; i < folders.length; i++) {
            var folder = folders[i];
            if (folder.kind == FolderKind.JUNK || folder.kind == FolderKind.TRASH)
                continue;
            var cached = this.message_cache.get (message_cache_key (account, folder));
            if (cached == null)
                continue;
            for (uint j = 0; j < cached.length; j++) {
                var message = cached[j];
                if (message.flagged && !message.is_placeholder)
                    result.add (message);
            }
        }

        result.sort ((a, b) => {
            if (a.date < b.date)
                return 1;
            if (a.date > b.date)
                return -1;
            return 0;
        });
        return result;
    }

    private Folder ensure_bookmarks_folder () {
        if (this.bookmarks_folder == null) {
            this.bookmarks_folder = new Folder () {
                name = _("Bookmarks"),
                full_name = Folder.BOOKMARKS_PATH,
            };
        }
        return this.bookmarks_folder;
    }

    private void sync_bookmarks_folder () {
        if (is_gmail_account ()) {
            var existing = bookmarks_row ();
            if (existing != null) {
                var viewing = this.selected_folder != null && this.selected_folder.is_virtual_view;
                this.folder_list.remove (existing);
                if (viewing)
                    select_inbox_folder ();
            }
            this.bookmarks_folder = null;
            return;
        }

        var folder = ensure_bookmarks_folder ();
        var messages = collect_flagged_messages ();
        folder.total = (int) messages.length;
        int unread = 0;
        for (uint i = 0; i < messages.length; i++) {
            if (!messages[i].seen)
                unread++;
        }
        folder.unread = unread;

        var row = bookmarks_row ();
        if (messages.length == 0) {
            if (row != null) {
                var viewing = this.selected_folder != null && this.selected_folder.is_virtual_view;
                this.folder_list.remove (row);
                if (viewing)
                    select_inbox_folder ();
            }
            return;
        }

        if (row == null) {
            var inserted = new FolderRow (folder);
            connect_folder_row (inserted);
            this.folder_list.insert (inserted, bookmarks_insert_index ());
            row = inserted;
        }
        row.update_unread ();

        if (this.selected_folder != null && this.selected_folder.is_virtual_view
            && this.search_text.length == 0)
            show_bookmarked_messages ();
    }

    private FolderRow? bookmarks_row () {
        for (int i = 0; this.folder_list.get_row_at_index (i) != null; i++) {
            var row = this.folder_list.get_row_at_index (i) as FolderRow;
            if (row != null && row.folder.is_virtual_view)
                return row;
        }
        return null;
    }

    private int bookmarks_insert_index () {
        int inbox = -1;
        uint inbox_indent = 0;
        int last = -1;
        for (int i = 0; this.folder_list.get_row_at_index (i) != null; i++) {
            var row = this.folder_list.get_row_at_index (i) as FolderRow;
            if (row == null || row.folder.is_virtual_view)
                continue;
            if (row.folder.kind == FolderKind.INBOX && inbox < 0) {
                inbox = i;
                inbox_indent = row.folder.indent;
                last = i;
                continue;
            }
            if (inbox >= 0 && row.folder.indent > inbox_indent) {
                last = i;
                continue;
            }
            if (inbox >= 0)
                break;
        }
        return last >= 0 ? last + 1 : 0;
    }

    private void select_inbox_folder () {
        var inbox = find_folder_kind (FolderKind.INBOX);
        if (inbox == null)
            return;
        for (int i = 0; this.folder_list.get_row_at_index (i) != null; i++) {
            var row = this.folder_list.get_row_at_index (i) as FolderRow;
            if (row == null || row.folder.full_name != inbox.full_name)
                continue;
            this.folder_list.select_row (row);
            on_folder_activated (row);
            return;
        }
    }

    private static void message_counts (GenericArray<Message> messages, out int total, out int unread) {
        total = (int) messages.length;
        unread = 0;
        for (uint i = 0; i < messages.length; i++) {
            if (!messages[i].seen)
                unread++;
        }
    }

    private static string message_cache_key (Account account, Folder folder) {
        return "%s\n%s".printf (account.source_uid ?? account.uid, folder.full_name);
    }

    private static string hide_key (Account account, Folder folder, string uid) {
        return "%s\n%s\n%s".printf (account.source_uid ?? account.uid, folder.full_name, uid);
    }

    private static string notification_token (Account account, Folder folder, Message message) {
        return "%s\x1f%s\x1f%s".printf (account.source_uid ?? account.uid, folder.full_name, message.uid);
    }

    private static bool parse_notification_token (
        string token,
        out string account_uid,
        out string folder_name,
        out string uid
    ) {
        account_uid = "";
        folder_name = "";
        uid = "";
        var parts = token.split ("\x1f", 3);
        if (parts.length < 3)
            return false;
        account_uid = parts[0];
        folder_name = parts[1];
        uid = parts[2];
        return account_uid.length > 0 && folder_name.length > 0 && uid.length > 0;
    }

    private Folder? folder_by_full_name (string full_name) {
        var folders = folders_from_tree ();
        for (uint i = 0; i < folders.length; i++) {
            if (folders[i].full_name == full_name)
                return folders[i];
        }
        return null;
    }

    private Message? find_cached_message (Account? account, Folder folder, string uid) {
        if (account == null)
            return null;
        var cache = this.message_cache.get (message_cache_key (account, folder));
        if (cache == null)
            return null;
        for (uint i = 0; i < cache.length; i++) {
            if (cache[i].uid == uid)
                return cache[i];
        }
        return null;
    }

    private Conversation? conversation_for_message (Message message) {
        for (uint i = 0; i < this.message_store.n_items; i++) {
            var conversation = this.message_store.get_item (i) as Conversation;
            if (conversation != null && conversation.contains (message.uid, message.folder_full_name))
                return conversation;
        }
        return null;
    }

    private void open_notified_message (Folder folder, string uid) {
        FolderRow? row = null;
        for (int i = 0; this.folder_list.get_row_at_index (i) != null; i++) {
            var candidate = this.folder_list.get_row_at_index (i) as FolderRow;
            if (candidate == null || candidate.folder.full_name != folder.full_name)
                continue;
            row = candidate;
            break;
        }
        if (row == null)
            return;

        this.pending_select_uid = uid;
        this.folder_list.select_row (row);
        on_folder_activated (row);
    }

    private static HashTable<string, uint8> snapshot_uids (GenericArray<Message>? messages) {
        var known = new HashTable<string, uint8> (str_hash, str_equal);
        if (messages == null)
            return known;
        for (uint i = 0; i < messages.length; i++)
            known.set (messages[i].uid, 1);
        return known;
    }

    private bool user_is_looking_at (Folder folder) {
        if (!is_current_folder (folder))
            return false;
        if (!this.get_mapped ())
            return false;
        if (this.is_suspended ())
            return false;
        return this.is_active;
    }

    private async void watch_new_mail_folders () {
        var account = this.selected_account;
        if (this.mail_session == null || account == null || account.kind == AccountKind.LOCAL || !account.has_mail)
            return;

        var folders = folders_from_tree ();
        uint n = 0;
        for (uint i = 0; i < folders.length; i++) {
            var folder = folders[i];
            if (!folder.watch_new_mail && folder.kind != FolderKind.INBOX)
                continue;
            try {
                yield this.mail_session.follow_folder (account, folder);
                n++;
            } catch (Error e) {
                debug ("Could not watch “%s”: %s", folder.name, e.message);
            }
        }
        Utils.sync_log ("watching %u new-mail folder(s)".printf (n));
    }

    private void notify_new_arrivals (
        Account account,
        Folder folder,
        GenericArray<Message> messages,
        HashTable<string, uint8> known
    ) {
        if (!this.settings.get_boolean ("notifications"))
            return;
        if (this.mailbox_bootstrapping)
            return;
        if (folder.kind == FolderKind.SENT || folder.kind == FolderKind.DRAFTS
            || folder.kind == FolderKind.OUTBOX || folder.kind == FolderKind.JUNK
            || folder.kind == FolderKind.TRASH || folder.kind == FolderKind.STARRED
            || folder.kind == FolderKind.IMPORTANT)
            return;
        if (!folder.watch_new_mail && folder.kind != FolderKind.INBOX)
            return;

        var fresh = new GenericArray<Message> ();
        for (uint i = 0; i < messages.length; i++) {
            var message = messages[i];
            if (known.contains (message.uid) || message.seen || message.outgoing || message.is_placeholder)
                continue;
            if (this.hidden_uids.contains (hide_key (account, folder, message.uid)))
                continue;
            var seen_key = hide_key (account, folder, message.uid);
            if (this.notified_uids.contains (seen_key))
                continue;
            fresh.add (message);
        }
        if (fresh.length == 0)
            return;

        if (user_is_looking_at (folder)) {
            Utils.sync_log ("skip notify “%s”: looking at folder (%u new)".printf (
                folder.name,
                fresh.length
            ));
            return;
        }

        var app = get_application () as Application;
        if (app == null)
            return;

        uint shown = 0;
        uint extra = 0;
        const uint LIMIT = 5;
        for (uint i = 0; i < fresh.length; i++) {
            var message = fresh[i];
            this.notified_uids.set (hide_key (account, folder, message.uid), 1);
            if (shown >= LIMIT) {
                extra++;
                continue;
            }
            send_mail_notification (app, account, folder, message, shown == 0);
            shown++;
        }
        Utils.sync_log ("notify “%s”: %u shown, %u extra".printf (folder.name, shown, extra));
        if (extra == 0)
            return;

        var title = ngettext ("%u more new message", "%u more new messages", extra).printf (extra);
        app.notifier.show_more (title, account.display_name, "more\x1f%s\x1f%s".printf (
            account.source_uid ?? account.uid,
            folder.full_name
        ));
    }

    private void send_mail_notification (Application app, Account account, Folder folder, Message message, bool sound) {
        var token = notification_token (account, folder, message);
        var title = message.subject != null && message.subject.length > 0
            ? message.subject
            : _("(No subject)");
        app.notifier.show_new_mail (title, message.from, token, sound);
    }

    private GenericArray<Message> visible_messages (Account account, Folder folder, GenericArray<Message> messages) {
        var visible = new GenericArray<Message> ();
        var present = new HashTable<string, uint8> (str_hash, str_equal);
        for (uint i = 0; i < messages.length; i++) {
            present.set (messages[i].uid, 1);
            if (this.hidden_uids.contains (hide_key (account, folder, messages[i].uid)))
                continue;
            visible.add (messages[i]);
        }

        var drop = new GenericArray<string> ();
        var prefix = "%s\n%s\n".printf (account.source_uid ?? account.uid, folder.full_name);
        this.hidden_uids.foreach ((key, value) => {
            if (!key.has_prefix (prefix))
                return;
            var uid = key.substring (prefix.length);
            if (!present.contains (uid))
                drop.add (key);
        });
        for (uint i = 0; i < drop.length; i++)
            this.hidden_uids.remove (drop[i]);

        return visible;
    }

    private void display_messages (Account account, Folder folder, GenericArray<Message> messages) {
        if (this.search_text.length > 0)
            return;

        var stored = visible_messages (account, folder, messages);
        Conversation.prune_duplicate_sends (stored);
        this.message_cache.set (message_cache_key (account, folder), stored);
        for (uint i = 0; i < stored.length; i++)
            stored[i].show_folder = false;
        int total;
        int unread;
        message_counts (stored, out total, out unread);
        folder.unread = unread;
        folder.total = total;
        refresh_folder_badge (folder);
        var conversations = this.conversation_view
            ? Conversation.group (stored, extra_thread_messages (account, folder))
            : Conversation.as_singles (stored);
        var listed = listed_conversations (conversations);
        update_folder_heading (folder, listed.length);

        if (listed.length == 0) {
            this.message_store.remove_all ();
            if (stored.length == 0) {
                show_conversation_placeholder (
                    _("No Messages"),
                    _("This folder is empty.")
                );
            } else {
                show_conversation_placeholder (
                    _("No Unread Messages"),
                    _("Turn off the unread filter to see the rest of this folder.")
                );
            }
            return;
        }

        if (is_showing_list () && same_conversation_ids (listed)) {
            apply_conversation_seen (listed);
            if (this.unread_only) {
                var still = listed_conversations (listed);
                if (still.length != listed.length) {
                    if (still.length == 0) {
                        this.message_store.remove_all ();
                        show_conversation_placeholder (
                            _("No Unread Messages"),
                            _("Turn off the unread filter to see the rest of this folder.")
                        );
                    } else {
                        show_conversation_list (still);
                    }
                }
            }
            return;
        }

        show_conversation_list (listed);
    }

    private bool same_conversation_ids (GenericArray<Conversation> conversations) {
        if (this.message_store.n_items != conversations.length)
            return false;

        for (uint i = 0; i < conversations.length; i++) {
            var item = this.message_store.get_item (i) as Conversation;
            if (item == null || item.id != conversations[i].id)
                return false;
            if (!same_conversation_messages (item, conversations[i]))
                return false;
        }

        return true;
    }

    private static bool same_conversation_messages (Conversation a, Conversation b) {
        if (a.messages.length != b.messages.length)
            return false;

        var keys = new HashTable<string, uint8> (str_hash, str_equal);
        for (uint i = 0; i < a.messages.length; i++)
            keys.set (message_flag_key (a.messages[i]), 1);
        for (uint i = 0; i < b.messages.length; i++) {
            if (!keys.contains (message_flag_key (b.messages[i])))
                return false;
        }
        return true;
    }

    private static string message_flag_key (Message message) {
        return "%s\n%s".printf (message.folder_full_name ?? "", message.uid);
    }

    private void apply_conversation_seen (GenericArray<Conversation> conversations) {
        var flags = new HashTable<string, bool> (str_hash, str_equal);
        for (uint i = 0; i < conversations.length; i++) {
            var messages = conversations[i].messages;
            for (uint j = 0; j < messages.length; j++)
                flags.set (message_flag_key (messages[j]), messages[j].seen);
        }

        for (uint i = 0; i < this.message_store.n_items; i++) {
            var conversation = this.message_store.get_item (i) as Conversation;
            if (conversation == null)
                continue;
            for (uint j = 0; j < conversation.messages.length; j++) {
                var message = conversation.messages[j];
                var key = message_flag_key (message);
                if (!flags.contains (key))
                    continue;
                var seen = flags.get (key);
                if (message.seen != seen)
                    message.seen = seen;
            }
            conversation.refresh ();
        }
    }

    private void apply_seen_flags (GenericArray<Message> messages) {
        var flags = new HashTable<string, bool> (str_hash, str_equal);
        for (uint i = 0; i < messages.length; i++)
            flags.set (message_flag_key (messages[i]), messages[i].seen);

        for (uint i = 0; i < this.message_store.n_items; i++) {
            var conversation = this.message_store.get_item (i) as Conversation;
            if (conversation == null)
                continue;
            for (uint j = 0; j < conversation.messages.length; j++) {
                var message = conversation.messages[j];
                var key = message_flag_key (message);
                if (!flags.contains (key))
                    continue;
                var seen = flags.get (key);
                if (message.seen != seen)
                    message.seen = seen;
            }
            conversation.refresh ();
        }
    }

    private void on_camel_folder_changed (string account_key, string folder_name) {
        var account = this.selected_account;
        if (this.mail_session == null || account == null)
            return;
        if ((account.source_uid ?? account.uid) != account_key)
            return;

        var folder = folder_by_full_name (folder_name);
        if (folder == null)
            return;

        var cache = this.message_cache.get (message_cache_key (account, folder));
        var created = cache == null;
        if (created)
            cache = new GenericArray<Message> ();

        var known = snapshot_uids (cache);

        var added = this.mail_session.append_live_headers (account, folder, cache);
        if (created) {
            if (added == 0)
                return;
            this.message_cache.set (message_cache_key (account, folder), cache);
        }
        var removed = this.mail_session.apply_live_flags (account, folder, cache);
        for (uint i = 0; i < removed.length; i++) {
            var uid = removed[i];
            this.hidden_uids.set (hide_key (account, folder, uid), 1);
            for (uint j = 0; j < cache.length; j++) {
                if (cache[j].uid != uid)
                    continue;
                cache.remove_index (j);
                break;
            }
            if (is_current_folder (folder))
                remove_message_from_list (uid, folder.full_name);
        }

        apply_seen_flags (cache);
        int total;
        int unread;
        message_counts (cache, out total, out unread);
        folder.unread = unread;
        folder.total = total;
        refresh_folder_badge (folder);
        sync_bookmarks_folder ();
        sync_important_markers ();
        if (is_current_folder (folder) && this.search_text.length == 0) {
            if (added > 0 || removed.length > 0)
                display_messages (account, folder, cache);
            else if (this.unread_only)
                redisplay_current_list ();
        }
        if (added > 0 && !created)
            notify_new_arrivals (account, folder, cache, known);
    }

    private void show_conversation_list (GenericArray<Conversation> conversations) {
        var keep_uid = this.open_message_uid;
        var keep_folder = this.open_message != null ? this.open_message.folder_full_name : null;
        var items = new Object[conversations.length];
        uint match = Gtk.INVALID_LIST_POSITION;
        for (uint i = 0; i < conversations.length; i++) {
            items[i] = conversations[i];
            if (keep_uid != null && conversations[i].contains (keep_uid, keep_folder))
                match = i;
        }

        this.restoring_selection = true;
        this.message_selection.unselect_all ();
        this.message_store.splice (0, this.message_store.n_items, items);
        this.list_body.child = this.message_scrolled;
        if (this.list_bin.child != this.list_pane)
            this.list_bin.child = this.list_pane;
        if (match != Gtk.INVALID_LIST_POSITION)
            this.message_selection.select_item (match, true);
        this.selection_anchor = match;
        this.restoring_selection = false;

        if (match != Gtk.INVALID_LIST_POSITION)
            on_message_selection_changed ();
    }

    private void on_message_item_setup (Object object) {
        var item = object as Gtk.ListItem;
        if (item == null)
            return;

        var row = new MessageRow ();
        row.mark_read_clicked.connect (() => mark_row_read (row));
        var click = new Gtk.GestureClick () {
            button = Gdk.BUTTON_SECONDARY,
        };
        click.pressed.connect ((n, x, y) => {
            if (!this.message_selection.is_selected (item.position))
                this.message_selection.select_item (item.position, true);
            var conversation = item.item as Conversation ?? row.conversation;
            popup_message_menu (row, x, y, conversation, null);
            click.set_state (Gtk.EventSequenceState.CLAIMED);
        });
        row.add_controller (click);
        item.child = row;
    }

    private void on_message_item_bind (Object object) {
        var item = object as Gtk.ListItem;
        var row = item != null ? item.child as MessageRow : null;
        var conversation = item != null ? item.item as Conversation : null;
        if (row == null || conversation == null)
            return;

        row.list_position = item.position;
        row.bind (conversation, this.search_text.length > 0 ? this.search_tokens : null);
    }

    private void on_message_item_unbind (Object object) {
        var item = object as Gtk.ListItem;
        var row = item != null ? item.child as MessageRow : null;
        row?.unbind ();
    }

    private uint selected_count () {
        return (uint) this.message_selection.get_selection ().get_size ();
    }

    private uint first_selected_position () {
        var bitset = this.message_selection.get_selection ();
        if (bitset.is_empty ())
            return Gtk.INVALID_LIST_POSITION;
        return bitset.get_minimum ();
    }

    private Conversation? selected_conversation () {
        var position = first_selected_position ();
        if (position == Gtk.INVALID_LIST_POSITION)
            return null;
        return this.message_store.get_item (position) as Conversation;
    }

    private GenericArray<Conversation> selected_conversations () {
        var result = new GenericArray<Conversation> ();
        var bitset = this.message_selection.get_selection ();
        var size = bitset.get_size ();
        for (uint64 i = 0; i < size; i++) {
            var conversation = this.message_store.get_item (bitset.get_nth ((uint) i)) as Conversation;
            if (conversation != null)
                result.add (conversation);
        }
        return result;
    }

    private GenericArray<Message> listed_messages_of (Conversation conversation) {
        var listed = new GenericArray<Message> ();
        for (uint i = 0; i < conversation.messages.length; i++) {
            if (conversation.in_list_folder (conversation.messages[i]))
                listed.add (conversation.messages[i]);
        }
        return listed;
    }

    private GenericArray<Message> selected_listed_messages () {
        var messages = new GenericArray<Message> ();
        var conversations = selected_conversations ();
        for (uint i = 0; i < conversations.length; i++) {
            var listed = listed_messages_of (conversations[i]);
            for (uint j = 0; j < listed.length; j++)
                messages.add (listed[j]);
        }
        return messages;
    }

    private uint selected_thread_count () {
        return selected_thread_messages ().length;
    }

    private bool is_thread_bulk () {
        return selected_thread_count () > 1;
    }

    private GenericArray<Message> selected_thread_messages () {
        var messages = new GenericArray<Message> ();
        this.thread_list.selected_foreach ((box, row) => {
            var thread_row = row as ThreadRow;
            if (thread_row != null)
                messages.add (thread_row.message);
        });
        return messages;
    }

    private GenericArray<Message> action_target_messages () {
        var thread = selected_thread_messages ();
        if (thread.length > 1)
            return thread;
        return selected_listed_messages ();
    }

    private uint message_position_at (double x, double y) {
        var picked = this.message_list.pick (x, y, Gtk.PickFlags.DEFAULT);
        while (picked != null && picked != this.message_list) {
            var row = picked as MessageRow;
            if (row != null && row.list_position != Gtk.INVALID_LIST_POSITION)
                return row.list_position;
            picked = picked.get_parent ();
        }
        return Gtk.INVALID_LIST_POSITION;
    }

    private void apply_range_selection (uint position, bool add) {
        var anchor = this.selection_anchor;
        if (anchor == Gtk.INVALID_LIST_POSITION || anchor >= this.message_store.n_items)
            anchor = position;
        var start = uint.min (anchor, position);
        var end = uint.max (anchor, position);
        this.message_selection.select_range (start, end - start + 1, !add);
    }

    private void select_only_position (uint position) {
        if (position == Gtk.INVALID_LIST_POSITION || position >= this.message_store.n_items) {
            this.message_selection.unselect_all ();
            this.selection_anchor = Gtk.INVALID_LIST_POSITION;
            return;
        }

        this.message_selection.select_item (position, true);
        this.selection_anchor = position;
    }

    private void show_bulk_reader (uint n) {
        cancel_mark_seen ();
        this.body_cancellable?.cancel ();
        this.open_content = null;
        this.open_message = null;
        this.open_message_uid = null;
        this.open_conversation = null;
        this.thread_revealer.reveal_child = false;
        this.thread_list.remove_all ();
        this.reader_page.icon_name = "checkbox-checked-symbolic";
        this.reader_page.title = ngettext (
            "%u conversation selected",
            "%u conversations selected",
            n
        ).printf (n);
        this.reader_page.description = _("Archive, move, delete, or mark as read or unread.");
        this.reader_bin.child = this.reader_page;
        update_message_actions ();
    }

    private void on_message_selection_changed () {
        if (this.restoring_selection)
            return;

        var n = selected_count ();
        if (n > 1) {
            show_bulk_reader (n);
            return;
        }
        if (n == 0)
            return;

        var position = first_selected_position ();
        if (position != Gtk.INVALID_LIST_POSITION)
            this.selection_anchor = position;

        var conversation = selected_conversation ();
        if (conversation == null)
            return;

        var message = pick_listed_open (conversation);
        if (message == null)
            return;

        if (this.open_conversation == conversation
            && this.open_message_uid == message.uid
            && this.open_message != null
            && (this.open_message.folder_full_name ?? "") == (message.folder_full_name ?? "")
            && this.reader_bin.child == this.reader_pane) {
            update_message_actions ();
            return;
        }

        this.open_conversation = conversation;
        this.open_message_uid = message.uid;
        this.open_message = message;
        cancel_mark_seen ();
        fill_thread_list (conversation, message);
        update_message_actions ();
        load_message_body.begin (message);
    }

    private void on_message_activated (uint position) {
        var conversation = this.message_store.get_item (position) as Conversation;
        if (conversation == null)
            return;

        Message? message;
        if (this.open_conversation == conversation && this.open_message != null
            && conversation.contains (this.open_message.uid, this.open_message.folder_full_name))
            message = this.open_message;
        else
            message = pick_listed_open (conversation);
        if (message == null)
            return;

        open_message_window.begin (message);
    }

    private async void load_message_body (Message message) {
        this.body_cancellable?.cancel ();
        this.body_cancellable = new Cancellable ();
        var cancellable = this.body_cancellable;
        var account = this.selected_account;
        var folder = folder_for_message (message);
        if (this.mail_session == null || account == null || folder == null)
            return;

        bind_reader_mailbox ();
        var cached = this.mail_session.peek_body (account, folder, message.uid);
        if (cached != null) {
            this.open_content = cached;
            this.message_reader.show_content (cached, message.outgoing);
            this.reader_bin.child = this.reader_pane;
            update_message_actions ();
            schedule_mark_seen (account, folder, message);
            prefetch_thread_bodies.begin (message);
            return;
        }

        this.message_reader.show_loading (message);
        this.reader_bin.child = this.reader_pane;
        set_message_actions_enabled (false);

        try {
            var content = yield this.mail_session.load_message (account, folder, message.uid, cancellable);
            if (cancellable.is_cancelled () || this.open_message_uid != message.uid)
                return;

            this.open_content = content;
            this.message_reader.show_content (content, message.outgoing);
            update_message_actions ();
            schedule_mark_seen (account, folder, message);
            prefetch_thread_bodies.begin (message);
        } catch (Error e) {
            if (cancellable.is_cancelled () || this.open_message_uid != message.uid)
                return;

            this.open_content = null;
            this.message_reader.show_error (e.message);
            this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                timeout = 5,
            });
        }
    }

    private async void prefetch_thread_bodies (Message opened) {
        var conversation = this.open_conversation;
        var account = this.selected_account;
        if (this.mail_session == null || account == null || conversation == null)
            return;
        if (this.open_message_uid != opened.uid)
            return;

        for (uint i = 0; i < conversation.messages.length; i++) {
            if (this.open_message_uid != opened.uid)
                return;

            var message = conversation.messages[i];
            if (message.uid == opened.uid)
                continue;
            var folder = folder_for_message (message);
            if (folder == null)
                continue;
            if (this.mail_session.peek_body (account, folder, message.uid) != null)
                continue;

            try {
                yield this.mail_session.load_message (account, folder, message.uid, null);
            } catch (Error e) {
                debug ("Could not prefetch conversation message: %s", e.message);
            }
        }
    }

    private void mark_message_seen (Message message, Folder folder) {
        var was_unseen = !message.seen;
        message.seen = true;
        if (was_unseen && folder.unread > 0)
            folder.unread--;
        refresh_folder_badge (folder);
        if (this.open_conversation != null) {
            this.open_conversation.refresh ();
            var selected = this.open_message ?? message;
            fill_thread_list (this.open_conversation, selected);
        }
    }

    private static string folder_counts_label (Folder folder) {
        var unread_n = int.max (folder.unread, 0);
        var total_n = int.max (folder.total, 0);
        var unread = ngettext ("%d unread", "%d unread", unread_n).printf (unread_n);
        var total = ngettext ("%d message", "%d messages", total_n).printf (total_n);
        return "%s · %s".printf (unread, total);
    }

    private void update_folder_heading (Folder folder, uint shown) {
        if (!is_current_folder (folder))
            return;

        this.conversation_title.title = folder.name;
        if (this.search_text.length > 0) {
            var count = (int) shown;
            this.conversation_title.subtitle = ngettext (
                "%d match",
                "%d matches",
                count
            ).printf (count);
        } else {
            this.conversation_title.subtitle = folder_counts_label (folder);
        }
        apply_offline_heading ();
    }

    private void show_folder_loading () {
        this.no_folders_page.icon_name = null;
        this.no_folders_page.paintable = this.folder_spinner;
        this.folder_bin.child = this.no_folders_page;
    }

    private void show_folder_status (string title, string description) {
        this.no_folders_page.paintable = null;
        this.no_folders_page.icon_name = "folder-symbolic";
        this.no_folders_page.title = title;
        this.no_folders_page.description = Markup.escape_text (description);
        this.folder_bin.child = this.no_folders_page;
    }

    private void show_conversation_loading (string title, string description) {
        this.conversation_page.icon_name = null;
        this.conversation_page.paintable = this.conversation_spinner;
        this.conversation_page.title = title;
        this.conversation_page.description = Markup.escape_text (description);
        show_list_placeholder ();
    }

    private void show_conversation_placeholder (string title, string description) {
        this.conversation_page.paintable = null;
        this.conversation_page.icon_name = "mail-unread-symbolic";
        this.conversation_page.title = title;
        this.conversation_page.description = Markup.escape_text (description);
        show_list_placeholder ();
        show_reader_empty ();
    }

    private void show_list_placeholder () {
        if (this.list_bin.child != this.list_pane)
            this.list_bin.child = this.list_pane;
        this.list_body.child = this.conversation_page;
    }

    private void show_reader_empty () {
        this.thread_revealer.reveal_child = false;
        this.thread_list.remove_all ();
        this.open_conversation = null;
        this.reader_page.icon_name = "mail-unread-symbolic";
        this.reader_page.title = _("Select a Message");
        this.reader_page.description = _("Choose a message from the list to read it.");
        this.reader_bin.child = this.reader_page;
        if (this.thread_action_bar != null)
            this.thread_action_bar.visible = false;
    }

    private void fill_thread_list (Conversation conversation, Message selected) {
        this.restoring_thread = true;
        this.thread_list.remove_all ();
        if (conversation.messages.length <= 1) {
            this.thread_revealer.reveal_child = false;
            this.restoring_thread = false;
            update_message_actions ();
            return;
        }

        Gtk.ListBoxRow? match = null;
        for (uint i = 0; i < conversation.messages.length; i++) {
            var row = new ThreadRow (conversation.messages[i], this.search_text.length > 0 ? this.search_tokens : null);
            connect_thread_context (row, conversation);
            this.thread_list.append (row);
            if (row.message.uid == selected.uid
                && (row.message.folder_full_name ?? "") == (selected.folder_full_name ?? ""))
                match = row;
        }

        this.thread_revealer.reveal_child = true;
        if (match != null)
            this.thread_list.select_row (match);
        this.restoring_thread = false;
        queue_thread_scroll (match);
        update_message_actions ();
    }

    private void queue_thread_scroll (Gtk.ListBoxRow? row) {
        if (this.thread_scroll_source != 0)
            Source.remove (this.thread_scroll_source);
        this.thread_scroll_source = Idle.add (() => {
            this.thread_scroll_source = 0;
            scroll_thread_to_row (row);
            this.thread_scroll_source = Timeout.add (50, () => {
                this.thread_scroll_source = 0;
                scroll_thread_to_row (row);
                return Source.REMOVE;
            });
            return Source.REMOVE;
        });
    }

    private void scroll_thread_to_row (Gtk.ListBoxRow? row) {
        var adj = this.thread_scroll.get_vadjustment ();
        var max_scroll = adj.upper - adj.page_size;
        if (max_scroll < adj.lower)
            max_scroll = adj.lower;
        if (row == null) {
            adj.value = max_scroll;
            return;
        }

        Graphene.Rect bounds;
        if (!row.compute_bounds (this.thread_list, out bounds)) {
            adj.value = max_scroll;
            return;
        }

        var target = bounds.origin.y + bounds.size.height - adj.page_size;
        if (target < adj.lower)
            target = adj.lower;
        if (target > max_scroll)
            target = max_scroll;
        adj.value = target;
    }

    private void on_thread_row_selected (Gtk.ListBoxRow? row) {
        if (this.restoring_thread)
            return;

        var thread_row = row as ThreadRow;
        if (thread_row == null)
            return;

        var message = thread_row.message;
        if (this.open_message_uid == message.uid
            && this.open_message != null
            && (this.open_message.folder_full_name ?? "") == (message.folder_full_name ?? ""))
            return;

        this.open_message_uid = message.uid;
        this.open_message = message;
        cancel_mark_seen ();
        load_message_body.begin (message);
        update_message_actions ();
    }

    private void on_thread_row_activated (Gtk.ListBoxRow row) {
        var thread_row = row as ThreadRow;
        if (thread_row == null || thread_row.message.is_placeholder)
            return;

        open_message_window.begin (thread_row.message);
    }

    private void on_thread_selection_changed () {
        if (this.restoring_thread)
            return;
        update_message_actions ();
    }

    private void apply_reading_pane () {
        var mode = this.settings.get_string ("reading-pane");
        if (mode == "bottom") {
            this.message_split.orientation = Gtk.Orientation.VERTICAL;
            this.reader_bin.visible = true;
        } else if (mode == "hidden") {
            this.reader_bin.visible = false;
        } else {
            this.message_split.orientation = Gtk.Orientation.HORIZONTAL;
            this.reader_bin.visible = true;
        }
    }

    private void on_message_pane_resized () {
        if (this.clamping_message_pane)
            return;

        var pos = this.message_split.position;
        var clamped = pos.clamp (MESSAGE_PANE_MIN, MESSAGE_PANE_MAX);
        if (clamped != pos) {
            this.clamping_message_pane = true;
            this.message_split.position = clamped;
            this.clamping_message_pane = false;
        }

        this.settings.set_int ("message-pane-width", clamped);
    }

    private void on_folder_pane_resized () {
        if (this.clamping_pane)
            return;

        var pos = this.content_split.position;
        var clamped = pos.clamp (FOLDER_PANE_MIN, FOLDER_PANE_MAX);
        if (clamped != pos) {
            this.clamping_pane = true;
            this.content_split.position = clamped;
            this.clamping_pane = false;
        }

        this.settings.set_int ("folder-pane-width", clamped);
    }

    private void on_toggle_sidebar () {
        this.sidebar_button.active = !this.sidebar_button.active;
    }

    private void bind_primary_menu () {
        var popover = new Gtk.PopoverMenu.from_model (this.menu_button.menu_model);
        popover.add_child (new ThemeSelector (this.settings), "theme");
        this.menu_button.popover = popover;
    }

    private void on_fullscreen () {
        if (fullscreened)
            unfullscreen ();
        else
            fullscreen ();
    }

    private void sync_fullscreen_action () {
        var action = lookup_action ("fullscreen") as SimpleAction;
        action?.set_state (new Variant.boolean (fullscreened));
    }

    private void on_message_sent (Account account, Message? sent) {
        if (sent == null || !is_current_account (account))
            return;

        var shown = sent;
        var sent_folder = find_folder_kind (FolderKind.SENT);
        if (sent_folder != null) {
            shown.folder_full_name = sent_folder.full_name;
            shown.folder_name = sent_folder.name;
            var key = message_cache_key (account, sent_folder);
            var cache = this.message_cache.get (key);
            if (cache != null) {
                var existing = matching_outgoing_send (cache, shown);
                if (existing == null) {
                    var next = new GenericArray<Message> ();
                    next.add (shown);
                    for (uint i = 0; i < cache.length; i++)
                        next.add (cache[i]);
                    this.message_cache.set (key, next);
                    cache = next;
                    if (sent_folder.total >= 0)
                        sent_folder.total++;
                    refresh_folder_badge (sent_folder);
                } else {
                    Conversation.prune_duplicate_sends (cache);
                    shown = existing;
                }

                if (is_current_folder (sent_folder) && this.search_text.length == 0)
                    display_messages (account, sent_folder, cache);
            }
        }

        var conversation = this.open_conversation;
        if (conversation == null)
            return;

        bool linked = false;
        for (uint i = 0; i < conversation.messages.length; i++) {
            if (!Conversation.same_thread (conversation.messages[i], shown))
                continue;
            linked = true;
            break;
        }
        if (!linked)
            return;

        conversation.add_message (shown);
        conversation.refresh ();
        fill_thread_list (this.open_conversation ?? conversation, this.open_message ?? shown);
    }

    private void on_draft_saved (Account account, Message? draft) {
        if (draft == null || !is_current_account (account))
            return;

        var folder = find_folder_kind (FolderKind.DRAFTS);
        if (folder == null)
            return;

        draft.folder_full_name = folder.full_name;
        draft.folder_name = folder.name;
        var key = message_cache_key (account, folder);
        var cache = this.message_cache.get (key);
        if (cache != null) {
            var existing = matching_outgoing_send (cache, draft);
            if (existing == null) {
                var next = new GenericArray<Message> ();
                next.add (draft);
                for (uint i = 0; i < cache.length; i++)
                    next.add (cache[i]);
                this.message_cache.set (key, next);
                cache = next;
                bump_folder_total (folder);
                if (is_current_folder (folder) && this.search_text.length == 0)
                    display_messages (account, folder, cache);
            } else {
                Conversation.prune_duplicate_sends (cache);
            }
        } else {
            bump_folder_total (folder);
        }

        enqueue_sync_job (SYNC_KIND_HEADERS, folder, RANK_NEW_MAIL);
        if (!folder_skips_body_prefetch (folder))
            enqueue_sync_job (SYNC_KIND_BODIES, folder, RANK_NEW_MAIL + 1);
        pump_sync.begin ();
    }

    private void bump_folder_total (Folder folder) {
        if (folder.total >= 0)
            folder.total++;
        else
            folder.total = 1;
        refresh_folder_badge (folder);
    }

    private static Message? matching_outgoing_send (GenericArray<Message> cache, Message sent) {
        Message? placeholder = null;
        for (uint i = 0; i < cache.length; i++) {
            if (cache[i].uid == sent.uid
                && (cache[i].folder_full_name ?? "") == (sent.folder_full_name ?? ""))
                return cache[i];
            if (!Conversation.same_outgoing_send (cache[i], sent))
                continue;
            if (!cache[i].is_placeholder)
                return cache[i];
            placeholder = cache[i];
        }
        return placeholder;
    }

    private void on_compose () {
        if (this.mail_session == null) {
            this.toast_overlay.add_toast (new Adw.Toast (_("Evolution Data Server is unavailable.")) {
                timeout = 4,
            });
            return;
        }

        var app = get_application () as Application;
        if (app == null)
            return;

        if (Utils.sendable_account_count (app.accounts) == 0) {
            this.toast_overlay.add_toast (new Adw.Toast (_("No account is configured to send mail.")) {
                timeout = 4,
            });
            return;
        }

        var compose = new ComposeWindow (app, this.mail_session, app.accounts, this.selected_account);
        compose.present ();
    }

    private void on_reply () {
        compose_from_open (ComposeKind.REPLY);
    }

    private void on_reply_all () {
        compose_from_open (ComposeKind.REPLY_ALL);
    }

    private void on_forward () {
        compose_from_open (ComposeKind.FORWARD);
    }

    private void on_send_again () {
        compose_from_open (ComposeKind.SEND_AGAIN);
    }

    private void compose_from_open (ComposeKind kind) {
        compose_from_open_async.begin (kind);
    }

    private async void compose_from_open_async (ComposeKind kind) {
        if (this.open_message != null && this.open_content == null)
            yield load_message_body (this.open_message);

        var app = get_application () as Application;
        if (app == null || this.mail_session == null || this.open_content == null)
            return;
        if (kind == ComposeKind.SEND_AGAIN
            && this.open_message != null && this.open_message.is_placeholder)
            return;
        if (kind != ComposeKind.FORWARD && kind != ComposeKind.REPLY_ALL
            && kind != ComposeKind.SEND_AGAIN
            && this.open_message != null && this.open_message.outgoing)
            return;

        string? to = null;
        string? cc = null;
        string? bcc = null;
        string subject;
        var resend = kind == ComposeKind.SEND_AGAIN;
        if (resend) {
            Utils.resend_addresses (this.open_content, out to, out cc, out bcc);
            subject = this.open_content.subject;
            if (subject == _("(No subject)"))
                subject = "";
        } else if (kind == ComposeKind.FORWARD) {
            subject = Utils.forward_subject (this.open_content.subject);
        } else if (kind == ComposeKind.REPLY_ALL) {
            string? self = null;
            if (this.selected_account != null) {
                var identity = this.mail_session.get_identity (this.selected_account);
                self = identity != null ? identity.address : this.selected_account.email;
            }
            Utils.reply_all_addresses (this.open_content, self, out to, out cc);
            subject = Utils.reply_subject (this.open_content.subject);
        } else {
            to = Utils.format_mailbox (
                Utils.display_address (this.open_content.from),
                this.open_content.from_email ?? Utils.email_from_header (this.open_content.from)
            );
            subject = Utils.reply_subject (this.open_content.subject);
        }

        var compose = new ComposeWindow (
            app,
            this.mail_session,
            app.accounts,
            this.selected_account,
            to,
            cc,
            subject,
            this.open_content,
            kind == ComposeKind.FORWARD,
            bcc,
            resend
        );
        compose.present ();
    }

    private void on_move () {
        if (is_thread_bulk () || selected_count () > 1)
            move_selected_messages.begin ();
        else
            move_open_message.begin ();
    }

    private void on_archive () {
        if (is_thread_bulk () || selected_count () > 1)
            archive_selected_messages.begin ();
        else
            archive_open_message.begin ();
    }

    private void on_delete () {
        if (is_thread_bulk () || selected_count () > 1)
            delete_selected_messages.begin ();
        else
            delete_open_message.begin ();
    }

    private void on_mark_unread () {
        if (selected_count () > 1)
            set_selected_seen.begin (false);
        else
            mark_open_unread.begin ();
    }

    private void on_mark_read () {
        if (selected_count () > 1)
            set_selected_seen.begin (true);
        else
            mark_open_read.begin ();
    }

    private void on_bookmark () {
        toggle_message_bookmark (this.open_message);
    }

    private void on_mark_important () {
        toggle_message_important (this.open_message);
    }

    private void toggle_message_important (Message? message) {
        if (message == null || message.is_placeholder || !is_gmail_account ())
            return;
        var one = new GenericArray<Message> ();
        one.add (message);
        set_messages_important.begin (one, !message.important);
    }

    private void toggle_message_bookmark (Message? message) {
        if (message == null || message.is_placeholder)
            return;
        var one = new GenericArray<Message> ();
        one.add (message);
        set_messages_flagged.begin (one, !message.flagged);
    }

    private async void set_messages_flagged (GenericArray<Message> messages, bool flagged) {
        var account = this.selected_account;
        if (this.mail_session == null || account == null)
            return;

        var changed = new GenericArray<Message> ();
        for (uint i = 0; i < messages.length; i++) {
            var message = messages[i];
            if (message.is_placeholder || message.flagged == flagged)
                continue;
            var folder = folder_for_message (message);
            if (folder == null || folder.is_virtual_view)
                continue;
            message.flagged = flagged;
            changed.add (message);
        }

        if (this.open_conversation != null)
            this.open_conversation.refresh ();
        var conversations = selected_conversations ();
        for (uint i = 0; i < conversations.length; i++)
            conversations[i].refresh ();

        if (!flagged && viewing_bookmarks () && this.open_conversation != null
            && this.open_message != null && !this.open_message.flagged) {
            var next = this.open_conversation.pick_flagged (this.open_message)
                ?? this.open_conversation.pick_flagged ();
            if (next != null && (next.uid != this.open_message.uid
                || (next.folder_full_name ?? "") != (this.open_message.folder_full_name ?? ""))) {
                this.open_message = next;
                this.open_message_uid = next.uid;
                fill_thread_list (this.open_conversation, next);
                load_message_body.begin (next);
            }
        }

        refresh_thread_rows ();
        update_message_actions ();
        var stay_in_bookmarks = viewing_bookmarks ();
        sync_bookmarks_folder ();
        if (stay_in_bookmarks && viewing_bookmarks () && selected_count () == 0) {
            this.open_content = null;
            this.open_message = null;
            this.open_message_uid = null;
            show_reader_empty ();
            set_message_actions_enabled (false);
        }

        if (changed.length == 0)
            return;

        var groups = group_messages_by_folder (changed);
        for (uint i = 0; i < groups.length; i++) {
            var folder = groups[i].folder;
            var uids = groups[i].uids;
            this.mail_session.set_uids_flagged.begin (
                account,
                folder,
                uids,
                flagged,
                (obj, res) => {
                    try {
                        this.mail_session.set_uids_flagged.end (res);
                    } catch (Error e) {
                        this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                            timeout = 4,
                        });
                    }
                }
            );
        }

        if (is_gmail_account ()) {
            var starred = find_folder_kind (FolderKind.STARRED);
            if (starred != null && !is_current_folder (starred))
                boost_folder_sync (starred);
            if (!flagged && this.selected_folder != null && this.selected_folder.kind == FolderKind.STARRED) {
                for (uint i = 0; i < changed.length; i++)
                    remove_message_from_list (changed[i].uid, changed[i].folder_full_name);
            }
        }
    }

    private async void set_messages_important (GenericArray<Message> messages, bool important) {
        var account = this.selected_account;
        if (this.mail_session == null || account == null || !is_gmail_account ())
            return;

        var destination = find_folder_kind (FolderKind.IMPORTANT);
        if (destination == null) {
            this.toast_overlay.add_toast (new Adw.Toast (_("No Important folder was found for this account.")) {
                timeout = 4,
            });
            return;
        }

        yield hydrate_folder_headers (account, destination, this.idle_cancellable ?? new Cancellable ());

        var changed = new GenericArray<Message> ();
        for (uint i = 0; i < messages.length; i++) {
            var message = messages[i];
            if (message.is_placeholder || message.important == important)
                continue;
            var folder = folder_for_message (message);
            if (folder == null || folder.is_virtual_view)
                continue;
            message.important = important;
            changed.add (message);
        }

        if (this.open_conversation != null)
            this.open_conversation.refresh ();
        var conversations = selected_conversations ();
        for (uint i = 0; i < conversations.length; i++)
            conversations[i].refresh ();
        refresh_thread_rows ();
        update_message_actions ();

        for (uint i = 0; i < changed.length; i++) {
            var message = changed[i];
            var folder = folder_for_message (message);
            if (folder == null)
                continue;
            try {
                if (important) {
                    if (folder.kind == FolderKind.IMPORTANT)
                        continue;
                    yield this.mail_session.copy_message (account, folder, message.uid, destination);
                } else {
                    var source = folder.kind == FolderKind.IMPORTANT
                        ? folder
                        : find_important_copy (message);
                    if (source == null)
                        continue;
                    var uid = source.kind == FolderKind.IMPORTANT ? message.uid : find_important_uid (message);
                    if (uid == null)
                        continue;
                    var uids = new GenericArray<string> ();
                    uids.add (uid);
                    yield this.mail_session.delete_uids (account, source, uids, null);
                    if (this.selected_folder != null && this.selected_folder.kind == FolderKind.IMPORTANT)
                        remove_message_from_list (message.uid, message.folder_full_name);
                }
            } catch (Error e) {
                this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                    timeout = 4,
                });
            }
        }

        if (!is_current_folder (destination))
            boost_folder_sync (destination);
        sync_important_markers ();
    }

    private Folder? find_important_copy (Message message) {
        var folder = find_folder_kind (FolderKind.IMPORTANT);
        if (folder == null)
            return null;
        return find_important_uid (message) != null ? folder : null;
    }

    private string? find_important_uid (Message message) {
        var account = this.selected_account;
        var folder = find_folder_kind (FolderKind.IMPORTANT);
        if (account == null || folder == null)
            return null;
        var cached = this.message_cache.get (message_cache_key (account, folder));
        if (cached == null)
            return null;
        for (uint i = 0; i < cached.length; i++) {
            var item = cached[i];
            if (message.msgid_hash != 0 && item.msgid_hash == message.msgid_hash)
                return item.uid;
            if (item.uid == message.uid)
                return item.uid;
        }
        return null;
    }

    private void sync_important_markers () {
        var account = this.selected_account;
        if (account == null || !is_gmail_account ())
            return;

        var important = find_folder_kind (FolderKind.IMPORTANT);
        if (important == null)
            return;

        var hashes = new HashTable<string, uint8> (str_hash, str_equal);
        var cached = this.message_cache.get (message_cache_key (account, important));
        if (cached != null) {
            for (uint i = 0; i < cached.length; i++) {
                cached[i].important = true;
                if (cached[i].msgid_hash != 0)
                    hashes.set (cached[i].msgid_hash.to_string (), 1);
            }
        }

        var folders = folders_from_tree (false);
        for (uint i = 0; i < folders.length; i++) {
            var folder = folders[i];
            if (folder.kind == FolderKind.IMPORTANT)
                continue;
            var items = this.message_cache.get (message_cache_key (account, folder));
            if (items == null)
                continue;
            for (uint j = 0; j < items.length; j++) {
                var message = items[j];
                message.important = message.msgid_hash != 0
                    && hashes.contains (message.msgid_hash.to_string ());
            }
        }

        if (this.open_conversation != null)
            this.open_conversation.refresh ();
        refresh_thread_rows ();
        for (uint i = 0; i < this.message_store.get_n_items (); i++) {
            var conversation = this.message_store.get_item (i) as Conversation;
            conversation?.refresh ();
        }
    }

    private void refresh_thread_rows () {
        for (int i = 0; this.thread_list.get_row_at_index (i) != null; i++) {
            var row = this.thread_list.get_row_at_index (i) as ThreadRow;
            row?.update ();
        }
    }

    private void on_mark_spam () {
        mark_open_spam.begin (true);
    }

    private void on_print () {
        print_open_message.begin ();
    }

    private void on_zoom_in () {
        this.message_reader.zoom_in ();
    }

    private void on_zoom_out () {
        this.message_reader.zoom_out ();
    }

    private void on_zoom_reset () {
        this.message_reader.zoom_reset ();
    }

    private async void mark_open_unread () {
        yield set_open_seen (false);
    }

    private async void mark_open_read () {
        yield set_open_seen (true);
    }

    private async void set_open_seen (bool seen) {
        var account = this.selected_account;
        var message = this.open_message;
        var folder = folder_for_message (message);
        if (this.mail_session == null || account == null || folder == null || message == null)
            return;
        if (message.outgoing)
            return;
        if (message.seen == seen)
            return;

        cancel_mark_seen ();
        message.seen = seen;
        if (seen) {
            if (folder.unread > 0)
                folder.unread--;
        } else {
            folder.unread++;
        }
        this.open_conversation?.refresh ();
        refresh_folder_badge (folder);
        update_message_actions ();

        try {
            yield this.mail_session.set_message_seen (account, folder, message.uid, seen);
            refresh_folder_badge (folder);
        } catch (Error e) {
            message.seen = !seen;
            if (seen)
                folder.unread++;
            else if (folder.unread > 0)
                folder.unread--;
            this.open_conversation?.refresh ();
            refresh_folder_badge (folder);
            update_message_actions ();
            this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                timeout = 4,
            });
        }
    }

    private async void mark_open_spam (bool spam) {
        var message = this.open_message;
        if (message == null || message.outgoing)
            return;

        var folder = folder_for_message (message);
        if (spam) {
            if (folder != null && folder.kind == FolderKind.JUNK)
                return;
            var junk = find_folder_kind (FolderKind.JUNK);
            if (junk == null) {
                this.toast_overlay.add_toast (new Adw.Toast (_("No Junk folder was found for this account.")) {
                    timeout = 4,
                });
                return;
            }
            yield transfer_open_message (junk);
        } else {
            if (folder == null || folder.kind != FolderKind.JUNK)
                return;
            var inbox = find_folder_kind (FolderKind.INBOX);
            if (inbox == null) {
                this.toast_overlay.add_toast (new Adw.Toast (_("No Inbox folder was found for this account.")) {
                    timeout = 4,
                });
                return;
            }
            yield transfer_open_message (inbox);
        }
    }

    private async void print_open_message () {
        if (this.open_message == null)
            return;
        if (this.open_content == null)
            yield load_message_body (this.open_message);
        if (this.open_content == null)
            return;
        this.message_reader.print (this);
    }

    private async void open_message_window (Message message) {
        var app = get_application () as Application;
        var account = this.selected_account;
        var folder = folder_for_message (message);
        if (app == null || this.mail_session == null || account == null || folder == null)
            return;

        MessageContent? content = this.open_content;
        if (content == null || content.uid != message.uid)
            content = this.mail_session.peek_body (account, folder, message.uid);
        if (content == null) {
            try {
                content = yield this.mail_session.load_message (account, folder, message.uid);
            } catch (Error e) {
                this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                    timeout = 4,
                });
                return;
            }
        }

        var win = new MessageWindow (
            app,
            this.mail_session,
            app.accounts,
            account,
            folder,
            folders_from_tree (),
            message,
            content
        );
        win.folder_changed.connect (() => {
            var source = folder_for_message (message);
            if (this.selected_account != null && source != null)
                hide_message (this.selected_account, source, message.uid, !message.seen);
        });
        win.flags_changed.connect (() => {
            this.open_conversation?.refresh ();
            refresh_thread_rows ();
            update_message_actions ();
            sync_bookmarks_folder ();
        });
        win.present ();
    }

    private async void move_open_message () {
        var message = this.open_message;
        var folder = folder_for_message (message);
        if (message == null || folder == null)
            return;

        var destination = yield pick_folder (this, folders_from_tree (), folder);
        if (destination == null)
            return;

        yield transfer_open_message (destination);
    }

    private async void archive_open_message () {
        var message = this.open_message;
        var folder = folder_for_message (message);
        if (message == null || message.outgoing)
            return;
        if (folder != null && folder.is_archive_mailbox)
            return;

        var archive = find_archive_folder ();
        if (archive == null) {
            this.toast_overlay.add_toast (new Adw.Toast (_("No Archive folder was found for this account.")) {
                timeout = 4,
            });
            return;
        }

        yield transfer_open_message (archive);
    }

    private async void delete_open_message () {
        var account = this.selected_account;
        var message = this.open_message;
        var folder = folder_for_message (message);
        if (this.mail_session == null || account == null || folder == null || message == null)
            return;

        var trash = find_folder_kind (FolderKind.TRASH);
        if (trash != null && folder.full_name != trash.full_name) {
            yield transfer_open_message (trash);
            return;
        }

        var uid = message.uid;
        var unseen = !message.seen;
        hide_message (account, folder, uid, unseen);

        try {
            yield this.mail_session.delete_message (account, folder, uid, null);
            refresh_folder_badge (folder);
        } catch (Error e) {
            this.hidden_uids.remove (hide_key (account, folder, uid));
            this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                timeout = 4,
            });
            refresh_open_folder.begin (true, false);
        }
    }

    private async void transfer_open_message (Folder destination) {
        var account = this.selected_account;
        var message = this.open_message;
        var folder = folder_for_message (message);
        if (this.mail_session == null || account == null || folder == null || message == null)
            return;
        if (folder.full_name == destination.full_name)
            return;

        var old_uid = message.uid;
        var old_full = message.folder_full_name;
        var old_name = message.folder_name;
        var old_outgoing = message.outgoing;
        var old_local = message.local_only;
        var unseen = !message.seen;
        var conversation = this.open_conversation;

        cancel_mark_seen ();
        this.hidden_uids.set (hide_key (account, folder, old_uid), 1);
        remove_from_folder_cache (account, folder, old_uid);
        if (folder.total > 0)
            folder.total--;
        if (unseen && folder.unread > 0)
            folder.unread--;
        refresh_folder_badge (folder);

        Conversation.apply_folder (message, destination, null);
        message.local_only = true;
        this.mail_session.rekey_body (account, folder, old_uid, destination, old_uid);
        if (conversation != null)
            conversation.refresh ();
        add_to_folder_cache (account, destination, message);
        destination.total++;
        if (unseen)
            destination.unread++;
        refresh_folder_badge (destination);

        if (conversation != null && conversation.listed_count == 0) {
            drop_conversation_row (conversation);
        } else if (conversation != null) {
            open_listed_message (conversation);
        }

        try {
            var new_uid = yield this.mail_session.move_message (account, folder, old_uid, destination);
            if (new_uid != old_uid) {
                message.uid = new_uid;
                this.mail_session.rekey_body (account, destination, old_uid, destination, new_uid);
                if (this.open_message_uid == old_uid)
                    this.open_message_uid = new_uid;
                if (conversation != null)
                    conversation.refresh ();
            }
            restore_folder_counts_from_cache (account, destination);
            refresh_folder_badge (folder);
            refresh_folder_badge (destination);
        } catch (Error e) {
            this.hidden_uids.remove (hide_key (account, folder, old_uid));
            Conversation.apply_folder (message, folder, old_uid);
            message.folder_name = old_name;
            message.outgoing = old_outgoing;
            message.local_only = old_local;
            if (old_full != null)
                message.folder_full_name = old_full;
            this.mail_session.rekey_body (account, destination, message.uid, folder, old_uid);
            remove_from_folder_cache (account, destination, message.uid);
            add_to_folder_cache (account, folder, message);
            folder.total++;
            if (unseen)
                folder.unread++;
            if (destination.total > 0)
                destination.total--;
            if (unseen && destination.unread > 0)
                destination.unread--;
            if (conversation != null) {
                conversation.refresh ();
                if (conversation.listed_count > 0) {
                    this.open_conversation = conversation;
                    this.open_content = null;
                    this.open_message = message;
                    this.open_message_uid = old_uid;
                    fill_thread_list (conversation, message);
                    load_message_body.begin (message);
                }
            }
            refresh_folder_badge (folder);
            refresh_folder_badge (destination);
            this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                timeout = 4,
            });
            refresh_open_folder.begin (true, false);
        }
    }

    private async void move_selected_messages () {
        var messages = action_target_messages ();
        if (messages.length == 0)
            return;

        Folder? current = folder_for_message (messages[0]);
        if (current == null)
            current = this.selected_folder;
        var destination = yield pick_folder (this, folders_from_tree (), current, messages.length);
        if (destination == null)
            return;

        transfer_selected_messages (destination, false);
    }

    private async void archive_selected_messages () {
        var archive = find_archive_folder ();
        if (archive == null) {
            this.toast_overlay.add_toast (new Adw.Toast (_("No Archive folder was found for this account.")) {
                timeout = 4,
            });
            return;
        }

        transfer_selected_messages (archive, true);
    }

    private async void delete_selected_messages () {
        var account = this.selected_account;
        if (this.mail_session == null || account == null)
            return;

        var from_thread = is_thread_bulk ();
        var trash = find_folder_kind (FolderKind.TRASH);
        var messages = action_target_messages ();
        if (messages.length == 0)
            return;

        var to_trash = new GenericArray<Message> ();
        for (uint i = 0; i < messages.length; i++) {
            var folder = folder_for_message (messages[i]);
            if (folder != null && trash != null && folder.full_name == trash.full_name)
                continue;
            to_trash.add (messages[i]);
        }

        if (to_trash.length > 0 && trash != null) {
            transfer_messages (to_trash, trash, false, from_thread);
            return;
        }

        cancel_mark_seen ();
        var groups = group_messages_by_folder (messages);
        var conversations = selected_conversations ();
        if (from_thread) {
            conversations = new GenericArray<Conversation> ();
            if (this.open_conversation != null)
                conversations.add (this.open_conversation);
        }
        for (uint c = 0; c < conversations.length; c++) {
            for (uint i = 0; i < messages.length; i++)
                conversations[c].remove_uid (messages[i].uid, messages[i].folder_full_name);
        }
        for (uint i = 0; i < messages.length; i++) {
            var message = messages[i];
            var folder = folder_for_message (message);
            if (folder == null)
                continue;
            this.hidden_uids.set (hide_key (account, folder, message.uid), 1);
            remove_from_folder_cache (account, folder, message.uid);
            remove_from_search_results (message.uid, folder.full_name);
            if (folder.total > 0)
                folder.total--;
            if (!message.seen && folder.unread > 0)
                folder.unread--;
            refresh_folder_badge (folder);
        }

        if (from_thread)
            finish_thread_bulk ();
        else
            finish_conversation_bulk ();

        for (uint i = 0; i < groups.length; i++) {
            var folder = groups[i].folder;
            var uids = groups[i].uids;
            this.mail_session.delete_uids.begin (
                account,
                folder,
                uids,
                null,
                (obj, res) => {
                    try {
                        this.mail_session.delete_uids.end (res);
                        refresh_folder_badge (folder);
                    } catch (Error e) {
                        this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                            timeout = 4,
                        });
                        refresh_open_folder.begin (true, false);
                    }
                }
            );
        }
    }

    private async void set_selected_seen (bool seen) {
        yield set_conversations_seen (selected_conversations (), seen);
    }

    private void mark_row_read (MessageRow row) {
        var conversation = row.conversation;
        if (conversation == null || conversation.seen)
            return;
        var listed = new GenericArray<Conversation> ();
        listed.add (conversation);
        set_conversations_seen.begin (listed, true);
    }

    private async void set_conversations_seen (GenericArray<Conversation> conversations, bool seen) {
        var account = this.selected_account;
        if (this.mail_session == null || account == null)
            return;

        var messages = new GenericArray<Message> ();
        for (uint i = 0; i < conversations.length; i++) {
            var listed = listed_messages_of (conversations[i]);
            for (uint j = 0; j < listed.length; j++)
                messages.add (listed[j]);
        }
        var changed = new GenericArray<Message> ();
        for (uint i = 0; i < messages.length; i++) {
            var message = messages[i];
            if (message.outgoing || message.seen == seen)
                continue;
            message.seen = seen;
            var folder = folder_for_message (message);
            if (folder != null) {
                if (seen) {
                    if (folder.unread > 0)
                        folder.unread--;
                } else {
                    folder.unread++;
                }
                refresh_folder_badge (folder);
            }
            changed.add (message);
        }

        for (uint i = 0; i < conversations.length; i++)
            conversations[i].refresh ();
        update_message_actions ();

        if (this.unread_only) {
            redisplay_current_list ();
            show_reader_empty ();
            update_message_actions ();
        }

        if (changed.length == 0)
            return;

        var groups = group_messages_by_folder (changed);
        for (uint i = 0; i < groups.length; i++) {
            var folder = groups[i].folder;
            var uids = groups[i].uids;
            this.mail_session.set_uids_seen.begin (
                account,
                folder,
                uids,
                seen,
                (obj, res) => {
                    try {
                        this.mail_session.set_uids_seen.end (res);
                        refresh_folder_badge (folder);
                    } catch (Error e) {
                        this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                            timeout = 4,
                        });
                    }
                }
            );
        }
    }

    private void transfer_selected_messages (Folder destination, bool archive_only) {
        transfer_messages (action_target_messages (), destination, archive_only, is_thread_bulk ());
    }

    private void transfer_messages (
        GenericArray<Message> messages,
        Folder destination,
        bool archive_only,
        bool from_thread
    ) {
        var account = this.selected_account;
        if (this.mail_session == null || account == null || messages.length == 0)
            return;

        cancel_mark_seen ();
        var groups = new GenericArray<FolderMessageGroup> ();
        var index = new HashTable<string, uint> (str_hash, str_equal);
        uint moved = 0;
        for (uint i = 0; i < messages.length; i++) {
            var message = messages[i];
            var from = folder_for_message (message);
            if (from == null || from.full_name == destination.full_name)
                continue;
            if (archive_only && (message.outgoing || from.is_archive_mailbox))
                continue;

            uint g;
            if (index.contains (from.full_name)) {
                g = index.get (from.full_name);
            } else {
                g = groups.length;
                var group = new FolderMessageGroup ();
                group.folder = from;
                group.messages = new GenericArray<Message> ();
                group.uids = new GenericArray<string> ();
                groups.add (group);
                index.set (from.full_name, g);
            }
            groups[g].uids.add (message.uid);
            groups[g].messages.add (message);
            apply_local_move (account, message, from, destination);
            moved++;
        }

        if (moved == 0)
            return;

        this.open_conversation?.refresh ();
        if (from_thread)
            finish_thread_bulk ();
        else
            finish_conversation_bulk ();

        for (uint i = 0; i < groups.length; i++) {
            refresh_folder_badge (groups[i].folder);
            this.mail_session.enqueue_move_messages (
                account,
                groups[i].folder,
                destination,
                groups[i].uids,
                groups[i].messages
            );
        }
        refresh_folder_badge (destination);
    }

    private void finish_thread_bulk () {
        var conversation = this.open_conversation;
        if (conversation == null) {
            update_message_actions ();
            return;
        }

        conversation.refresh ();
        if (conversation.listed_count == 0) {
            drop_conversation_row (conversation);
            return;
        }

        var keep = this.open_message;
        if (keep == null || !conversation.contains (keep.uid, keep.folder_full_name)) {
            keep = viewing_bookmarks ()
                ? conversation.pick_flagged () ?? conversation.pick_open ()
                : conversation.pick_open ();
        }
        if (keep == null)
            return;

        this.open_message = keep;
        this.open_message_uid = keep.uid;
        fill_thread_list (conversation, keep);
        update_message_actions ();
    }

    private void finish_conversation_bulk () {
        var conversations = selected_conversations ();
        var drop = new GenericArray<Conversation> ();
        for (uint i = 0; i < conversations.length; i++) {
            conversations[i].refresh ();
            if (conversations[i].listed_count == 0)
                drop.add (conversations[i]);
        }

        if (drop.length > 0)
            drop_conversations (drop);
        else {
            this.message_selection.unselect_all ();
            this.selection_anchor = Gtk.INVALID_LIST_POSITION;
            if (this.message_store.n_items > 0)
                show_reader_empty ();
            update_message_actions ();
        }
    }

    private void apply_local_move (Account account, Message message, Folder from, Folder destination) {
        var old_uid = message.uid;
        var unseen = !message.seen;
        this.hidden_uids.set (hide_key (account, from, old_uid), 1);
        remove_from_folder_cache (account, from, old_uid);
        remove_from_search_results (old_uid, from.full_name);
        if (from.total > 0)
            from.total--;
        if (unseen && from.unread > 0)
            from.unread--;
        Conversation.apply_folder (message, destination, null);
        message.local_only = true;
        this.mail_session.rekey_body (account, from, old_uid, destination, old_uid);
        add_to_folder_cache (account, destination, message);
        destination.total++;
        if (unseen)
            destination.unread++;
    }

    private void drop_conversations (GenericArray<Conversation> conversations) {
        if (conversations.length == 0) {
            this.message_selection.unselect_all ();
            this.selection_anchor = Gtk.INVALID_LIST_POSITION;
            this.open_content = null;
            this.open_message = null;
            this.open_message_uid = null;
            this.open_conversation = null;
            show_reader_empty ();
            update_message_actions ();
            return;
        }

        var drop = new HashTable<Conversation, uint8> (direct_hash, direct_equal);
        for (uint i = 0; i < conversations.length; i++)
            drop.set (conversations[i], 1);

        this.restoring_selection = true;
        var n = this.message_store.n_items;
        var keepers = new GenericArray<Object> ();
        for (uint i = 0; i < n; i++) {
            var item = this.message_store.get_item (i) as Conversation;
            if (item != null && drop.contains (item))
                continue;
            keepers.add (item);
        }
        var items = new Object[keepers.length];
        for (uint i = 0; i < keepers.length; i++)
            items[i] = keepers[i];
        this.message_store.splice (0, n, items);
        this.message_selection.unselect_all ();
        this.selection_anchor = Gtk.INVALID_LIST_POSITION;
        this.restoring_selection = false;
        this.open_content = null;
        this.open_message = null;
        this.open_message_uid = null;
        this.open_conversation = null;
        set_message_actions_enabled (false);
        if (this.message_store.n_items == 0) {
            if (this.unread_only) {
                show_conversation_placeholder (
                    _("No Unread Messages"),
                    _("Turn off the unread filter to see the rest of this folder.")
                );
            } else {
                show_conversation_placeholder (
                    _("No Messages"),
                    _("This folder is empty.")
                );
            }
        } else {
            show_reader_empty ();
        }
        update_message_actions ();
    }

    private GenericArray<FolderMessageGroup> group_messages_by_folder (GenericArray<Message> messages) {
        var groups = new GenericArray<FolderMessageGroup> ();
        var index = new HashTable<string, uint> (str_hash, str_equal);
        for (uint i = 0; i < messages.length; i++) {
            var folder = folder_for_message (messages[i]);
            if (folder == null || folder.is_virtual_view)
                continue;
            uint g;
            if (index.contains (folder.full_name)) {
                g = index.get (folder.full_name);
            } else {
                g = groups.length;
                var group = new FolderMessageGroup ();
                group.folder = folder;
                group.messages = new GenericArray<Message> ();
                group.uids = new GenericArray<string> ();
                groups.add (group);
                index.set (folder.full_name, g);
            }
            groups[g].messages.add (messages[i]);
            groups[g].uids.add (messages[i].uid);
        }
        return groups;
    }

    private void remove_from_search_results (string uid, string? folder_full_name) {
        if (this.search_results == null)
            return;
        for (uint i = 0; i < this.search_results.length; i++) {
            var item = this.search_results[i];
            if (item.uid != uid)
                continue;
            if (folder_full_name != null && (item.folder_full_name ?? "") != folder_full_name)
                continue;
            this.search_results.remove_index (i);
            return;
        }
    }

    private void on_transfer_failed (Account account, Folder from, GenericArray<string> uids, string error) {
        for (uint i = 0; i < uids.length; i++)
            this.hidden_uids.remove (hide_key (account, from, uids[i]));
        this.toast_overlay.add_toast (new Adw.Toast (error) {
            timeout = 4,
        });
        refresh_open_folder.begin (true, false);
    }

    private Folder? find_archive_folder () {
        return find_folder_kind (FolderKind.ARCHIVE) ?? find_folder_kind (FolderKind.ALL);
    }

    private Folder? find_folder_kind (FolderKind kind) {
        var folders = folders_from_tree ();
        for (uint i = 0; i < folders.length; i++) {
            if (folders[i].kind == kind)
                return folders[i];
        }
        return null;
    }

    private void hide_message (Account account, Folder folder, string uid, bool unseen) {
        this.hidden_uids.set (hide_key (account, folder, uid), 1);

        var cache = this.message_cache.get (message_cache_key (account, folder));
        if (cache != null) {
            for (uint i = 0; i < cache.length; i++) {
                if (cache[i].uid != uid)
                    continue;
                cache.remove_index (i);
                break;
            }
        }

        if (this.search_results != null) {
            for (uint i = 0; i < this.search_results.length; i++) {
                var item = this.search_results[i];
                if (item.uid != uid)
                    continue;
                if ((item.folder_full_name ?? "") != folder.full_name)
                    continue;
                this.search_results.remove_index (i);
                break;
            }
        }

        if (folder.total > 0)
            folder.total--;
        if (unseen && folder.unread > 0)
            folder.unread--;
        refresh_folder_badge (folder);
        remove_message_from_list (uid, folder.full_name);
    }

    private void remove_from_folder_cache (Account account, Folder folder, string uid) {
        var cache = this.message_cache.get (message_cache_key (account, folder));
        if (cache == null)
            return;

        for (uint i = 0; i < cache.length; i++) {
            if (cache[i].uid != uid)
                continue;
            cache.remove_index (i);
            return;
        }
    }

    private void add_to_folder_cache (Account account, Folder folder, Message message) {
        var key = message_cache_key (account, folder);
        var cache = this.message_cache.get (key);
        if (cache == null)
            return;

        for (uint i = 0; i < cache.length; i++) {
            if (cache[i].uid == message.uid
                && (cache[i].folder_full_name ?? "") == (message.folder_full_name ?? ""))
                return;
        }
        cache.add (message);
    }

    private void restore_folder_counts_from_cache (Account account, Folder folder) {
        var cache = this.message_cache.get (message_cache_key (account, folder));
        if (cache == null)
            return;

        int total;
        int unread;
        message_counts (cache, out total, out unread);
        folder.unread = unread;
        folder.total = total;
    }

    private void drop_conversation_row (Conversation conversation) {
        uint index = Gtk.INVALID_LIST_POSITION;
        for (uint i = 0; i < this.message_store.n_items; i++) {
            if (this.message_store.get_item (i) == conversation) {
                index = i;
                break;
            }
        }

        this.open_content = null;
        this.open_message = null;
        this.open_message_uid = null;
        this.open_conversation = null;
        set_message_actions_enabled (false);

        if (index == Gtk.INVALID_LIST_POSITION) {
            if (this.message_store.n_items == 0)
                show_reader_empty ();
            return;
        }

        this.restoring_selection = true;
        this.message_store.remove (index);
        if (this.message_store.n_items == 0) {
            this.restoring_selection = false;
            show_reader_empty ();
            return;
        }

        var next = uint.min (index, this.message_store.n_items - 1);
        select_only_position (next);
        this.restoring_selection = false;
        on_message_selection_changed ();
    }

    private void open_listed_message (Conversation conversation) {
        var next = pick_listed_open (conversation);
        if (next == null)
            return;

        this.open_conversation = conversation;
        fill_thread_list (conversation, next);

        if (this.open_message == next
            && this.open_message_uid == next.uid
            && (this.open_message.folder_full_name ?? "") == (next.folder_full_name ?? "")
            && this.reader_bin.child == this.reader_pane) {
            update_message_actions ();
            return;
        }

        this.open_content = null;
        this.open_message = next;
        this.open_message_uid = next.uid;
        cancel_mark_seen ();
        load_message_body.begin (next);
    }

    private void remove_message_from_list (string uid, string? folder_full_name = null) {
        uint index = Gtk.INVALID_LIST_POSITION;
        Conversation? conversation = null;
        for (uint i = 0; i < this.message_store.n_items; i++) {
            var item = this.message_store.get_item (i) as Conversation;
            if (item == null || !item.contains (uid, folder_full_name))
                continue;
            index = i;
            conversation = item;
            break;
        }

        var closing = this.open_message != null && this.open_message.uid == uid
            && (folder_full_name == null || (this.open_message.folder_full_name ?? "") == folder_full_name);

        if (conversation != null && conversation.remove_uid (uid, folder_full_name) && conversation.listed_count > 0) {
            if (closing)
                open_listed_message (conversation);
            else if (this.open_conversation == conversation && this.open_message != null)
                fill_thread_list (conversation, this.open_message);
            return;
        }

        this.open_content = null;
        this.open_message = null;
        this.open_message_uid = null;
        this.open_conversation = null;
        set_message_actions_enabled (false);

        if (index == Gtk.INVALID_LIST_POSITION) {
            if (this.message_store.n_items == 0)
                show_reader_empty ();
            return;
        }

        this.restoring_selection = true;
        this.message_store.remove (index);
        if (this.message_store.n_items == 0) {
            this.restoring_selection = false;
            show_reader_empty ();
            return;
        }

        var next = uint.min (index, this.message_store.n_items - 1);
        select_only_position (next);
        this.restoring_selection = false;
        on_message_selection_changed ();
    }

    public static async Folder? pick_folder (Gtk.Widget parent, GenericArray<Folder> folders, Folder? current, uint count = 1) {
        var description = count > 1
            ? _("Choose where to move the selected messages.")
            : _("Choose where to move this message.");
        var dialog = new Adw.AlertDialog (_("Move to Folder"), description) {
            default_response = "move",
            close_response = "cancel",
        };
        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("move", _("Move"));
        dialog.set_response_appearance ("move", Adw.ResponseAppearance.SUGGESTED);
        dialog.set_response_enabled ("move", false);

        var list = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.SINGLE,
            valign = Gtk.Align.START,
        };
        list.add_css_class ("boxed-list");
        Folder? picked = null;
        for (uint i = 0; i < folders.length; i++) {
            var folder = folders[i];
            if (current != null && folder.full_name == current.full_name)
                continue;
            if (folder.is_virtual_view)
                continue;

            list.append (new FolderPickRow (folder));
        }

        list.row_selected.connect ((row) => {
            var pick = row as FolderPickRow;
            picked = pick != null ? pick.mail_folder : null;
            dialog.set_response_enabled ("move", picked != null);
        });

        var scrolled = new Gtk.ScrolledWindow () {
            min_content_height = 280,
            child = list,
        };
        dialog.extra_child = scrolled;

        var response = yield dialog.choose (parent, null);
        return response == "move" ? picked : null;
    }

    private void set_message_actions_enabled (bool enabled) {
        if (!enabled) {
            string[] names = {
                "reply", "reply-all", "forward", "send-again", "move", "archive", "delete",
                "mark-unread", "mark-read", "bookmark", "mark-important", "mark-spam", "print"
            };
            foreach (var name in names)
                set_win_action_enabled (name, false);
            this.message_reader?.set_bookmarked (false);
            this.message_reader?.set_seen (false, false);
            this.message_reader?.set_outgoing (false);
            this.message_reader?.set_important (false, false);
            return;
        }

        update_message_actions ();
    }

    private async void respond_invitation (Invitation invitation, InvitationStatus status) {
        var app = get_application () as Application;
        var account = this.selected_account;
        if (app == null || account == null)
            return;

        var identity = this.mail_session.get_identity (account);
        var email = identity != null ? identity.address : account.email;
        if (email == null || email.length == 0) {
            this.toast_overlay.add_toast (new Adw.Toast (_("This account has no sending identity.")) {
                timeout = 4,
            });
            return;
        }

        this.message_reader.set_invitation_busy (true);
        try {
            yield app.calendars.respond (invitation, email, account.source_uid, status, null);
            this.message_reader.show_invitation_status (status);
            if (status != InvitationStatus.TENTATIVE)
                delete_open_message.begin ();
        } catch (Error e) {
            this.message_reader.set_invitation_busy (false);
            this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                timeout = 4,
            });
        }
    }

    private void update_message_actions () {
        var thread_n = selected_thread_count ();
        if (this.thread_action_bar != null)
            this.thread_action_bar.visible = thread_n > 1 && this.thread_revealer.reveal_child;

        var n = selected_count ();
        if (n > 1 && thread_n <= 1) {
            var messages = selected_listed_messages ();
            var has = messages.length > 0;
            var any_unread = false;
            var any_read = false;
            var any_archive = false;
            for (uint i = 0; i < messages.length; i++) {
                var message = messages[i];
                if (message.outgoing)
                    continue;
                if (message.seen)
                    any_read = true;
                else
                    any_unread = true;
                var folder = folder_for_message (message);
                if (folder == null || !folder.is_archive_mailbox)
                    any_archive = true;
            }
            set_win_action_enabled ("reply", false);
            set_win_action_enabled ("reply-all", false);
            set_win_action_enabled ("forward", false);
            set_win_action_enabled ("send-again", false);
            set_win_action_enabled ("move", has);
            set_win_action_enabled ("archive", any_archive);
            set_win_action_enabled ("delete", has);
            set_win_action_enabled ("mark-unread", any_read);
            set_win_action_enabled ("mark-read", any_unread);
            set_win_action_enabled ("bookmark", false);
            set_win_action_enabled ("mark-important", false);
            set_win_action_enabled ("mark-spam", false);
            set_win_action_enabled ("print", false);
            sync_action_bars (!any_unread && any_read, any_unread || any_read, false, false, false, false);
            return;
        }

        var bulk_messages = thread_n > 1 ? selected_thread_messages () : null;
        var message = this.open_message;
        var folder = folder_for_message (message);
        var has_message = message != null;
        var has = has_message && this.open_content != null;
        var outgoing = has_message && message.outgoing;
        var archived = folder != null && folder.is_archive_mailbox;
        var junk = folder != null && folder.kind == FolderKind.JUNK;
        var any_archive = has_message && !outgoing && !archived;
        if (bulk_messages != null) {
            any_archive = false;
            for (uint i = 0; i < bulk_messages.length; i++) {
                if (bulk_messages[i].outgoing)
                    continue;
                var source = folder_for_message (bulk_messages[i]);
                if (source == null || !source.is_archive_mailbox)
                    any_archive = true;
            }
        }

        set_win_action_enabled ("reply", has_message && !outgoing);
        set_win_action_enabled ("reply-all", has_message);
        set_win_action_enabled ("forward", has_message);
        set_win_action_enabled ("send-again", has_message && outgoing && !message.is_placeholder);
        set_win_action_enabled ("move", has_message || thread_n > 1);
        set_win_action_enabled ("archive", any_archive);
        set_win_action_enabled ("delete", has_message || thread_n > 1);
        set_win_action_enabled ("mark-unread", has_message && !outgoing && message.seen);
        set_win_action_enabled ("mark-read", has_message && !outgoing && !message.seen);
        set_win_action_enabled ("bookmark", has_message && !message.is_placeholder);
        var can_important = is_gmail_account () && has_message && !outgoing && !message.is_placeholder
            && find_folder_kind (FolderKind.IMPORTANT) != null;
        set_win_action_enabled ("mark-important", can_important);
        set_win_action_enabled ("mark-spam", has_message && !outgoing && !junk && find_folder_kind (FolderKind.JUNK) != null);
        set_win_action_enabled ("print", has);
        sync_action_bars (
            has_message && message.seen,
            has_message && !outgoing,
            has_message && message.flagged,
            can_important,
            has_message && message.important,
            outgoing
        );
    }

    private void sync_action_bars (
        bool seen,
        bool seen_enabled,
        bool bookmarked,
        bool important_visible,
        bool important,
        bool outgoing
    ) {
        this.message_reader?.set_seen (seen, seen_enabled);
        this.message_reader?.set_outgoing (outgoing);
        this.message_reader?.set_bookmarked (bookmarked);
        this.message_reader?.set_important (important_visible, important);
    }

    private void set_win_action_enabled (string name, bool enabled) {
        var action = lookup_action (name) as SimpleAction;
        action?.set_enabled (enabled);
    }

    private void restart_sync_timer () {
        if (this.sync_source != 0) {
            Source.remove (this.sync_source);
            this.sync_source = 0;
        }

        var seconds = this.settings.get_int ("sync-interval");
        if (seconds <= 0)
            return;
        seconds = seconds.clamp (60, 1800);
        this.sync_source = Timeout.add_seconds (seconds, () => {
            Utils.sync_log ("timer fired (%d s) pump=%s queue=%u".printf (
                seconds,
                this.sync_pump_running ? "busy" : "idle",
                this.sync_jobs.length
            ));
            schedule_mail_check (false);
            return Source.CONTINUE;
        });
    }

    private uint show_sync_status (string text) {
        this.sync_status_token++;
        this.folder_status_label.label = text;
        this.folder_status_bar.visible = true;
        return this.sync_status_token;
    }

    private void hide_sync_status (uint token) {
        if (token != this.sync_status_token)
            return;

        this.folder_status_bar.visible = false;
    }

    private void append_folder_row (Folder folder) {
        var row = new FolderRow (folder);
        connect_folder_row (row);
        this.folder_list.append (row);
    }

    private void connect_folder_row (FolderRow row) {
        row.context_pressed.connect ((x, y) => popup_folder_menu (row, x, y));
        row.expander_toggled.connect (() => toggle_folder_collapsed (row));
    }

    private bool on_folder_key_pressed (uint keyval) {
        var row = this.folder_list.get_selected_row () as FolderRow;
        if (row == null || !row.folder.has_children)
            return false;

        var collapsed = folder_is_collapsed (row.folder);
        if ((keyval == Gdk.Key.Left || keyval == Gdk.Key.minus) && !collapsed) {
            toggle_folder_collapsed (row);
            return true;
        }
        if ((keyval == Gdk.Key.Right || keyval == Gdk.Key.plus) && collapsed) {
            toggle_folder_collapsed (row);
            return true;
        }
        return false;
    }

    private string collapse_key (string folder_full) {
        var account = this.selected_account;
        var uid = account != null ? (account.source_uid ?? account.uid) : "";
        return "%s\n%s".printf (uid, folder_full);
    }

    private bool folder_is_collapsed (Folder folder) {
        return this.collapsed_folders.contains (collapse_key (folder.full_name));
    }

    private void toggle_folder_collapsed (FolderRow row) {
        if (!row.folder.has_children)
            return;

        var key = collapse_key (row.folder.full_name);
        if (this.collapsed_folders.contains (key))
            this.collapsed_folders.remove (key);
        else
            this.collapsed_folders.set (key, 1);
        persist_collapsed_folders ();
        apply_folder_collapse ();
    }

    private void persist_collapsed_folders () {
        string[] items = {};
        this.collapsed_folders.foreach ((key, value) => {
            items += key;
        });
        this.settings.set_strv ("collapsed-folders", items);
    }

    private void refresh_folder_expanders () {
        for (int i = 0; this.folder_list.get_row_at_index (i) != null; i++) {
            var row = this.folder_list.get_row_at_index (i) as FolderRow;
            if (row == null)
                continue;
            var has_children = next_folder_indent (i) > row.folder.indent;
            row.update_expander (has_children, !folder_is_collapsed (row.folder));
        }
    }

    private uint next_folder_indent (int index) {
        for (int i = index + 1; this.folder_list.get_row_at_index (i) != null; i++) {
            var row = this.folder_list.get_row_at_index (i) as FolderRow;
            if (row == null || row.folder.is_virtual_view)
                continue;
            return row.folder.indent;
        }
        return 0;
    }

    private void expand_ancestors_of (string? full_name) {
        if (full_name == null || full_name.length == 0)
            return;

        var changed = false;
        for (int i = 0; this.folder_list.get_row_at_index (i) != null; i++) {
            var row = this.folder_list.get_row_at_index (i) as FolderRow;
            if (row == null || !row.folder.has_children)
                continue;
            if (!full_name.has_prefix (row.folder.full_name + "/"))
                continue;
            var key = collapse_key (row.folder.full_name);
            if (!this.collapsed_folders.contains (key))
                continue;
            this.collapsed_folders.remove (key);
            changed = true;
        }
        if (changed)
            persist_collapsed_folders ();
    }

    private void apply_folder_collapse () {
        Folder? hide_under = null;
        uint hide_indent = 0;
        FolderRow? hidden_selected = null;
        FolderRow? collapse_parent = null;

        for (int i = 0; this.folder_list.get_row_at_index (i) != null; i++) {
            var row = this.folder_list.get_row_at_index (i) as FolderRow;
            if (row == null)
                continue;

            var folder = row.folder;
            if (hide_under != null && folder.indent > hide_indent) {
                row.visible = false;
                if (row.is_selected ())
                    hidden_selected = collapse_parent;
                continue;
            }

            hide_under = null;
            row.visible = true;
            row.update_expander (folder.has_children, !folder_is_collapsed (folder));

            if (folder.has_children && folder_is_collapsed (folder)) {
                hide_under = folder;
                hide_indent = folder.indent;
                collapse_parent = row;
            }
        }

        if (hidden_selected != null) {
            this.folder_list.select_row (hidden_selected);
            on_folder_activated (hidden_selected);
        }
    }

    private void connect_thread_context (ThreadRow row, Conversation conversation) {
        var open_click = new Gtk.GestureClick () {
            button = Gdk.BUTTON_PRIMARY,
        };
        open_click.set_propagation_phase (Gtk.PropagationPhase.CAPTURE);
        open_click.pressed.connect ((n) => {
            if (n != 2)
                return;
            if (!row.is_selected ()) {
                this.thread_list.select_row (row);
                on_thread_row_selected (row);
            }
            if (!row.message.is_placeholder)
                open_message_window.begin (row.message);
            open_click.set_state (Gtk.EventSequenceState.CLAIMED);
        });
        row.add_controller (open_click);
        row.context_pressed.connect ((x, y) => {
            if (!row.is_selected ())
                this.thread_list.select_row (row);
            on_thread_row_selected (row);
            if (is_thread_bulk ())
                popup_bulk_message_menu (row, x, y);
            else
                popup_message_menu (row, x, y, conversation, row.message);
        });
    }

    private void popup_folder_menu (FolderRow row, double x, double y) {
        var folder = row.folder;
        if (folder.is_virtual_view) {
            popup_bookmarks_folder_menu (row, x, y);
            return;
        }
        var trash = find_folder_kind (FolderKind.TRASH);
        var in_trash = trash != null && folder.is_inside (trash);
        var group = new SimpleActionGroup ();

        var create = new SimpleAction ("new-subfolder", null);
        create.set_enabled (folder.can_create_children);
        create.activate.connect (() => prompt_new_subfolder.begin (folder));
        group.add_action (create);

        var rename = new SimpleAction ("rename", null);
        rename.set_enabled (!folder.is_server_required && !in_trash);
        rename.activate.connect (() => prompt_rename_folder.begin (folder));
        group.add_action (rename);

        var toggle = new SimpleAction ("toggle-collapse", null);
        toggle.set_enabled (folder.has_children);
        toggle.activate.connect (() => toggle_folder_collapsed (row));
        group.add_action (toggle);

        var mark_read = new SimpleAction ("mark-all-read", null);
        mark_read.activate.connect (() => mark_folder_seen.begin (folder, true));
        group.add_action (mark_read);

        var mark_unread = new SimpleAction ("mark-all-unread", null);
        mark_unread.activate.connect (() => mark_folder_seen.begin (folder, false));
        group.add_action (mark_unread);

        var trash_action = new SimpleAction ("move-trash", null);
        trash_action.set_enabled (!folder.is_server_required && !in_trash);
        trash_action.activate.connect (() => confirm_trash_folder.begin (folder));
        group.add_action (trash_action);

        var empty = new SimpleAction ("empty", null);
        var can_empty = folder.kind == FolderKind.TRASH || folder.kind == FolderKind.JUNK;
        empty.set_enabled (can_empty);
        empty.activate.connect (() => confirm_empty_folder.begin (folder));
        group.add_action (empty);

        var restore = new SimpleAction ("restore", null);
        restore.set_enabled (in_trash);
        restore.activate.connect (() => restore_trashed_folder.begin (folder));
        group.add_action (restore);

        var purge = new SimpleAction ("delete-forever", null);
        purge.set_enabled (in_trash);
        purge.activate.connect (() => confirm_purge_folder.begin (folder));
        group.add_action (purge);

        var menu = new Menu ();
        var create_section = new Menu ();
        create_section.append (_("New Subfolder…"), "ctx.new-subfolder");
        if (!folder.is_server_required && !in_trash)
            create_section.append (_("Rename…"), "ctx.rename");
        menu.append_section (null, create_section);

        if (folder.has_children) {
            var tree_section = new Menu ();
            tree_section.append (
                folder_is_collapsed (folder) ? _("Expand") : _("Collapse"),
                "ctx.toggle-collapse"
            );
            menu.append_section (null, tree_section);
        }

        var seen_section = new Menu ();
        seen_section.append (_("Mark All as Read"), "ctx.mark-all-read");
        seen_section.append (_("Mark All as Unread"), "ctx.mark-all-unread");
        menu.append_section (null, seen_section);

        var delete_section = new Menu ();
        if (can_empty)
            delete_section.append (_("Empty"), "ctx.empty");
        if (in_trash) {
            delete_section.append (_("Restore"), "ctx.restore");
            delete_section.append (_("Delete Permanently"), "ctx.delete-forever");
        } else if (!folder.is_server_required) {
            delete_section.append (_("Move to Trash"), "ctx.move-trash");
        }
        if (delete_section.get_n_items () > 0)
            menu.append_section (null, delete_section);

        popup_context_menu (row, menu, group, x, y);
    }

    private void popup_bookmarks_folder_menu (FolderRow row, double x, double y) {
        var group = new SimpleActionGroup ();
        var clear = new SimpleAction ("remove-all-bookmarks", null);
        clear.activate.connect (() => confirm_remove_all_bookmarks.begin ());
        group.add_action (clear);

        var menu = new Menu ();
        var section = new Menu ();
        section.append (_("Remove All Bookmarks"), "ctx.remove-all-bookmarks");
        menu.append_section (null, section);
        popup_context_menu (row, menu, group, x, y);
    }

    private async void confirm_remove_all_bookmarks () {
        var messages = collect_flagged_messages ();
        if (messages.length == 0)
            return;

        var dialog = new Adw.AlertDialog (
            _("Remove all bookmarks?"),
            _("Every bookmarked message in this account will lose its bookmark. The messages themselves will not be deleted.")
        );
        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("remove", _("Remove All Bookmarks"));
        dialog.set_response_appearance ("remove", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.default_response = "cancel";
        dialog.close_response = "cancel";
        var response = yield dialog.choose (this, null);
        if (response != "remove")
            return;

        yield set_messages_flagged (messages, false);
    }

    private async void confirm_empty_folder (Folder folder) {
        var account = this.selected_account;
        if (this.mail_session == null || account == null)
            return;

        var dialog = new Adw.AlertDialog (
            _("Empty “%s”?").printf (folder.name),
            _("All messages in this folder will be permanently deleted. This cannot be undone.")
        );
        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("empty", _("Empty"));
        dialog.set_response_appearance ("empty", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.default_response = "cancel";
        dialog.close_response = "cancel";
        var response = yield dialog.choose (this, null);
        if (response != "empty")
            return;

        var key = message_cache_key (account, folder);
        var cache = this.message_cache.get (key);
        if (cache != null) {
            for (uint i = 0; i < cache.length; i++)
                this.hidden_uids.set (hide_key (account, folder, cache[i].uid), 1);
            this.message_cache.set (key, new GenericArray<Message> ());
        }
        folder.unread = 0;
        folder.total = 0;
        refresh_folder_badge (folder);

        if (is_current_folder (folder)) {
            this.open_content = null;
            this.open_message = null;
            this.open_message_uid = null;
            this.open_conversation = null;
            this.message_store.remove_all ();
            show_conversation_placeholder (
                _("No Messages"),
                _("This folder is empty.")
            );
            set_message_actions_enabled (false);
        }
        sync_bookmarks_folder ();

        try {
            yield this.mail_session.empty_folder (account, folder);
            refresh_folder_badge (folder);
        } catch (Error e) {
            this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                timeout = 5,
            });
            if (is_current_folder (folder))
                yield refresh_open_folder (true, false);
        }
    }

    private void popup_message_menu (
        Gtk.Widget widget,
        double x,
        double y,
        Conversation? conversation,
        Message? specific
    ) {
        if (conversation == null)
            return;

        if (specific == null && selected_count () > 1) {
            popup_bulk_message_menu (widget, x, y);
            return;
        }

        var message = specific ?? pick_listed_open (conversation);
        if (message == null)
            return;

        var folder = folder_for_message (message);
        var outgoing = message.outgoing;
        var archived = folder != null && folder.is_archive_mailbox;
        var junk = folder != null && folder.kind == FolderKind.JUNK;
        var has_junk = find_folder_kind (FolderKind.JUNK) != null;
        var group = new SimpleActionGroup ();

        add_ctx_action (group, "reply", !outgoing, () => on_reply ());
        add_ctx_action (group, "reply-all", true, () => on_reply_all ());
        add_ctx_action (group, "forward", true, () => on_forward ());
        add_ctx_action (group, "send-again", outgoing && !message.is_placeholder, () => on_send_again ());
        add_ctx_action (group, "move", true, () => on_move ());
        add_ctx_action (group, "archive", !outgoing && !archived, () => on_archive ());
        add_ctx_action (group, "spam", !outgoing && !junk && has_junk, () => mark_open_spam.begin (true));
        add_ctx_action (group, "not-spam", !outgoing && junk, () => mark_open_spam.begin (false));
        add_ctx_action (group, "mark-read", !outgoing && !message.seen, () => mark_open_read.begin ());
        add_ctx_action (group, "mark-unread", !outgoing && message.seen, () => mark_open_unread.begin ());
        add_ctx_action (group, "bookmark", !message.is_placeholder, () => toggle_message_bookmark (message));
        add_ctx_action (group, "mark-important", is_gmail_account () && !outgoing && !message.is_placeholder
            && find_folder_kind (FolderKind.IMPORTANT) != null, () => toggle_message_important (message));
        add_ctx_action (group, "print", true, () => print_open_message.begin ());
        add_ctx_action (group, "delete", true, () => on_delete ());

        var menu = new Menu ();
        var compose = new Menu ();
        if (outgoing)
            compose.append (_("Send Again"), "ctx.send-again");
        else
            compose.append (_("Reply"), "ctx.reply");
        compose.append (_("Reply All"), "ctx.reply-all");
        compose.append (_("Forward"), "ctx.forward");
        menu.append_section (null, compose);

        var file = new Menu ();
        file.append (_("Move"), "ctx.move");
        if (!outgoing && !archived)
            file.append (_("Archive"), "ctx.archive");
        if (!outgoing && junk)
            file.append (_("Not Spam"), "ctx.not-spam");
        else if (!outgoing && has_junk)
            file.append (_("Mark as Spam"), "ctx.spam");
        menu.append_section (null, file);

        var flags = new Menu ();
        if (!outgoing && !message.seen)
            flags.append (_("Mark as Read"), "ctx.mark-read");
        if (!outgoing && message.seen)
            flags.append (_("Mark as Unread"), "ctx.mark-unread");
        if (!message.is_placeholder)
            flags.append (message.flagged ? _("Remove Bookmark") : _("Bookmark"), "ctx.bookmark");
        if (is_gmail_account () && !outgoing && !message.is_placeholder
            && find_folder_kind (FolderKind.IMPORTANT) != null)
            flags.append (message.important ? _("Not Important") : _("Mark as Important"), "ctx.mark-important");
        flags.append (_("Print"), "ctx.print");
        menu.append_section (null, flags);

        var remove = new Menu ();
        remove.append (_("Delete"), "ctx.delete");
        menu.append_section (null, remove);

        popup_context_menu (widget, menu, group, x, y);
    }

    private void popup_bulk_message_menu (Gtk.Widget widget, double x, double y) {
        var messages = action_target_messages ();
        if (messages.length == 0)
            return;

        var any_unread = false;
        var any_read = false;
        var any_archive = false;
        for (uint i = 0; i < messages.length; i++) {
            var message = messages[i];
            if (message.outgoing)
                continue;
            if (message.seen)
                any_read = true;
            else
                any_unread = true;
            var folder = folder_for_message (message);
            if (folder == null || !folder.is_archive_mailbox)
                any_archive = true;
        }

        var group = new SimpleActionGroup ();
        add_ctx_action (group, "move", true, () => on_move ());
        add_ctx_action (group, "archive", any_archive, () => on_archive ());
        add_ctx_action (group, "mark-read", any_unread, () => on_mark_read ());
        add_ctx_action (group, "mark-unread", any_read, () => on_mark_unread ());
        add_ctx_action (group, "delete", true, () => on_delete ());

        var menu = new Menu ();
        var file = new Menu ();
        file.append (_("Move"), "ctx.move");
        if (any_archive)
            file.append (_("Archive"), "ctx.archive");
        menu.append_section (null, file);

        var flags = new Menu ();
        if (any_unread)
            flags.append (_("Mark as Read"), "ctx.mark-read");
        if (any_read)
            flags.append (_("Mark as Unread"), "ctx.mark-unread");
        if (flags.get_n_items () > 0)
            menu.append_section (null, flags);

        var remove = new Menu ();
        remove.append (_("Delete"), "ctx.delete");
        menu.append_section (null, remove);

        popup_context_menu (widget, menu, group, x, y);
    }

    private delegate void ContextAction ();

    private static void add_ctx_action (
        SimpleActionGroup group,
        string name,
        bool enabled,
        owned ContextAction callback
    ) {
        var action = new SimpleAction (name, null);
        action.set_enabled (enabled);
        action.activate.connect (() => callback ());
        group.add_action (action);
    }

    private static Gtk.Button thread_action_button (string icon, string tooltip, string action) {
        var button = new Gtk.Button.from_icon_name (icon) {
            tooltip_text = tooltip,
            action_name = action,
            has_frame = false,
        };
        button.add_css_class ("flat");
        button.add_css_class ("message-action-button");
        return button;
    }

    private void popup_context_menu (
        Gtk.Widget widget,
        Menu menu,
        SimpleActionGroup group,
        double x,
        double y
    ) {
        dismiss_context_menu ();
        this.context_actions = group;
        this.context_host = widget;
        widget.insert_action_group ("ctx", group);
        insert_action_group ("ctx", group);

        var popover = new Gtk.PopoverMenu.from_model (menu) {
            has_arrow = false,
            halign = Gtk.Align.START,
        };
        popover.set_parent (widget);
        popover.set_pointing_to (Gdk.Rectangle () {
            x = (int) x,
            y = (int) y,
            width = 1,
            height = 1,
        });
        popover.closed.connect (() => {
            Idle.add (() => {
                if (this.context_menu == popover) {
                    this.context_menu = null;
                    if (popover.parent != null)
                        popover.unparent ();
                }
                return Source.REMOVE;
            });
        });
        this.context_menu = popover;
        popover.popup ();
    }

    private void dismiss_context_menu () {
        var popover = this.context_menu;
        this.context_menu = null;
        if (popover != null && popover.parent != null)
            popover.unparent ();
        if (this.context_host != null) {
            this.context_host.insert_action_group ("ctx", null);
            this.context_host = null;
        }
    }

    private async void prompt_new_subfolder (Folder parent) {
        var account = this.selected_account;
        if (this.mail_session == null || account == null)
            return;

        var dialog = new Adw.AlertDialog (
            _("New Subfolder"),
            _("The folder will be created under “%s”.").printf (parent.name)
        );
        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("create", _("Create"));
        dialog.set_response_appearance ("create", Adw.ResponseAppearance.SUGGESTED);
        dialog.default_response = "create";
        dialog.close_response = "cancel";
        dialog.set_response_enabled ("create", false);

        var name_row = new Adw.EntryRow () {
            title = _("Name"),
        };
        name_row.notify["text"].connect (() => {
            dialog.set_response_enabled ("create", name_row.text.strip ().length > 0);
        });
        dialog.extra_child = name_row;

        var response = yield dialog.choose (this, null);
        if (response != "create")
            return;

        try {
            yield this.mail_session.create_mailbox_folder (account, parent, name_row.text);
            yield refresh_folder_tree_now ();
        } catch (Error e) {
            this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                timeout = 5,
            });
        }
    }

    private async void prompt_rename_folder (Folder folder) {
        var account = this.selected_account;
        if (this.mail_session == null || account == null)
            return;

        var dialog = new Adw.AlertDialog (
            _("Rename Folder"),
            _("Choose a new name for “%s”.").printf (folder.name)
        );
        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("rename", _("Rename"));
        dialog.set_response_appearance ("rename", Adw.ResponseAppearance.SUGGESTED);
        dialog.default_response = "rename";
        dialog.close_response = "cancel";

        var name_row = new Adw.EntryRow () {
            title = _("Name"),
            text = folder.leaf_name,
        };
        name_row.notify["text"].connect (() => {
            var cleaned = name_row.text.strip ();
            dialog.set_response_enabled (
                "rename",
                cleaned.length > 0
                && !cleaned.contains ("/")
                && !cleaned.contains ("\\")
            );
        });
        dialog.extra_child = name_row;

        var response = yield dialog.choose (this, null);
        if (response != "rename")
            return;

        var cleaned = name_row.text.strip ();
        if (cleaned.length == 0 || cleaned.contains ("/") || cleaned.contains ("\\"))
            return;
        if (cleaned == folder.leaf_name)
            return;

        var parent = folder.parent_full_name;
        var dest = parent.length > 0 ? "%s/%s".printf (parent, cleaned) : cleaned;
        if (folder_path_taken (dest, folder)) {
            this.toast_overlay.add_toast (new Adw.Toast (
                _("A folder named “%s” already exists.").printf (cleaned)
            ) {
                timeout = 4,
            });
            return;
        }

        try {
            yield this.mail_session.rename_mailbox_folder (account, folder, dest);
            remap_folder_prefix (folder.full_name, dest);
            yield refresh_folder_tree_now ();
        } catch (Error e) {
            this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                timeout = 5,
            });
        }
    }

    private bool folder_path_taken (string full_name, Folder except) {
        var folders = folders_from_tree (false);
        for (uint i = 0; i < folders.length; i++) {
            if (folders[i] == except)
                continue;
            if (folders[i].full_name == full_name)
                return true;
        }
        return false;
    }

    private void remap_folder_prefix (string old_full, string new_full) {
        if (old_full == new_full)
            return;

        var account = this.selected_account;
        var uid = account != null ? (account.source_uid ?? account.uid) : "";

        remap_path_table (this.message_cache, uid, old_full, new_full, (messages) => {
            for (uint i = 0; i < messages.length; i++) {
                var message = messages[i];
                var name = message.folder_full_name;
                if (name == null || (name != old_full && !name.has_prefix (old_full + "/")))
                    continue;
                message.folder_full_name = new_full + name.substring (old_full.length);
                var slash = message.folder_full_name.last_index_of_char ('/');
                message.folder_name = slash < 0
                    ? message.folder_full_name
                    : message.folder_full_name.substring (slash + 1);
            }
        });
        remap_flag_table (this.hidden_uids, uid, old_full, new_full);
        remap_flag_table (this.collapsed_folders, uid, old_full, new_full);
        persist_collapsed_folders ();

        var last = this.settings.get_string ("last-folder");
        if (last == old_full)
            this.settings.set_string ("last-folder", new_full);
        else if (last.has_prefix (old_full + "/"))
            this.settings.set_string ("last-folder", new_full + last.substring (old_full.length));

        if (this.selected_folder != null) {
            var name = this.selected_folder.full_name;
            if (name == old_full || name.has_prefix (old_full + "/")) {
                this.selected_folder.full_name = new_full + name.substring (old_full.length);
                if (name == old_full)
                    this.selected_folder.name = new_full.substring (new_full.last_index_of_char ('/') + 1);
            }
        }

        if (this.open_message != null) {
            var name = this.open_message.folder_full_name;
            if (name != null && (name == old_full || name.has_prefix (old_full + "/"))) {
                this.open_message.folder_full_name = new_full + name.substring (old_full.length);
                var slash = this.open_message.folder_full_name.last_index_of_char ('/');
                this.open_message.folder_name = slash < 0
                    ? this.open_message.folder_full_name
                    : this.open_message.folder_full_name.substring (slash + 1);
            }
        }
    }

    private void remap_path_table (
        HashTable<string, GenericArray<Message>> table,
        string uid,
        string old_full,
        string new_full,
        owned FolderCacheRewrite rewrite
    ) {
        var from = new GenericArray<string> ();
        var payloads = new GenericArray<GenericArray<Message>> ();
        table.foreach ((key, messages) => {
            var rewritten = rewrite_account_path_key (key, uid, old_full, new_full);
            if (rewritten == null || rewritten == key)
                return;
            from.add (key);
            payloads.add (messages);
            rewrite (messages);
        });
        for (uint i = 0; i < from.length; i++) {
            table.remove (from[i]);
            var rewritten = rewrite_account_path_key (from[i], uid, old_full, new_full);
            if (rewritten != null)
                table.set (rewritten, payloads[i]);
        }
    }

    private delegate void FolderCacheRewrite (GenericArray<Message> messages);

    private void remap_flag_table (
        HashTable<string, uint8> table,
        string uid,
        string old_full,
        string new_full
    ) {
        var from = new GenericArray<string> ();
        table.foreach ((key, value) => {
            var rewritten = rewrite_account_path_key (key, uid, old_full, new_full);
            if (rewritten != null && rewritten != key)
                from.add (key);
        });
        for (uint i = 0; i < from.length; i++) {
            var rewritten = rewrite_account_path_key (from[i], uid, old_full, new_full);
            table.remove (from[i]);
            if (rewritten != null)
                table.set (rewritten, 1);
        }
    }

    private static string? rewrite_account_path_key (
        string key,
        string uid,
        string old_full,
        string new_full
    ) {
        var prefix = uid + "\n";
        if (!key.has_prefix (prefix))
            return null;

        var rest = key.substring (prefix.length);
        var nl = rest.index_of_char ('\n');
        var folder_part = nl < 0 ? rest : rest.substring (0, nl);
        var tail = nl < 0 ? "" : rest.substring (nl);
        if (folder_part != old_full && !folder_part.has_prefix (old_full + "/"))
            return null;
        return prefix + new_full + folder_part.substring (old_full.length) + tail;
    }

    private async void confirm_trash_folder (Folder folder) {
        var account = this.selected_account;
        var trash = find_folder_kind (FolderKind.TRASH);
        if (this.mail_session == null || account == null)
            return;

        var nested = folder_has_visible_children (folder);
        var dialog = new Adw.AlertDialog (
            _("Move “%s” to Trash?").printf (folder.name),
            nested
                ? _("The folder and its subfolders will be moved to Trash. You can restore them from there.")
                : _("The folder will be moved to Trash. You can restore it from there.")
        );
        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("trash", _("Move to Trash"));
        dialog.set_response_appearance ("trash", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.default_response = "trash";
        dialog.close_response = "cancel";
        var trash_response = yield dialog.choose (this, null);
        if (trash_response != "trash")
            return;

        try {
            if (trash == null) {
                yield this.mail_session.delete_mailbox_folder (account, folder);
            } else {
                var dest = MailSession.unique_child_path (
                    trash.full_name,
                    folder.leaf_name,
                    folders_from_tree ()
                );
                yield this.mail_session.rename_mailbox_folder (account, folder, dest);
            }
            yield after_folder_removed (folder);
        } catch (Error e) {
            this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                timeout = 5,
            });
        }
    }

    private async void restore_trashed_folder (Folder folder) {
        var account = this.selected_account;
        var trash = find_folder_kind (FolderKind.TRASH);
        if (this.mail_session == null || account == null || trash == null)
            return;

        var inbox = find_folder_kind (FolderKind.INBOX);
        var parent = inbox != null ? inbox.full_name : "";
        var dest = MailSession.unique_child_path (parent, folder.leaf_name, folders_from_tree ());
        try {
            yield this.mail_session.rename_mailbox_folder (account, folder, dest);
            yield refresh_folder_tree_now ();
        } catch (Error e) {
            this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                timeout = 5,
            });
        }
    }

    private async void confirm_purge_folder (Folder folder) {
        var account = this.selected_account;
        if (this.mail_session == null || account == null)
            return;

        var dialog = new Adw.AlertDialog (
            _("Delete “%s” permanently?").printf (folder.name),
            _("This cannot be undone.")
        );
        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("delete", _("Delete Permanently"));
        dialog.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.default_response = "cancel";
        dialog.close_response = "cancel";
        var purge_response = yield dialog.choose (this, null);
        if (purge_response != "delete")
            return;

        try {
            yield this.mail_session.delete_mailbox_folder (account, folder);
            yield after_folder_removed (folder);
        } catch (Error e) {
            this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                timeout = 5,
            });
        }
    }

    private async void after_folder_removed (Folder folder) {
        var selected = this.selected_folder;
        var lost = selected != null
            && (selected.full_name == folder.full_name || selected.is_inside (folder));
        yield refresh_folder_tree_now ();
        if (!lost)
            return;

        var inbox = find_folder_kind (FolderKind.INBOX);
        if (inbox != null) {
            for (int i = 0; this.folder_list.get_row_at_index (i) != null; i++) {
                var row = this.folder_list.get_row_at_index (i) as FolderRow;
                if (row == null || row.folder.full_name != inbox.full_name)
                    continue;
                this.folder_list.select_row (row);
                on_folder_activated (row);
                break;
            }
        }
    }

    private async void mark_folder_seen (Folder folder, bool seen) {
        var account = this.selected_account;
        if (this.mail_session == null || account == null)
            return;

        apply_folder_seen_locally (folder, seen);
        try {
            yield this.mail_session.set_folder_seen (account, folder, seen);
            refresh_folder_badge (folder);
        } catch (Error e) {
            this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                timeout = 5,
            });
            yield refresh_open_folder (true, false);
        }
    }

    private void apply_folder_seen_locally (Folder folder, bool seen) {
        var account = this.selected_account;
        if (account == null)
            return;

        var cache = this.message_cache.get (message_cache_key (account, folder));
        if (cache != null) {
            for (uint i = 0; i < cache.length; i++)
                cache[i].seen = seen;
        }

        if (this.open_message != null) {
            var open_folder = folder_for_message (this.open_message);
            if (open_folder != null && open_folder.full_name == folder.full_name)
                this.open_message.seen = seen;
        }

        if (is_current_folder (folder)) {
            for (uint i = 0; i < this.message_store.n_items; i++) {
                var conversation = this.message_store.get_item (i) as Conversation;
                if (conversation == null)
                    continue;
                for (uint j = 0; j < conversation.messages.length; j++) {
                    if ((conversation.messages[j].folder_full_name ?? "") == folder.full_name)
                        conversation.messages[j].seen = seen;
                }
                conversation.refresh ();
            }
        }

        if (seen)
            folder.unread = 0;
        else if (folder.total > folder.unread)
            folder.unread = folder.total;
        refresh_folder_badge (folder);
        update_message_actions ();
    }

    private async void refresh_folder_tree_now () {
        var account = this.selected_account;
        if (this.mail_session == null || account == null)
            return;

        try {
            var folders = yield this.mail_session.list_folders (account, null, true);
            if (!is_current_account (account) || folders.length == 0)
                return;
            apply_folder_tree (folders);
            remember_folder_tree (account, folders);
        } catch (Error e) {
            this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                timeout = 5,
            });
        }
    }

    private bool folder_has_visible_children (Folder folder) {
        var folders = folders_from_tree ();
        for (uint i = 0; i < folders.length; i++) {
            if (folders[i].is_inside (folder))
                return true;
        }
        return false;
    }

    private void on_refresh () {
        refresh_now_all ();
    }

    public void refresh_now () {
        refresh_now_all ();
    }

    private void refresh_now_all () {
        Utils.sync_log ("manual refresh");
        this.last_full_align = 0;
        schedule_mail_check (true);
        if (this.selected_folder != null)
            boost_folder_sync (this.selected_folder);
    }

    private void schedule_mail_check (bool force_tree) {
        var account = this.selected_account;
        if (this.mail_session == null || account == null || account.kind == AccountKind.LOCAL || !account.has_mail)
            return;

        var full_due = force_tree || this.last_full_align == 0
            || (Utils.sync_tick () - this.last_full_align) >= (int64) FULL_ALIGN_SECONDS * 1000 * 1000;
        if (full_due)
            enqueue_sync_job (SYNC_KIND_TREE, null, RANK_TREE);
        enqueue_new_mail_sync ();
    }

    private GenericArray<Folder> folders_from_tree (bool include_virtual = true) {
        var folders = new GenericArray<Folder> ();
        for (int i = 0; this.folder_list.get_row_at_index (i) != null; i++) {
            var row = this.folder_list.get_row_at_index (i) as FolderRow;
            if (row == null)
                continue;
            if (!include_virtual && row.folder.is_virtual_view)
                continue;
            folders.add (row.folder);
        }
        return folders;
    }

    private void refresh_folder_badge (Folder folder) {
        for (int i = 0; this.folder_list.get_row_at_index (i) != null; i++) {
            var row = this.folder_list.get_row_at_index (i) as FolderRow;
            if (row == null)
                continue;
            if (row.folder != folder && row.folder.full_name != folder.full_name)
                continue;

            if (row.folder != folder) {
                row.folder.unread = folder.unread;
                row.folder.total = folder.total;
            }
            row.update_unread ();
            break;
        }

        if (is_current_folder (folder) && this.search_text.length == 0) {
            this.conversation_title.subtitle = folder_counts_label (folder);
            apply_offline_heading ();
        }
    }

    private void apply_folder_tree (GenericArray<Folder> folders) {
        var current = folders_from_tree (false);
        var same = current.length == folders.length;
        if (same) {
            for (uint i = 0; i < folders.length; i++) {
                if (current[i].full_name != folders[i].full_name) {
                    same = false;
                    break;
                }
            }
        }

        if (same) {
            var account = this.selected_account;
            for (uint i = 0; i < folders.length; i++) {
                var cached = account != null
                    ? this.message_cache.get (message_cache_key (account, current[i]))
                    : null;
                if (cached != null) {
                    int total;
                    int unread;
                    message_counts (cached, out total, out unread);
                    if (MailSession.folder_is_heavy (current[i]) && folders[i].total >= 0) {
                        current[i].total = folders[i].total;
                        current[i].unread = folders[i].unread >= 0 ? folders[i].unread : unread;
                    } else {
                        current[i].unread = unread;
                        current[i].total = total;
                    }
                } else {
                    current[i].unread = folders[i].unread;
                    current[i].total = folders[i].total;
                }
                current[i].indent = folders[i].indent;
                current[i].flags = folders[i].flags;
                current[i].watch_new_mail = folders[i].watch_new_mail;
                refresh_folder_badge (current[i]);
            }
            sync_bookmarks_folder ();
            refresh_folder_expanders ();
            apply_folder_collapse ();
            return;
        }

        var selected_name = this.selected_folder != null ? this.selected_folder.full_name : null;
        var account = this.selected_account;
        this.folder_list.remove_all ();
        for (uint i = 0; i < folders.length; i++) {
            var folder = folders[i];
            var cached = account != null
                ? this.message_cache.get (message_cache_key (account, folder))
                : null;
            if (cached != null) {
                int total;
                int unread;
                message_counts (cached, out total, out unread);
                if (MailSession.folder_is_heavy (folder) && folder.total >= 0) {
                    folder.unread = folder.unread >= 0 ? folder.unread : unread;
                } else {
                    folder.unread = unread;
                    folder.total = total;
                }
            }
            append_folder_row (folder);
        }

        sync_bookmarks_folder ();
        refresh_folder_expanders ();
        expand_ancestors_of (selected_name);
        apply_folder_collapse ();

        if (selected_name == null)
            return;

        for (int i = 0; this.folder_list.get_row_at_index (i) != null; i++) {
            var row = this.folder_list.get_row_at_index (i) as FolderRow;
            if (row == null || row.folder.full_name != selected_name)
                continue;

            this.selected_folder = row.folder;
            if (is_searching)
                break;

            this.folder_list.select_row (row);
            this.conversation_title.title = row.folder.name;
            this.conversation_title.subtitle = folder_counts_label (row.folder);
            apply_offline_heading ();
            break;
        }
        watch_new_mail_folders.begin ();
    }

    private async void refresh_open_folder (bool quiet, bool from_server = true) {
        var account = this.selected_account;
        var folder = this.selected_folder;
        if (this.mail_session == null || account == null || folder == null)
            return;
        if (this.search_text.length > 0)
            return;
        if (folder.is_virtual_view) {
            show_bookmarked_messages ();
            return;
        }

        if (from_server) {
            if (this.selected_folder != null)
                boost_folder_sync (this.selected_folder);
            return;
        }

        if (quiet && this.conversation_sync_spinner.visible)
            return;

        try {
            var cached = this.message_cache.get (message_cache_key (account, folder));
            var messages = yield this.mail_session.list_messages (
                account,
                folder,
                false,
                null,
                true,
                cached
            );
            if (!is_current_folder (folder))
                return;

            display_messages (account, folder, messages);
            refresh_folder_badge (folder);
        } catch (Error e) {
            if (!quiet && !(e is IOError.CANCELLED)) {
                this.toast_overlay.add_toast (new Adw.Toast (e.message) {
                    timeout = 4,
                });
            }
        }
    }

    private bool on_close_request () {
        var app = get_application () as Application;
        if (app != null && !app.shutting_down) {
            app.request_quit.begin ();
            return true;
        }

        persist_window_state ();
        teardown_on_close ();
        return false;
    }

    private void persist_window_state () {
        this.settings.set_int ("window-width", get_width ().clamp (WINDOW_MIN_WIDTH, 4000));
        this.settings.set_int ("window-height", get_height ().clamp (WINDOW_MIN_HEIGHT, 4000));
        this.settings.set_boolean ("window-maximized", maximized);
        this.settings.set_boolean ("show-folder-sidebar", this.sidebar_button.active);
        this.settings.set_int ("folder-pane-width", this.content_split.position.clamp (FOLDER_PANE_MIN, FOLDER_PANE_MAX));
        this.settings.set_int ("message-pane-width", this.message_split.position.clamp (MESSAGE_PANE_MIN, MESSAGE_PANE_MAX));
    }

    private void teardown_on_close () {
        if (this.tearing_down)
            return;
        this.tearing_down = true;

        if (this.sync_source != 0) {
            Source.remove (this.sync_source);
            this.sync_source = 0;
        }
        if (this.search_source != 0) {
            Source.remove (this.search_source);
            this.search_source = 0;
        }
        this.search_generation++;
        cancel_mark_seen ();
        if (this.conversation_index_source != 0) {
            Source.remove (this.conversation_index_source);
            this.conversation_index_source = 0;
        }
        this.idle_cancellable?.cancel ();
        this.sync_jobs = new GenericArray<MailSyncJob> ();

        this.restoring_selection = true;
        this.message_list.factory = null;
        this.message_list.model = null;
        this.message_store.remove_all ();

        if (this.mail_session != null) {
            this.mail_session.folder_changed.disconnect (on_camel_folder_changed);
            this.mail_session.message_sent.disconnect (on_message_sent);
            this.mail_session.draft_saved.disconnect (on_draft_saved);
            this.mail_session.transfer_failed.disconnect (on_transfer_failed);
        }
    }
}

private class Mail.FolderPickRow : Adw.ActionRow {
    public Folder mail_folder { get; construct; }

    public FolderPickRow (Folder folder) {
        Object (
            mail_folder: folder,
            title: folder.name,
            activatable: true,
            use_markup: false
        );
        add_prefix (new Gtk.Image.from_icon_name (folder.icon_name));
    }
}

private class Mail.FolderMessageGroup {
    public Folder folder;
    public GenericArray<Message> messages;
    public GenericArray<string> uids;
}

private class Mail.MailSyncJob : Object {
    public int kind;
    public Folder? folder;
    public int rank;
}
